$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this suite in Windows PowerShell 5.1.' }
$sourceRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $sourceRoot 'VeyonUpdater.Security.ps1')
$root = Get-VeyonRoot
$programData = [Environment]::GetFolderPath('CommonApplicationData')
$probeRoot = Join-Path $programData ('VeyonSelfUpdateTest-' + [guid]::NewGuid().ToString('N'))
$taskName = 'Veyon Updater self-update test ' + [guid]::NewGuid().ToString('N')
$taskRegistered = $false
$rootCreated = $false
$probeCreated = $false
$key = $null
$certificate = $null

if ((Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -eq 'Veyon AutoUpdate (winget)') -or
    [IO.Directory]::Exists($root) -or [IO.File]::Exists($root) -or
    [IO.Directory]::Exists((Join-Path $programData 'Veyon'))) {
    throw 'The self-update suite requires a disposable clean Windows runner without existing Veyon data or task.'
}
foreach ($programRoot in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
    if ($programRoot -and [IO.Directory]::Exists((Join-Path $programRoot 'Veyon'))) {
        throw 'The self-update suite requires a disposable runner without a Veyon installation.'
    }
}

function Assert-True($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Write-ProtectedBytes([string]$Path, [byte[]]$Bytes) {
    [IO.File]::WriteAllBytes($Path, $Bytes)
    Set-VeyonProtectedAcl -Path $Path
}
function Set-TestRelease([string]$Version, [string]$Mode = 'valid') {
    $text = [pscustomobject]@{version=$Version;mode=$Mode} | ConvertTo-Json -Compress
    Write-ProtectedBytes -Path (Join-Path $probeRoot 'response.json') -Bytes ([Text.Encoding]::ASCII.GetBytes($text))
}
function Set-CheckDue {
    $old = [DateTime]::UtcNow.AddHours(-25).ToString('O', [Globalization.CultureInfo]::InvariantCulture)
    Write-ProtectedBytes -Path (Join-Path $root 'selfupdate-check.txt') -Bytes ([Text.Encoding]::ASCII.GetBytes($old))
}
function Get-RequestCount {
    $path = Join-Path $probeRoot 'requests.log'
    if (-not [IO.File]::Exists($path)) { return 0 }
    return [IO.File]::ReadAllLines($path).Length
}
function Assert-StagingEmpty {
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'staging') -Force).Count -eq 0) 'Self-update retained temporary extraction files.'
}
function Invoke-SystemRun([string]$Version, [switch]$ExpectFailure, [switch]$ActualRuntime) {
    $proofPath = Join-Path $root 'selfupdate-test-proof.json'
    if ([IO.File]::Exists($proofPath)) { [IO.File]::Delete($proofPath) }
    $runtimeLog = Join-Path $root 'veyon_autoupdate.log'
    if (($ActualRuntime -or $ExpectFailure) -and [IO.File]::Exists($runtimeLog)) { [IO.File]::Delete($runtimeLog) }
    $before = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    $limit = [DateTime]::UtcNow.AddSeconds(90)
    $finished = $false
    do {
        Start-Sleep -Milliseconds 250
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
        $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
        if ($task.State -eq 'Ready' -and
            ($info.LastRunTime -gt $before.LastRunTime -or $info.LastTaskResult -ne $before.LastTaskResult -or
                [IO.File]::Exists($proofPath) -or ($ActualRuntime -and [IO.File]::Exists($runtimeLog))) -and
            $info.LastTaskResult -ne 267009) {
            $finished = $true
            break
        }
    } while ([DateTime]::UtcNow -lt $limit)
    Assert-True $finished 'The SYSTEM self-update task did not finish in time.'
    if ($ExpectFailure) {
        Assert-True ($info.LastTaskResult -ne 0 -and -not [IO.File]::Exists($proofPath) -and
            -not [IO.File]::Exists($runtimeLog)) 'Corrupt state did not fail closed with a nonzero task result and no runtime execution.'
        return
    }
    Assert-True ($info.LastTaskResult -eq 0) ('The SYSTEM self-update task failed: ' + $info.LastTaskResult)
    if ($ActualRuntime) {
        Assert-True ([IO.File]::Exists($runtimeLog)) 'The actual runtime did not produce its normal-run log.'
        $log = [IO.File]::ReadAllText($runtimeLog)
        Assert-True ($log.Contains('Installierte Version unbekannt. Kein Upgrade und keine Quellenaenderung.') -or
            $log.Contains('winget im aktuellen Kontext nicht verf')) 'The actual runtime did not take its safe missing-installation path.'
        Assert-True (-not $log.Contains('winget: Quellen') -and -not $log.Contains('Ausf') -and
            -not $log.Contains('Update fehlgeschlagen:')) 'The clean-runner runtime changed sources, ran an upgrade or failed.'
        $state = Read-VeyonState -Root $root
        $runtimePath = Join-Path (Join-Path (Join-Path $root 'versions') $state.current.directory) 'Veyon-AutoUpdate.ps1'
        Assert-True ($state.current.version -ceq $Version -and
            (Get-FileHash -LiteralPath $runtimePath).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $sourceRoot 'Veyon-AutoUpdate.ps1')).Hash) 'The activated package does not contain the exact actual runtime source.'
        Assert-VeyonProtectedRoot -Root $root
        Assert-StagingEmpty
        return
    }
    Assert-True ([IO.File]::Exists($proofPath)) 'The activated runtime did not execute.'
    $proof = [IO.File]::ReadAllText($proofPath) | ConvertFrom-Json
    $state = Read-VeyonState -Root $root
    $expectedScript = Join-Path (Join-Path (Join-Path $root 'versions') $state.current.directory) 'Veyon-AutoUpdate.ps1'
    Assert-True ($proof.version -ceq $Version -and $state.current.version -ceq $Version) 'The launcher did not execute the active runtime version.'
    Assert-True ($proof.identity -ceq 'S-1-5-18') 'The runtime did not run as SYSTEM.'
    Assert-True ($proof.script -ieq $expectedScript -and $proof.lockExclusive -eq $true) 'The runtime did not receive the real launcher lock in its active version directory.'
    Assert-VeyonProtectedRoot -Root $root
    Assert-StagingEmpty
}

function New-SignedTestRelease([string]$Version, [switch]$FailHealth, [switch]$ActualRuntime) {
    $runtime = @'
param([switch]$Testlauf, [System.IO.FileStream]$UpdateLock)
$ErrorActionPreference = 'Stop'
if ($Testlauf) {
    __HEALTH__
    return
}
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'VeyonUpdater'
$expectedLock = Join-Path $root 'update.lock'
if ($null -eq $UpdateLock -or -not $UpdateLock.CanRead -or -not $UpdateLock.CanWrite -or
    $UpdateLock.SafeFileHandle.IsClosed -or $UpdateLock.SafeFileHandle.IsInvalid -or
    [IO.Path]::GetFullPath($UpdateLock.Name) -ine $expectedLock) { throw 'Missing launcher lock.' }
$competing = $null
$exclusive = $false
try {
    $competing = New-Object IO.FileStream($expectedLock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
} catch [IO.IOException] {
    $cause = $_.Exception
    while ($cause.InnerException) { $cause = $cause.InnerException }
    if (($cause.HResult -band 0xFFFF) -notin @(32,33)) { throw }
    $exclusive = $true
} finally { if ($competing) { $competing.Dispose() } }
if (-not $exclusive) { throw 'The launcher lock is not held exclusively for mutation.' }
$proof = [pscustomobject]@{
    version='__VERSION__'; identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    script=$PSCommandPath; lockExclusive=$exclusive
}
[IO.File]::WriteAllText((Join-Path $root 'selfupdate-test-proof.json'), ($proof | ConvertTo-Json -Compress))
Set-VeyonProtectedAcl -Path (Join-Path $root 'selfupdate-test-proof.json')
'@
    $health = if ($FailHealth) { "throw 'Signed test payload failed its health check.'" } else { '# Healthy payload.' }
    $runtime = $runtime.Replace('__VERSION__', $Version).Replace('__HEALTH__', $health)
    [byte[]]$runtimeBytes = if ($ActualRuntime) { [IO.File]::ReadAllBytes((Join-Path $sourceRoot 'Veyon-AutoUpdate.ps1')) } else { [Text.Encoding]::UTF8.GetBytes($runtime) }
    $files = [ordered]@{
        'Veyon-AutoUpdate.ps1' = $runtimeBytes
        'Veyon-SelfUpdate.ps1' = [Text.Encoding]::UTF8.GetBytes($selfUpdateText)
    }
    $directory = Join-Path $probeRoot $Version
    New-VeyonProtectedDirectory -Path $directory
    $archivePath = Join-Path $directory ('VeyonUpdater_v' + $Version + '_Update.zip')
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    $records = @()
    try {
        foreach ($name in $files.Keys) {
            $entry = $archive.CreateEntry($name)
            $stream = $entry.Open()
            try { $stream.Write($files[$name], 0, $files[$name].Length) } finally { $stream.Dispose() }
            $records += [pscustomobject]@{path=$name;length=$files[$name].Length;sha256=(Get-VeyonSha256 -Bytes $files[$name])}
        }
    } finally { $archive.Dispose() }
    Set-VeyonProtectedAcl -Path $archivePath
    $bytes = [IO.File]::ReadAllBytes($archivePath)
    $archiveHash = Get-VeyonSha256 -Bytes $bytes
    $lines = @('VEYON-UPDATER-MANIFEST-1', 'product=VeyonUpdater',
        'repository=Railsimulatornet/VeyonAutoupdateforWindows', 'channel=stable',
        ('version=' + $Version), ('tag=' + $Version), ('source=' + ('a' * 40)), 'bootstrap=1',
        ('payload=VeyonUpdater_v' + $Version + '_Update.zip'), ('length=' + $bytes.Length), ('sha256=' + $archiveHash))
    foreach ($record in $records) { $lines += ('file={0}|{1}|{2}' -f $record.path,$record.length,$record.sha256) }
    $manifestBytes = [Text.Encoding]::ASCII.GetBytes(($lines -join "`n") + "`n")
    $signature = $key.SignData($manifestBytes, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pss)
    Write-ProtectedBytes -Path (Join-Path $directory 'VeyonUpdater-release.manifest') -Bytes $manifestBytes
    Write-ProtectedBytes -Path (Join-Path $directory 'VeyonUpdater-release.manifest.sig') -Bytes $signature
    return [pscustomobject]@{
        record=[pscustomobject]@{version=$Version;directory=($Version + '-' + $archiveHash.Substring(0,16));sourceCommit=('a'*40);files=$records}
        manifest=(ConvertFrom-VeyonManifest -Bytes $manifestBytes)
        archive=$archivePath
    }
}

try {
    Initialize-VeyonProtectedRoot -Root $root
    $rootCreated = $true
    New-VeyonProtectedDirectory -Path $probeRoot
    $probeCreated = $true
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $key = New-Object Security.Cryptography.RSACng(3072)
    $request = New-Object Security.Cryptography.X509Certificates.CertificateRequest(
        'CN=Veyon Updater disposable test key', $key, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddHours(-1), [DateTimeOffset]::UtcNow.AddDays(1))
    $testPin = Get-VeyonSha256 -Bytes $certificate.RawData
    $coreText = [IO.File]::ReadAllText((Join-Path $sourceRoot 'VeyonUpdater.Security.ps1'))
    $productionPin = '7b698f2726348060cddf8b10a5a82d39ed907062265edf2e926dd9d6c5a72b7d'
    Assert-True ([regex]::Matches($coreText, $productionPin).Count -eq 1) 'Expected exactly one production certificate pin.'
    # Only this disposable verifier copy trusts the test certificate. The production files stay unchanged.
    Write-ProtectedBytes -Path (Join-Path $root 'VeyonUpdater.Security.ps1') -Bytes ([Text.Encoding]::UTF8.GetBytes($coreText.Replace($productionPin, $testPin)))
    Write-ProtectedBytes -Path (Join-Path $root 'VeyonUpdater-release-public.cer') -Bytes $certificate.RawData
    $launcherBytes = [IO.File]::ReadAllBytes((Join-Path $sourceRoot 'Start-VeyonUpdater.ps1'))
    Write-ProtectedBytes -Path (Join-Path $root 'Start-VeyonUpdater.ps1') -Bytes $launcherBytes
    $launcherHash = Get-VeyonSha256 -Bytes $launcherBytes
    $coreHash = (Get-FileHash -LiteralPath (Join-Path $root 'VeyonUpdater.Security.ps1')).Hash

    # Replace just the transport function in each test payload; verification, scheduling and activation are unchanged.
    $transport = @'
function Receive-VeyonBytes {
    param([Parameter(Mandatory=$true)][uri]$Uri, [Parameter(Mandatory=$true)][int]$MaximumBytes)
    $fixture = '__PROBE_ROOT__'
    $response = [IO.File]::ReadAllText((Join-Path $fixture 'response.json')) | ConvertFrom-Json
    [IO.File]::AppendAllText((Join-Path $fixture 'requests.log'), $Uri.AbsoluteUri + [Environment]::NewLine)
    if ($response.mode -ceq 'offline') { throw 'Simulated offline connection.' }
    if ($Uri.AbsoluteUri -ceq 'https://api.github.com/repos/Railsimulatornet/VeyonAutoupdateforWindows/releases/latest') {
        $text = '{"draft":false,"prerelease":false,"tag_name":"' + $response.version + '"}'
        return ,([Text.Encoding]::ASCII.GetBytes($text))
    }
    $prefix = 'https://github.com/Railsimulatornet/VeyonAutoupdateforWindows/releases/download/' + $response.version + '/'
    if (-not $Uri.AbsoluteUri.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Unexpected fixture release address.' }
    $name = $Uri.AbsoluteUri.Substring($prefix.Length)
    if ($name -cnotin @('VeyonUpdater-release.manifest', 'VeyonUpdater-release.manifest.sig', ('VeyonUpdater_v' + $response.version + '_Update.zip'))) {
        throw 'Unexpected fixture release asset.'
    }
    $bytes = [IO.File]::ReadAllBytes((Join-Path (Join-Path $fixture $response.version) $name))
    if ($response.mode -ceq 'wrong-signature' -and $name.EndsWith('.sig')) { $bytes[0] = $bytes[0] -bxor 1 }
    if ($response.mode -ceq 'wrong-payload' -and $name.EndsWith('.zip')) { $bytes[$bytes.Length - 1] = $bytes[$bytes.Length - 1] -bxor 1 }
    if ($bytes.Length -gt $MaximumBytes) { throw 'Fixture exceeded the requested response limit.' }
    return ,$bytes
}
'@
    $transport = $transport.Replace('__PROBE_ROOT__', $probeRoot.Replace("'", "''"))
    $selfUpdateSource = [IO.File]::ReadAllText((Join-Path $sourceRoot 'Veyon-SelfUpdate.ps1'))
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($selfUpdateSource, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'The self-update source did not parse.'
    $functions = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Receive-VeyonBytes'
    }, $false))
    Assert-True ($functions.Count -eq 1) 'Expected exactly one release transport function.'
    $extent = $functions[0].Extent
    $selfUpdateText = $selfUpdateSource.Substring(0, $extent.StartOffset) + $transport + $selfUpdateSource.Substring($extent.EndOffset)

    $initial = New-SignedTestRelease -Version '1.5.0'
    New-SignedTestRelease -Version '1.5.1' | Out-Null
    New-SignedTestRelease -Version '1.5.2' | Out-Null
    New-SignedTestRelease -Version '1.5.3' -FailHealth | Out-Null
    New-SignedTestRelease -Version '1.5.4' | Out-Null
    New-SignedTestRelease -Version '1.5.5' -ActualRuntime | Out-Null
    Expand-VeyonVerifiedPayload -Archive $initial.archive -Manifest $initial.manifest -Destination (Join-Path (Join-Path $root 'versions') $initial.record.directory)
    Write-VeyonState -Root $root -State ([pscustomobject]@{schema=1;current=$initial.record;previous=$null;highestVersion='1.5.0';failedVersion=$null})
    $action = New-ScheduledTaskAction -Execute (Get-VeyonPowerShell) -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-VeyonUpdater.ps1') + '"') -WorkingDirectory $root
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal -Settings $settings | Out-Null
    $taskRegistered = $true
    $taskXml = Export-ScheduledTask -TaskName $taskName -TaskPath '\'

    Set-TestRelease -Version '1.5.1'
    Invoke-SystemRun -Version '1.5.1'
    $state = Read-VeyonState -Root $root
    Assert-True ($state.previous.version -ceq '1.5.0' -and $state.highestVersion -ceq '1.5.1' -and $null -eq $state.failedVersion) 'Initial activation lost fallback or high-water state.'
    Assert-True ((Get-RequestCount) -eq 4) 'Initial activation did not fetch metadata, manifest, signature and payload.'
    Write-Host 'PASS: normal SYSTEM launcher verifies a signed package, activates it and runs the new version under its lock with task result 0'

    $stateHash = (Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash
    $checkHash = (Get-FileHash -LiteralPath (Join-Path $root 'selfupdate-check.txt')).Hash
    Set-TestRelease -Version '1.5.2' -Mode offline
    Invoke-SystemRun -Version '1.5.1'
    Assert-True ((Get-RequestCount) -eq 4 -and (Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash -ceq $stateHash -and
        (Get-FileHash -LiteralPath (Join-Path $root 'selfupdate-check.txt')).Hash -ceq $checkHash) 'The 24-hour check interval was not respected.'
    Write-Host 'PASS: a second normal launch within 24 hours runs the current package without a network check or state change'

    Set-TestRelease -Version '1.5.2'
    Set-CheckDue
    Invoke-SystemRun -Version '1.5.2'
    $state = Read-VeyonState -Root $root
    Assert-True ($state.previous.version -ceq '1.5.1' -and $state.highestVersion -ceq '1.5.2') 'A successive self-update did not retain the previous working version.'
    $stateHash = (Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash
    Write-Host 'PASS: the updated self-updater accepts a later signed release and retains its working predecessor'

    foreach ($mode in @('wrong-signature', 'wrong-payload', 'offline')) {
        $beforeRequests = Get-RequestCount
        Set-TestRelease -Version '1.5.3' -Mode $mode
        Set-CheckDue
        Invoke-SystemRun -Version '1.5.2'
        $expectedRequests = switch ($mode) { 'wrong-signature' { 3 } 'wrong-payload' { 4 } 'offline' { 1 } }
        Assert-True (((Get-RequestCount) - $beforeRequests) -eq $expectedRequests) ('Unexpected download sequence for ' + $mode)
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash -ceq $stateHash) ('Rejected self-update changed active state: ' + $mode)
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $root 'versions') -Directory).Count -eq 2) 'Unused versions were not removed.'
    }
    Write-Host 'PASS: wrong signature, modified payload and offline download preserve the installed state and still run the current version successfully'

    Set-TestRelease -Version '1.5.3'
    Set-CheckDue
    Invoke-SystemRun -Version '1.5.2'
    $state = Read-VeyonState -Root $root
    Assert-True ($state.current.version -ceq '1.5.2' -and $state.previous.version -ceq '1.5.1' -and
        $state.highestVersion -ceq '1.5.3' -and $state.failedVersion -ceq '1.5.3') 'Signed health failure did not preserve the working runtime and rejection high-water mark.'
    Write-Host 'PASS: a validly signed package with a failing health check is not activated and retains its rejection high-water mark'

    $damaged = Join-Path (Join-Path (Join-Path $root 'versions') $state.current.directory) 'Veyon-AutoUpdate.ps1'
    [IO.File]::AppendAllText($damaged, "`r`n# damaged fixture`r`n")
    $beforeRequests = Get-RequestCount
    Set-CheckDue
    Invoke-SystemRun -Version '1.5.1'
    $state = Read-VeyonState -Root $root
    Assert-True ($null -eq $state.previous -and $state.highestVersion -ceq '1.5.3' -and $state.failedVersion -ceq '1.5.2') 'Local fallback lost its anti-rollback state.'
    Assert-True (((Get-RequestCount) - $beforeRequests) -eq 1) 'Fallback downloaded an already rejected release again.'
    Write-Host 'PASS: a damaged current package falls back to the verified previous version without redownloading a rejected release'

    Set-TestRelease -Version '1.5.4'
    Set-CheckDue
    Invoke-SystemRun -Version '1.5.4'
    $state = Read-VeyonState -Root $root
    Assert-True ($state.previous.version -ceq '1.5.1' -and $state.highestVersion -ceq '1.5.4' -and $null -eq $state.failedVersion) 'A newer recovery release did not activate cleanly.'
    Write-Host 'PASS: a newer signed release recovers automatic updates after a failed package and local fallback'

    $stateHash = (Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash
    $beforeRequests = Get-RequestCount
    Set-TestRelease -Version '1.5.2'
    Set-CheckDue
    Invoke-SystemRun -Version '1.5.4'
    Assert-True (((Get-RequestCount) - $beforeRequests) -eq 1 -and (Get-FileHash -LiteralPath (Join-Path $root 'state.json')).Hash -ceq $stateHash) 'An older remote release changed current state or downloaded assets.'
    Assert-True ((Export-ScheduledTask -TaskName $taskName -TaskPath '\') -ceq $taskXml -and
        (Get-VeyonSha256 -Bytes ([IO.File]::ReadAllBytes((Join-Path $root 'Start-VeyonUpdater.ps1')))) -ceq $launcherHash -and
        (Get-FileHash -LiteralPath (Join-Path $root 'VeyonUpdater.Security.ps1')).Hash -ceq $coreHash -and
        (Get-VeyonSha256 -Bytes ([IO.File]::ReadAllBytes((Join-Path $root 'VeyonUpdater-release-public.cer')))) -ceq $testPin) 'Self-update changed the stable task, launcher, verifier or key.'
    Write-Host 'PASS: downgrade metadata cannot replace the installed release; the task, bootstrap, verifier and key remain unchanged'

    Set-TestRelease -Version '1.5.5'
    Set-CheckDue
    Invoke-SystemRun -Version '1.5.5' -ActualRuntime
    Write-Host 'PASS: signed activation also runs the byte-for-byte actual application updater as SYSTEM with task result 0 and no installed Veyon'

    Write-ProtectedBytes -Path (Join-Path $root 'state.json') -Bytes ([Text.Encoding]::ASCII.GetBytes('broken'))
    Invoke-SystemRun -ExpectFailure
    Write-Host 'PASS: corrupt state fails closed with a nonzero real task result and no runtime execution'
} catch {
    foreach ($name in @('selfupdate.log', 'state.json')) {
        $path = Join-Path $root $name
        if ([IO.File]::Exists($path)) { Write-Host ($name + ':'); Get-Content -LiteralPath $path -Tail 25 | Write-Host }
    }
    throw
} finally {
    if ($taskRegistered) {
        Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
        $stopLimit = [DateTime]::UtcNow.AddSeconds(15)
        while ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running' -and [DateTime]::UtcNow -lt $stopLimit) { Start-Sleep -Milliseconds 250 }
        if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running') { throw 'The test task is still running; its disposable files were retained.' }
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
    }
    if ($certificate) { $certificate.Dispose() }
    if ($key) { $key.Dispose() }
    if ($rootCreated -and [IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
    if ($probeCreated -and [IO.Directory]::Exists($probeRoot)) { [IO.Directory]::Delete($probeRoot, $true) }
}
