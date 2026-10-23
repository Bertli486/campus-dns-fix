# Adds a UTF-8 BOM to .ps1 files so Windows PowerShell 5.1 reads Chinese text correctly.
# ASCII-only by design, so it can never be corrupted by the very problem it fixes.
param([Parameter(Mandatory=$true)][string[]]$Path)

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "MISSING: $p"; continue }
    $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($p, $raw, $utf8Bom)
    $bytes = [System.IO.File]::ReadAllBytes($p)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Write-Host ("BOM={0}  {1}" -f $hasBom, $p)
}
