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
Write-Host (" timeout    : {0}s per step (-TimeoutSec)" -f $TimeoutSec)
if ($Skip.Count -gt 0) { Write-Host (" skip       : {0}" -f ($Skip -join ',')) }
Write-Host '============================================================================='

if ($NodeBin -like '*.cmd') {
    Write-Host "WARN: node resolves to a .cmd shim ($NodeBin) - js target may report 'failed to parse args'" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Step runner
# ---------------------------------------------------------------------------
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
    # 硬超时：PowerShell 入口没有内建超时（js 测试二进制有挂死风险，实测有先例）。
    # 需要超时保护时请用 `bash scripts/test_all.sh`（bash 版内置 timeout）或
    # 在 run_check 侧设 timeout_ms。这里只在 -TimeoutSec 大于 0 时打印提醒。
    $captured = @()
    & $MoonBin @MoonArgs 2>&1 | Tee-Object -Variable captured | Out-Null
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

    if ($timedOut) {
        $detail = "step timed out after ${TimeoutSec}s (test binary may be hung; use -TimeoutSec to adjust)"
    }
    elseif ($Name -eq 'check') {
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
    if ($verdict -eq 'FAIL') { $color = 'Red'; $script:OverallRc = 1 }
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
if ($OverallRc -eq 0) {
    Write-Host ' RESULT: PASS - every executed step is green' -ForegroundColor Green
}
else {
    Write-Host ' RESULT: FAIL - see FAIL rows above' -ForegroundColor Red
}
Write-Host '============================================================================='
exit $OverallRc
