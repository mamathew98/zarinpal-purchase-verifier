# Load local ps2exe so Invoke-ps2exe becomes available
$LocalPs2Exe = Join-Path $PSScriptRoot "ps2exe\ps2exe.ps1"

if (Test-Path $LocalPs2Exe) {
    . $LocalPs2Exe
} else {
    Write-Host "Local ps2exe not found at $LocalPs2Exe"
    exit
}

# Paths
$BuilderScript = Join-Path $PSScriptRoot "ZarinVerifier-Admin.ps1"
$OutputExe     = Join-Path $PSScriptRoot "ZarinVerifier-Admin.exe"
$Icon          = Join-Path $PSScriptRoot "icons\Poshtibani.ico"

if (-not (Test-Path $BuilderScript)) {
    Write-Host "Builder.ps1 not found!"
    exit
}

# Build EXE
Write-Host "Building Builder.exe ..."
Invoke-ps2exe `
    -inputFile  $BuilderScript `
    -outputFile $OutputExe `
    -NoConsole `
    -iconFile   $Icon

Write-Host "Done! Builder.exe created."
