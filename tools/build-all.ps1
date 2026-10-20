param([switch]$Install, [string]$Device = '')
$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'build-engine.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Install) {
    & (Join-Path $PSScriptRoot 'build-hap.ps1') -Install -Device $Device
} else {
    & (Join-Path $PSScriptRoot 'build-hap.ps1')
}
exit $LASTEXITCODE