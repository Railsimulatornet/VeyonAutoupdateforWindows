param([Parameter(Mandatory = $true)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
foreach ($name in @('Veyon-AutoUpdate.ps1', 'Register-Veyon-AutoUpdateTask.ps1')) {
    $path = (Get-Item -LiteralPath (Join-Path $PackageRoot $name)).FullName
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
        $details = $errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.ErrorId) - $($_.Message)" }
        throw "Packaged PowerShell parse failed for ${name}: $($details -join ' / ')"
    }
    Write-Host "PASS: Windows PowerShell $($PSVersionTable.PSVersion) parsed packaged $name"
}
