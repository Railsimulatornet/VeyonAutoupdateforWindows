param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon-installer-check-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$oldPath = $env:PATH
$oldAudit = $env:INSTALLER_AUDIT
$oldMode = $env:INSTALLER_MODE
$oldNoPause = $env:VEYON_SETUP_NO_PAUSE
$env:VEYON_SETUP_NO_PAUSE = '1'
try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    $code = @'
using System;
using System.IO;
using System.Diagnostics;
class Stub {
    static int Main(string[] args) {
        string name = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName).ToLowerInvariant();
        File.AppendAllText(Environment.GetEnvironmentVariable("INSTALLER_AUDIT"), name + " " + String.Join(" ", args) + Environment.NewLine);
        string mode = Environment.GetEnvironmentVariable("INSTALLER_MODE");
        if (name == "powershell") {
            if (mode == "task-fail" && Array.Exists(args, a => a.EndsWith("Register-Veyon-AutoUpdateTask.ps1"))) return 1;
            if (mode == "dry-run-fail" && Array.Exists(args, a => a == "-Testlauf")) return 1;
        }
        return 0;
    }
}
'@
    $source = Join-Path $temporary 'Stub.cs'
    [IO.File]::WriteAllText($source, $code)
    $stub = Join-Path $temporary 'Stub.exe'
    & $compiler /nologo /target:exe "/out:$stub" $source
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile isolated command doubles.' }
    foreach ($mode in @('success', 'copy-fail', 'task-fail', 'dry-run-fail', 'missing-script', 'missing-task-script')) {
        $caseRoot = Join-Path $temporary $mode
        [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
        foreach ($command in @('net','powershell')) {
            [IO.File]::Copy($stub, (Join-Path $caseRoot ($command + '.exe')))
        }
        $destination = Join-Path $caseRoot 'destination'
        if ($mode -eq 'copy-fail') { [IO.File]::WriteAllText($destination, 'BLOCKED') }
        $installerText = [IO.File]::ReadAllText((Join-Path $PackageRoot 'Install-Veyon-AutoUpdate.cmd'))
        $original = 'set "DST_DIR=C:\ProgramData\Veyon\Update"'
        if (-not $installerText.Contains($original)) { throw 'Installer destination contract changed; review test isolation.' }
        $installerText = $installerText.Replace($original, ('set "DST_DIR=' + $destination + '"'))
        $installer = Join-Path $caseRoot 'Install-Veyon-AutoUpdate.cmd'
        [IO.File]::WriteAllText($installer, $installerText, [Text.UTF8Encoding]::new($false))
        [IO.File]::Copy((Join-Path $PackageRoot 'Remove-Veyon-AutoUpdate.cmd'), (Join-Path $caseRoot 'Remove-Veyon-AutoUpdate.cmd'))
        $taskScript = 'Register-Veyon-AutoUpdateTask.ps1'
        if ($mode -ne 'missing-task-script') {
            [IO.File]::Copy((Join-Path $PackageRoot $taskScript), (Join-Path $caseRoot $taskScript))
        }
        if ($mode -ne 'missing-script') {
            [IO.File]::Copy((Join-Path $PackageRoot 'Veyon-AutoUpdate.ps1'), (Join-Path $caseRoot 'Veyon-AutoUpdate.ps1'))
        }
        $env:PATH = $caseRoot + ';' + $oldPath
        $env:INSTALLER_AUDIT = Join-Path $caseRoot 'audit.txt'
        $env:INSTALLER_MODE = $mode
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $env:ComSpec
        $start.Arguments = '/d /c Install-Veyon-AutoUpdate.cmd'
        $start.WorkingDirectory = $caseRoot
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        $process.StandardInput.WriteLine('')
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Installer simulation timed out.' }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $expected = @{ success = 0; 'task-fail' = 3; 'dry-run-fail' = 4 }
        $expectedCode = if ($expected.ContainsKey($mode)) { $expected[$mode] } else { 2 }
        if ($process.ExitCode -ne $expectedCode) { throw "Unexpected result for ${mode}: $stdout $stderr" }
        if (($stdout -match '(?m)^FERTIG\.') -ne ($mode -eq 'success')) {
            throw "Incorrect success message for ${mode}: $stdout"
        }
        $audit = [IO.File]::ReadAllText($env:INSTALLER_AUDIT)
        $dryRunIndex = $audit.IndexOf('-Testlauf')
        $registrationIndex = $audit.IndexOf($taskScript)
        if ($mode -in @('success','task-fail')) {
            if ($dryRunIndex -lt 0 -or $registrationIndex -le $dryRunIndex) {
                throw "Expected a dry run before registration for $mode."
            }
        } elseif ($registrationIndex -ge 0 -or ($mode -ne 'dry-run-fail' -and $dryRunIndex -ge 0)) {
            throw "Unexpected PowerShell invocation for $mode."
        }
        if ($mode -eq 'success') {
            $copied = Join-Path $destination 'Veyon-AutoUpdate.ps1'
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($copied)) -ne [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $PackageRoot 'Veyon-AutoUpdate.ps1')))) { throw 'Installed script differs from package.' }
        }
        $process.Dispose()
        Write-Host "PASS: isolated installer $mode"
    }
} finally {
    $env:PATH = $oldPath
    $env:INSTALLER_AUDIT = $oldAudit
    $env:INSTALLER_MODE = $oldMode
    $env:VEYON_SETUP_NO_PAUSE = $oldNoPause
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
