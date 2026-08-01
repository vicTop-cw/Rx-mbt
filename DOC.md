# RX-MBT API 文档

> 本文档由 `rx/pkg.generated.mbti`（`moon info` 生成）与源码注释整理，列出全部公开 API 的签名与语义说明。
> 库版本：`vicTop/RX-MBT@0.1.0`　工具链：`moon 0.1.20260724`　编译目标：`wasm`

## 目录

- [核心类型](#核心类型)
- [创建类工厂（自由函数）](#创建类工厂自由函数)
- [Observable 方法——创建](#observable-方法创建)
- [Observable 方法——转换](#observable-方法转换)
- [Observable 方法——过滤](#observable-方法过滤)
- [Observable 方法——聚合](#observable-方法聚合)
- [Observable 方法——组合](#observable-方法组合)
- [Observable 方法——条件](#observable-方法条件)
- [Observable 方法——错误处理](#observable-方法错误处理)
- [Observable 方法——时间类](#observable-方法时间类)
- [Observable 方法——工具类](#observable-方法工具类)
- [Observable 方法——订阅](#observable-方法订阅)
- [Subject（多播主题）](#subject多播主题)
- [调度器](#调度器)
- [自由函数操作符](#自由函数操作符)
- [行为约定](#行为约定)

---

## 核心类型

### `Observable[T, E]`

可观察对象（冷流），包装订阅函数，每次 `subscribe` 重新执行。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new((Observer[T, E]) -> Subscription) -> Observable[T, E]` | 用订阅函数构造 Observable |

### `Observer[T, E]`

观察者，承载三个回调。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new((T) -> Unit, (E) -> Unit, () -> Unit) -> Observer[T, E]` | 三回调构造 |
| `on_next_only` | `fn on_next_only((T) -> Unit) -> Observer[T, E]` | 只关心 next，error/complete 为空 |
| `on_next` | `fn on_next(Self, T) -> Unit` | 发射值 |
| `on_error` | `fn on_error(Self, E) -> Unit` | 报错 |
| `on_completed` | `fn on_completed(Self) -> Unit` | 完成 |

### `Subscription`

订阅句柄，`dispose()` 幂等取消订阅。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new(() -> Unit) -> Subscription` | 用清理函数构造 |
| `empty` | `fn empty() -> Subscription` | 空句柄（不做事） |
| `dispose` | `fn dispose(Self) -> Unit` | 取消订阅（幂等） |
| `is_disposed` | `fn is_disposed(Self) -> Bool` | 是否已取消 |

### `Clock`

虚拟时钟：毫秒计数 + 定时器队列，通过 `advance` 手动推进。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new() -> Clock` | 创建虚拟时钟（时间从 0 开始） |
| `now` | `fn now(Self) -> Int64` | 当前虚拟时间（毫秒） |
| `advance` | `fn advance(Self, Int64) -> Unit` | 推进时间并触发到期定时器 |

---

## 创建类工厂（自由函数）

| 函数 | 签名 | 说明 |
|---|---|---|
| `advance_time` | `fn advance_time(Int64) -> Unit` | 推进默认虚拟时钟 |
| `interval` | `fn interval(Int64) -> Observable[Int64, Unit]` | 每隔 ms 发射递增计数（0, 1, 2, …），默认时钟 |
| `interval_on` | `fn interval_on(Clock, Int64) -> Observable[Int64, Unit]` | 指定虚拟时钟的 interval |
| `timer` | `fn timer(Int64) -> Observable[Int64, Unit]` | ms 后发射 0L 并完成，默认时钟 |
| `timer_on` | `fn timer_on(Clock, Int64) -> Observable[Int64, Unit]` | 指定虚拟时钟的 timer |

---

## Observable 方法——创建

| 方法 | 签名 | 说明 |
|---|---|---|
| `of` | `fn of(T) -> Observable[T, E]` | 发射单值并完成 |
| `from_iter` | `fn from_iter(Array[T]) -> Observable[T, E]` | 逐个发射数组元素并完成 |
| `empty` | `fn empty() -> Observable[T, E]` | 立即完成，不发射值 |
| `never` | `fn never() -> Observable[T, E]` | 不发射、不完成、不报错 |
| `error` | `fn error(E) -> Observable[T, E]` | 只触发错误回调 |
| `repeat` | `fn repeat(T, Int) -> Observable[T, E]` | 重复发射同一值 n 次 |
| `range` | `fn range(Int64, Int64) -> Observable[Int64, E]` | 发射 `[start, end)` 区间序列 |
| `from_range` | `fn from_range(Int64, Int64) -> Observable[Int64, E]` | 等价 `range` |
| `from_range_with_step` | `fn from_range_with_step(Int64, Int64, Int64) -> Observable[Int64, E]` | 按步长发射区间 |
| `from_callable` | `fn from_callable(() -> T) -> Observable[T, E]` | 订阅时调用函数并发射结果 |
| `start` | `fn start(() -> T) -> Observable[T, E]` | 等价 `from_callable` |

---

## Observable 方法——转换

| 方法 | 签名 | 说明 |
|---|---|---|
| `map` | `fn map(Self[T, E], (T) -> U) -> Observable[U, E]` | 对每个值应用映射 |
| `filter_map` | `fn filter_map(Self[T, E], (T) -> U?) -> Observable[U, E]` | 保留 `Some` 丢弃 `None` |
| `flat_map` | `fn flat_map(Self[T, E], (T) -> Observable[U, E]) -> Observable[U, E]` | 平铺内部流（交错合并语义） |
| `flat_map_latest` | `fn flat_map_latest(Self[T, E], (T) -> Observable[U, E]) -> Observable[U, E]` | 别名 `switch_map` |
| `concat_map` | `fn concat_map(Self[T, E], (T) -> Observable[U, E]) -> Observable[U, E]` | 串行平铺（前一个完成才订阅下一个） |
| `scan` | `fn scan(Self[T, E], Acc, (Acc, T) -> Acc) -> Observable[Acc, E]` | 累积并发出每个中间结果 |
| `switch_map` | `fn switch_map(Self[T, E], (T) -> Observable[U, E]) -> Observable[U, E]` | 切换到最新内部流，取消旧订阅 |
| `group_by` | `fn group_by(Self[T, E], (T) -> K, () -> Observable[T, E]) -> Observable[(K, Observable[T, E]), E]` | 按键分组，发出 `(key, 子流)` |
| `curry_map` | `fn curry_map((T, A) -> R, A) -> (Observable[T, E]) -> Observable[R, E]` | 柯里化映射：先绑定参数返回函数，再应用到流 |

---

## Observable 方法——过滤

| 方法 | 签名 | 说明 |
|---|---|---|
| `filter` | `fn filter(Self[T, E], (T) -> Bool) -> Observable[T, E]` | 只放行满足谓词的值 |
| `take` | `fn take(Self[T, E], Int) -> Observable[T, E]` | 取前 n 个后完成并取消上游 |
| `skip` | `fn skip(Self[T, E], Int) -> Observable[T, E]` | 跳过前 n 个 |
| `first` | `fn first(Self[T, E]) -> Observable[T, E]` | 取第一个值后完成 |
| `last` | `fn last(Self[T, E]) -> Observable[T, E]` | 完成时发最后一个值 |
| `first_or_first` | `fn first_or_first(Self[T, E]) -> Observable[T, E]` | 兼容别名（与 `first` 同语义） |
| `last_or_last` | `fn last_or_last(Self[T, E]) -> Observable[T, E]` | 兼容别名（与 `last` 同语义） |
| `take_while` | `fn take_while(Self[T, E], (T) -> Bool) -> Observable[T, E]` | 谓词为真持续放行，为假即停并完成 |
| `skip_while` | `fn skip_while(Self[T, E], (T) -> Bool) -> Observable[T, E]` | 跳过满足谓词的前缀 |
| `skip_n_events` | `fn skip_n_events(Self[T, E], Int) -> Observable[T, E]` | 跳过前 n 个事件（含 error/complete 计数） |
| `take_n_events` | `fn take_n_events(Self[T, E], Int) -> Observable[T, E]` | 取前 n 个事件后完成 |
| `skip_last` | `fn skip_last(Self[T, E], Int) -> Observable[T, E]` | 跳过最后 n 个值 |
| `take_last` | `fn take_last(Self[T, E], Int) -> Observable[T, E]` | 只取最后 n 个值 |
| `element_at` | `fn element_at(Self[T, E], Int) -> Observable[T, E]` | 取第 index 个值；越界发 `E::default()` 错误 |
| `distinct` | `fn distinct(Self[T, E]) -> Observable[T, E]`（T : Hash + Eq） | 全局去重 |
| `distinct_by` | `fn distinct_by(Self[T, E], (T) -> K) -> Observable[T, E]`（K : Hash + Eq） | 按键去重 |
| `distinct_until_changed` | `fn distinct_until_changed(Self[T, E]) -> Observable[T, E]`（T : Eq） | 去连续重复 |
| `distinct_until_changed_by` | `fn distinct_until_changed_by(Self[T, E], (T) -> K) -> Observable[T, E]`（K : Eq） | 按键去连续重复 |
| `skip_until` | `fn skip_until(Self[T, E], Observable[Unit, E]) -> Observable[T, E]` | 触发流发值前不放行 |
| `take_until` | `fn take_until(Self[T, E], Observable[Unit, E]) -> Observable[T, E]` | 触发流发值后即停并完成 |
| `contains` | `fn contains(Self[T, E], T) -> Observable[Bool, E]`（T : Eq） | 命中返回 true（发射一次后完成） |
| `includes` | `fn includes(Self[T, E], T) -> Observable[Bool, E]`（T : Eq） | 等价 `contains` |
| `sort` | `fn sort(Self[T, E]) -> Observable[Array[T], E]`（T : Compare） | 收集全部后排序并一次性发出 |
| `top_k` | `fn top_k(Self[T, E], Int) -> Observable[Array[T], E]`（T : Compare） | 收集后取最大 k 个 |
| `bottom_k` | `fn bottom_k(Self[T, E], Int) -> Observable[Array[T], E]`（T : Compare） | 收集后取最小 k 个 |
| `drop_none` | `fn drop_none(Self[T?, E]) -> Observable[T, E]` | 丢弃 `None`，放行 `Some` 解包值 |
| `fill_none` | `fn fill_none(Self[T?, E], T) -> Observable[T, E]` | `None` 用默认值替换 |
| `clamp` | `fn clamp(Self[T, E], T, T) -> Observable[T, E]`（T : Compare） | 夹取到 `[min, max]` 区间 |

---

## Observable 方法——聚合

| 方法 | 签名 | 说明 |
|---|---|---|
| `count` | `fn count(Self[T, E]) -> Observable[Int, E]` | 完成时统计发射个数 |
| `reduce` | `fn reduce(Self[T, E], Acc, (Acc, T) -> Acc) -> Observable[Acc, E]` | 带初始值累积，完成时发最终结果 |
| `reduce_no_seed` | `fn reduce_no_seed(Self[T, E], (T, T) -> T) -> Observable[T, E]` | 首元素作初始值累积 |
| `collect` | `fn collect(Self[T, E]) -> Observable[Array[T], E]` | 收集成数组，完成时发出 |
| `to_list` | `fn to_list(Self[T, E]) -> Observable[Array[T], E]` | 别名 `collect` |
| `sum` | `fn sum(Self[T, E]) -> Observable[T, E]`（T : Add + Default） | 累加 |
| `sum_direct` | `fn sum_direct(Self[T, E], T) -> Observable[T, E]`（T : Add） | 从给定 seed 累加（不等完成，逐值可发） |
| `sum_by` | `fn sum_by(Self[T, E], (T) -> Double) -> Observable[Double, E]` | 按 key_mapper 累加为 Double |
| `average` | `fn average(Self[Double, E]) -> Observable[Double, E]` | 求均值 |
| `average_direct` | `fn average_direct(Self[Double, E]) -> Observable[Double, E]` | 流式均值（每次发射更新） |
| `average_by` | `fn average_by(Self[T, E], (T) -> Double) -> Observable[Double, E]` | 按 key_mapper 求均值 |
| `minimum` | `fn minimum(Self[T, E]) -> Observable[T, E]`（T : Compare） | 求最小值 |
| `minimum_direct` | `fn minimum_direct(Self[T, E]) -> Observable[T, E]`（T : Compare） | 流式最小值 |
| `minimum_by` | `fn minimum_by(Self[T, E], (T) -> Double) -> Observable[Double, E]` | 按 key_mapper 求最小值 |
| `maximum` | `fn maximum(Self[T, E]) -> Observable[T, E]`（T : Compare） | 求最大值 |
| `maximum_direct` | `fn maximum_direct(Self[T, E]) -> Observable[T, E]`（T : Compare） | 流式最大值 |
| `maximum_by` | `fn maximum_by(Self[T, E], (T) -> Double) -> Observable[Double, E]` | 按 key_mapper 求最大值 |
| `mean` | `fn mean(Self[Double, E]) -> Observable[Double, E]` | 自由函数版求均值 |
| `median` | `fn median(Self[Double, E]) -> Observable[Double, E]` | 求中位数（偶数取中间平均） |
| `variance` | `fn variance(Self[Double, E]) -> Observable[Double, E]` | 求总体方差 |
| `std` | `fn std(Self[Double, E]) -> Observable[Double, E]` | 求标准差 |
| `quantile` | `fn quantile(Self[Double, E], Double) -> Observable[Double, E]` | 求分位数 |
| `n_unique` | `fn n_unique(Self[T, E]) -> Observable[Int, E]`（T : Hash + Eq） | 去重计数 |
| `arg_min` | `fn arg_min(Self[T, E]) -> Observable[Int, E]`（T : Compare） | 返回最小值首次出现的索引 |
| `arg_max` | `fn arg_max(Self[T, E]) -> Observable[Int, E]`（T : Compare） | 返回最大值首次出现的索引 |
| `cum_prod` | `fn cum_prod(Self[T, E]) -> Observable[T, E]`（T : Mul） | 累积乘积，逐值发出 |
| `cum_mean` | `fn cum_mean(Self[Double, E]) -> Observable[Double, E]` | 累积均值，逐值发出 |
| `cum_sum` | `fn cum_sum(Self[T, E]) -> Observable[T, E]`（T : Add + Default） | 累积求和，逐值发出 |
| `cum_min` | `fn cum_min(Self[T, E]) -> Observable[T, E]`（T : Compare） | 累积最小值，逐值发出 |
| `cum_max` | `fn cum_max(Self[T, E]) -> Observable[T, E]`（T : Compare） | 累积最大值，逐值发出 |
| `rolling_sum` | `fn rolling_sum(Self[Double, E], Int) -> Observable[Double, E]` | 滑动窗口求和 |
| `rolling_mean` | `fn rolling_mean(Self[Double, E], Int) -> Observable[Double, E]` | 滑动窗口均值 |
| `rolling_min` | `fn rolling_min(Self[T, E], Int) -> Observable[T, E]`（T : Compare） | 滑动窗口最小值 |
| `rolling_max` | `fn rolling_max(Self[T, E], Int) -> Observable[T, E]`（T : Compare） | 滑动窗口最大值 |
| `rolling_count` | `fn rolling_count(Self[T, E], Int) -> Observable[Int, E]` | 滑动窗口计数 |
| `to_map` | `fn to_map(Self[T, E], (T) -> K, (T) -> V) -> Observable[HashMap[K, V], E]`（K : Hash + Eq） | 收集成映射 |
| `to_set` | `fn to_set(Self[T, E]) -> Observable[HashSet[T], E]`（T : Hash + Eq） | 收集去重成集合 |
| `abs` | `fn abs(Self[Double, E]) -> Observable[Double, E]` | 逐元素取绝对值 |

---

## Observable 方法——组合

| 方法 | 签名 | 说明 |
|---|---|---|
| `start_with` | `fn start_with(Self[T, E], Array[T]) -> Observable[T, E]` | 订阅时先发射前缀再发射源值 |
| `concat` | `fn concat(Self[T, E], Self[T, E]) -> Observable[T, E]` | 串接两个流（前一个完成才订阅下一个） |
| `merge` | `fn merge(Self[T, E], Self[T, E]) -> Observable[T, E]` | 合并两个流（交错） |
| `zip` | `fn zip(Self[T, E], Self[U, E]) -> Observable[(T, U), E]` | 按位置配对；任一源完成即终止 |
| `combine_latest` | `fn combine_latest(Self[T, E], Observable[U, E]) -> Observable[(T, U), E]` | 任一源有新值时组合各自最新值 |
| `with_latest_from` | `fn with_latest_from(Self[T, E], Observable[U, E]) -> Observable[(T, U), E]` | 主源发值时带次源最新值 |
| `amb` | `fn amb(Self[T, E], Self[T, E]) -> Observable[T, E]` | 先发射者胜出，取消另一路 |
| `end_with` | `fn end_with(Self[T, E], Array[T]) -> Observable[T, E]` | 完成前追加后缀值 |
| `iif` | `fn iif(Bool, Observable[T, E], Observable[T, E]) -> Observable[T, E]` | 条件为真选 then 分支 |
| `sequence_equal` | `fn sequence_equal(Self[T, E], Observable[T, E]) -> Observable[Bool, E]`（T : Eq） | 两流逐元素相等发 true |

---

## Observable 方法——条件

| 方法 | 签名 | 说明 |
|---|---|---|
| `every` | `fn every(Self[T, E], (T) -> Bool) -> Observable[Bool, E]` | 全部满足发 true（任一不满足发 false 并完成） |
| `all` | `fn all(Self[T, E], (T) -> Bool) -> Observable[Bool, E]` | 等价 `every` |
| `some` | `fn some(Self[T, E], (T) -> Bool) -> Observable[Bool, E]` | 命中发 true，否则完成时发 false |
| `find` | `fn find(Self[T, E], (T) -> Bool) -> Observable[T, E]` | 发首个匹配值后完成 |
| `find_index` | `fn find_index(Self[T, E], (T) -> Bool) -> Observable[Int64, E]` | 发匹配索引；未找到发 -1 |
| `is_empty` | `fn is_empty(Self[T, E]) -> Observable[Bool, E]` | 完成时无值发 true |

---

## Observable 方法——错误处理

| 方法 | 签名 | 说明 |
|---|---|---|
| `retry` | `fn retry(Self[T, E], Int) -> Observable[T, E]` | 出错重试最多 n 次（立即重试） |
| `retry_indefinitely` | `fn retry_indefinitely(Self[T, E]) -> Observable[T, E]` | 出错无限重试 |
| `retry_when` | `fn retry_when(Self[T, E], (E) -> Bool) -> Observable[T, E]` | 谓词为 true 才重试，否则转发错误 |
| `retry_with_backoff` | `fn retry_with_backoff(Self[T, E], Int64) -> Observable[T, E]` | 指数退避重试（2^n 倍初始延迟），默认时钟 |
| `retry_with_backoff_on` | `fn retry_with_backoff_on(Self[T, E], Clock, Int64) -> Observable[T, E]` | 指定时钟的指数退避重试 |
| `catch_error` | `fn catch_error(Self[T, E], (E) -> Observable[T, E]) -> Observable[T, E]` | 出错时切换到 handler 返回的备用流 |
| `on_error_return` | `fn on_error_return(Self[T, E], T) -> Observable[T, E]` | 出错时发射兜底值并完成 |
| `on_error_resume_next` | `fn on_error_resume_next(Self[T, E], Self[T, E]) -> Observable[T, E]` | 出错时切到备用流继续 |
| `circuit_breaker` | `fn circuit_breaker(Self[T, E], Int, Int64) -> Observable[T, E]` | 熔断器：threshold 次错误后暂停 ms 毫秒，默认时钟 |
| `circuit_breaker_on` | `fn circuit_breaker_on(Self[T, E], Clock, Int, Int64) -> Observable[T, E]` | 指定时钟的熔断器 |
| `backpressure_error` | `fn backpressure_error(Self[T, E], Int) -> Observable[T, E]` | 背压占位：同步模型下透传（max_size 保留签名） |
| `backpressure_buffer` | `fn backpressure_buffer(Self[T, E], Int) -> Observable[T, E]` | 背压占位：同步模型下透传 |
| `backpressure_drop` | `fn backpressure_drop(Self[T, E]) -> Observable[T, E]` | 背压占位：同步模型下透传 |
| `backpressure_latest` | `fn backpressure_latest(Self[T, E]) -> Observable[T, E]` | 背压占位：同步模型下透传 |

---

## Observable 方法——时间类

基于虚拟时钟实现，均提供 `_on(clock)` 变体。

| 方法 | 签名 | 说明 |
|---|---|---|
| `delay` / `delay_on` | `fn delay(Self[T, E], Int64) -> Observable[T, E]` | 每个值延迟 ms 毫秒发射 |
| `debounce` / `debounce_on` | `fn debounce(Self[T, E], Int64) -> Observable[T, E]` | 防抖：停止发射 ms 后发最后一个值；完成时立即刷出 |
| `throttle` / `throttle_on` | `fn throttle(Self[T, E], Int64) -> Observable[T, E]` | 节流：每 ms 最多放行一个值 |
| `throttle_first` | `fn throttle_first(Self[T, E], Int64) -> Observable[T, E]` | 窗口首值立即发 |
| `rate_limit` / `rate_limit_on` | `fn rate_limit(Self[T, E], Int64) -> Observable[T, E]` | 限速：ms 内只放行一个 |
| `timeout` / `timeout_on` | `fn timeout(Self[T, E], Int64) -> Observable[T, E]`（E : Default） | 超时发 `E::default()` 错误 |
| `sample` / `sample_on` | `fn sample(Self[T, E], Int64) -> Observable[T, E]` | 每 ms 采样最近值 |
| `timestamp` | `fn timestamp(Self[T, E]) -> Observable[(T, Int64), E]` | 附虚拟时间戳 |
| `buffer_time` / `buffer_time_on` | `fn buffer_time(Self[T, E], Int64) -> Observable[Array[T], E]` | 按时间窗口缓冲 |
| `window` / `window_on` | `fn window(Self[T, E], Int64) -> Observable[Observable[T, E], E]` | 按时间窗口切子流 |

---

## Observable 方法——工具类

| 方法 | 签名 | 说明 |
|---|---|---|
| `tap` | `fn tap(Self[T, E], (T) -> Unit) -> Observable[T, E]` | 旁路观察每个值，原样透传 |
| `tap_on_next` | `fn tap_on_next(Self[T, E], (T) -> Unit) -> Observable[T, E]` | 等价 `tap` |
| `default_if_empty` | `fn default_if_empty(Self[T, E], T) -> Observable[T, E]` | 空流完成时发默认值 |
| `ignore_elements` | `fn ignore_elements(Self[T, E]) -> Observable[T, E]` | 丢弃所有值只透传完成/错误 |
| `pairwise` | `fn pairwise(Self[T, E]) -> Observable[(T, T), E]` | 每对相邻值 `(prev, cur)` |
| `pairwise_with_buffer` | `fn pairwise_with_buffer(Self[T, E], Int) -> Observable[(Array[T], Array[T]), E]` | 前后缓冲窗口对 |
| `buffer_count` | `fn buffer_count(Self[T, E], Int) -> Observable[Array[T], E]` | 按数量窗口缓冲 |
| `switch` | `fn switch(Self[Observable[T, E], E]) -> Observable[T, E]` | 切换到最新内部流 |
| `sample_first` | `fn sample_first(Self[T, E]) -> Observable[T, E]` | 只发首值（等价 `first`） |
| `skip_until_data` | `fn skip_until_data(Self[T, E], (T) -> Bool) -> Observable[T, E]` | 谓词首次为 true 前跳过 |
| `take_until_data` | `fn take_until_data(Self[T, E], (T) -> Bool) -> Observable[T, E]` | 谓词首次为 true 后停止 |
| `run` | `fn run(Self[T, E]) -> Observable[T, E]` | 立即消费并原样返回（副作用：订阅立即执行） |
| `debug` | `fn debug(Self[T, E], String?) -> Observable[T, E]` | 打印每个事件（next/error/complete）后透传 |

---

## Observable 方法——订阅

| 方法 | 签名 | 说明 |
|---|---|---|
| `subscribe` | `fn subscribe(Self[T, E], Observer[T, E]) -> Subscription` | 订阅完整观察者 |
| `subscribe_on_next` | `fn subscribe_on_next(Self[T, E], (T) -> Unit) -> Subscription` | 只订 next |
| `subscribe_on_error` | `fn subscribe_on_error(Self[T, E], (E) -> Unit) -> Subscription` | 只订 error |
| `subscribe_on_completed` | `fn subscribe_on_completed(Self[T, E], () -> Unit) -> Subscription` | 只订 complete |

---

## Subject（多播主题）

### `PublishSubject[T, E]`

订阅后收到之后的所有值。

| 方法 | 签名 |
|---|---|
| `new` | `fn new() -> PublishSubject[T, E]` |
| `subscribe` | `fn subscribe(Self, Observer[T, E]) -> Subscription` |
| `on_next` | `fn on_next(Self, T) -> Unit` |
| `on_error` | `fn on_error(Self, E) -> Unit` |
| `on_completed` | `fn on_completed(Self) -> Unit` |
| `as_observable` | `fn as_observable(Self) -> Observable[T, E]` |

### `BehaviorSubject[T, E]`

订阅时立即重放当前值。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new() -> BehaviorSubject[T, E]` | 初始无值 |
| `with_value` | `fn with_value(T) -> BehaviorSubject[T, E]` | 带初始值创建 |
| `value` | `fn value(Self) -> T?` | 当前值 |
| `subscribe` / `on_next` / `on_error` / `on_completed` / `as_observable` | 同 `PublishSubject` | |

### `ReplaySubject[T, E]`

订阅时重放历史值。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new() -> ReplaySubject[T, E]` | 重放全部历史 |
| `with_buffer_size` | `fn with_buffer_size(Int) -> ReplaySubject[T, E]` | 只重放最近 N 个 |
| `subscribe` / `on_next` / `on_error` / `on_completed` / `as_observable` | 同 `PublishSubject` | |

---

## 调度器

同步语义 + 虚拟时钟等价实现（MoonBit wasm 目标无线程）。所有调度器提供：

| 方法 | 签名 | 说明 |
|---|---|---|
| `now` | `fn now(Self) -> Int64` | 返回虚拟时间（毫秒） |
| `schedule` | `fn schedule(Self, () -> Unit) -> Unit` | 立即同步执行任务 |

| 类型 | 额外方法 |
|---|---|
| `CurrentThreadScheduler` | `new` / `with_clock(Clock)` |
| `ImmediateScheduler` | `new` / `with_clock(Clock)` |
| `AsyncScheduler` | `new` / `with_clock(Clock)` |
| `ThreadPoolScheduler` | `new` / `with_threads(Int)` / `with_clock(Clock, Int)` / `get_num_threads(Self) -> Int` |

---

## 自由函数操作符

| 函数 | 签名 | 说明 |
|---|---|---|
| `amb` | `fn amb(Observable[T, E], Observable[T, E]) -> Observable[T, E]` | 先发射者胜出 |
| `combine_latest` | `fn combine_latest(Observable[T, E], Observable[U, E]) -> Observable[(T, U), E]` | 组合最新值 |
| `count_events` | `fn count_events(Observable[T, E], Int) -> Observable[Int, E]` | 每 n 个事件发一次计数 |
| `curry_map` | `fn curry_map((T, A) -> R, A) -> (Observable[T, E]) -> Observable[R, E]` | 柯里化映射 |
| `first` | `fn first(Observable[T, E], (T) -> Bool) -> Observable[T, E]` | 首个匹配值（谓词版） |
| `iif` | `fn iif(Bool, Observable[T, E], Observable[T, E]) -> Observable[T, E]` | 条件分支 |
| `last` | `fn last(Observable[T, E], (T) -> Bool) -> Observable[T, E]` | 最后匹配值 |
| `max` | `fn max(Observable[T, E]) -> Observable[T, E]`（T : Compare） | 最大值 |
| `mean` | `fn mean(Observable[Double, E]) -> Observable[Double, E]` | 均值 |
| `median` | `fn median(Observable[Double, E]) -> Observable[Double, E]` | 中位数 |
| `merge` | `fn merge(Observable[T, E], Observable[T, E]) -> Observable[T, E]` | 合并 |
| `min` | `fn min(Observable[T, E]) -> Observable[T, E]`（T : Compare） | 最小值 |
| `n_unique` | `fn n_unique(Observable[T, E]) -> Observable[Int, E]`（T : Hash + Eq） | 去重计数 |
| `quantile` | `fn quantile(Observable[Double, E], Double) -> Observable[Double, E]` | 分位数 |
| `sample_first` | `fn sample_first(Observable[T, E]) -> Observable[T, E]` | 首值 |
| `sequence_equal` | `fn sequence_equal(Observable[T, E], Observable[T, E]) -> Observable[Bool, E]`（T : Eq） | 序列相等 |
| `std` | `fn std(Observable[Double, E]) -> Observable[Double, E]` | 标准差 |
| `switch` | `fn switch(Observable[Observable[T, E], E]) -> Observable[T, E]` | 最新内部流 |
| `variance` | `fn variance(Observable[Double, E]) -> Observable[Double, E]` | 方差 |
| `with_latest_from` | `fn with_latest_from(Observable[T, E], Observable[U, E]) -> Observable[(T, U), E]` | 带最新值 |
| `zip` | `fn zip(Observable[T, E], Observable[U, E]) -> Observable[(T, U), E]` | 配对 |
| `arg_max` / `arg_min` | `fn arg_max(Observable[T, E]) -> Observable[Int, E]`（T : Compare） | 最值索引 |

---

## 行为约定

1. **冷流语义**：`Observable` 每次 `subscribe` 都重新执行订阅函数；`Subject` 是热流（多播）。
2. **同步执行**：`subscribe` 时源同步发射所有值（wasm 单线程，无异步调度）。
3. **终止后静默**：完成/错误后，后续 `on_next` 一律忽略（操作符内部用 `stopped` 标志保护）。
4. **dispose 幂等**：`Subscription::dispose` 可多次调用，只生效一次。
5. **资源清理**：组合/时间类操作符在 dispose 时级联取消上游订阅并取消挂起的虚拟定时器。
6. **虚拟时钟**：所有时间类操作符基于 `Clock`（默认 `default_clock`），测试用 `advance_time(ms)` 推进；`interval`/`timer` 需推进时钟才会触发。
7. **错误类型**：`element_at` 越界、`timeout` 超时均发射 `E::default()`。
8. **背压占位**：`backpressure_*` 在同步模型下透传（无积压场景），保留 Rx-Rust 签名便于后续异步扩展。
