param([switch]$Install, [string]$Device = '')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path -Parent $PSScriptRoot
$dev = $env:DEVECO_HOME
if ([string]::IsNullOrEmpty($dev)) { throw "Set DEVECO_HOME to your DevEco Studio installation" }
$hvigor = Join-Path $dev 'tools\hvigor\bin\hvigorw.bat'
if (-not (Test-Path $hvigor)) { throw "hvigorw not found: $hvigor" }

$env:PATH = "$(Join-Path $dev 'tools\node');$(Join-Path $dev 'tools\ohpm\bin');$(Join-Path $dev 'tools\hvigor\bin');$env:PATH"
$env:DEVECO_SDK_HOME = Join-Path $dev 'sdk'

Push-Location (Join-Path $root 'app')
try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $hvigor assembleHap --no-daemon 2>&1 | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { throw "hvigor build failed with exit code $code" }
}
finally {
    Pop-Location
}

$hap = Join-Path $root 'app\entry\build\default\outputs\default\entry-default-signed.hap'
Write-Host "[build-hap] OK: $hap"
if ($Install) {
    if ([string]::IsNullOrEmpty($Device)) { throw 'Pass -Device <serial> with -Install' }
    $hdc = Join-Path $dev 'sdk\default\openharmony\toolchains\hdc.exe'
    & $hdc -t $Device install -r $hap
    if ($LASTEXITCODE -ne 0) { throw "install failed with exit code $LASTEXITCODE" }
    Write-Host '[build-hap] installed'
}