# 核对 README 声明的 API 是否都在实际 mbti 中
$ErrorActionPreference = "Stop"
$mbti = Get-Content "rx\pkg.generated.mbti" -Encoding UTF8
$impl = New-Object System.Collections.Generic.HashSet[string]
foreach ($l in $mbti) {
  if ($l -match '^pub fn(\[[^\]]*\])?\s+([A-Za-z_][A-Za-z0-9_]*)::([A-Za-z_][A-Za-z0-9_]*)') {
    [void]$impl.Add($matches[3])
  } elseif ($l -match '^pub fn(\[[^\]]*\])?\s+([A-Za-z_][A-Za-z0-9_]*)\(') {
    [void]$impl.Add($matches[2])
  }
}
# README 中反引号包裹的 API 名（小写标识符）
$readme = Get-Content "README.md" -Encoding UTF8 | Out-String
$names = [regex]::Matches($readme, '`([a-z_][a-z0-9_]*)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$missing = @()
foreach ($n in $names) {
  if (-not $impl.Contains($n)) { $missing += $n }
}
Write-Output "README API mentions: $($names.Count)"
Write-Output "Implemented APIs: $($impl.Count)"
if ($missing.Count -eq 0) {
  Write-Output "PASS: all README-mentioned APIs are implemented"
} else {
  Write-Output "MISSING ($($missing.Count)): $($missing -join ', ')"
}
