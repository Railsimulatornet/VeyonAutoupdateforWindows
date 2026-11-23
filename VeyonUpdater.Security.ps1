# Veyon Updater bootstrap protocol 1
# Compatible with Windows PowerShell 5.1 and .NET Framework 4.8.
Set-StrictMode -Version 2.0

function Get-VeyonRoot {
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'VeyonUpdater'
}

function Get-VeyonPowerShell {
    $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $native = Join-Path $windows 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if ([IO.File]::Exists($native)) { return $native }
    Join-Path $windows 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Initialize-VeyonNative {
    if ('VeyonUpdater.NativeFile' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace VeyonUpdater {
    public static class NativeFile {
        [StructLayout(LayoutKind.Sequential)] private struct Info {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
        public static uint LinkCount(string path) {
            using (var handle = CreateFile(path, 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                Info info;
                if (!GetFileInformationByHandle(handle, out info))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                if ((info.Attributes & 0x400) != 0) throw new IOException("Reparse point rejected: " + path);
                return info.Links;
            }
        }
    }
}
'@
}

function Assert-VeyonSafePath {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$AllowHardLinks)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':')) {
        throw "A local absolute path is required: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $next = $full
    while ($next) {
        if ([IO.File]::Exists($next) -or [IO.Directory]::Exists($next)) {
            $attributes = [IO.File]::GetAttributes($next)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point rejected: $next"
            }
        } else {
            # GetAttributes also sees dangling reparse points that Exists hides.
            try {
                $attributes = [IO.File]::GetAttributes($next)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point rejected: $next" }
            } catch [IO.FileNotFoundException] {} catch [IO.DirectoryNotFoundException] {}
        }
        $parent = [IO.Directory]::GetParent($next)
        $next = if ($parent) { $parent.FullName } else { $null }
    }
    if (-not $AllowHardLinks -and [IO.File]::Exists($full)) {
        Initialize-VeyonNative
        if ([VeyonUpdater.NativeFile]::LinkCount($full) -ne 1) { throw "Hard link rejected: $full" }
    }
}

function Assert-VeyonAcl {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$Private, [switch]$Ancestor)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $raw = New-Object Security.AccessControl.RawSecurityDescriptor($acl.GetSecurityDescriptorBinaryForm(),0)
    if ($null -eq $raw.DiscretionaryAcl) { throw "Null DACL rejected: $Path" }
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if (-not $Private) {
        $trusted += 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    }
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trusted) { throw "Untrusted owner: $Path" }
    $writeMask = if ($Ancestor) { 0x100D0040 } else { 0x500D0156 }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if (-not $Private -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if ($rule.IdentityReference.Value -notin $trusted -and
            ($Private -or (([int]$rule.FileSystemRights -band $writeMask) -ne 0))) {
            throw "Unsafe permissions: $Path"
        }
    }
    if ($Private -and -not $acl.AreAccessRulesProtected) {
        # Inheritance is safe only inside our already protected root. Callers check the chain.
        $parent = [IO.Directory]::GetParent($Path)
        if (-not $parent) { throw "Unprotected permissions: $Path" }
    }
}

function New-VeyonDirectorySecurity {
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)),
            [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    return $security
}

function New-VeyonProtectedDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    Assert-VeyonSafePath -Path $Path
    if ([IO.Directory]::Exists($Path)) { Assert-VeyonAcl -Path $Path -Private; return }
    $parent = [IO.Directory]::GetParent($Path)
    if (-not $parent -or -not $parent.Exists) { throw "Parent directory missing: $Path" }
    Assert-VeyonAcl -Path $parent.FullName -Ancestor
    [IO.Directory]::CreateDirectory($Path, (New-VeyonDirectorySecurity)) | Out-Null
    Assert-VeyonAcl -Path $Path -Private
}

function Set-VeyonProtectedAcl {
    param([Parameter(Mandatory=$true)][string]$Path)
    Assert-VeyonSafePath -Path $Path
    if ([IO.Directory]::Exists($Path)) {
        Set-Acl -LiteralPath $Path -AclObject (New-VeyonDirectorySecurity) -ErrorAction Stop
    } else {
        $security = New-Object Security.AccessControl.FileSecurity
        $security.SetAccessRuleProtection($true, $false)
        $security.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
            $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                (New-Object Security.Principal.SecurityIdentifier($sid)),
                [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow)))
        }
        Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
    }
    Assert-VeyonAcl -Path $Path -Private
}

function Assert-VeyonProtectedRoot {
    param([Parameter(Mandatory=$true)][string]$Root)
    Assert-VeyonSafePath -Path $Root
    if (-not [IO.Directory]::Exists($Root)) { throw 'The protected updater directory is missing. Run setup.' }
    if (-not (Get-Acl -LiteralPath $Root).AreAccessRulesProtected) { throw 'The updater root inherits unsafe permissions.' }
    $parent = [IO.Directory]::GetParent($Root)
    while ($parent) {
        Assert-VeyonAcl -Path $parent.FullName -Ancestor
        $parent = $parent.Parent
    }
    $queue = New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue($Root)
    $count = 0
    while ($queue.Count) {
        $path = $queue.Dequeue()
        $count++
        if ($count -gt 500) { throw 'Unexpected number of updater files.' }
        Assert-VeyonSafePath -Path $path
        Assert-VeyonAcl -Path $path -Private
        if ([IO.Directory]::Exists($path)) {
            foreach ($item in Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop) { $queue.Enqueue($item.FullName) }
        }
    }
}

function Initialize-VeyonProtectedRoot {
    param([Parameter(Mandatory=$true)][string]$Root)
    New-VeyonProtectedDirectory -Path $Root
    Assert-VeyonProtectedRoot -Root $Root
    foreach ($name in @('versions','staging','config-backups')) {
        New-VeyonProtectedDirectory -Path (Join-Path $Root $name)
    }
}

function Assert-VeyonTrustedExecutable {
    param([Parameter(Mandatory=$true)][string]$Path)
    Assert-VeyonSafePath -Path $Path -AllowHardLinks
    if (-not [IO.File]::Exists($Path)) { throw "Executable missing: $Path" }
    Assert-VeyonAcl -Path $Path
    $parent = [IO.Directory]::GetParent($Path)
    Assert-VeyonAcl -Path $parent.FullName
    while ($parent) {
        Assert-VeyonAcl -Path $parent.FullName -Ancestor
        $parent = $parent.Parent
    }
}

function Enter-VeyonUpdateLock {
    param([Parameter(Mandatory=$true)][string]$Root)
    Assert-VeyonProtectedRoot -Root $Root
    $path = Join-Path $Root 'update.lock'
    Assert-VeyonSafePath -Path $path
    try {
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    } catch [IO.IOException] {
        $cause = $_.Exception
        while ($cause.InnerException) { $cause = $cause.InnerException }
        if (($cause.HResult -band 0xFFFF) -in @(32,33)) { return $null }
        throw
    }
    try {
        Set-VeyonProtectedAcl -Path $path
        if (Test-Path -LiteralPath (Join-Path $Root 'native-operation.json')) {
            throw 'Eine fruehere Prozessausfuehrung wurde unterbrochen. Vor einem neuen Lauf die Wartungshinweise fuer native-operation.json beachten.'
        }
    } catch { $stream.Dispose(); throw }
    return $stream
}

function Get-VeyonSha256 {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertTo-VeyonVersion {
    param([Parameter(Mandatory=$true)][string]$Value)
    if ($Value -cnotmatch '\A(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\z') {
        throw 'Invalid updater version.'
    }
    $version = [version]$Value
    if ($version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535) { throw 'Updater version out of range.' }
    return $version
}

function Assert-VeyonFields {
    param($Object, [string[]]$Names)
    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { throw 'Invalid object.' }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw 'Unexpected object fields.' }
    foreach ($name in $Names) { if ($name -cnotin $actual) { throw "Missing field: $name" } }
}

function Assert-VeyonVersionRecord {
    param($Record)
    Assert-VeyonFields -Object $Record -Names @('version','directory','sourceCommit','files')
    ConvertTo-VeyonVersion -Value $Record.version | Out-Null
    if ($Record.directory -cnotmatch ('\A' + [regex]::Escape($Record.version) + '-[0-9a-f]{16}\z') -or
        $Record.sourceCommit -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Invalid version record.' }
    $names = @('Veyon-AutoUpdate.ps1','Veyon-SelfUpdate.ps1')
    if (@($Record.files).Count -ne $names.Count) { throw 'Invalid payload file count.' }
    for ($i=0; $i -lt $names.Count; $i++) {
        $file = $Record.files[$i]
        Assert-VeyonFields -Object $file -Names @('path','length','sha256')
        if ($file.path -cne $names[$i] -or $file.sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or
            "$($file.length)" -notmatch '\A[1-9][0-9]{0,6}\z' -or [long]$file.length -gt 1MB) {
            throw 'Invalid payload file record.'
        }
    }
}

function Assert-VeyonState {
    param($State)
    Assert-VeyonFields -Object $State -Names @('schema','current','previous','highestVersion','failedVersion')
    if ($State.schema -ne 1) { throw 'Unknown updater state schema.' }
    Assert-VeyonVersionRecord -Record $State.current
    $highest = ConvertTo-VeyonVersion -Value $State.highestVersion
    if ($highest -lt (ConvertTo-VeyonVersion -Value $State.current.version)) { throw 'Invalid update high-water mark.' }
    if ($null -ne $State.previous) {
        Assert-VeyonVersionRecord -Record $State.previous
        if ((ConvertTo-VeyonVersion -Value $State.previous.version) -gt $highest) { throw 'Invalid fallback version.' }
    }
    if ($null -ne $State.failedVersion -and (ConvertTo-VeyonVersion -Value $State.failedVersion) -gt $highest) { throw 'Invalid failed version.' }
}

function Read-VeyonState {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'state.json'
    Assert-VeyonSafePath -Path $path
    Assert-VeyonAcl -Path $path -Private
    if ((Get-Item -LiteralPath $path).Length -gt 16384) { throw 'Updater state too large.' }
    $state = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false,$true))) | ConvertFrom-Json -ErrorAction Stop
    Assert-VeyonState -State $state
    return $state
}

function Write-VeyonState {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)]$State)
    Assert-VeyonState -State $State
    $path = Join-Path $Root 'state.json'
    Assert-VeyonSafePath -Path $path
    $temporary = Join-Path $Root ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($State | ConvertTo-Json -Depth 8 -Compress))
    try {
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Set-VeyonProtectedAcl -Path $temporary
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-VeyonReleaseCertificate {
    param([Parameter(Mandatory=$true)][string]$Root)
    $path = Join-Path $Root 'VeyonUpdater-release-public.cer'
    Assert-VeyonSafePath -Path $path
    if ((Get-VeyonSha256 -Bytes ([IO.File]::ReadAllBytes($path))) -cne
        '7b698f2726348060cddf8b10a5a82d39ed907062265edf2e926dd9d6c5a72b7d') { throw 'Release certificate pin mismatch.' }
    return New-Object Security.Cryptography.X509Certificates.X509Certificate2($path)
}

function ConvertFrom-VeyonManifest {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    if ($Bytes.Length -gt 4096 -or $Bytes.Length -eq 0) { throw 'Invalid manifest size.' }
    foreach ($value in $Bytes) { if ($value -gt 126 -or ($value -lt 32 -and $value -ne 10)) { throw 'Invalid manifest encoding.' } }
    $text = [Text.Encoding]::ASCII.GetString($Bytes)
    $lines = $text.Split([char]10)
    if ($lines.Count -ne 14 -or $lines[13] -cne '') { throw 'Invalid manifest line count.' }
    $fixed = @('VEYON-UPDATER-MANIFEST-1','product=VeyonUpdater',
        'repository=Railsimulatornet/VeyonAutoupdateforWindows','channel=stable')
    for ($i=0; $i -lt $fixed.Count; $i++) { if ($lines[$i] -cne $fixed[$i]) { throw 'Wrong release identity or channel.' } }
    if ($lines[4] -cnotmatch '\Aversion=(.+)\z') { throw 'Missing release version.' }
    $version = $Matches[1]
    ConvertTo-VeyonVersion -Value $version | Out-Null
    if ($lines[5] -cne ('tag=' + $version)) { throw 'Release tag/version mismatch.' }
    if ($lines[6] -cnotmatch '\Asource=([0-9a-f]{40})\z') { throw 'Invalid source commit.' }
    $commit = $Matches[1]
    if ($lines[7] -cne 'bootstrap=1') { throw 'This release requires a different bootstrap. Run the trusted setup.' }
    $payload = 'VeyonUpdater_v' + $version + '_Update.zip'
    if ($lines[8] -cne ('payload=' + $payload)) { throw 'Invalid payload name.' }
    if ($lines[9] -cnotmatch '\Alength=([1-9][0-9]{0,6})\z') { throw 'Invalid payload length.' }
    $length = [long]$Matches[1]
    if ($length -gt 4MB) { throw 'Payload too large.' }
    if ($lines[10] -cnotmatch '\Asha256=([0-9a-f]{64})\z') { throw 'Invalid payload hash.' }
    $hash = $Matches[1]
    $files = @()
    $names = @('Veyon-AutoUpdate.ps1','Veyon-SelfUpdate.ps1')
    for ($i=0; $i -lt $names.Count; $i++) {
        $pattern = '\Afile=' + [regex]::Escape($names[$i]) + '\|([1-9][0-9]{0,6})\|([0-9a-f]{64})\z'
        if ($lines[11+$i] -cnotmatch $pattern) { throw 'Invalid manifest file entry.' }
        if ([long]$Matches[1] -gt 1MB) { throw 'Payload entry too large.' }
        $files += [pscustomobject]@{path=$names[$i]; length=[long]$Matches[1]; sha256=$Matches[2]}
    }
    [pscustomobject]@{version=$version; sourceCommit=$commit; payload=$payload; length=$length; sha256=$hash; files=$files}
}

function Test-VeyonSignedManifest {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes, [Parameter(Mandatory=$true)][byte[]]$Signature,
        [Parameter(Mandatory=$true)][string]$Root)
    if ($Bytes.Length -gt 4096 -or $Signature.Length -ne 384) { throw 'Invalid manifest or signature size.' }
    $cert = $null; $public = $null; $rsa = $null
    try {
        $cert = Get-VeyonReleaseCertificate -Root $Root
        $now = [DateTime]::UtcNow
        if ($now -lt $cert.NotBefore.ToUniversalTime() -or $now -gt $cert.NotAfter.ToUniversalTime()) {
            throw 'Release certificate is outside its validity period. Check the clock or install a current trusted bootstrap.'
        }
        $public = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        if ($public.KeySize -ne 3072) { throw 'Invalid release key size.' }
        $rsa = New-Object Security.Cryptography.RSACng
        $rsa.ImportParameters($public.ExportParameters($false))
        if (-not $rsa.VerifyData($Bytes, $Signature, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pss)) { throw 'Invalid release signature.' }
        return ConvertFrom-VeyonManifest -Bytes $Bytes
    } finally {
        if ($rsa) { $rsa.Dispose() }; if ($public) { $public.Dispose() }; if ($cert) { $cert.Dispose() }
    }
}

function Assert-VeyonVersionFiles {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)]$Record)
    Assert-VeyonVersionRecord -Record $Record
    $directory = Join-Path (Join-Path $Root 'versions') $Record.directory
    Assert-VeyonSafePath -Path $directory
    Assert-VeyonAcl -Path $directory -Private
    $items = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
    if ($items.Count -ne 2) { throw 'Unexpected files in installed version.' }
    foreach ($file in $Record.files) {
        $path = Join-Path $directory $file.path
        Assert-VeyonSafePath -Path $path
        Assert-VeyonAcl -Path $path -Private
        if (-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -ne $file.length -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.sha256) { throw 'Installed updater integrity check failed.' }
    }
    return $directory
}

function Expand-VeyonVerifiedPayload {
    param([Parameter(Mandatory=$true)][string]$Archive, [Parameter(Mandatory=$true)]$Manifest,
        [Parameter(Mandatory=$true)][string]$Destination)
    Assert-VeyonSafePath -Path $Archive
    if ((Get-Item -LiteralPath $Archive).Length -ne $Manifest.length -or
        (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ine $Manifest.sha256) { throw 'Payload checksum or length mismatch.' }
    if ([IO.Directory]::Exists($Destination) -or [IO.File]::Exists($Destination)) { throw 'Staging destination already exists.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -ne 2) { throw 'Unexpected ZIP entry count.' }
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            $expected = @($Manifest.files | Where-Object { $_.path -ceq $entry.FullName })
            $mode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($expected.Count -ne 1 -or $seen.ContainsKey($entry.FullName) -or
                $entry.Length -ne $expected[0].length -or $entry.Length -gt 1MB -or
                ($mode -ne 0 -and $mode -ne 0x8000) -or ($entry.ExternalAttributes -band 0x410) -ne 0) {
                throw 'Unsafe ZIP entry.'
            }
            $seen[$entry.FullName] = $true
        }
        New-VeyonProtectedDirectory -Path $Destination
        foreach ($entry in $zip.Entries) {
            $path = Join-Path $Destination $entry.FullName
            $expected = @($Manifest.files | Where-Object { $_.path -ceq $entry.FullName })[0]
            $input = $entry.Open()
            try {
                $output = New-Object IO.FileStream($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {
                    $buffer = New-Object byte[] 8192
                    $total = 0
                    while (($count = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $total += $count
                        if ($total -gt $expected.length) { throw 'ZIP expansion limit exceeded.' }
                        $output.Write($buffer,0,$count)
                    }
                    if ($total -ne $expected.length) { throw 'Incomplete ZIP entry.' }
                    $output.Flush($true)
                } finally { $output.Dispose() }
            } finally { $input.Dispose() }
            Set-VeyonProtectedAcl -Path $path
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected.sha256) { throw 'Payload file hash mismatch.' }
        }
    } finally { $zip.Dispose() }
}

function Test-VeyonPayloadHealth {
    param([Parameter(Mandatory=$true)][string]$Directory)
    foreach ($name in @('Veyon-AutoUpdate.ps1','Veyon-SelfUpdate.ps1')) {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $Directory $name),[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors.Count) { throw 'Updater payload does not parse on this Windows PowerShell version.' }
    }
    $powerShell = Get-VeyonPowerShell
    Assert-VeyonTrustedExecutable -Path $powerShell
    $script = Join-Path $Directory 'Veyon-AutoUpdate.ps1'
    $process = Start-Process -FilePath $powerShell -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '" -Testlauf') -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Updater healthcheck timed out.' }
        if ($process.ExitCode -ne 0) { throw 'Updater healthcheck failed.' }
    } finally { $process.Dispose() }
}
