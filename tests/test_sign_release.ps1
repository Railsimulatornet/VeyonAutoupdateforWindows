param([switch]$Portable)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Portable -and $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run the complete signer test in Windows PowerShell 5.1.'
}
$sourceRoot = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon-sign-test-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $temporary 'source'
$assets = Join-Path $temporary 'assets'
$signaturePath = Join-Path $assets 'VeyonUpdater-release.manifest.sig'
$productionPin = '7b698f2726348060cddf8b10a5a82d39ed907062265edf2e926dd9d6c5a72b7d'
$passwordText = 'Disposable-release-test-only-2026'
$key = $null
$certificate = $null
$wrongKey = $null
$wrongCertificate = $null
$originalSevenZip = $env:SEVEN_ZIP

function Assert-SignerRejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw $Message }
}
function Invoke-FixtureGit([string[]]$Arguments) {
    $result = @(& $git -C $fixture @Arguments)
    if ($LASTEXITCODE -ne 0) { throw 'Fixture Git command failed.' }
    return $result
}
function New-DisposableCertificate($Rsa) {
    $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=Veyon Updater disposable signing test', $Rsa,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
}

try {
    $null = [IO.Directory]::CreateDirectory($fixture)
    $null = [IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts'))
    $null = [IO.Directory]::CreateDirectory((Join-Path $fixture 'packaging'))
    $config = Get-Content -LiteralPath (Join-Path $sourceRoot 'release.json') -Raw | ConvertFrom-Json
    foreach ($name in @($config.files) + @('release.json', 'scripts/build_release.py', 'scripts/Sign-VeyonRelease.ps1', 'packaging/7zSD.sfx')) {
        $destination = Join-Path $fixture $name
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy((Join-Path $sourceRoot $name), $destination, $true)
    }
    $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
    $python = $pythonCommand.Source
    $sevenZip = $env:SEVEN_ZIP
    if (-not $sevenZip) { $sevenZip = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) '7-Zip\7z.exe' }
    if (-not [IO.File]::Exists($sevenZip)) { throw '7-Zip is required for the signer test.' }
    $env:SEVEN_ZIP = $sevenZip
    if ($Portable) { $key = [Security.Cryptography.RSA]::Create(); $key.KeySize = 3072 }
    else { $key = [Security.Cryptography.RSACng]::new(3072) }
    $certificate = New-DisposableCertificate $key
    $publicPath = Join-Path $fixture 'VeyonUpdater-release-public.cer'
    [IO.File]::WriteAllBytes($publicPath, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    $pin = (Get-FileHash -LiteralPath $publicPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $pfxPath = Join-Path $temporary 'disposable-private.pfx'
    [IO.File]::WriteAllBytes($pfxPath, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $passwordText))

    # Only this isolated copy accepts the disposable key and supplies test input.
    $signerPath = Join-Path $fixture 'scripts/Sign-VeyonRelease.ps1'
    $signerText = [IO.File]::ReadAllText($signerPath)
    if (-not $signerText.Contains($productionPin)) { throw 'Production pin missing from signer.' }
    $signerText = $signerText.Replace($productionPin, $pin)
    $approvalLine = '$approval = Read-Host "Fuer die lokale Signierfreigabe SIGNIEREN $version eingeben"'
    $passwordLine = '$password = Read-Host ''PFX-Passwort'' -AsSecureString'
    if (-not $signerText.Contains($approvalLine) -or -not $signerText.Contains($passwordLine)) { throw 'Signer prompt contract changed.' }
    $signerText = $signerText.Replace($approvalLine, '$approval = "SIGNIEREN $version"')
    $signerText = $signerText.Replace($passwordLine, ('$password = ConvertTo-SecureString ''' + $passwordText + ''' -AsPlainText -Force'))
    if ($Portable) {
        $signerText = $signerText.Replace('[PlatformID]::Win32NT', '[Environment]::OSVersion.Platform')
        $signerText = $signerText.Replace('Get-Command git.exe', 'Get-Command git')
        $signerText = $signerText.Replace('[Security.Cryptography.RSACng]::new()', '[Security.Cryptography.RSA]::Create()')
    }
    [IO.File]::WriteAllText($signerPath, $signerText, [Text.UTF8Encoding]::new($false))
    $builderPath = Join-Path $fixture 'scripts/build_release.py'
    $builderText = [IO.File]::ReadAllText($builderPath).Replace($productionPin, $pin)
    [IO.File]::WriteAllText($builderPath, $builderText, [Text.UTF8Encoding]::new($false))
    $hooks = Join-Path $temporary 'empty-hooks'
    $null = [IO.Directory]::CreateDirectory($hooks)
    Invoke-FixtureGit @('init', '--template=', '--initial-branch=main') | Out-Null
    Invoke-FixtureGit @('config', 'core.hooksPath', $hooks) | Out-Null
    Invoke-FixtureGit @('config', 'core.autocrlf', 'false') | Out-Null
    Invoke-FixtureGit @('add', '--all') | Out-Null
    Invoke-FixtureGit @('-c', 'user.name=Release test', '-c', 'user.email=release-test@example.invalid', 'commit', '-m', 'Release test fixture') | Out-Null
    $commit = ([string](Invoke-FixtureGit @('rev-parse', 'HEAD'))).Trim()
    & $python $builderPath --output $assets
    if ($LASTEXITCODE -ne 0) { throw 'Fixture build failed.' }
    $arguments = @{AssetDirectory=$assets; SourceCommit=$commit; PfxPath=$pfxPath; SevenZip=$sevenZip}
    & $signerPath @arguments -ValidateOnly
    if ([IO.File]::Exists($signaturePath)) { throw 'Read-only validation wrote a signature.' }
    Write-Host 'PASS: complete artifact validation without a private-key operation'

    Assert-SignerRejected { & $signerPath -AssetDirectory $assets -SourceCommit ('0'*40) -PfxPath $pfxPath -SevenZip $sevenZip -ValidateOnly } 'Wrong source commit accepted.'
    $readmePath = Join-Path $fixture 'README.md'
    $originalReadme = [IO.File]::ReadAllBytes($readmePath)
    try {
        [IO.File]::AppendAllText($readmePath, "`nchanged`n")
        Assert-SignerRejected { & $signerPath @arguments -ValidateOnly } 'Modified source checkout accepted.'
    } finally { [IO.File]::WriteAllBytes($readmePath, $originalReadme) }
    foreach ($flag in @('skip-worktree', 'assume-unchanged')) {
        Invoke-FixtureGit @('update-index', ('--' + $flag), '--', 'README.md') | Out-Null
        try { Assert-SignerRejected { & $signerPath @arguments -ValidateOnly } "Hidden index flag accepted: $flag" }
        finally { Invoke-FixtureGit @('update-index', ('--no-' + $flag), '--', 'README.md') | Out-Null }
    }
    $manifestPath = Join-Path $assets $config.manifest
    $manifest = [IO.File]::ReadAllBytes($manifestPath)
    try {
        [IO.File]::WriteAllText($manifestPath, [Text.Encoding]::ASCII.GetString($manifest).Replace('channel=stable', 'channel=preview'), [Text.Encoding]::ASCII)
        Assert-SignerRejected { & $signerPath @arguments -ValidateOnly } 'Wrong update channel accepted.'
    } finally { [IO.File]::WriteAllBytes($manifestPath, $manifest) }
    $updatePath = Join-Path $assets $config.update_archive
    $update = [IO.File]::ReadAllBytes($updatePath)
    try {
        [IO.File]::WriteAllBytes($updatePath, $update[0..($update.Length-2)])
        Assert-SignerRejected { & $signerPath @arguments -ValidateOnly } 'Changed update package accepted.'
    } finally { [IO.File]::WriteAllBytes($updatePath, $update) }
    Write-Host 'PASS: wrong source commit, dirty checkout, hidden index flags, wrong channel and changed payload rejected'

    $wrongPasswordPath = Join-Path $temporary 'wrong-password.pfx'
    [IO.File]::WriteAllBytes($wrongPasswordPath, $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'Different-disposable-password'))
    Assert-SignerRejected { & $signerPath -AssetDirectory $assets -SourceCommit $commit -PfxPath $wrongPasswordPath -SevenZip $sevenZip } 'Wrong PFX password accepted.'
    if ($Portable) { $wrongKey = [Security.Cryptography.RSA]::Create(); $wrongKey.KeySize = 3072 }
    else { $wrongKey = [Security.Cryptography.RSACng]::new(3072) }
    $wrongCertificate = New-DisposableCertificate $wrongKey
    $wrongKeyPath = Join-Path $temporary 'wrong-key.pfx'
    [IO.File]::WriteAllBytes($wrongKeyPath, $wrongCertificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $passwordText))
    Assert-SignerRejected { & $signerPath -AssetDirectory $assets -SourceCommit $commit -PfxPath $wrongKeyPath -SevenZip $sevenZip } 'Wrong private key accepted.'
    if ([IO.File]::Exists($signaturePath)) { throw 'Failed signing left a signature file.' }
    Write-Host 'PASS: wrong password and wrong private key leave no signature'

    & $signerPath @arguments
    $signature = [IO.File]::ReadAllBytes($signaturePath)
    if ($signature.Length -ne 384 -or -not $key.VerifyData($manifest, $signature,
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)) {
        throw 'The signer did not produce a valid RSA-3072/PSS signature.'
    }
    Assert-SignerRejected { & $signerPath @arguments } 'Existing signature was overwritten.'
    $after = [IO.File]::ReadAllBytes($signaturePath)
    if ([Convert]::ToBase64String($after) -cne [Convert]::ToBase64String($signature)) { throw 'Signature changed after rejected overwrite.' }
    Write-Host 'PASS: ephemeral PFX import, RSA-3072/PSS signing, verification and no overwrite'
    if ($Portable) { Write-Host 'Portable signing passed; Windows CNG/PowerShell 5.1 validation remains a separate check.' }
} finally {
    if ($wrongCertificate) { $wrongCertificate.Dispose() }
    if ($wrongKey) { $wrongKey.Dispose() }
    if ($certificate) { $certificate.Dispose() }
    if ($key) { $key.Dispose() }
    $env:SEVEN_ZIP = $originalSevenZip
    if ([IO.Directory]::Exists($temporary)) { [IO.Directory]::Delete($temporary, $true) }
}
