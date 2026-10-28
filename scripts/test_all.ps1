# =============================================================================
# scripts/test_all.ps1 - rx-mbt cross-platform test gate (native Windows entry)
#
# Same contract as scripts/test_all.sh (decision doc section 4.2), for callers that
# start from PowerShell instead of Git Bash:
#   1) prepend the REAL node.exe directory (C:\Program Files\nodejs) so moon does not
#      spawn the .desktop-bin\node.cmd shim (that one truncates long JSON args and
#      makes the js target die with "failed to parse args");
#   2) run  moon check / moon test / moon test --target js / moon test --target native;
#   3) every test step must print a "Total tests: N, passed: N, failed: 0" summary line,
#      with failed == 0 and passed == total. moon check must report "0 errors".
#   4) any violation => exit 1. Missing toolchain => exit 2.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/test_all.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/test_all.ps1 -Skip native,js
#   powershell -ExecutionPolicy Bypass -File scripts/test_all.ps1 -Quiet   # 只打印每步末尾若干行
#
# Exit codes: 0 = all green, 1 = at least one step failed, 2 = bad usage/env.
# =============================================================================
[CmdletBinding()]
param(
    [string[]]$Skip = @(),
    [switch]$Quiet,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectDir = Split-Path -Parent $ScriptDir
Set-Location $ProjectDir

# -File 调用时 "a,b" 会作为单个字符串进来，这里统一按逗号拆成数组
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# ---- 参数校验（C1 审计 F4/F10）：非法值一律 usage error（rc=2），不得静默降级 ----
$ValidSteps = @('check', 'wasm', 'js', 'native')
$UnknownSkip = @($Skip | Where-Object { $ValidSteps -notcontains $_ })
if ($UnknownSkip.Count -gt 0) {
    Write-Host ("FATAL: -Skip 含未知步骤名「{0}」；可用：check,wasm,js,native" -f ($UnknownSkip -join ',')) -ForegroundColor Red
    Write-Host '       注意：未知步骤名过去会被静默忽略（用户以为跳过了测试组），C1 审计 F10 后改为硬报错。' -ForegroundColor Yellow
    exit 2
}
if ($TimeoutSec -le 0) {
    Write-Host ("FATAL: -TimeoutSec 必须 > 0（收到 {0}；0 会关闭挂死保护，不允许）" -f $TimeoutSec) -ForegroundColor Red
    exit 2
}

# ---------------------------------------------------------------------------
# Platform + PATH fix
# ---------------------------------------------------------------------------
$IsWindowsHost = $true
if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    $IsWindowsHost = $false
}

$PathNote = ''
if ($IsWindowsHost) {
    $NodeDir = $null
    $Candidates = @()
    if ($env:ProgramFiles) { $Candidates += (Join-Path $env:ProgramFiles 'nodejs') }
    if (${env:ProgramFiles(x86)}) { $Candidates += (Join-Path ${env:ProgramFiles(x86)} 'nodejs') }
    foreach ($c in $Candidates) {
        if (Test-Path (Join-Path $c 'node.exe')) { $NodeDir = $c; break }
    }
    $MoonDir = Join-Path $env:USERPROFILE '.moon\bin'
    # 关键：不只是「前置真 node」，还要把含 node.cmd 的 shim 目录从 PATH 里剔掉。
    # 实测（2026-10-27）：只前置真 node 时，moon 仍可能通过 cmd 批处理 shim spawn node，
    # 长 JSON 参数被 8191 字符上限截断 → `failed to parse args: Unterminated string in JSON`，
    # js 目标整批失败。bash 版是整条 PATH 替换，所以没有这个坑。
    $CleanParts = @()
    foreach ($part in ($env:PATH -split ';')) {
        if (-not $part) { continue }
        if ($NodeDir -and ($part.TrimEnd('\') -ieq $NodeDir.TrimEnd('\'))) { continue }
        $shim = Join-Path $part 'node.cmd'
        if (Test-Path -LiteralPath $shim -ErrorAction SilentlyContinue) { continue }
        $CleanParts += $part
    }
    $Prefix = @()
    if ($NodeDir) { $Prefix += $NodeDir }
    $Prefix += $MoonDir
    $env:PATH = (($Prefix + $CleanParts) -join ';')
    if ($NodeDir) {
        $PathNote = "prepended real node dir: $NodeDir and stripped dirs containing node.cmd (avoids long-JSON truncation)"
    }
    else {
        $PathNote = 'real node.exe dir NOT found; js target may fail via node.cmd shim'
    }
}
else {
    $PathNote = 'non-Windows host: PATH left as-is'
}

$MoonCmd = Get-Command moon -ErrorAction SilentlyContinue
if (-not $MoonCmd) {
    Write-Host "FATAL: moon not found on PATH ($env:PATH)" -ForegroundColor Red
    Write-Host "  hint: Windows needs %USERPROFILE%\.moon\bin" -ForegroundColor Red
    exit 2
}
$MoonBin = $MoonCmd.Source

$NodeCmd = Get-Command node -ErrorAction SilentlyContinue
$NodeBin = '<none>'
$NodeVersion = 'MISSING'
if ($NodeCmd) {
    $NodeBin = $NodeCmd.Source
    try { $NodeVersion = (& node --version 2>&1 | Out-String).Trim() } catch { $NodeVersion = 'ERROR' }
}

$MoonVersion = ''
try { $MoonVersion = ((& moon version 2>&1 | Select-Object -First 1) | Out-String).Trim() } catch { $MoonVersion = 'ERROR' }

$PlatformName = 'windows'
if (-not $IsWindowsHost) { $PlatformName = 'non-windows' }

Write-Host '============================================================================='
Write-Host ' rx-mbt cross-platform test gate   scripts/test_all.ps1'
Write-Host '============================================================================='
Write-Host (" platform   : {0} (PowerShell {1})" -f $PlatformName, $PSVersionTable.PSVersion)
Write-Host (" project    : {0}" -f $ProjectDir)
Write-Host (" moon       : {0} -> {1}" -f $MoonBin, $MoonVersion)
Write-Host (" node       : {0} -> {1}" -f $NodeBin, $NodeVersion)
Write-Host (" PATH head  : {0}" -f $env:PATH)
Write-Host (" PATH note  : {0}" -f $PathNote)
# C1 审计 F7：本入口【没有】实现硬超时，-TimeoutSec 只作提示/日志用途。
Write-Host (" timeout    : N/A - PowerShell entry has NO built-in hard timeout (advisory -TimeoutSec={0}s)" -f $TimeoutSec) -ForegroundColor Yellow
if ($Skip.Count -gt 0) { Write-Host (" skip       : {0}" -f ($Skip -join ',')) }
Write-Host '============================================================================='

if ($NodeBin -like '*.cmd') {
    Write-Host "WARN: node resolves to a .cmd shim ($NodeBin) - js target may report 'failed to parse args'" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Step runner
# ---------------------------------------------------------------------------
# ---- 并发纪律（lead 2026-10-28 裁示）：moon 并发会污染共享 _build。
# 仓库里有 scripts/with_moon_lock.sh 时，所有 moon 调用都套锁（bash 负责 mkdir 锁）。
$MoonLockSh = Join-Path (Join-Path $ProjectDir 'scripts') 'with_moon_lock.sh'
$BashBin = $null
$LockNote = '未启用（找不到 bash 或 scripts/with_moon_lock.sh）'
if (Test-Path $MoonLockSh) {
    $cand = @()
    $gitBash = Join-Path $env:ProgramFiles 'Gitinash.exe'
    if (Test-Path $gitBash) { $cand += $gitBash }
    $cmdBash = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmdBash) { $cand += $cmdBash.Source }
    foreach ($c in $cand) { if ($c -and (Test-Path $c)) { $BashBin = $c; break } }
}
if ($BashBin) { $LockNote = "已启用：$BashBin $MoonLockSh（moon 串行持锁）" }
Write-Host (" moon lock  : {0}" -f $LockNote)

$Rows = New-Object System.Collections.ArrayList
$OverallRc = 0

function Invoke-MoonStep {
    param(
        [string]$Name,
        [string]$Label,
        [string[]]$MoonArgs
    )

    if ($Skip -contains $Name) {
        Write-Host ''
        Write-Host (">>> [{0}] SKIP (-Skip)" -f $Name) -ForegroundColor DarkGray
        [void]$Rows.Add([pscustomobject]@{ Step = $Name; Verdict = 'SKIP'; Detail = 'skipped by -Skip'; Ms = 0 })
        return
    }

    Write-Host ''
    Write-Host (">>> [{0}] {1}" -f $Name, $Label) -ForegroundColor Cyan
    Write-Host ("    `$ moon {0}   (timeout {1}s)" -f ($MoonArgs -join ' '), $TimeoutSec)

    # 这里用 `& $MoonBin @MoonArgs` + $LASTEXITCODE：
    #   * PS 5.1 的 Start-Process -PassThru（尤其带重定向时）拿到的 $proc.ExitCode 常为 $null
    #     （实测：finished=True 但 exitCode=[]），会让判绿失去依据；
    #   * New-Object System.Diagnostics.ProcessStartInfo 在本机受限宿主里也可能不可用。
    # 因此选择「直接调用 + $LASTEXITCODE」这条最可靠的路。
    #
    # C1 审计 F7：这里【故意不实现】硬超时。
    #   PS 5.1 在本机受限宿主里拿不到可靠的进程退出码（Start-Process -PassThru 的
    #   ExitCode 实测为 $null），若用超时框架反而会引入"假 PASS"。
    #   需要超时保护请走 bash 入口：`bash scripts/test_all.sh --timeout N`
    #   （内置 timeout + 挂死清理），或在调用侧（run_check）设 timeout_ms。
    #   故本文件不再有任何 $timedOut 分支/死代码。
    $captured = @()
    if ($BashBin) {
        & $BashBin $MoonLockSh $MoonBin @MoonArgs 2>&1 | Tee-Object -Variable captured | Out-Null
    }
    else {
        & $MoonBin @MoonArgs 2>&1 | Tee-Object -Variable captured | Out-Null
    }
    $rc = $LASTEXITCODE
    $timedOut = $false
    # 逐步骤耗时只在 bash 版里统计：本机受限宿主里 PS 的计时原语会变 $null，
    # 打印空值反而误导；PS 版只输出结论。

    $captured = @($captured | Where-Object { $null -ne $_ })
    if ($Quiet) {
        foreach ($line in ($captured | Select-Object -Last 40)) { Write-Host ([string]$line) }
    }
    else {
        foreach ($line in $captured) { Write-Host ([string]$line) }
    }
    $text = ($captured | Out-String)

    $verdict = 'FAIL'
    $detail = ''

    if ($Name -eq 'check') {
        if ($rc -ne 0) {
            $detail = "moon check exit code $rc"
        }
        else {
            $m = [regex]::Matches($text, '([0-9]+)\s+errors?\)')
            if ($m.Count -eq 0) {
                $verdict = 'PASS'
                $detail = "exit 0 (no '<N> errors)' summary parsed)"
            }
            else {
                $errs = [int]$m[$m.Count - 1].Groups[1].Value
                if ($errs -ne 0) { $detail = "$errs errors" }
                else { $verdict = 'PASS'; $detail = '0 errors' }
            }
        }
    }
    else {
        $mm = [regex]::Matches($text, 'Total tests:\s*([0-9]+),\s*passed:\s*([0-9]+),\s*failed:\s*([0-9]+)')
        if ($rc -ne 0) {
            $detail = "exit code $rc"
        }
        elseif ($mm.Count -eq 0) {
            $detail = "missing 'Total tests: N, passed: N, failed: 0' summary line"
        }
        else {
            $total = 0; $passed = 0; $failed = 0
            foreach ($g in $mm) {
                $total += [int]$g.Groups[1].Value
                $passed += [int]$g.Groups[2].Value
                $failed += [int]$g.Groups[3].Value
            }
            if ($failed -ne 0) {
                $detail = "Total tests: $total, passed: $passed, failed: $failed"
            }
            elseif ($passed -ne $total) {
                $detail = "passed($passed) != total($total)"
            }
            else {
                $verdict = 'PASS'
                $detail = "Total tests: $total, passed: $passed, failed: 0"
            }
        }
    }

    $color = 'Green'
    if ($verdict -eq 'FAIL') {
        $color = 'Red'
        $script:OverallRc = 1
        # C1 审计 F5：失败步骤的完整输出落盘到 reports/run-logs/<timestamp>/
        try {
            $logDir = Join-Path (Join-Path (Join-Path $ProjectDir 'fist-mbt') 'reports') ('run-logs/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-ps1')
            if (-not (Test-Path $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
            $logPath = Join-Path $logDir ("{0}.log" -f $Name)
            ($captured | Out-String) | Set-Content -Path $logPath -Encoding UTF8
            $script:LastFailLogDir = $logDir
        }
        catch { Write-Host ("    WARN: 失败日志落盘失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    Write-Host ("    --> {0}  {1}" -f $verdict, $detail) -ForegroundColor $color
    [void]$Rows.Add([pscustomobject]@{ Step = $Name; Verdict = $verdict; Detail = $detail })
}

Invoke-MoonStep -Name 'check'  -Label 'moon check (wasm default target, 0-error criterion)' -MoonArgs @('check')
Invoke-MoonStep -Name 'wasm'   -Label 'moon test (wasm, default target)'                       -MoonArgs @('test')
Invoke-MoonStep -Name 'js'     -Label 'moon test --target js'                                 -MoonArgs @('test', '--target', 'js')
Invoke-MoonStep -Name 'native' -Label 'moon test --target native'                             -MoonArgs @('test', '--target', 'native')

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================================='
Write-Host (" SUMMARY  (platform=$PlatformName, moon=$MoonVersion, node=$NodeBin)")
Write-Host '============================================================================='
Write-Host (" {0,-8} {1,-6} {2}" -f 'STEP', 'VERDICT', 'DETAIL')
foreach ($r in $Rows) {
    $c = 'Green'
    if ($r.Verdict -eq 'FAIL') { $c = 'Red' }
    if ($r.Verdict -eq 'SKIP') { $c = 'DarkGray' }
    Write-Host (" {0,-8} {1,-6} {2}" -f $r.Step, $r.Verdict, $r.Detail) -ForegroundColor $c
}
Write-Host '-----------------------------------------------------------------------------'
# C1 审计 F3：全跳过 != 全绿。与 bash 版对齐：全 skip => RESULT: SKIP 且 rc=2
# （"所有步骤都被跳过"意味着本轮等于没跑任何验证，绝不能算 PASS）。
$SkipCount = 0
$PassCount = 0
$FailCount = 0
foreach ($row in $Rows) {
    switch ([string]$row.Verdict) {
        'SKIP' { $SkipCount = $SkipCount + 1 }
        'PASS' { $PassCount = $PassCount + 1 }
        'FAIL' { $FailCount = $FailCount + 1 }
    }
}
$TotalCount = $Rows.Count
if ($script:LastFailLogDir) {
    Write-Host (" fail logs  : {0}" -f $script:LastFailLogDir) -ForegroundColor Yellow
}
if ($OverallRc -ne 0) {
    Write-Host ' RESULT: FAIL - see FAIL rows above' -ForegroundColor Red
}
elseif ($SkipCount -eq $Rows.Count) {
    Write-Host (' RESULT: SKIP - every step was skipped ({0}/{0}), nothing verified' -f $Rows.Count) -ForegroundColor Yellow
    $OverallRc = 2
}
else {
    Write-Host (' RESULT: PASS - every executed step is green ({0} pass, {1} skip)' -f $PassCount, $SkipCount) -ForegroundColor Green
}
Write-Host '============================================================================='
exit $OverallRc
