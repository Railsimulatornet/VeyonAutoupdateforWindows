# Veyon Updater bootstrap protocol 1
param([switch]$Testlauf)
$ErrorActionPreference = 'Stop'
# Resolve modules only from the PowerShell installation used by this process.
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
Set-StrictMode -Version 2.0

$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VeyonUpdater'
if ($root -notmatch '^[A-Za-z]:\\' -or $root.Substring(2).Contains(':')) { throw 'The updater requires a local data directory.' }
if ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ine $root.TrimEnd('\')) {
    throw 'Run the installed updater from its protected directory.'
}
# An unsafe ancestor must be rejected before a module could be substituted.
$parent = [IO.Directory]::GetParent($root)
while ($parent) {
    if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe bootstrap ancestor.' }
    $acl = Get-Acl -LiteralPath $parent.FullName
    $raw = New-Object Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(),0)
    $trusted = @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($null -eq $raw.DiscretionaryAcl -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) {
        throw 'Unsafe bootstrap ancestor security.'
    }
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and
            $rule.IdentityReference.Value -notin $trusted -and ([int]$rule.FileSystemRights -band 0x100D0040) -ne 0) {
            throw 'Unsafe bootstrap ancestor permissions.'
        }
    }
    $parent = $parent.Parent
}
# Check the loader boundary before importing any additional executable file.
foreach ($path in @($root,(Join-Path $root 'VeyonUpdater.Security.ps1'))) {
    if (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe bootstrap path.' }
    $acl = Get-Acl -LiteralPath $path
    $raw = New-Object Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(),0)
    if ($null -eq $raw.DiscretionaryAcl) { throw 'Unsafe bootstrap DACL.' }
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Unsafe bootstrap owner.' }
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')) { throw 'Unsafe bootstrap permissions.' }
    }
}
if (-not (Get-Acl -LiteralPath $root).AreAccessRulesProtected) { throw 'The bootstrap root must not inherit permissions.' }
. (Join-Path $root 'VeyonUpdater.Security.ps1')
Assert-VeyonProtectedRoot -Root $root
if ($Testlauf) {
    $state = Read-VeyonState -Root $root
    $directory = Assert-VeyonVersionFiles -Root $root -Record $state.current
    Test-VeyonPayloadHealth -Directory $directory
    Write-Host ('Installierte Version ' + $state.current.version + ': Integritaet und Testlauf OK.')
    exit 0
}
$lock = Enter-VeyonUpdateLock -Root $root
if ($null -eq $lock) { Write-Host 'Veyon Updater laeuft bereits.'; exit 0 }
try {
    $state = Read-VeyonState -Root $root
    try {
        $directory = Assert-VeyonVersionFiles -Root $root -Record $state.current
        Test-VeyonPayloadHealth -Directory $directory
    } catch {
        if ($null -eq $state.previous) { throw }
        $directory = Assert-VeyonVersionFiles -Root $root -Record $state.previous
        Test-VeyonPayloadHealth -Directory $directory
        $state = [pscustomobject]@{schema=1;current=$state.previous;previous=$null;
            highestVersion=$state.highestVersion;failedVersion=$state.current.version}
        Write-VeyonState -Root $root -State $state
    }
    . (Join-Path $directory 'Veyon-SelfUpdate.ps1')
    try { Invoke-VeyonSelfUpdate -Root $root -State $state | Out-Null }
    catch { Write-VeyonSelfUpdateLog -Root $root -Message ('Hinweis bei der Selbstupdate-Pruefung: ' + $_.Exception.Message) }
    # Re-read after a possible atomic activation. A corrupt state is never replaced with an older copy.
    Assert-VeyonProtectedRoot -Root $root
    $state = Read-VeyonState -Root $root
    $directory = Assert-VeyonVersionFiles -Root $root -Record $state.current
    # Keep the real lock handle in the same process for the entire Veyon run.
    & (Join-Path $directory 'Veyon-AutoUpdate.ps1') -UpdateLock $lock
} finally { $lock.Dispose() }
