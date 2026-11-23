$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'This integration test requires Windows.' }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'VeyonUpdater.Security.ps1')
$sourcePath = if ($env:VEYON_SOURCE) { $env:VEYON_SOURCE } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'Veyon-AutoUpdate.ps1' }
$tokens = $null
$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Updater syntax is invalid.' }
$definitions = ($tree.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst]
} | ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($definitions))

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('Veyon runtime smoke test ' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$fixtureExe = Join-Path $temporary 'argument fixture.exe'
$regExe = Join-Path ([Environment]::SystemDirectory) 'reg.exe'
$taskKillExe = Join-Path ([Environment]::SystemDirectory) 'taskkill.exe'
$registrySuffix = 'Software\Veyon Runtime Test ' + [guid]::NewGuid().ToString('N')
$registryPath = 'HKCU:\' + $registrySuffix
$nativeRegistryPath = 'HKCU\' + $registrySuffix
$protectedTestRoot = $null
$script:VeyonRuntimeLock = $null
$script:VeyonRuntimeRoot = $null

# This test isolates process argument handling. ACL checks are tested with the
# installer; the only extra executable here is this locally compiled fixture.
function Assert-VeyonTrustedExecutable {
    param([string]$Path)
    if ($Path -notin @($fixtureExe, $regExe, $taskKillExe)) { throw 'Unexpected test executable.' }
}

try {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
public static class VeyonRuntimeArgumentFixture {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--sleep") { Thread.Sleep(60000); return 0; }
        if (args.Length == 1 && args[0] == "--exit-failure") return 7;
        if (args.Length == 1 && args[0] == "--large") { Console.Write(new string('x', 2 * 1024 * 1024)); return 0; }
        foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        return 0;
    }
}
'@ -OutputAssembly $fixtureExe -OutputType ConsoleApplication

    $arguments = @('', 'ordinary', 'path with spaces', 'C:\trailing slash\', 'embedded"quote', 'slash\"quote', "single'quote", '&|<>^%!()', 'Unicode äöü 日本語', 'last')
    $result = Invoke-VeyonNativeProcess -File $fixtureExe -ArgList $arguments -CaptureOutput
    Assert-True ($result.ExitCode -eq 0) 'Argument fixture failed.'
    $lines = @($result.Output.TrimEnd([char[]]@("`r", "`n")) -split '\r?\n')
    Assert-True ($lines.Count -eq $arguments.Count) 'Native argument count changed.'
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        $actual = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($lines[$i]))
        Assert-True ($actual -ceq $arguments[$i]) "Native argument $i changed."
    }
    Write-Host 'PASS: real native argument roundtrip'

    New-Item -Path $registryPath -Force | Out-Null
    New-ItemProperty -LiteralPath $registryPath -Name 'BackupTest' -Value 'value with spaces' -PropertyType String | Out-Null
    $exportFile = Join-Path $temporary 'registry backup with spaces.reg'
    $exitCode = Invoke-RegistryExport -RegistryKey $nativeRegistryPath -OutputPath $exportFile
    Assert-True ($exitCode -eq 0) 'Real registry export returned failure.'
    $export = Get-Content -LiteralPath $exportFile -Raw
    Assert-True ($export.Contains('[HKEY_CURRENT_USER\' + $registrySuffix + ']')) 'Registry key with spaces was not exported.'
    Assert-True ($export.Contains('"BackupTest"="value with spaces"')) 'Registry value was not preserved.'
    Write-Host 'PASS: real reg.exe export with spaces in key and destination'

    $timedOut = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-VeyonNativeProcess -File $fixtureExe -ArgList @('--sleep') -TimeoutSeconds 1 | Out-Null }
    catch { $timedOut = $_.Exception.Message -match 'Zeitlimit' }
    Assert-True $timedOut 'Hung process did not fail at its time limit.'
    Assert-True ($watch.Elapsed.TotalSeconds -lt 40) 'Timeout cleanup exceeded its bound.'
    Assert-True (-not (Get-Process | Where-Object { try { $_.Path -eq $fixtureExe } catch { $false } })) 'Timed-out fixture is still running.'
    Write-Host 'PASS: timed-out process is stopped'

    $oversized = $false
    try { Invoke-VeyonNativeProcess -File $fixtureExe -ArgList @('--large') -CaptureOutput | Out-Null }
    catch { $oversized = $_.Exception.Message -match 'Groessenlimit' }
    Assert-True $oversized 'Oversized process output was accepted.'
    Write-Host 'PASS: process output size limit'

    $directRefused = $false
    try { & $sourcePath } catch { $directRefused = $_.Exception.Message -match 'offene Sperre' }
    Assert-True $directRefused 'Direct runtime invocation without the launcher lock was accepted.'
    Write-Host 'PASS: direct runtime requires the launcher lock'

    $protectedTestRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('VeyonUpdater-runtime-test-' + [guid]::NewGuid().ToString('N'))
    Initialize-VeyonProtectedRoot -Root $protectedTestRoot
    $script:VeyonRuntimeRoot = $protectedTestRoot
    $script:VeyonRuntimeLock = Enter-VeyonUpdateLock -Root $protectedTestRoot
    Assert-True ($null -ne $script:VeyonRuntimeLock) 'Runtime marker test could not acquire its lock.'
    $marker = Join-Path $protectedTestRoot 'native-operation.json'
    $result = Invoke-VeyonNativeProcess -File $fixtureExe -ArgList @('normal') -CaptureOutput
    Assert-True ($result.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $marker)) 'Completed process retained a marker.'
    $result = Invoke-VeyonNativeProcess -File $fixtureExe -ArgList @('--exit-failure')
    Assert-True ($result.ExitCode -eq 7 -and -not (Test-Path -LiteralPath $marker)) 'Normally completed nonzero exit retained a marker.'
    $timedOut = $false
    try { Invoke-VeyonNativeProcess -File $fixtureExe -ArgList @('--sleep') -TimeoutSeconds 1 | Out-Null }
    catch { $timedOut = $_.Exception.Message -match 'Zeitlimit' }
    Assert-True ($timedOut -and (Test-Path -LiteralPath $marker -PathType Leaf)) 'Uncertain native operation lost its recovery marker.'
    $operation = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    Assert-True ($operation.schema -eq 1 -and $operation.executable -ceq $fixtureExe) 'Recovery marker omitted the operation identity.'
    $script:VeyonRuntimeLock.Dispose()
    $script:VeyonRuntimeLock = $null
    $blocked = $false
    try {
        $unexpectedLock = Enter-VeyonUpdateLock -Root $protectedTestRoot
        if ($unexpectedLock) { $unexpectedLock.Dispose() }
    } catch { $blocked = $true }
    Assert-True $blocked 'Recovery marker did not block the next update.'
    Write-Host 'PASS: durable native-operation marker and fail-closed recovery'
} finally {
    if ($script:VeyonRuntimeLock) { $script:VeyonRuntimeLock.Dispose(); $script:VeyonRuntimeLock = $null }
    $script:VeyonRuntimeRoot = $null
    if ($protectedTestRoot -and (Test-Path -LiteralPath $protectedTestRoot)) { [IO.Directory]::Delete($protectedTestRoot, $true) }

    if (Test-Path -LiteralPath $registryPath) { Remove-Item -LiteralPath $registryPath -Recurse -Force }
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
