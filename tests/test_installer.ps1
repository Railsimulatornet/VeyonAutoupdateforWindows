param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon-installer-check-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($temporary) | Out-Null
$oldPath = $env:PATH
$oldAudit = $env:INSTALLER_AUDIT
$oldMode = $env:INSTALLER_MODE
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
        if (name == "reg") Console.WriteLine("    HiberbootEnabled    REG_DWORD    0x1");
        if (name == "schtasks" && Environment.GetEnvironmentVariable("INSTALLER_MODE") == "task-fail") return 1;
        return 0;
    }
}
'@
    $source = Join-Path $temporary 'Stub.cs'
    [IO.File]::WriteAllText($source, $code)
    $stub = Join-Path $temporary 'Stub.exe'
    & $compiler /nologo /target:exe "/out:$stub" $source
    if ($LASTEXITCODE -ne 0) { throw 'Cannot compile isolated command doubles.' }
    foreach ($mode in @('success', 'copy-fail', 'task-fail', 'missing-script')) {
        $caseRoot = Join-Path $temporary $mode
        [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
        foreach ($command in @('net','reg','schtasks','powershell')) {
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
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Installer simulation timed out.' }
        $expected = if ($mode -eq 'success') { 0 } elseif ($mode -eq 'task-fail') { 3 } else { 2 }
        if ($process.ExitCode -ne $expected) { throw "Unexpected result for ${mode}: $stdout $stderr" }
        $audit = [IO.File]::ReadAllText($env:INSTALLER_AUDIT)
        if ($audit -match 'schtasks /Delete') { throw 'Installer deletes an existing task before replacement.' }
        if ($mode -in @('copy-fail','missing-script') -and $audit -match 'schtasks /Create') { throw 'Task changed after failed copy.' }
        if ($mode -eq 'success') {
            if ($audit -notmatch '/SC ONLOGON' -or $audit -notmatch '-Testlauf') { throw 'Missing configured trigger or dry run.' }
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
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
