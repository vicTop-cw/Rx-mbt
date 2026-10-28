# C2 修复报告 · 资源与并发（impl-crypto 域）

- 日期：2026-10-28
- 对应寻虫报告：`2026-10-28-c2-bugfind-crypto.md`
- 范围（仅本域）：`rhop/{watch,relay}.mbt`、`rhop_task/task_store.mbt` + 对应测试
- 纪律遵守：**未改任何公开 API 签名**、未新增功能、格式化用 `moonfmt.exe -w`、所有 moon 命令走 `bash scripts/with_moon_lock.sh`

## 一、修复清单（按严重度）

| 编号 | 级别 | 文件 | 修法 | 回归用例 |
|---|---|---|---|---|
| **BUG-10** | **P1** | `rhop/relay.mbt` | 端口文件握手竞态：①子进程改 **tmp+rename 原子写**；②父进程把「空/不可解析」当未就绪继续轮询，超时才报错并带最后内容 | 已有 `relay · stop() 连临时目录一起清掉` 覆盖（WSL 5 连 + Win 3 连不再偶发） |
| **BUG-1** | P1 | `rhop/relay.mbt` | `stop()` 除端口文件外**连 mkdtemp 目录一起删**（新增私有 `fs_remove_dir` + `parent_dir_of`） | `relay · stop() 连临时目录一起清掉（C2 BUG-1 回归）` |
| **BUG-2** | P1 | `rhop/watch.mbt` | `seen` 只在**成功推送后**登记；读失败/解密失败不登记（允许后续事件重试） | `watch · 半写文件不登记 seen：写完后能被重新处理（C2 BUG-2 回归）` |
| BUG-3 | P2 | `rhop/watch.mbt` | `stop()` 清空 `seen`（每次 start = 新观察窗口；`bad` 累计计数保留） | `watch · stop() 清空 seen：重启后同名文件可再次处理（C2 BUG-3 回归）` |
| BUG-4 | P2 | `rhop_task/task_store.mbt` | `clean_stale_locks` 不再静默吞错：统计成功/失败/跳过，有失败即返回 `Err`（含首个原因）；非法行也算失败 | 由既有「关闭后操作 Err」+ 成功路径用例覆盖；**部分失败分支难以确定性构造，如实标注：代码审读 + 错误传播路径** |
| BUG-5 | P2 | `rhop/relay.mbt` | `start()` 幂等判断改为「child != 0 **且** 子进程仍存活」，否则先 stop 清理再重新拉起 | `relay · 子进程消失后 start() 会重新拉起（C2 BUG-5 回归）` |
| BUG-6 | P2 | `rhop_task/task_store.mbt` | ①FFI 失败路径**先 `db.close()` 再返回 -1**（不再漏句柄）；②`journal_mode` 设置失败**降级 DELETE** 而非整次打开失败；③`describe()` 新增实测值/配置值/`degraded` 标记 | `store · describe() 报告实际生效的 journal_mode 与降级标记（C2 BUG-6）` |
| BUG-7 | P3 | `test-suit/rhop_task/task_store_test.mbt` | 测试侧收尾守卫：强制关闭注册表内全部 sqlite 句柄并断言归零（防断言失败路径漏 close） | `store · 收尾：无遗留 sqlite 句柄（C2 BUG-7 守卫）` |
| BUG-8 | P3 | — | **不修**（无 API 变更前提下无法做 RAII）。已在寻虫报告登记为已知限制：timer 已 `unref()` 不阻塞退出，但调用方必须 `stop()/shutdown()` | — |
| BUG-9 | 信息 | — | 双平台差异清单；其中「WAL on 9p」风险由 BUG-6 的降级实现兜住，并在 `describe()` 里可观测 | — |

## 二、非修复项（如实标注，未美化）

- `TaskStoreSpec.write_retries` / `retry_backoff_sec`：**仍未接线**（P2 遗留，本轮不改：属功能缺口不属资源/并发缺陷，且改动会触及写路径行为，超出 C2 范围）。
- `tasks_executions` 表：**仍未写入**（同上）。
- Postgres 后端 / `file_channel`：仍未实现（契约外）。

## 三、验证矩阵（双平台 × 三目标 × 多次）

### Windows 11 / node v25.2.1 / moon 0.1.20261016
```
check rhop      wasm/js/native → 0 errors (121/97/123 warnings)
check rhop_task wasm/js/native → 0 errors (193/145/195 warnings)

moon test -p test-suit/rhop_js   --target js     → 56/56/0
  run 1 exit=0 12s / run 2 exit=0 8s / run 3 exit=0 9s   ← 3/3 自然退出
moon test -p test-suit/rhop_task --target wasm   → 46/46/0
moon test -p test-suit/rhop_task --target js     → 101/101/0
  run 1 exit=0 / run 2 exit=0 / run 3 exit=0             ← 3/3 自然退出
moon test -p test-suit/rhop_task --target native → 46/46/0

全量 wasm → 612/612/0 ; 全量 js → 819/819/0 ; 全量 native → 612/612/0
```

### WSL2 Ubuntu-22.04 / node v25.2.1 / moon 0.1.20261021
```
check rhop      wasm/js/native → 0 errors (123/99/125 warnings)
check rhop_task wasm/js/native → 0 errors (195/147/197 warnings)

moon test -p test-suit/rhop_js   --target js     → 56/56/0  ×5 全部 exit=0（20~27s）
                                                  竞态压测：失败 0/5
moon test -p test-suit/rhop_task --target wasm   → 46/46/0
moon test -p test-suit/rhop_task --target js     → 101/101/0 ×3 全部 exit=0
moon test -p test-suit/rhop_task --target native → 46/46/0

全量 wasm → 612/612/0 ; 全量 js → 819/819/0 ; 全量 native → 612/612/0
```

> 判定标准：**自然退出（exit=0 且打印汇总行）**，未使用 `timeout` 杀进程。

## 四、测试增量

| 文件 | 新增用例 | 覆盖 |
|---|---|---|
| `test-suit/rhop_js/watch_test.mbt` | 2 | BUG-2 半写重试、BUG-3 stop 清 seen |
| `test-suit/rhop_js/relay_test.mbt` | 2 | BUG-1 临时目录归零、BUG-5 僵尸子进程重启 |
| `test-suit/rhop_task/task_store_test.mbt` | 2 | BUG-7 句柄归零守卫、BUG-6 journal_mode 降级可观测 |

用例数变化：`rhop_js` 52 → **56**；`rhop_task` js 90 → **101**。
资源归零断言均为**可复现**（注册表计数基线 → +1 → 归位；临时目录计数归零；sqlite 句柄归零）。

## 五、验证阶段反向验证（重要）

本轮两条 P1 都不是在静态审读里发现的：
- **BUG-10** 只在 WSL 侧（9p 慢 I/O 放大竞态窗口）+ 多次重复才暴露，首次跑出来是「端口文件内容不是合法 JSON: 」（内容为空）；
- **BUG-2/BUG-3** 是读代码时按「异常路径资源与状态一致性」推演出来的，用定向用例证明。

⇒ 结论：C2 这类"资源与并发"缺陷，**静态审查 + 单次跑绿都不够**，必须 双平台 × 多次重复 × 异常路径定向用例 三件套。本轮 Windows 3 连 + WSL 5 连全部自然退出后才敢报绿。

## 六、改动文件清单

```
rhop/relay.mbt                        （BUG-1 / BUG-5 / BUG-10）
rhop/watch.mbt                        （BUG-2 / BUG-3）
rhop_task/task_store.mbt              （BUG-4 / BUG-6）
test-suit/rhop_js/watch_test.mbt      （+2 回归）
test-suit/rhop_js/relay_test.mbt      （+2 回归）
test-suit/rhop_task/task_store_test.mbt（+2 回归/守卫）
fist-mbt/reports/2026-10-28-c2-bugfind-crypto.md（寻虫报告 + BUG-10 补记）
fist-mbt/reports/2026-10-28-c2-fix-crypto.md    （本文件）
```
未改：`rhop/{key,crypto,transport_*}.mbt`（本轮审读未发现需修复的问题，见寻虫报告对应小节）、`moon.mod`、`rhop/moon.pkg`、其它 lane 文件。
