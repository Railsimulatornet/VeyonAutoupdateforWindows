# Veyon Updater V1.5.0
# Called only by the protected bootstrap while holding update.lock.

function Write-VeyonSelfUpdateLog {
    param([string]$Root, [string]$Message)
    $path = Join-Path $Root 'selfupdate.log'
    Assert-VeyonSafePath -Path $path
    if ([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -gt 256KB) {
        [IO.File]::Delete($path)
    }
    [IO.File]::AppendAllText($path, ('[{0:u}] {1}{2}' -f [DateTime]::UtcNow,$Message,[Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false)))
    Set-VeyonProtectedAcl -Path $path
}

function Receive-VeyonBytes {
    param([Parameter(Mandatory=$true)][uri]$Uri, [Parameter(Mandatory=$true)][int]$MaximumBytes)
    $allowed = @('api.github.com','github.com','release-assets.githubusercontent.com','objects.githubusercontent.com')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        for ($redirect=0; $redirect -le 4; $redirect++) {
            if ($Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.DnsSafeHost -cnotin $allowed) {
                throw 'Unapproved release download address.'
            }
            if ($watch.Elapsed.TotalSeconds -gt 45) { throw 'Release download timed out.' }
            $request = [Net.HttpWebRequest]::Create($Uri)
            $request.Method = 'GET'
            $request.UserAgent = 'VeyonUpdater/1.5.0'
            $request.Accept = if ($Uri.DnsSafeHost -ceq 'api.github.com') { 'application/vnd.github+json' } else { 'application/octet-stream' }
            $request.Timeout = 10000
            $request.ReadWriteTimeout = 10000
            $request.AllowAutoRedirect = $false
            $request.UseDefaultCredentials = $false
            $request.AutomaticDecompression = [Net.DecompressionMethods]::None
            $response = $null
            try {
                $response = [Net.HttpWebResponse]$request.GetResponse()
                $status = [int]$response.StatusCode
                if ($status -in @(301,302,303,307,308)) {
                    $location = $response.Headers['Location']
                    if (-not $location -or $redirect -eq 4) { throw 'Invalid download redirect.' }
                    $Uri = New-Object uri($Uri,$location)
                    continue
                }
                if ($status -ne 200 -or $response.ContentLength -gt $MaximumBytes) { throw 'Unexpected release response.' }
                $input = $response.GetResponseStream()
                $output = New-Object IO.MemoryStream
                try {
                    $buffer = New-Object byte[] 8192
                    while (($count = $input.Read($buffer,0,$buffer.Length)) -gt 0) {
                        if ($watch.Elapsed.TotalSeconds -gt 45) { throw 'Release download timed out.' }
                        if ($output.Length + $count -gt $MaximumBytes) { throw 'Release download size limit exceeded.' }
                        $output.Write($buffer,0,$count)
                    }
                    return ,$output.ToArray()
                } finally { $input.Dispose(); $output.Dispose() }
            } finally { if ($response) { $response.Dispose() }; $request.Abort() }
        }
        throw 'Release redirect limit exceeded.'
    } finally { [Net.ServicePointManager]::SecurityProtocol = $oldTls }
}

function Remove-VeyonUnusedVersions {
    param([string]$Root, $State)
    $keep = @($State.current.directory)
    if ($null -ne $State.previous) { $keep += $State.previous.directory }
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $Root 'versions') -Force) {
        if ($item.Name -notin $keep) {
            Assert-VeyonSafePath -Path $item.FullName
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        }
    }
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $Root 'staging') -Force) {
        Assert-VeyonSafePath -Path $item.FullName
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
    }
}

function Test-VeyonCheckDue {
    param([string]$Root)
    $path = Join-Path $Root 'selfupdate-check.txt'
    Assert-VeyonSafePath -Path $path
    $now = [DateTime]::UtcNow
    if ([IO.File]::Exists($path) -and (Get-Item -LiteralPath $path).Length -le 64) {
        $last = [DateTime]::MinValue
        if ([DateTime]::TryParseExact([IO.File]::ReadAllText($path), 'O',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$last)) {
            $age = $now - $last.ToUniversalTime()
            if ($age.TotalHours -ge 0 -and $age.TotalHours -lt 24) { return $false }
        }
    }
    [IO.File]::WriteAllText($path,$now.ToString('O',[Globalization.CultureInfo]::InvariantCulture),[Text.Encoding]::ASCII)
    Set-VeyonProtectedAcl -Path $path
    return $true
}

function Invoke-VeyonSelfUpdate {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)]$State)
    Assert-VeyonProtectedRoot -Root $Root
    Assert-VeyonState -State $State
    Remove-VeyonUnusedVersions -Root $Root -State $State
    if (-not (Test-VeyonCheckDue -Root $Root)) { return $State }
    $repository = 'https://api.github.com/repos/Railsimulatornet/VeyonAutoupdateforWindows/releases/latest'
    $responseBytes = Receive-VeyonBytes -Uri $repository -MaximumBytes 1MB
    $release = (New-Object Text.UTF8Encoding($false,$true)).GetString($responseBytes) | ConvertFrom-Json -ErrorAction Stop
    if ($release.draft -ne $false -or $release.prerelease -ne $false -or $release.tag_name -isnot [string]) {
        throw 'A stable published release is required.'
    }
    if ($release.tag_name -ceq '1.4') { return $State }
    $version = ConvertTo-VeyonVersion -Value $release.tag_name
    if ($version -le (ConvertTo-VeyonVersion -Value $State.highestVersion)) { return $State }
    $base = 'https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/releases/download/' + $release.tag_name + '/'
    $manifestBytes = Receive-VeyonBytes -Uri ($base + 'VeyonUpdater-release.manifest') -MaximumBytes 4096
    $signature = Receive-VeyonBytes -Uri ($base + 'VeyonUpdater-release.manifest.sig') -MaximumBytes 384
    $manifest = Test-VeyonSignedManifest -Bytes $manifestBytes -Signature $signature -Root $Root
    if ($manifest.version -cne $release.tag_name) { throw 'Signed release identity mismatch.' }
    $payload = Receive-VeyonBytes -Uri ($base + $manifest.payload) -MaximumBytes ([int]$manifest.length)
    if ($payload.Length -ne $manifest.length -or (Get-VeyonSha256 -Bytes $payload) -cne $manifest.sha256) {
        throw 'Downloaded release checksum mismatch.'
    }
    $id = [guid]::NewGuid().ToString('N')
    $archive = Join-Path (Join-Path $Root 'staging') ($id + '.zip')
    $staging = Join-Path (Join-Path $Root 'staging') $id
    $record = [pscustomobject]@{
        version=$manifest.version
        directory=($manifest.version + '-' + $manifest.sha256.Substring(0,16))
        sourceCommit=$manifest.sourceCommit
        files=$manifest.files
    }
    $destination = Join-Path (Join-Path $Root 'versions') $record.directory
    try {
        [IO.File]::WriteAllBytes($archive,$payload)
        Set-VeyonProtectedAcl -Path $archive
        Expand-VeyonVerifiedPayload -Archive $archive -Manifest $manifest -Destination $staging
        if ([IO.Directory]::Exists($destination)) { throw 'Release destination already exists.' }
        [IO.Directory]::Move($staging,$destination)
        Assert-VeyonVersionFiles -Root $Root -Record $record | Out-Null
        try { Test-VeyonPayloadHealth -Directory $destination } catch {
            # Keep the high-water mark even if a signed release fails its offline healthcheck.
            $State.highestVersion = $record.version
            $State.failedVersion = $record.version
            Write-VeyonState -Root $Root -State $State
            throw
        }
        $next = [pscustomobject]@{schema=1;current=$record;previous=$State.current;
            highestVersion=$record.version;failedVersion=$null}
        Write-VeyonState -Root $Root -State $next
        Write-VeyonSelfUpdateLog -Root $Root -Message ('Updater ' + $record.version + ' aktiviert.')
        return $next
    } finally {
        foreach ($path in @($archive,$staging)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
        }
    }
}
