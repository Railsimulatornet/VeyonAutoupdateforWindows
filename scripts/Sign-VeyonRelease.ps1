#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AssetDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('\A[0-9a-f]{40}\z')][string]$SourceCommit,
    [string]$PfxPath = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VeyonReleaseSigning\VeyonUpdater-release-private.pfx'),
    [string]$SevenZip = (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) '7-Zip\7z.exe'),
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$certificateHash = '7b698f2726348060cddf8b10a5a82d39ed907062265edf2e926dd9d6c5a72b7d'
$updateNames = @('Veyon-AutoUpdate.ps1', 'Veyon-SelfUpdate.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ReleaseHash([byte[]]$Bytes) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Read-ReleaseBytes([string]$Path, [long]$Maximum) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt $Maximum) { throw "Unzulaessige Dateigroesse: $Path" }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $count = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($count -eq 0) { throw "Datei wurde unvollstaendig gelesen: $Path" }
            $offset += $count
        }
        return ,$bytes
    } finally { $stream.Dispose() }
}

function Read-ReleaseZip([byte[]]$Bytes, [string[]]$ExpectedNames) {
    $memory = [IO.MemoryStream]::new($Bytes, $false)
    $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
    $files = @{}
    try {
        if ($archive.Entries.Count -ne $ExpectedNames.Count) { throw 'Unerwartete ZIP-Dateiliste.' }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if ($name -cnotin $ExpectedNames -or $files.ContainsKey($name) -or $entry.Length -lt 1 -or $entry.Length -gt 4MB) {
                throw "Unerwarteter oder doppelter ZIP-Eintrag: $name"
            }
            $kind = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($kind -ne 0 -and $kind -ne 0x8000) { throw 'ZIP enthaelt einen besonderen Dateityp.' }
            $inputStream = $entry.Open()
            $output = [IO.MemoryStream]::new()
            try {
                $buffer = New-Object byte[] 8192
                while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($output.Length + $read -gt $entry.Length) { throw 'ZIP-Eintrag ueberschreitet die angegebene Groesse.' }
                    $output.Write($buffer, 0, $read)
                }
                if ($output.Length -ne $entry.Length) { throw 'Unvollstaendiger ZIP-Eintrag.' }
                $files[$name] = $output.ToArray()
            } finally {
                $inputStream.Dispose()
                $output.Dispose()
            }
        }
        return $files
    } finally {
        $archive.Dispose()
        $memory.Dispose()
    }
}

function Get-CanonicalReleaseBytes([string]$Name) {
    $bytes = Read-ReleaseBytes (Join-Path $repositoryRoot $Name) 4MB
    if ([IO.Path]::GetExtension($Name).ToLowerInvariant() -in @('.cer', '.pdf', '.sfx', '.png', '.jpg', '.jpeg', '.ico')) {
        return ,$bytes
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($bytes).Replace("`r`n", "`n")
    if ([IO.Path]::GetExtension($Name).ToLowerInvariant() -in @('.ps1', '.cmd')) { $text = $text.Replace("`n", "`r`n") }
    return ,$encoding.GetBytes($text)
}

function Read-SevenZipOutput([string[]]$Arguments, [long]$Maximum) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $SevenZip
    $info.Arguments = ($Arguments | ForEach-Object {
        if ($_.Contains('"') -or $_.EndsWith('\')) { throw 'Ungueltiges 7-Zip-Argument.' }
        '"' + $_ + '"'
    }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $output = [IO.MemoryStream]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    try {
        $errorText = $process.StandardError.ReadToEndAsync()
        $buffer = New-Object byte[] 8192
        while ($true) {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { throw 'Zeitlimit bei der Paketpruefung.' }
            $readTask = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait($remaining)) { throw 'Zeitlimit bei der Paketpruefung.' }
            $count = $readTask.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            if ($output.Length + $count -gt $Maximum) { throw '7-Zip-Ausgabe ueberschreitet das Groessenlimit.' }
            $output.Write($buffer, 0, $count)
        }
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $process.WaitForExit($remaining)) { throw 'Zeitlimit bei der Paketpruefung.' }
        $null = $errorText.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "7-Zip-Paketpruefung fehlgeschlagen: $($process.ExitCode)" }
        return ,$output.ToArray()
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
        $output.Dispose()
    }
}

function Test-SetupContents([byte[]]$SetupBytes, [hashtable]$Files, [object]$Config, [string]$Temporary) {
    $stub = Read-ReleaseBytes (Join-Path $repositoryRoot 'packaging/7zSD.sfx') 1MB
    if ((Get-ReleaseHash $stub) -cne $Config.sfx_sha256) { throw 'SFX-Pruefsumme stimmt nicht.' }
    $header = [Text.Encoding]::UTF8.GetBytes((';!@Install@!UTF-8!' + "`n" + 'Title="Veyon Updater v' + $Config.version +
        '"' + "`n" + 'BeginPrompt="Veyon Updater installieren?"' + "`n" +
        'Progress="no"' + "`n" + 'Directory=""' + "`n" +
        'RunProgram="cmd.exe /d /c Install-Veyon-AutoUpdate.cmd"' + "`n" + ';!@InstallEnd@!' + "`n"))
    if ($SetupBytes.Length -le $stub.Length + $header.Length) { throw 'Setup ist unvollstaendig.' }
    for ($index = 0; $index -lt $stub.Length; $index++) {
        if ($SetupBytes[$index] -ne $stub[$index]) { throw 'Setup enthaelt ein abweichendes SFX-Modul.' }
    }
    for ($index = 0; $index -lt $header.Length; $index++) {
        if ($SetupBytes[$stub.Length + $index] -ne $header[$index]) { throw 'Setup startet ein abweichendes Installationsprogramm.' }
    }
    $snapshot = Join-Path $Temporary 'setup.exe'
    [IO.File]::WriteAllBytes($snapshot, $SetupBytes)
    $listingBytes = Read-SevenZipOutput @('l', '-slt', '-ba', '-sccUTF-8', '--', $snapshot) 256KB
    $listing = [Text.UTF8Encoding]::new($false, $true).GetString($listingBytes)
    $listed = @{}
    foreach ($record in @($listing.Trim() -split '\r?\n\r?\n')) {
        $lines = @($record -split '\r?\n')
        if ($lines.Count -lt 2 -or $lines[0] -cnotmatch '\APath = (.+)\z') { throw 'Unlesbare Setup-Dateiliste.' }
        $name = $Matches[1].Replace('\', '/')
        if ($name -cnotin @($Files.Keys) -or $listed.ContainsKey($name)) { throw "Unerwartete Setup-Datei: $name" }
        $fields = @{}
        foreach ($line in $lines) {
            if ($line -cnotmatch '\A([A-Za-z0-9 ]+) = ([^\r\n]*)\z' -or $fields.ContainsKey($Matches[1])) {
                throw 'Uneindeutige Setup-Dateiliste.'
            }
            if ($Matches[1] -match 'Link') { throw 'Setup enthaelt einen Link.' }
            $fields[$Matches[1]] = $Matches[2]
        }
        $listed[$name] = $true
    }
    if ($listed.Count -ne $Files.Count) { throw 'Setup-Dateiliste ist unvollstaendig.' }
    foreach ($name in $Files.Keys) {
        $content = Read-SevenZipOutput @('x', '-so', '-y', '--', $snapshot, $name) $Files[$name].Length
        if ($content.Length -ne $Files[$name].Length -or (Get-ReleaseHash $content) -cne (Get-ReleaseHash $Files[$name])) {
            throw "Setup und ZIP unterscheiden sich: $name"
        }
    }
}

function Invoke-ReleaseSigning {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Dieses Signierwerkzeug benoetigt Windows.' }
    $assetRoot = (Get-Item -LiteralPath $AssetDirectory).FullName
    if (-not [IO.Directory]::Exists($assetRoot)) { throw 'Artefaktverzeichnis fehlt.' }
    if (-not [IO.Path]::IsPathRooted($SevenZip) -or -not [IO.File]::Exists($SevenZip)) { throw '7-Zip fehlt. Bei Bedarf -SevenZip mit dem absoluten EXE-Pfad angeben.' }
    $git = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $head = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $SourceCommit) { throw 'Der Checkout entspricht nicht dem freigegebenen SourceCommit.' }
    $status = @(& $git.Source -C $repositoryRoot -c core.fsmonitor=false status --porcelain --untracked-files=no)
    if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) { throw 'Zum Signieren wird ein unveraenderter Git-Checkout benoetigt.' }
    $config = [Text.UTF8Encoding]::new($false, $true).GetString((Read-ReleaseBytes (Join-Path $repositoryRoot 'release.json') 16KB)) | ConvertFrom-Json
    $expected = @($config.files) + @('BUILDINFO.json')
    $null = & $git.Source -C $repositoryRoot ls-files --error-unmatch -- @($config.files) 'release.json' 'scripts/Sign-VeyonRelease.ps1'
    if ($LASTEXITCODE -ne 0) { throw 'Nicht versionierte Paket- oder Signierdatei.' }
    $indexEntries = @(& $git.Source -C $repositoryRoot ls-files -v -- @($config.files) 'release.json' 'scripts/Sign-VeyonRelease.ps1' 'scripts/build_release.py')
    if ($LASTEXITCODE -ne 0 -or $indexEntries.Count -ne $config.files.Count + 3) { throw 'Der Git-Index ist unvollstaendig.' }
    foreach ($entry in $indexEntries) {
        if ($entry -cnotmatch '\AH [^\r\n]+\z') {
            throw 'Paket-, Build- und Signierdateien duerfen nicht mit assume-unchanged oder skip-worktree markiert sein.'
        }
    }
    $manifestPath = Join-Path $assetRoot 'VeyonUpdater-release.manifest'
    $manifestBytes = Read-ReleaseBytes $manifestPath 4096
    if (@($manifestBytes | Where-Object { $_ -gt 127 -or $_ -eq 13 }).Count -ne 0) { throw 'Manifest muss ASCII mit LF-Zeilenenden sein.' }
    $manifestText = [Text.Encoding]::ASCII.GetString($manifestBytes)
    $versionPattern = '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    $pattern = '\AVEYON-UPDATER-MANIFEST-1\nproduct=VeyonUpdater\nrepository=Railsimulatornet/VeyonAutoupdateforWindows\nchannel=stable\n' +
        'version=(?<version>' + $versionPattern + ')\ntag=\k<version>\nsource=(?<source>[0-9a-f]{40})\nbootstrap=1\n' +
        'payload=VeyonUpdater_v\k<version>_Update\.zip\nlength=(?<length>[1-9][0-9]{0,7})\nsha256=(?<hash>[0-9a-f]{64})\n' +
        'file=Veyon-AutoUpdate\.ps1\|(?<length0>[1-9][0-9]{0,6})\|(?<hash0>[0-9a-f]{64})\n' +
        'file=Veyon-SelfUpdate\.ps1\|(?<length1>[1-9][0-9]{0,6})\|(?<hash1>[0-9a-f]{64})\n\z'
    $match = [regex]::Match($manifestText, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { throw 'Manifest entspricht nicht dem Releaseformat.' }
    $version = $match.Groups['version'].Value
    if (@($version.Split('.') | Where-Object { [long]$_ -gt 65535 }).Count -ne 0 -or
        $version -cne $config.version -or $config.tag -cne $version -or $config.bootstrap_version -ne 1 -or
        $match.Groups['source'].Value -cne $SourceCommit) { throw 'Version, Bootstrap oder SourceCommit stimmen nicht ueberein.' }
    $assetNames = @(('VeyonUpdater_v' + $version + '.zip'), ('VeyonUpdater_v' + $version + '_Setup.exe'),
        ('VeyonUpdater_v' + $version + '_Update.zip'), 'VeyonUpdater-release.manifest')
    $assets = @{}
    foreach ($name in $assetNames) { $assets[$name] = Read-ReleaseBytes (Join-Path $assetRoot $name) 16MB }
    if ((Get-ReleaseHash $assets['VeyonUpdater-release.manifest']) -cne (Get-ReleaseHash $manifestBytes)) { throw 'Manifest wurde waehrend der Pruefung veraendert.' }
    $sums = [Text.Encoding]::ASCII.GetString((Read-ReleaseBytes (Join-Path $assetRoot 'SHA256SUMS') 4096))
    $verified = @{}
    foreach ($line in @($sums.TrimEnd("`n") -split "`n")) {
        if ($line -cnotmatch '\A([0-9a-f]{64})  ([A-Za-z0-9._-]+)\z') { throw 'Ungueltige SHA256SUMS.' }
        $name = $Matches[2]
        if ($name -cnotin $assetNames -or $verified.ContainsKey($name) -or (Get-ReleaseHash $assets[$name]) -cne $Matches[1]) {
            throw 'SHA256SUMS oder Paketdateien stimmen nicht ueberein.'
        }
        $verified[$name] = $true
    }
    if ($verified.Count -ne 4) { throw 'Unvollstaendige SHA256SUMS.' }
    $updateBytes = $assets[$assetNames[2]]
    if ($updateBytes.Length -gt 4MB -or $updateBytes.Length -ne [long]$match.Groups['length'].Value -or
        (Get-ReleaseHash $updateBytes) -cne $match.Groups['hash'].Value) { throw 'Updatepaket stimmt nicht mit dem Manifest ueberein.' }
    $files = Read-ReleaseZip $assets[$assetNames[0]] $expected
    $updateFiles = Read-ReleaseZip $updateBytes $updateNames
    $buildInfo = [Text.UTF8Encoding]::new($false, $true).GetString($files['BUILDINFO.json']) | ConvertFrom-Json
    if ($buildInfo.version -cne $version -or $buildInfo.source_commit -cne $SourceCommit -or
        @($buildInfo.sha256.PSObject.Properties).Count -ne $config.files.Count) { throw 'BUILDINFO stimmt nicht mit der Freigabe ueberein.' }
    foreach ($name in $config.files) {
        $actualHash = Get-ReleaseHash $files[$name]
        if ($buildInfo.sha256.PSObject.Properties[$name].Value -cne $actualHash -or
            (Get-ReleaseHash (Get-CanonicalReleaseBytes $name)) -cne $actualHash) {
            throw "Paket und gepruefter Quellstand unterscheiden sich: $name"
        }
    }
    for ($index = 0; $index -lt $updateNames.Count; $index++) {
        $name = $updateNames[$index]
        $bytes = $updateFiles[$name]
        if ($bytes.Length -gt 1MB -or $bytes.Length -ne [long]$match.Groups['length' + $index].Value -or
            (Get-ReleaseHash $bytes) -cne $match.Groups['hash' + $index].Value -or
            (Get-ReleaseHash $bytes) -cne (Get-ReleaseHash $files[$name])) { throw "Abweichende Updatedatei: $name" }
    }
    $publicBytes = $files['VeyonUpdater-release-public.cer']
    if ((Get-ReleaseHash $publicBytes) -cne $certificateHash) { throw 'Oeffentliches Zertifikat stimmt nicht mit dem festen Pin ueberein.' }
    $certificateInfo = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicBytes)
    try {
        if ([DateTime]::UtcNow -lt $certificateInfo.NotBefore.ToUniversalTime() -or
            [DateTime]::UtcNow -gt $certificateInfo.NotAfter.ToUniversalTime()) { throw 'Das Release-Zertifikat liegt ausserhalb seiner Laufzeit.' }
    } finally { $certificateInfo.Dispose() }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('veyon-release-check-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($temporary)
    try { Test-SetupContents $assets[$assetNames[1]] $files $config $temporary }
    finally { [IO.Directory]::Delete($temporary, $true) }
    Write-Host "Artefakte geprueft: Version $version, Commit $SourceCommit"
    Write-Host ('Manifest SHA-256: ' + (Get-ReleaseHash $manifestBytes))
    if ($ValidateOnly) { return }
    $signaturePath = $manifestPath + '.sig'
    if ([IO.File]::Exists($signaturePath)) { throw 'Signaturdatei existiert bereits; sie wird nicht ueberschrieben.' }
    if (-not [IO.File]::Exists($PfxPath)) { throw 'Private PFX-Datei fehlt.' }
    $approval = Read-Host "Fuer die lokale Signierfreigabe SIGNIEREN $version eingeben"
    if ($approval -cne "SIGNIEREN $version") { throw 'Signierung abgebrochen.' }
    $password = Read-Host 'PFX-Passwort' -AsSecureString
    $private = $null
    $public = $null
    $rsaPrivate = $null
    $rsaSource = $null
    $rsaPublic = $null
    $temporarySignature = $signaturePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        if ($null -eq $password -or $password.Length -eq 0) { throw 'Kein PFX-Passwort eingegeben.' }
        $private = [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $password,
            [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicBytes)
        if (-not $private.HasPrivateKey -or (Get-ReleaseHash $private.RawData) -cne $certificateHash -or
            [DateTime]::UtcNow -lt $private.NotBefore.ToUniversalTime() -or [DateTime]::UtcNow -gt $private.NotAfter.ToUniversalTime()) {
            throw 'Privater Schluessel oder Zertifikatslaufzeit ungueltig.'
        }
        $rsaPrivate = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($private)
        $rsaSource = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($public)
        $privatePublicParameters = $rsaPrivate.ExportParameters($false)
        $publicParameters = $rsaSource.ExportParameters($false)
        if ($privatePublicParameters.Modulus.Length -ne 384 -or $privatePublicParameters.Modulus[0] -lt 128 -or
            $publicParameters.Modulus.Length -ne 384 -or $publicParameters.Modulus[0] -lt 128) { throw 'RSA-3072 ist erforderlich.' }
        $rsaPublic = [Security.Cryptography.RSACng]::new()
        $rsaPublic.ImportParameters($publicParameters)
        $signature = $rsaPrivate.SignData($manifestBytes, [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pss)
        if ($signature.Length -ne 384 -or -not $rsaPublic.VerifyData($manifestBytes, $signature,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)) {
            throw 'Signaturpruefung fehlgeschlagen.'
        }
        foreach ($name in $assetNames) {
            if ((Get-ReleaseHash (Read-ReleaseBytes (Join-Path $assetRoot $name) 16MB)) -cne (Get-ReleaseHash $assets[$name])) {
                throw 'Artefakte wurden nach der Freigabe veraendert.'
            }
        }
        $stream = [IO.File]::Open($temporarySignature, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($signature, 0, $signature.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporarySignature, $signaturePath)
        Write-Host "Signatur erstellt und geprueft: $signaturePath"
    } finally {
        if ([IO.File]::Exists($temporarySignature)) { [IO.File]::Delete($temporarySignature) }
        if ($rsaPublic) { $rsaPublic.Dispose() }
        if ($rsaSource) { $rsaSource.Dispose() }
        if ($rsaPrivate) { $rsaPrivate.Dispose() }
        if ($public) { $public.Dispose() }
        if ($private) { $private.Dispose() }
        if ($password) { $password.Dispose() }
    }
}

Invoke-ReleaseSigning
