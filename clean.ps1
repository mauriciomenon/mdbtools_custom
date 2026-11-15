#requires -Version 7
# .\clean.ps1        removes build.stage.*\ and dist\.stage\ (intermediates)
# .\clean.ps1 -Dist  also removes dist\ (all products). .tools\ is never removed.
param([switch]$Dist)
$ErrorActionPreference = 'Stop'
$targets = @(Get-ChildItem $PSScriptRoot -Directory -Filter 'build.stage.*' | ForEach-Object FullName) + "$PSScriptRoot\dist\.stage"
if ($Dist) { $targets += "$PSScriptRoot\dist" }
foreach ($dir in $targets) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir; Write-Host "removed $dir" }
}
