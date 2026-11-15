@echo off
REM start_server.cmd - dual-process harness server launcher (cmd env)
REM args: exe tmp_dir
setlocal
set EXE=%1
set TMP=%2
start "rx-watch" /MIN "%EXE%" --watch-dir "%TMP%\watch" --results "%TMP%\results.jsonl" --ready "%TMP%\.ready" --stop-after 20 --debug-log "%TMP%\server.dbg"
endlocal
