@echo off
REM start_server.bat - dual-process harness server launcher (cmd env)
REM args: exe tmp_dir
setlocal
set EXE=%1
set TMP=%2
set WATCH=%TMP%\watch
set RESULTS=%TMP%\results.jsonl
set READY=%TMP%\.ready
set DBG=%TMP%\server.dbg
set OUT=%TMP%\server.out
set ERR=%TMP%\server.err
powershell -NoProfile -Command "Start-Process -FilePath '%EXE%' -ArgumentList @('--watch-dir','%WATCH%','--results','%RESULTS%','--ready','%READY%','--stop-after','20','--debug-log','%DBG%') -NoNewWindow -RedirectStandardOutput '%OUT%' -RedirectStandardError '%ERR%'"
endlocal
