# 提取 rx 包所有公开 API 名，输出到 _all_api.txt
$ErrorActionPreference = "Stop"
$c = Get-Content "rx\pkg.generated.mbti" -Encoding UTF8
$names = New-Object System.Collections.Generic.List[string]
foreach ($l in $c) {
  if ($l -match '^pub fn(\[[^\]]*\])?\s+([A-Za-z_][A-Za-z0-9_]*)::([A-Za-z_][A-Za-z0-9_]*)') {
    $names.Add($matches[3])
  } elseif ($l -match '^pub fn(\[[^\]]*\])?\s+([A-Za-z_][A-Za-z0-9_]*)\(') {
    $names.Add($matches[2])
  }
}
$unique = $names | Sort-Object -Unique
$unique | Out-File -FilePath "_all_api.txt" -Encoding utf8
Write-Output ("unique api count: " + $unique.Count)
Write-Output ($unique -join " ")
