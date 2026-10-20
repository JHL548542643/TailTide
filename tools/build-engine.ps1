param([switch]$Clean)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$go = Join-Path $root 'third_party\ohos-go\bin\go.exe'
if (-not (Test-Path $go)) { throw "Go toolchain not found: $go" }

$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:CGO_ENABLED = '1'
$env:CC = Join-Path $root 'tools\p2-probe\cc-ohos.cmd'
$env:GOPROXY = 'https://goproxy.cn,direct'
$env:GOPATH = Join-Path $root '.cache\gopath'
$env:GOCACHE = Join-Path $root '.cache\go-build'
$env:GOTMPDIR = Join-Path $root '.cache\tmp'

if ($Clean) {
    Remove-Item -Recurse -Force (Join-Path $root '.cache\go-build') -ErrorAction SilentlyContinue
}

Push-Location (Join-Path $root 'engine')
try {
    & $go build '-ldflags=-extldflags=-Wl,-soname,libtailscale_go.so' -buildmode=c-shared -o dist\libtailscale_go.so .
    if ($LASTEXITCODE -ne 0) { throw "engine build failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

Copy-Item (Join-Path $root 'engine\dist\libtailscale_go.so') (Join-Path $root 'app\entry\libs\arm64-v8a\libtailscale_go.so') -Force
Copy-Item (Join-Path $root 'engine\dist\libtailscale_go.h') (Join-Path $root 'app\entry\src\main\cpp\include\libtailscale_go.h') -Force
Write-Host '[build-engine] OK: libtailscale_go.so + .h copied into app'
