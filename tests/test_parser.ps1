param([Parameter(Mandatory = $true)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
$required = @('Install-Veyon-AutoUpdate.ps1', 'Remove-Veyon-AutoUpdate.ps1',
    'Register-Veyon-AutoUpdateTask.ps1', 'Start-VeyonUpdater.ps1',
    'VeyonUpdater.Security.ps1', 'Veyon-AutoUpdate.ps1', 'Veyon-SelfUpdate.ps1')
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageRoot $name) -PathType Leaf)) {
        throw "Packaged PowerShell script missing: $name"
    }
}
foreach ($file in @(Get-ChildItem -LiteralPath $PackageRoot -Filter '*.ps1' -File -Recurse | Sort-Object FullName)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
        $details = $errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.ErrorId) - $($_.Message)" }
        throw "Packaged PowerShell parse failed for $($file.Name): $($details -join ' / ')"
    }
    Write-Host "PASS: Windows PowerShell $($PSVersionTable.PSVersion) parsed packaged $($file.Name)"
}
