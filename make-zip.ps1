# make-zip.ps1 - pack SendToKindle v1.5.0 for sharing (ASCII only, works on PS 5.1 / 7+)
# Usage:
#   1) copy the rebuilt binary (send_to_kindle) into this folder
#   2) powershell -ExecutionPolicy Bypass -File .\make-zip.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $here 'send_to_kindle'

if (-not (Test-Path $bin)) {
    Write-Host '[ERROR] send_to_kindle not found in this folder.' -ForegroundColor Red
    Write-Host '        Build it first:  CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o send_to_kindle main.go' -ForegroundColor Yellow
    exit 1
}

# sanity check: ARM ELF + version string
$bytes = [IO.File]::ReadAllBytes($bin)
$isElf = ($bytes[0] -eq 0x7F -and $bytes[1] -eq 0x45 -and $bytes[2] -eq 0x4C -and $bytes[3] -eq 0x46)
$machine = $bytes[18] -bor ($bytes[19] -shl 8)
$ascii = [Text.Encoding]::ASCII.GetString($bytes)
$hasVer = $ascii.Contains('1.5.0')
Write-Host ('binary : {0:N0} bytes  ELF={1}  arch={2}  contains 1.5.0={3}' -f $bytes.Length, $isElf, $(if ($machine -eq 40) { 'ARM32' } elseif ($machine -eq 183) { 'AARCH64' } else { $machine }), $hasVer)
if (-not $isElf) { Write-Host '[ERROR] not an ELF file.' -ForegroundColor Red; exit 1 }
if (-not $hasVer) { Write-Host '[WARN] version string 1.5.0 not found - did you rebuild main.go?' -ForegroundColor Yellow }

# stage: <tmp>\SendToKindle\*
$tmp = Join-Path $env:TEMP ('stk_pkg_' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $tmp 'SendToKindle'
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'bin') | Out-Null
Get-ChildItem -LiteralPath $here -File | Where-Object { $_.Extension -in @('.ini', '.xml', '.json', '.md') -or $_.Name -eq '.gitignore' -or $_.Name -eq 'send_to_kindle' } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Force }
Get-ChildItem -LiteralPath (Join-Path $here 'bin') -File |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage 'bin') -Force }

$zip = Join-Path (Split-Path $here -Parent) 'SendToKindle-1.5.0.zip'
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
Remove-Item -LiteralPath $tmp -Recurse -Force

Write-Host ''
Write-Host ('zip: {0}  ({1:N2} MB)' -f $zip, ((Get-Item $zip).Length / 1MB)) -ForegroundColor Green
$z = [System.IO.Compression.ZipFile]::OpenRead($zip)
$z.Entries | ForEach-Object { Write-Host ('  {0,9:N1} KB  {1}' -f ($_.Length / 1KB), $_.FullName) }
$z.Dispose()
Write-Host ''
Write-Host 'Done. Upload this zip to GitHub Release v1.5.0 (or send it directly).' -ForegroundColor Green
