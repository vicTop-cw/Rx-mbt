# RX-MBT

Rx-Rust 的 MoonBit 复刻：基于 Observer 模式的响应式编程库，纯 MoonBit 实现，零外部依赖。

## 作为三方依赖使用

本仓库是标准 MoonBit 库模块，**库代码在 `rx/` 子包中**，可通过两种方式引入：

### 方式一：git 依赖（无需发布到中心仓库）

```bash
# 在你的项目里执行（仓库地址替换为实际 git 地址）
moon add git+https://<你的仓库地址>.git
```

然后在依赖包的 `moon.pkg` 中声明并起别名：

```toml
import {
  "vicTop/RX-MBT/rx" @rx,
}
```

### 方式二：发布到 MoonBit 中心仓库

```bash
moon publish
# 之后任何项目可用：
moon add vicTop/RX-MBT
```

### 使用示例（外部项目视角）

```moonbit
// moon.pkg 中已 import "vicTop/RX-MBT/rx" @rx
fn main {
  // 链式调用：map -> filter -> collect
  let result = @rx.Observable::from_iter([1, 2, 3, 4, 5])
    .map(fn(x) { x * 2 })
    .filter(fn(x) { x > 4 })
  let _ = result.subscribe_on_next(fn(v) { println(v) })

  // Subject 多播
  let subject : @rx.PublishSubject[Int, Unit] = @rx.PublishSubject::new()
  let _ = subject.subscribe(@rx.Observer::on_next_only(fn(v) { println("收到: \{v}") }))
  subject.on_next(42)
  subject.on_completed()
}
```

本仓库自带的 `cmd/main` 就是一个完整可运行的示例：`moon run cmd/main`。

## 启动与测试

```bash
moon check      # 类型检查（零警告零错误）
moon test       # 运行全部测试
```

> 完整的 API 签名与语义说明见 [DOC.md](DOC.md)（按分类整理的全部公开 API）。

### 版本与测试环境

本项目在以下环境验证通过：

| 项目 | 值 |
|---|---|
| MoonBit 工具链 | `moon 0.1.20260724 (5f1406a 2026-07-24)`（`moon version` 输出） |
| 操作系统 | Windows 11（PowerShell 7 / Windows PowerShell 5.1 均可运行脚本） |
| 编译目标 | `wasm`（`preferred_target = "wasm"`，见 `moon.mod`） |
| 测试后端 | `moon test` 默认 wasm 后端 |
| 库版本 | `vicTop/RX-MBT@0.1.0`（`moon.mod` 的 `version` 字段） |
| 测试数量 | 377（基本 + 高压 + Haskell API 回归，全部通过，见 `TEST_REPORT.md`） |
| 基准测试 | `test-suit/bench`（`#skip` 默认跳过，`moon test -g "bench"` 运行） |

> 工具链版本以 `moon version` 输出为准。要求 `moon >= 0.1.20260724`（本项目使用了较新的 `moon.mod` / `moon.pkg` 语法与 Feature flags：`rr_moon_mod, rr_moon_pkg`）。

### 测试报告

运行报告生成脚本（PowerShell，无需额外依赖）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/gen_test_report.ps1
```

产物：

| 文件 | 说明 |
|---|---|
| `TEST_REPORT.md` | 测试环境、汇总统计、按包分类的完整测试清单 |
| `TEST_REPORT.json` | 机器可读报告（供 CI / 对比脚本消费） |

报告包含 moon 版本、生成时间、总测试数/通过/失败，以及每个测试包的全部测试名清单。

测试按分类组织在 `test-suit/` 下（每个子目录独立成包，黑盒引用 `@rx`）：

| 目录 | 覆盖 |
|---|---|
| `test-suit/create` | of / from_iter / empty / never / error / repeat / range / from_callable / start |
| `test-suit/transform` | map / filter_map / flat_map / scan / concat_map / switch_map / group_by / curry_map |
| `test-suit/filter` | filter / take / skip / first / last / distinct / skip_until / take_until / contains |
| `test-suit/aggregation` | count / reduce / collect / sum / average / min / max / mean / median / variance / rolling_* / to_map / to_set |
| `test-suit/composite` | start_with / concat / merge / zip / combine_latest / with_latest_from / amb / iif / sequence_equal |
| `test-suit/math_conditions` | drop_none / fill_none / clamp / abs / every / some / all / find / is_empty |
| `test-suit/core` | run / debug / Subject / Scheduler / cum_* 等基础行为 |
| `test-suit/itor` | Itor / Node 可控制迭代器：send 插队 / set_pause / resume_iter / restart 重放 / stop / history 策略 |
| `test-suit/haskell` | Haskell 迭代器 API（Data.List / Data.Foldable 语义）：iterate / scanl1 / foldr1 / map_accum_l / inits / tails / union / insert / lines / words 等 |
| `test-suit/stress` | 高压测试：10 万元素链、多订阅者、Subject 高压、递归重试 |
| `test-suit/bench` | 基准测试（`#skip` 默认跳过，`moon test -g bench` 运行） |

基准测试以控制台 JSON 输出结果（每个用例一行），可与 Rx-Rust 的 `benches/bench.rs` 结果对比。如需保存：

```bash
moon test -p test-suit/bench --include-skipped > moon_bench.json
```

## 核心抽象

| 类型 | 说明 |
|---|---|
| `Observable[T, E]` | 可观察对象（冷流），包装订阅函数，每次 `subscribe` 重新执行 |
| `Observer[T, E]` | 观察者，承载 `on_next` / `on_error` / `on_completed` 三个回调 |
| `Subscription` | 订阅句柄，`dispose()` 幂等取消订阅 |
| `Clock` | 虚拟时钟，时间类操作符基于它实现，`advance_time(ms)` 推进 |
| `Node[T]` | 惰性链表节点：持有值 + 懒加载源 + fallback，`from_iter` 构建 |
| `Itor[T]` | 可控制迭代器（vools 风格）：支持 send 插队 / 暂停 / 重放 / 停止 / 历史策略 |

## Itor / Node（可控制迭代器）

复刻 vools 的 `Itor` 相关 API，包装任意可重复迭代的源（`() -> Iter[T]`）：

| API | 说明 |
|---|---|
| `Node::new(val, next?)` / `Node::from_iter(iter)` | 构造节点 / 从迭代器构建惰性链表 |
| `Node::val()` / `Node::next()` | 取值 / 取下一节点（懒加载展开） |
| `Node::to_itor()` / `Node::to_iter()` | 节点链表 → Itor / Iter |
| `Itor::new(source)` / `from_array` / `from_iter` | 构造（数组源可重复迭代，副本独立） |
| `Itor::next()` | 取下一个值（自动初始化源） |
| `Itor::send(node, jump_when?)` / `send_value(v)` / `send_values(arr)` | 紧急插队 / 条件插队 |
| `Itor::set_pause()` / `resume_iter()` / `stop()` | 暂停 / 恢复 / 终止 |
| `Itor::restart()` | 回到 Pending，从历史头部重放，重放后继续源 |
| `Itor::history_strategy(fn)` / `set_history_max(n)` | 历史保留策略（-1 全保留 / n 条窗口） |
| `Itor::state()` / `is_pending` / `is_iterring` / `is_paused` / `is_stopped` | 状态查询 |
| `Itor::copy()` / `call()` | 返回独立副本（共享源工厂） |
| `Itor::do_iter(f, pre_f?, sub_f?)` | 副作用遍历（支持前置 / 后置钩子） |

**取值顺序**：历史重放（restart 后）→ 紧急插队 → 待处理源值 → 源迭代器。

## 创建类工厂

`from_iter` / `of` / `repeat` / `empty` / `never` / `error` / `range` / `from_range` / `from_range_with_step` / `from_callable` / `start` / `interval` / `timer`

## 操作符

**转换类**：`map` / `filter_map` / `flat_map` / `flat_map_latest` / `scan` / `concat_map` / `switch_map` / `group_by` / `curry_map`

**过滤类**：`filter` / `take` / `skip` / `first` / `last` / `take_while` / `skip_while` / `skip_n_events` / `take_n_events` / `skip_last` / `take_last` / `element_at` / `distinct` / `distinct_by` / `distinct_until_changed` / `distinct_until_changed_by` / `skip_until` / `take_until` / `contains` / `includes` / `sort` / `top_k` / `bottom_k` / `drop_none` / `fill_none` / `clamp`

**聚合类**：`count` / `reduce` / `collect` / `to_list` / `sum` / `average` / `minimum` / `maximum` / `min` / `max` / `mean` / `median` / `variance` / `std` / `quantile` / `n_unique` / `arg_min` / `arg_max` / `cum_prod` / `cum_mean` / `cum_sum` / `cum_min` / `cum_max` / `rolling_sum` / `rolling_mean` / `rolling_min` / `rolling_max` / `rolling_count` / `to_map` / `to_set` / `abs`

**组合类**：`start_with` / `concat` / `merge` / `zip` / `combine_latest` / `with_latest_from` / `amb` / `end_with` / `iif` / `sequence_equal`

**条件类**：`every` / `all` / `some` / `find` / `find_index` / `is_empty`

**错误处理类**：`retry` / `retry_indefinitely` / `retry_when` / `retry_with_backoff` / `retry_with_backoff_on` / `catch_error` / `on_error_return` / `on_error_resume_next` / `circuit_breaker` / `circuit_breaker_on`（背压操作符 `backpressure_*` 保留签名、同步模型下透传）

**时间类**（基于虚拟时钟）：`delay` / `debounce` / `throttle` / `throttle_first` / `rate_limit` / `timeout` / `sample` / `timestamp`（均提供 `_on(clock)` 变体）

**工具类**：`tap` / `tap_on_next` / `default_if_empty` / `ignore_elements` / `pairwise` / `pairwise_with_buffer` / `buffer_count` / `buffer_time` / `window` / `switch` / `sample_first` / `skip_until_data` / `take_until_data` / `run` / `debug`

## Subject（多播主题）

`PublishSubject` / `BehaviorSubject` / `ReplaySubject`（`with_buffer_size` 限制重放窗口），均提供 `subscribe` / `on_next` / `on_error` / `on_completed` / `as_observable`。

## 调度器

同步语义 + 虚拟时钟等价实现（MoonBit wasm 目标无线程）：

`CurrentThreadScheduler` / `ImmediateScheduler` / `AsyncScheduler` / `ThreadPoolScheduler`

每个提供 `now()` 返回虚拟时间（毫秒）、`schedule(task)` 立即同步执行；`ThreadPoolScheduler` 额外提供 `get_num_threads()`。

## 示例

```moonbit
// 链式调用：map -> filter -> collect
let result = Observable::from_iter([1, 2, 3, 4, 5])
  .map(fn(x) { x * 2 })
  .filter(fn(x) { x > 4 })
  .collect()
let _ = result.subscribe_on_next(fn(v) { println(v) })

// Subject 多播
let subject : PublishSubject[Int, Unit] = PublishSubject::new()
let _ = subject.subscribe_on_next(fn(v) { println("收到: \{v}") })
subject.on_next(42)
subject.on_completed()
```

## 与 Rx-Rust 的差异

- 监控类 API（文件/文件夹监听、`watch_file` / `watch_folder` 等）未移植
- 时间类操作符基于虚拟时钟而非真实定时器，测试时用 `advance_time(ms)` 推进
- 背压与线程池调度器在同步模型下为签名占位，语义等价透传/立即执行

