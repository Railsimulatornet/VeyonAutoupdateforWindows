param([switch]$Portable)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $sourceRoot 'VeyonUpdater.Security.ps1')
. (Join-Path $sourceRoot 'Veyon-SelfUpdate.ps1')

function Assert-True($Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Rejected([scriptblock]$Action,[string]$Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw $Message }
}
function New-TestManifestBytes($Files,[byte[]]$ArchiveBytes,[string]$Version='1.5.1') {
    $lines = @('VEYON-UPDATER-MANIFEST-1','product=VeyonUpdater',
        'repository=Railsimulatornet/VeyonAutoupdateforWindows','channel=stable',
        ('version='+$Version),('tag='+$Version),('source='+('a'*40)), 'bootstrap=1',
        ('payload=VeyonUpdater_v'+$Version+'_Update.zip'),('length='+$ArchiveBytes.Length),
        ('sha256='+(Get-VeyonSha256 -Bytes $ArchiveBytes)))
    foreach ($file in $Files) { $lines += ('file={0}|{1}|{2}' -f $file.path,$file.length,$file.sha256) }
    return ,([Text.Encoding]::ASCII.GetBytes(($lines -join "`n")+"`n"))
}

$fileRecords = @(
    [pscustomobject]@{path='Veyon-AutoUpdate.ps1';length=10;sha256=('b'*64)},
    [pscustomobject]@{path='Veyon-SelfUpdate.ps1';length=20;sha256=('c'*64)}
)
$validBytes = New-TestManifestBytes -Files $fileRecords -ArchiveBytes ([byte[]](1,2,3))
$manifest = ConvertFrom-VeyonManifest -Bytes $validBytes
Assert-True ($manifest.version -ceq '1.5.1' -and $manifest.files.Count -eq 2) 'Valid manifest rejected'
$text = [Text.Encoding]::ASCII.GetString($validBytes)
foreach ($bad in @(
    $text.Replace("`n","`r`n"), $text.TrimEnd([char]10), ($text+"`n"),
    $text.Replace('channel=stable','channel=preview'), $text.Replace('product=VeyonUpdater','product=Other'),
    $text.Replace('repository=Railsimulatornet/VeyonAutoupdateforWindows','repository=attacker/project'),
    $text.Replace('version=1.5.1','version=01.5.1'), $text.Replace('tag=1.5.1','tag=1.5.2'),
    $text.Replace('bootstrap=1','bootstrap=2'), $text.Replace('length=3','length=9999999'),
    $text.Replace('file=Veyon-SelfUpdate.ps1','file=../Veyon-SelfUpdate.ps1'),
    $text.Replace('file=Veyon-SelfUpdate.ps1','file=Veyon-AutoUpdate.ps1'),
    $text.Replace('source='+('a'*40),'source='+('A'*40)), $text.Replace('length=3','length=3.0')
)) {
    Assert-Rejected { ConvertFrom-VeyonManifest -Bytes ([Text.Encoding]::ASCII.GetBytes($bad)) } 'Malformed manifest accepted'
}
Assert-Rejected { ConvertFrom-VeyonManifest -Bytes (([byte[]](239,187,191))+$validBytes) } 'Manifest BOM accepted'
Assert-Rejected { ConvertTo-VeyonVersion '65536.0.0' } 'Version overflow accepted'
Assert-Rejected { ConvertTo-VeyonVersion '1.5.1-rc1' } 'Prerelease version accepted'
Write-Host 'PASS: exact manifest identity, encoding, paths, lengths and versions'

$record = [pscustomobject]@{version='1.5.1';directory=('1.5.1-'+('d'*16));sourceCommit=('a'*40);files=$fileRecords}
$state = [pscustomobject]@{schema=1;current=$record;previous=$null;highestVersion='1.5.1';failedVersion=$null}
Assert-VeyonState -State $state
$state.highestVersion='1.5.0'
Assert-Rejected { Assert-VeyonState -State $state } 'Decreasing high-water mark accepted'
$state.highestVersion='1.5.1'; $record.directory='../escape'
Assert-Rejected { Assert-VeyonState -State $state } 'State path traversal accepted'
$record.directory='1.5.1-'+('d'*16)
$record.files[1].path='Veyon-AutoUpdate.ps1'
Assert-Rejected { Assert-VeyonState -State $state } 'Duplicate state file accepted'
$record.files[1].path='Veyon-SelfUpdate.ps1'
Write-Host 'PASS: state schema and rollback bounds'

if ($Portable) { Write-Host 'Windows ACL, native PSS and activation tests require Windows PowerShell 5.1.'; exit 0 }
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run the complete security suite in Windows PowerShell 5.1.' }

$testRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('VeyonUpdater-test-'+[guid]::NewGuid().ToString('N'))
$key = $null; $certificate = $null; $lock = $null
try {
    Initialize-VeyonProtectedRoot -Root $testRoot
    $lock = Enter-VeyonUpdateLock -Root $testRoot
    Assert-True ($null -ne $lock) 'First lock failed'
    Assert-True ($null -eq (Enter-VeyonUpdateLock -Root $testRoot)) 'Concurrent lock acquired'
    $lock.Dispose(); $lock=$null
    $operation = Join-Path $testRoot 'native-operation.json'
    [IO.File]::WriteAllText($operation,'{"interrupted":true}')
    Set-VeyonProtectedAcl -Path $operation
    Assert-Rejected { Enter-VeyonUpdateLock -Root $testRoot } 'Interrupted native operation allowed another update'
    [IO.File]::Delete($operation)

    $aclTest = Join-Path $testRoot 'acl-test'
    New-VeyonProtectedDirectory -Path $aclTest
    $acl = Get-Acl -LiteralPath $aclTest
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),
        [Security.AccessControl.FileSystemRights]::ReadAndExecute,
        ([Security.AccessControl.InheritanceFlags]::ObjectInherit -bor [Security.AccessControl.InheritanceFlags]::ContainerInherit),
        [Security.AccessControl.PropagationFlags]::InheritOnly,
        [Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $aclTest -AclObject $acl
    Assert-Rejected { Assert-VeyonProtectedRoot -Root $testRoot } 'Inherited future backup read permission accepted'
    Set-VeyonProtectedAcl -Path $aclTest
    [IO.Directory]::Delete($aclTest)
    Write-Host 'PASS: protected root, inherited confidentiality and exclusive lock'

    $original = Join-Path $testRoot 'original.txt'
    [IO.File]::WriteAllText($original,'hardlink test')
    Set-VeyonProtectedAcl -Path $original
    $link = Join-Path $testRoot 'hardlink.txt'
    New-Item -ItemType HardLink -Path $link -Target $original | Out-Null
    Assert-Rejected { Assert-VeyonSafePath -Path $original } 'Hardlink accepted'
    [IO.File]::Delete($link); [IO.File]::Delete($original)
    $junction = Join-Path $testRoot 'junction'
    New-Item -ItemType Junction -Path $junction -Target (Join-Path $testRoot 'versions') | Out-Null
    Assert-Rejected { Assert-VeyonProtectedRoot -Root $testRoot } 'Junction accepted'
    [IO.Directory]::Delete($junction)
    Write-Host 'PASS: hardlink and junction rejection'

    $productionCert = Get-VeyonReleaseCertificate -Root $sourceRoot
    $productionCert.Dispose()
    $badCert = Join-Path $testRoot 'VeyonUpdater-release-public.cer'
    [IO.File]::WriteAllBytes($badCert,[byte[]](1,2,3))
    Set-VeyonProtectedAcl -Path $badCert
    Assert-Rejected { Get-VeyonReleaseCertificate -Root $testRoot } 'Wrong production certificate accepted'
    [IO.File]::Delete($badCert)

    $key = New-Object Security.Cryptography.RSACng(3072)
    $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
        'CN=Veyon Updater disposable test key',$key,[Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-1),[DateTimeOffset]::UtcNow.AddDays(1))
    $script:TestCertificateBytes = $certificate.RawData
    # Override only in this disposable test process, never in the installed verifier.
    function Get-VeyonReleaseCertificate { param([string]$Root)
        return New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$script:TestCertificateBytes)
    }
    $signature = $key.SignData($validBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
    Test-VeyonSignedManifest -Bytes $validBytes -Signature $signature -Root $testRoot | Out-Null
    $changed = [byte[]]$validBytes.Clone(); $changed[0] = $changed[0] -bxor 1
    Assert-Rejected { Test-VeyonSignedManifest -Bytes $changed -Signature $signature -Root $testRoot } 'Altered signed bytes accepted'
    $wrongPadding = $key.SignData($validBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    Assert-Rejected { Test-VeyonSignedManifest -Bytes $validBytes -Signature $wrongPadding -Root $testRoot } 'PKCS1 padding accepted'
    $other = New-Object Security.Cryptography.RSACng(3072)
    try { $wrongKey = $other.SignData($validBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss) }
    finally { $other.Dispose() }
    Assert-Rejected { Test-VeyonSignedManifest -Bytes $validBytes -Signature $wrongKey -Root $testRoot } 'Wrong key accepted'
    Write-Host 'PASS: native Windows RSA-3072/PSS, tamper, wrong key, wrong padding and production pin'

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $payloadFiles = [ordered]@{
        'Veyon-AutoUpdate.ps1' = [Text.Encoding]::ASCII.GetBytes('param([switch]$Testlauf)' + "`r`n" + 'if (-not $Testlauf) { throw "test fixture" }' + "`r`n")
        'Veyon-SelfUpdate.ps1' = [Text.Encoding]::ASCII.GetBytes('# disposable test payload' + "`r`n")
    }
    function New-TestArchive([string]$Path,[string]$SecondName='Veyon-SelfUpdate.ps1') {
        $archive = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $index=0
            foreach ($name in $payloadFiles.Keys) {
                $entryName = if ($index -eq 1) { $SecondName } else { $name }
                $entry = $archive.CreateEntry($entryName)
                $stream = $entry.Open()
                try { $stream.Write($payloadFiles[$name],0,$payloadFiles[$name].Length) } finally { $stream.Dispose() }
                $index++
            }
        } finally { $archive.Dispose() }
        Set-VeyonProtectedAcl -Path $Path
    }
    $records = @()
    foreach ($name in $payloadFiles.Keys) { $records += [pscustomobject]@{path=$name;length=$payloadFiles[$name].Length;sha256=(Get-VeyonSha256 -Bytes $payloadFiles[$name])} }
    $archivePath = Join-Path (Join-Path $testRoot 'staging') 'good.zip'
    New-TestArchive $archivePath
    $archiveBytes = [IO.File]::ReadAllBytes($archivePath)
    $manifestBytes = New-TestManifestBytes -Files $records -ArchiveBytes $archiveBytes
    $releaseManifest = ConvertFrom-VeyonManifest -Bytes $manifestBytes
    $record = [pscustomobject]@{version='1.5.1';directory=('1.5.1-'+$releaseManifest.sha256.Substring(0,16));sourceCommit=('a'*40);files=$records}
    $destination = Join-Path (Join-Path $testRoot 'versions') $record.directory
    Expand-VeyonVerifiedPayload -Archive $archivePath -Manifest $releaseManifest -Destination $destination
    Assert-VeyonVersionFiles -Root $testRoot -Record $record | Out-Null
    Test-VeyonPayloadHealth -Directory $destination
    $state = [pscustomobject]@{schema=1;current=$record;previous=$null;highestVersion='1.5.1';failedVersion=$null}
    Write-VeyonState -Root $testRoot -State $state
    Assert-True ((Read-VeyonState -Root $testRoot).current.version -eq '1.5.1') 'Atomic state initial write failed'
    $state.highestVersion='1.5.2'; $state.failedVersion='1.5.2'
    Write-VeyonState -Root $testRoot -State $state
    $recovered = Read-VeyonState -Root $testRoot
    Assert-True ($recovered.highestVersion -eq '1.5.2' -and $recovered.current.version -eq '1.5.1') 'Rollback lost high-water mark'
    foreach ($name in @('../escape.ps1','Veyon-SelfUpdate.ps1:evil','VEYON-AUTOUPDATE.PS1','C:\escape.ps1','Veyon-AutoUpdate.ps1')) {
        $badArchive = Join-Path (Join-Path $testRoot 'staging') ([guid]::NewGuid().ToString('N')+'.zip')
        New-TestArchive -Path $badArchive -SecondName $name
        $badManifest = ConvertFrom-VeyonManifest -Bytes (New-TestManifestBytes -Files $records -ArchiveBytes ([IO.File]::ReadAllBytes($badArchive)))
        $badDestination = Join-Path (Join-Path $testRoot 'staging') ([guid]::NewGuid().ToString('N'))
        Assert-Rejected { Expand-VeyonVerifiedPayload -Archive $badArchive -Manifest $badManifest -Destination $badDestination } 'Unsafe ZIP accepted'
        Assert-True (-not [IO.Directory]::Exists($badDestination)) 'Unsafe ZIP created an extraction directory'
        [IO.File]::Delete($badArchive)
    }
    $badHashManifest = ConvertFrom-VeyonManifest -Bytes $manifestBytes
    $badHashManifest.files[0].sha256='e'*64
    Assert-Rejected { Expand-VeyonVerifiedPayload -Archive $archivePath -Manifest $badHashManifest -Destination (Join-Path (Join-Path $testRoot 'staging') 'bad-content') } 'File hash mismatch accepted'
    $badBytes = [byte[]]$archiveBytes.Clone(); $badBytes[0] = $badBytes[0] -bxor 1
    [IO.File]::WriteAllBytes($archivePath,$badBytes)
    Assert-Rejected { Expand-VeyonVerifiedPayload -Archive $archivePath -Manifest $releaseManifest -Destination (Join-Path (Join-Path $testRoot 'staging') 'bad-archive') } 'Archive hash mismatch accepted'
    Assert-True ((Read-VeyonState -Root $testRoot).current.version -eq '1.5.1') 'Rejected package changed active state'
    Write-Host 'PASS: bounded ZIP extraction, paths, duplicates, archive/file hashes, health and atomic rollback state'

    & {
        function Test-VeyonCheckDue { param($Root); return $true }
        $nextBytes = New-TestManifestBytes -Files $records -ArchiveBytes $archiveBytes -Version '1.5.3'
        $nextSignature = $key.SignData($nextBytes,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pss)
        $script:NetworkCase = 'offline'
        function Receive-VeyonBytes {
            param([uri]$Uri,[int]$MaximumBytes)
            if ($script:NetworkCase -eq 'offline') { throw 'Simulated offline connection' }
            if ($Uri.AbsolutePath.EndsWith('/latest')) {
                $preview = if ($script:NetworkCase -eq 'preview') { 'true' } else { 'false' }
                return ,([Text.Encoding]::ASCII.GetBytes('{"draft":false,"prerelease":'+$preview+',"tag_name":"1.5.3"}'))
            }
            if ($Uri.AbsolutePath.EndsWith('.manifest')) { return ,$nextBytes }
            if ($Uri.AbsolutePath.EndsWith('.sig')) {
                if ($script:NetworkCase -eq 'wrong-signature') { return ,(New-Object byte[] 384) }
                return ,$nextSignature
            }
            return ,$archiveBytes
        }
        foreach ($case in @('offline','preview','wrong-signature')) {
            $script:NetworkCase=$case
            Assert-Rejected { Invoke-VeyonSelfUpdate -Root $testRoot -State (Read-VeyonState -Root $testRoot) } 'Unsafe update attempt succeeded'
            Assert-True ((Read-VeyonState -Root $testRoot).current.version -eq '1.5.1') 'Failed download/verification changed current version'
        }
        $script:NetworkCase='valid'
        & {
            function Write-VeyonState { param($Root,$State); throw 'Simulated interruption before atomic activation' }
            Assert-Rejected { Invoke-VeyonSelfUpdate -Root $testRoot -State (Read-VeyonState -Root $testRoot) } 'Interrupted activation unexpectedly succeeded'
        }
        Assert-True ((Read-VeyonState -Root $testRoot).current.version -eq '1.5.1') 'Pre-commit interruption changed active state'
        $activated = Invoke-VeyonSelfUpdate -Root $testRoot -State (Read-VeyonState -Root $testRoot)
        Assert-True ($activated.current.version -eq '1.5.3' -and $activated.previous.version -eq '1.5.1') 'Valid update did not retain fallback'
        Assert-True ((Read-VeyonState -Root $testRoot).highestVersion -eq '1.5.3') 'Activation lost high-water mark'
        $script:NetworkCase='wrong-signature'
        $same = Invoke-VeyonSelfUpdate -Root $testRoot -State (Read-VeyonState -Root $testRoot)
        Assert-True ($same.current.version -eq '1.5.3') 'Accepted replay attempted another activation'
        $nextBytes = New-TestManifestBytes -Files $records -ArchiveBytes $archiveBytes -Version '1.5.0'
        function Receive-VeyonBytes { param([uri]$Uri,[int]$MaximumBytes)
            if (-not $Uri.AbsolutePath.EndsWith('/latest')) { throw 'Downgrade attempted an asset download' }
            return ,([Text.Encoding]::ASCII.GetBytes('{"draft":false,"prerelease":false,"tag_name":"1.5.0"}'))
        }
        Invoke-VeyonSelfUpdate -Root $testRoot -State (Read-VeyonState -Root $testRoot) | Out-Null
        Assert-True ((Read-VeyonState -Root $testRoot).current.version -eq '1.5.3') 'Downgrade changed current version'
    }
    Write-Host 'PASS: offline, prerelease, invalid signature, interrupted activation, valid activation, replay and downgrade'

    [IO.File]::WriteAllText((Join-Path $testRoot 'state.json'),'broken')
    Assert-Rejected { Read-VeyonState -Root $testRoot } 'Corrupt state silently accepted'
    Write-Host 'PASS: corrupt state fails closed'
} finally {
    if ($lock) { $lock.Dispose() }
    if ($certificate) { $certificate.Dispose() }
    if ($key) { $key.Dispose() }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot,$true) }
}
