$ErrorActionPreference = 'Stop'
$sourcePath = if ($env:VEYON_SOURCE) { $env:VEYON_SOURCE } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'Veyon-AutoUpdate.ps1' }
$tokens = $null
$errors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Updater syntax is invalid.' }
$definitions = ($tree.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
} | ForEach-Object { $_.Extent.Text }) -join "`n"

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-Scenario([string]$Name, [scriptblock]$Setup, [bool]$ExpectUpgrade, [bool]$ExpectFailure = $false) {
    . ([scriptblock]::Create($definitions))
    $Testlauf = $false
    $PkgId = 'VeyonSolutions.Veyon'
    $WingLog = 'synthetic.log'
    $installedVersion = [version]'4.9.0'
    $onlineVersion = [version]'4.10.0'
    $masterPresent = $false
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:VersionQueries = 0
    function Write-Log { param($Text) }
    function Trim-LogIfOversize { }
    function Resolve-WingetPath { return 'simulated-winget' }
    function Get-VeyonInstalledVersion {
        param([switch]$FilesOnly)
        $script:VersionQueries++
        if ($script:VersionQueries -eq 1) { return $installedVersion }
        return $onlineVersion
    }
    function Get-OnlineVersionStrict { param($WingetExe); return $onlineVersion }
    function Ensure-WingetSources { param($WingetExe); $script:Calls.Add('sources') }
    function Test-MasterPresent { return $masterPresent }
    function Backup-VeyonConfig { $script:Calls.Add('backup'); return $true }
    function Invoke-Proc { param($File, $ArgList); $script:Calls.Add(($ArgList -join ' ')); return 0 }
    . $Setup
    $failed = $false
    try { Invoke-VeyonUpdate } catch { $failed = $true }
    Assert-True ($failed -eq $ExpectFailure) "${Name}: unexpected failure result"
    $upgrades = @($script:Calls | Where-Object { $_ -like 'upgrade *' })
    Assert-True (($upgrades.Count -gt 0) -eq $ExpectUpgrade) "${Name}: unexpected upgrade"
    if ($ExpectUpgrade) {
        Assert-True ($script:Calls.IndexOf('backup') -lt $script:Calls.IndexOf($upgrades[0])) "${Name}: backup must precede upgrade"
        Assert-True ($upgrades[0] -match '--version 4.10.0 --source winget') "${Name}: upgrade must pin the checked version"
        Assert-True (($upgrades[0] -match '/NoMaster') -eq (-not $masterPresent)) "${Name}: must preserve existing installation components"
    }
    if ($Testlauf) { Assert-True ($script:Calls.Count -eq 0) 'Dry run invoked a modifying command' }
    if (-not $installedVersion) { Assert-True ($script:Calls.Count -eq 0) 'Unknown installation changed sources or configuration' }
    Write-Host "PASS: $Name"
}

Test-Scenario 'newer version' { } $true
Test-Scenario 'existing master' { $masterPresent = $true } $true
Test-Scenario 'missing winget' { function Resolve-WingetPath { return $null } } $false
Test-Scenario 'equal version' { $onlineVersion = [version]'4.9.0' } $false
Test-Scenario 'older online version' { $onlineVersion = [version]'4.8.0' } $false
Test-Scenario 'unknown installed version' { $installedVersion = $null } $false
Test-Scenario 'unknown online version' { $onlineVersion = $null } $false
Test-Scenario 'both versions unknown' { $installedVersion = $null; $onlineVersion = $null } $false
Test-Scenario 'backup refused' { function Backup-VeyonConfig { return $false } } $false $true
Test-Scenario 'backup exception' { function Backup-VeyonConfig { throw 'simulated backup failure' } } $false $true
Test-Scenario 'source update failed' { function Ensure-WingetSources { param($WingetExe); throw 'simulated source failure' } } $false $true
Test-Scenario 'upgrade failed' {
    function Invoke-Proc { param($File, $ArgList); $script:Calls.Add(($ArgList -join ' ')); return 1 }
} $true $true
Test-Scenario 'dry run' { $Testlauf = $true } $false
Test-Scenario 'missing post-upgrade version' {
    function Get-VeyonInstalledVersion {
        param([switch]$FilesOnly)
        $script:VersionQueries++
        if ($script:VersionQueries -eq 1) { return $installedVersion }
        return $null
    }
} $true $true

& {
    . ([scriptblock]::Create($definitions))
    foreach ($text in @('unknown', 'error 5.2', '4.9.0 beta', "4.9.0`n4.10.0")) {
        Assert-True ($null -eq (Parse-InstalledSemVer $text)) 'Ambiguous version was accepted'
    }
    Assert-True ((Parse-InstalledSemVer 'Veyon 4.9.0') -eq [version]'4.9.0') 'Valid version rejected'
    function winget-double { $global:LASTEXITCODE = 1; 'Version: 4.10.0' }
    Assert-True ($null -eq (Get-OnlineVersionStrict -WingetExe winget-double)) 'Failed query accepted'
    function winget-double { $global:LASTEXITCODE = 0; 'Version: 4.10.0'; 'Version: 4.11.0' }
    Assert-True ($null -eq (Get-OnlineVersionStrict -WingetExe winget-double)) 'Conflicting versions accepted'
    function winget-double { $global:LASTEXITCODE = 0; 'Version: 4.10.0' }
    Assert-True ((Get-OnlineVersionStrict -WingetExe winget-double) -eq [version]'4.10.0') 'Valid online version rejected'
    function Write-Log { param($Text) }
    $script:SourceCalls = [System.Collections.Generic.List[string]]::new()
    function Invoke-Proc { param($File, $ArgList); $script:SourceCalls.Add(($ArgList -join ' ')); return 1 }
    $failed = $false
    try { Ensure-WingetSources -WingetExe simulated-winget } catch { $failed = $true }
    Assert-True $failed 'Failed source update did not abort'
    Assert-True ($script:SourceCalls.Count -eq 1 -and $script:SourceCalls[0] -eq 'source update') 'Unexpected source reset'
    Write-Host 'PASS: strict version parsing'
}

& {
    . ([scriptblock]::Create($definitions))
    $BkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('veyon-registry-test-' + [guid]::NewGuid())
    [System.IO.Directory]::CreateDirectory($BkDir) | Out-Null
    function Write-Log { param($Text) }
    function Rotate-Backups { }
    function Get-VeyonCliPath { return $null }
    try {
        function Invoke-Proc {
            param($File, $ArgList)
            [System.IO.File]::WriteAllText($ArgList[2], "Windows Registry Editor Version 5.00`r`n`r`n[HKEY_LOCAL_MACHINE\SOFTWARE\Veyon Solutions]`r`n")
            return 0
        }
        Assert-True (Backup-VeyonConfig) 'Valid registry fallback rejected'
        function Invoke-Proc { param($File, $ArgList); [System.IO.File]::WriteAllText($ArgList[2], 'unrelated'); return 0 }
        Assert-True (-not (Backup-VeyonConfig)) 'Invalid registry export accepted'
        function Invoke-Proc { param($File, $ArgList); return 0 }
        Assert-True (-not (Backup-VeyonConfig)) 'Missing registry export accepted'
        Write-Host 'PASS: registry fallback validation'
    } finally { [System.IO.Directory]::Delete($BkDir, $true) }
}

& {
    . ([scriptblock]::Create($definitions))
    $BkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('veyon-backup-test-' + [guid]::NewGuid())
    [System.IO.Directory]::CreateDirectory($BkDir) | Out-Null
    function Write-Log { param($Text) }
    function Rotate-Backups { }
    function Get-VeyonCliPath { return 'simulated-veyon-cli' }
    function Export-RegistryBackup { return $false }
    try {
        function Invoke-Proc { param($File, $ArgList); [System.IO.File]::WriteAllText($ArgList[2], '{}'); return 0 }
        Assert-True (Backup-VeyonConfig) 'Valid configuration export rejected'
        function Invoke-Proc { param($File, $ArgList); [System.IO.File]::WriteAllText($ArgList[2], ''); return 0 }
        Assert-True (-not (Backup-VeyonConfig)) 'Empty configuration export accepted'
        function Invoke-Proc { param($File, $ArgList); [System.IO.File]::WriteAllText($ArgList[2], '{broken'); return 0 }
        Assert-True (-not (Backup-VeyonConfig)) 'Malformed configuration export accepted'
        function Invoke-Proc { param($File, $ArgList); [System.IO.File]::WriteAllText($ArgList[2], 'null'); return 0 }
        Assert-True (-not (Backup-VeyonConfig)) 'Null configuration export accepted'
        function Invoke-Proc { param($File, $ArgList); return 1 }
        Assert-True (-not (Backup-VeyonConfig)) 'Failed configuration export accepted'
        Write-Host 'PASS: configuration export validation'
    } finally {
        [System.IO.Directory]::Delete($BkDir, $true)
    }
}

& {
    function New-Item { throw 'Unexpected directory creation' }
    function Add-Content { throw 'Unexpected log write' }
    function Set-Content { throw 'Unexpected file write' }
    function Clear-Content { throw 'Unexpected truncation' }
    function Start-Process { throw 'Unexpected process launch' }
    & $sourcePath -Testlauf
    Write-Host 'PASS: full dry-run entry point'
}

& (Join-Path $PSScriptRoot 'test_installer.ps1') -PackageRoot (Split-Path $sourcePath -Parent)
