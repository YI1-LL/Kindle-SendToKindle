# Cross-compile the Kindle static binary from Windows (ASCII only, works on PS 5.1 and PS 7+)
# Usage: powershell -ExecutionPolicy Bypass -File build.ps1
#        powershell -File build.ps1 -Arch armv7
param(
    [ValidateSet('armv7', 'armv6', 'aarch64', 'all')]
    [string]$Arch = 'all'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root 'dist'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$go = Get-Command go -ErrorAction SilentlyContinue
if (-not $go) {
    Write-Host '[ERROR] Go not found in PATH.' -ForegroundColor Red
    Write-Host '        Use .github/workflows/build.yml on GitHub Actions instead,' -ForegroundColor Yellow
    Write-Host '        or install Go: https://go.dev/dl/' -ForegroundColor Yellow
    exit 1
}

$targets = @(
    @{ Name = 'armv7';   GOARCH = 'arm';   GOARM = '7' },
    @{ Name = 'armv6';   GOARCH = 'arm';   GOARM = '6' },
    @{ Name = 'aarch64'; GOARCH = 'arm64'; GOARM = '' }
)
if ($Arch -ne 'all') {
    $targets = @($targets | Where-Object { $_.Name -eq $Arch })
}

foreach ($t in $targets) {
    $env:CGO_ENABLED = '0'
    $env:GOOS = 'linux'
    $env:GOARCH = $t.GOARCH
    if ($t.GOARM) {
        $env:GOARM = $t.GOARM
    } else {
        Remove-Item Env:\GOARM -ErrorAction SilentlyContinue
    }

    $target = Join-Path $out ('send_to_kindle-' + $t.Name)
    Write-Host ('==> building {0}  GOOS=linux GOARCH={1} GOARM={2}' -f $t.Name, $t.GOARCH, $t.GOARM) -ForegroundColor Cyan
    & go build -trimpath -ldflags="-s -w" -o $target .
    if ($LASTEXITCODE -ne 0) { throw ('build failed: ' + $t.Name) }

    $sizeMB = [math]::Round((Get-Item $target).Length / 1MB, 2)
    Write-Host ('    -> {0}  ({1} MB)' -f $target, $sizeMB) -ForegroundColor Green
}

Write-Host ''
Write-Host 'ELF header check:' -ForegroundColor Cyan
foreach ($f in Get-ChildItem -Path $out -File) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $isElf = ($b[0] -eq 0x7F -and $b[1] -eq 0x45 -and $b[2] -eq 0x4C -and $b[3] -eq 0x46)
    $eType = $b[16] -bor ($b[17] -shl 8)
    if ($eType -eq 40) { $archName = 'ARM 32-bit' }
    elseif ($eType -eq 183) { $archName = 'AArch64' }
    else { $archName = ('unknown ' + $eType) }
    Write-Host ('    {0}: ELF={1} arch={2}' -f $f.Name, $isElf, $archName)
}

Write-Host ''
Write-Host 'Done. Copy dist\send_to_kindle-armv7 into this folder as send_to_kindle, then run make-zip.ps1' -ForegroundColor Green
