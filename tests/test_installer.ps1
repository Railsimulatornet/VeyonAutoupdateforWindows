param([Parameter(Mandatory = $true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$PackageRoot = (Get-Item -LiteralPath $PackageRoot).FullName
$installer = Join-Path $PackageRoot 'Install-Veyon-AutoUpdate.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw 'Installer parse failed.' }
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
. (Join-Path $PackageRoot 'VeyonUpdater.Security.ps1')
if (-not (Test-VeyonAdministrator)) { throw 'Installer tests require an elevated disposable Windows runner.' }
$actualCopy = ${function:Copy-VeyonVerifiedFile}
$actualHealth = ${function:Invoke-VeyonCandidateHealth}
$script:fakeTask = $null
$script:mode = ''
$script:registrationCalled = $false
$script:healthCalled = $false
$script:legacyCalled = $false

# Task Scheduler calls are isolated; filesystem permissions, package hashes,
# the exclusive lock, offline process test and state replacement remain real.
function Get-VeyonTaskSnapshot { return $script:fakeTask }
function Suspend-VeyonTask { param($Snapshot) $script:fakeTask = 'disabled' }
function Restore-VeyonTask { param($Snapshot) $script:fakeTask = $Snapshot }
function Invoke-VeyonTaskRegistration {
    param([string]$PackageRoot, [string]$Root)
    $script:registrationCalled = $true
    $script:fakeTask = 'new-task'
    if ($script:mode -eq 'task-fail') { throw 'Injected Task Scheduler failure.' }
}
function Invoke-VeyonCandidateHealth {
    param([string]$Path)
    $script:healthCalled = $true
    if ($script:mode -eq 'health-fail') { throw 'Injected offline health failure.' }
    & $actualHealth -Path $Path
}
function Copy-VeyonVerifiedFile {
    param([string]$Source, [string]$Destination, [string]$ExpectedHash)
    if ($script:mode -eq 'copy-fail' -and $Destination -match '\\versions\\1\.5\.0-[a-f0-9]+\\Veyon-SelfUpdate\.ps1$') {
        throw 'Injected payload copy failure.'
    }
    & $actualCopy -Source $Source -Destination $Destination -ExpectedHash $ExpectedHash
}
function Move-VeyonLegacyBackups { param([string]$Root) $script:legacyCalled = $true }

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon installer package ' + [guid]::NewGuid().ToString('N'))
$roots = @()
try {
    $info = Assert-VeyonPackage -PackageRoot $PackageRoot
    Write-Host 'PASS: complete package hashes, pinned public certificate and native PowerShell parser'
    [IO.Directory]::CreateDirectory($temporary) | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $PackageRoot -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $temporary -Recurse
    }
    $modified = Join-Path $temporary 'Veyon-AutoUpdate.ps1'
    $originalBytes = [IO.File]::ReadAllBytes($modified)
    [IO.File]::AppendAllText($modified, "`r`n# modified`r`n")
    $rejected = $false
    try { Assert-VeyonPackage -PackageRoot $temporary | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected 'Changed package file was accepted.'
    [IO.File]::WriteAllBytes($modified, $originalBytes)
    [IO.File]::WriteAllText((Join-Path $temporary 'unexpected.ps1'), 'exit 0')
    $rejected = $false
    try { Assert-VeyonPackage -PackageRoot $temporary | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected 'Unexpected package file was accepted.'
    [IO.File]::Delete((Join-Path $temporary 'unexpected.ps1'))
    [IO.File]::Delete((Join-Path $temporary 'Veyon-SelfUpdate.ps1'))
    $rejected = $false
    try { Assert-VeyonPackage -PackageRoot $temporary | Out-Null } catch { $rejected = $true }
    Assert-Test $rejected 'Incomplete package was accepted.'
    Write-Host 'PASS: changed, unexpected and missing package files rejected before installation'

    foreach ($mode in @('success', 'copy-fail', 'health-fail', 'task-fail', 'busy', 'core-mismatch', 'downgrade')) {
        $script:mode = $mode
        $script:fakeTask = 'old-task'
        $script:registrationCalled = $false
        $script:healthCalled = $false
        $script:legacyCalled = $false
        $root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('VeyonInstallerTest-' + [guid]::NewGuid().ToString('N'))
        $roots += $root
        Initialize-VeyonProtectedRoot -Root $root
        foreach ($name in @('Start-VeyonUpdater.ps1', 'VeyonUpdater.Security.ps1', 'VeyonUpdater-release-public.cer')) {
            & $actualCopy -Source (Join-Path $PackageRoot $name) -Destination (Join-Path $root $name) -ExpectedHash $info.sha256.$name
        }
        $version = if ($mode -eq 'downgrade') { '9.0.0' } else { '1.4.0' }
        $directoryName = $version + '-0000000000000000'
        $oldDirectory = Join-Path (Join-Path $root 'versions') $directoryName
        New-VeyonProtectedDirectory -Path $oldDirectory
        $files = @()
        foreach ($name in @('Veyon-AutoUpdate.ps1', 'Veyon-SelfUpdate.ps1')) {
            $target = Join-Path $oldDirectory $name
            & $actualCopy -Source (Join-Path $PackageRoot $name) -Destination $target -ExpectedHash $info.sha256.$name
            $files += [pscustomobject]@{ path = $name; length = (Get-Item -LiteralPath $target).Length; sha256 = $info.sha256.$name }
        }
        $oldState = [pscustomobject]@{
            schema = 1
            current = [pscustomobject]@{ version = $version; directory = $directoryName; sourceCommit = ('0' * 40); files = $files }
            previous = $null
            highestVersion = $version
            failedVersion = $null
        }
        Write-VeyonState -Root $root -State $oldState
        $held = $null
        if ($mode -eq 'busy') { $held = Enter-VeyonUpdateLock -Root $root }
        if ($mode -eq 'core-mismatch') { [IO.File]::AppendAllText((Join-Path $root 'Start-VeyonUpdater.ps1'), "`r`n# changed") }
        $failed = $false
        try { Invoke-VeyonInstall -PackageRoot $PackageRoot -Root $root }
        catch { $failed = $true }
        finally { if ($held) { $held.Dispose() } }
        Assert-Test ($failed -eq ($mode -ne 'success')) "Unexpected installation result: $mode"
        $after = Read-VeyonState -Root $root
        if ($mode -eq 'success') {
            Assert-Test ($after.current.version -eq '1.5.0' -and $after.previous.directory -eq $directoryName) 'Successful activation did not retain the previous version.'
            Assert-Test ($script:fakeTask -eq 'new-task' -and $script:healthCalled -and $script:legacyCalled) 'Successful activation omitted a prerequisite.'
        } else {
            Assert-Test ($after.current.directory -eq $directoryName -and $after.highestVersion -eq $version) "Previous state not restored after $mode."
            Assert-Test ($script:fakeTask -eq 'old-task') "Previous task not restored after $mode."
            if ($mode -ne 'task-fail') { Assert-Test (-not $script:registrationCalled) "Task registered too early after $mode." }
        }
        Assert-Test ([IO.File]::Exists((Join-Path $oldDirectory 'Veyon-AutoUpdate.ps1'))) 'Previous version was modified or removed.'
        Assert-VeyonProtectedRoot -Root $root
        Write-Host "PASS: protected installation transaction $mode"
    }
} finally {
    foreach ($root in $roots) {
        if ([IO.Directory]::Exists($root)) {
            Assert-VeyonProtectedRoot -Root $root
            [IO.Directory]::Delete($root, $true)
        }
    }
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
