# start_server.ps1 —— 双进程物料的 server 启动脚本
# 参数：exe watch_dir results ready debug_log
param(
  [Parameter(Mandatory=$true)][string]$exe,
  [Parameter(Mandatory=$true)][string]$watch_dir,
  [Parameter(Mandatory=$true)][string]$results,
  [Parameter(Mandatory=$true)][string]$ready,
  [Parameter(Mandatory=$true)][string]$debug_log
)

$out = Join-Path (Split-Path $watch_dir -Parent) "server.out"
$err = Join-Path (Split-Path $watch_dir -Parent) "server.err"

Start-Process -FilePath $exe -ArgumentList @(
  "--watch-dir", $watch_dir,
  "--results", $results,
  "--ready", $ready,
  "--stop-after", "20",
  "--debug-log", $debug_log
) -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
