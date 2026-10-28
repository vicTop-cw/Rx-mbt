# RX-MBT API 文档

> 本文档由 `rx/pkg.generated.mbti`（`moon info` 生成）与源码注释整理，列出全部公开 API 的签名与语义说明。
> 库版本：`vicTop-cw/RX-MBT@0.3.1`　工具链：`moon 0.1.20261016`　编译目标：`wasm`（rhop 相关 API 另见各条目标标注）

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
- [触发机制（Trigger）](#触发机制trigger)
- [自由函数操作符](#自由函数操作符)
- [Itor / Node（可控制迭代器）](#itor--node可控制迭代器)
- [Haskell 迭代器 API 对照](#haskell-迭代器-api-对照)
- [rhop（vools-rhop 协议复刻）](#rhopvools-rhop-协议复刻)
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

## 触发机制（Trigger）

事件驱动的非定时任务触发：`事件名精确 / 通配匹配 → 条件过滤 → 优先级排序 → 分发执行`。`once` 触发器触发一次后自动注销；`fire_with_key` 提供幂等去重；触发与执行解耦（事件驱动，与时间类操作符互补）。

### `TriggerEvent[T]`

触发事件：事件名 + 载荷 + 自增事件序号 + 发生时刻（虚拟时钟毫秒）。

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | `String` | 事件名（按 `.` 分段） |
| `payload` | `T` | 事件载荷 |
| `id` | `Int64` | 自增事件序号（注册表内全局递增） |
| `at` | `Int64` | 发生时刻（虚拟时钟毫秒） |

### `Trigger[T]`

触发器：事件名（支持通配）+ 条件 + 时机 + 处理器。

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | `Int` | 触发器 id（注册表内递增，`unregister` 用） |
| `event_name` | `String` | 事件名模式（支持 `*` / `**` 通配） |
| `condition` | `(TriggerEvent[T]) -> Bool` | 条件过滤器，不满足则跳过 |
| `once` | `Bool` | 是否一次性（触发后自动注销） |
| `priority` | `Int` | 优先级（越大越先执行） |
| `handler` | `(TriggerEvent[T]) -> Unit` | 事件处理器 |
| `fired_count` | `Ref[Int]` | 已触发次数（内部计数，condition 不满足不递增） |

### `TriggerRegistry[T]`

触发器注册表：集中管理 + 事件分发 + 幂等去重。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new() -> TriggerRegistry[T]` | 创建空注册表 |
| `register` | `fn register(Self, String, (TriggerEvent[T]) -> Unit) -> Int` | 注册简单触发器（无条件、非一次性、优先级 0） |
| `register_with` | `fn register_with(Self, String, (TriggerEvent[T]) -> Unit, condition? : ((TriggerEvent[T]) -> Bool)?, once? : Bool, priority? : Int) -> Int` | 注册可配置触发器，返回 trigger_id |
| `unregister` | `fn unregister(Self, Int) -> Bool` | 注销触发器（存在返回 true，否则 false） |
| `fire` | `fn fire(Self, String, T) -> Unit` | 分发事件，时刻取默认虚拟时钟当前时间 |
| `fire_at` | `fn fire_at(Self, String, T, Int64) -> Unit` | 分发事件（指定时刻） |
| `fire_with_key` | `fn fire_with_key(Self, String, T, String) -> Unit` | 幂等触发：key 已存在则整体跳过 |
| `has_trigger` | `fn has_trigger(Self, String) -> Bool` | 是否存在匹配该事件名（含通配）的触发器 |
| `trigger_count` | `fn trigger_count(Self) -> Int` | 当前注册的触发器数量 |
| `clear` | `fn clear(Self) -> Unit` | 清空所有触发器与幂等键（事件序号继续递增） |

### 事件名匹配规则

按 `.` 分段比较，不引入正则：

| 模式 | 含义 | 示例 |
|---|---|---|
| 精确 | 逐段相等 | `task.done` 匹配 `task.done` |
| `*` | 单段通配（不跨段边界） | `task.*` 匹配 `task.done`，不匹配 `task.a.b` 或 `task` |
| `**` | 多段通配（匹配零段或多段，可出现在任意位置） | `a.**.b` 匹配 `a.b` / `a.x.b` / `a.c.d.b`，不匹配 `a.x`；纯 `**` 匹配任意事件名 |

### 分发顺序

命中事件名后按 `priority` 降序执行（同优先级保持注册序）；`condition` 不满足则跳过且不递增 `fired_count`；`once=true` 的触发器触发一次后自动注销。

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

## Itor / Node（可控制迭代器）

复刻 vools 的 `Itor` 相关 API：可控制迭代器包装"可重复迭代的源"（`() -> Iter[T]`），支持紧急/条件插队、断点暂停、历史重放重启与停止。内部以惰性链表 `Node[T]` 组织产出序列。

### `Node[T]`

惰性链表节点：持有值 `val`，通过懒加载源 `iter` 按需展开下一节点，`fallback` 指向尾后接续节点。

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new(T, next? : Node[T]) -> Node[T]` | 构造节点（可指定后继） |
| `from_iter` | `fn from_iter(Iter[T]) -> Node[T]?` | 从迭代器构建链表头；空迭代器返回 `None` |
| `val` | `fn val(Self) -> T` | 取节点值 |
| `set_val` | `fn set_val(Self, T) -> Unit` | 设置节点值 |
| `next` | `fn next(Self) -> Node[T]?` | 取下一节点；懒加载节点首次访问时从源取数展开 |
| `set_next` | `fn set_next(Self, Node[T]?) -> Unit` | 手动设置后继并清除懒加载源 |
| `to_iter` | `fn to_iter(Self) -> Iter[T]` | 按链表顺序产出（惰性） |
| `to_itor` | `fn to_itor(Self) -> Itor[T]` | 链表 → Itor 实例 |

### `Itor[T]`

| 方法 | 签名 | 说明 |
|---|---|---|
| `new` | `fn new(() -> Iter[T]) -> Itor[T]` | 用源工厂构造（每次 copy 重新调用工厂） |
| `from_array` | `fn from_array(Array[T]) -> Itor[T]` | 数组源（副本互相独立） |
| `from_iter` | `fn from_iter(Iter[T]) -> Itor[T]` | 一次性迭代器源（副本共享底层迭代器，与 vools 一致） |
| `next` | `fn next(Self) -> T?` | 取下一个值（自动初始化源） |
| `send` | `fn send(Self, Node[T], jump_when? : (Self) -> Bool) -> Self` | 紧急插队；带 `jump_when` 则为条件插队 |
| `send_value` | `fn send_value(Self, T) -> Self` | 插队单个值 |
| `send_values` | `fn send_values(Self, Array[T]) -> Self` | 插队一组值 |
| `set_pause` | `fn set_pause(Self) -> Self` | 强制暂停（暂停期 `next` 返回 `None` 且不推进源） |
| `resume_iter` | `fn resume_iter(Self) -> Self` | 恢复迭代 |
| `stop` | `fn stop(Self) -> Self` | 终止（后续 `next` 返回 `None`） |
| `restart` | `fn restart(Self) -> Self` | 回到 Pending，从历史头部重放，重放后继续源 |
| `copy` / `call` | `fn copy(Self) -> Self` | 返回独立副本（共享源工厂与历史策略） |
| `history_strategy` | `fn history_strategy(Self, ((Self) -> Unit)?) -> Self` | 设置历史保留策略（`None` 完全保留） |
| `set_history_max` | `fn set_history_max(Self, Int) -> Unit` | 窗口化：最多保留最近 N 条（`-1` 完全保留） |
| `history_len` | `fn history_len(Self) -> Int` | 当前历史条数 |
| `state` | `fn state(Self) -> ItorState` | 当前状态 |
| `is_pending` / `is_iterring` / `is_paused` / `is_stopped` | `fn is_*(Self) -> Bool` | 状态查询 |
| `do_iter` | `fn do_iter(Self, (Self) -> Unit, pre_f? : (Self) -> Self, sub_f? : (Self) -> Unit) -> Self` | 副作用遍历（支持前置/后置钩子） |

### 取值顺序

历史重放（restart 后）→ 紧急插队 → 待处理源值 → 源迭代器。

### `ItorState`

`Pending` / `Iterring` / `Paused` / `Stopped`（derive `Eq`、`Debug`）。

---

## Haskell 迭代器 API 对照

> 语义对照 Haskell `Prelude` / `Data.List` / `Data.Foldable` 的常用迭代器操作。
> 命名说明：`break` / `group` / `delete` 等与语言关键字或既有语义冲突，映射为
> `break_pred` / `group_adjacent` / `delete_first`。`Observable` 层为异步流版本，
> `Itor` 层为可控制同步迭代器版本。

### Observable 层（流式/收集式操作符）

| Haskell | rx-mbt Observable | 语义 |
|---|---|---|
| `iterate f x` | `iterate(f, x)` | 无限发射 `x, f(x), f(f(x))...`，配合 `take` 截断 |
| `repeat x` | `repeat_infinite(x)` | 无限重复同一值 |
| `cycle xs` | `cycle(xs)` | 无限循环数组 |
| `unfoldr f z` | `unfoldr(f, z)` | 用 `f : (S) -> (T, S)?` 逐步展开 |
| `replicate n x` | `repeat(x, n)` | 发射同一值 n 次 |
| `tail xs` | `tail()` | 丢弃首元素（空流安全） |
| `init xs` | `init()` | 丢弃末元素（空流安全） |
| `scanl f z xs` | `scan(z, f)` | 带种子左扫描，逐值发累积 |
| `scanl1 f xs` | `scanl1(f)` | 无种子左扫描，首元素作初始累积 |
| `scanr f z xs` | `scanr(z, f)` | 右扫描，收集后发全部中间结果数组 |
| `scanr1 f xs` | `scanr1(f)` | 无种子右扫描，收集后发全部中间结果数组 |
| `foldl f z xs` | `reduce(z, f)` | 左折叠，完成时发最终结果 |
| `foldl1 f xs` | `reduce_no_seed(f)` | 无种子左折叠 |
| `foldr f z xs` | `foldr(z, f)` | 右折叠，完成时发最终结果 |
| `foldr1 f xs` | `foldr1(f)` | 无种子右折叠（空流不发值） |
| `foldMap f xs` | `fold_map(f)` | 映射后幺半群累积 |
| `mapAccumL f z xs` | `map_accum_l(z, f)` | 带状态左遍历，逐值发 `(新累积, 输出)` |
| `mapAccumR f z xs` | `map_accum_r(z, f)` | 带状态右遍历，输出保持原顺序 |
| `takeWhile p xs` | `take_while(p)` | 谓词为真放行，为假即完成 |
| `dropWhile p xs` | `skip_while(p)` | 跳过满足谓词的前缀 |
| `takeWhileEnd p xs` | `take_while_end(p)` | 从尾部取连续满足谓词的最长后缀 |
| `dropWhileEnd p xs` | `drop_while_end(p)` | 去掉尾部连续满足谓词的段 |
| `zipWith f xs ys` | `zip_with(other, f)` | 双流合并映射 |
| `zip3 xs ys zs` | `zip3(other1, other2)` | 三流拉链 |
| `unzip3 xyzs` | `unzip3()` | 三元组流拆三列 |
| `transpose xss` | `transpose()` | 矩阵转置（收集后发二维数组） |
| `intersperse sep xs` | `intersperse(sep)` | 元素间插入分隔符 |
| `intercalate sep xss` | `intercalate(sep)` | 数组流用分隔数组连接 |
| `span p xs` | `span(p)` | 发 `(满足谓词的最长前缀, 剩余)` |
| `break p xs` | `break_pred(p)` | 发 `(前缀不满足谓词, 剩余)` |
| `splitAt n xs` | `split_at(n)` | 发 `(前 n 个, 剩余)` |
| `partition p xs` | `partition(p)` | 发 `(满足的, 不满足的)` |
| `group xs` | `group_adjacent()` | 相邻相等分组 |
| `groupBy f xs` | `group_adjacent_by(f)` | 相邻满足谓词分组 |
| `sort xs` | `sort()` | 收集排序 |
| `sortBy cmp xs` | `sort_by(cmp)` | 按比较函数排序 |
| `sortOn key xs` | `sort_on(key_fn)` | 按键投影排序 |
| `nub xs` | `distinct()` | 去重（Hash） |
| `nubBy eq xs` | `nub_by(eq)` | 两两比较去重（无 Hash 约束） |
| `delete x xs` | `delete_first(x)` | 删除第一个匹配值 |
| `deleteBy eq x xs` | `delete_first_by(x, eq)` | 按谓词删除第一个 |
| `union xs ys` | `union(ys)` | 并集（源流全保留，ys 补充） |
| `intersect xs ys` | `intersect(ys)` | 交集（源流顺序） |
| `xs \\ ys` | `difference(ys)` | 列表差集（按出现次数逐个删除） |
| `insert x xs` | `insert(x)` | 插入已排序流保持升序 |
| `insertBy cmp x xs` | `insert_by(cmp, x)` | 按比较函数插入 |
| `inits xs` | `inits()` | 全部前缀（含空与全量） |
| `tails xs` | `tails()` | 全部后缀（含全量与空） |
| `isPrefixOf xs ys` | `is_prefix_of(xs)` | 是否前缀 |
| `isSuffixOf xs ys` | `is_suffix_of(xs)` | 是否后缀 |
| `isInfixOf xs ys` | `is_infix_of(xs)` | 是否连续子序列 |
| `isSubsequenceOf xs ys` | `is_subsequence_of(xs)` | 是否可跳跃子序列 |
| `stripPrefix xs ys` | `strip_prefix(xs)` | 匹配前缀则发剩余数组，否则 `None` |
| `stripSuffix xs ys` | `strip_suffix(xs)` | 匹配后缀则发剩余数组，否则 `None` |
| `elem x xs` | `contains(x)` | 是否包含 |
| `notElem x xs` | `not_elem(x)` | 是否不包含 |
| `lookup k kvs` | `lookup(k, key_fn, val_fn)` | 按键查值，发 `V?` |
| `find p xs` | `find(p)` | 发第一个满足谓词的值 |
| `findIndex p xs` | `find_index(p)` | 发第一个满足谓词的索引 |
| `findIndices p xs` | `find_indices(p)` | 发全部满足谓词的索引数组 |
| `elemIndex x xs` | `elem_index(x)` | 发等值索引（找不到发 -1） |
| `elemIndices x xs` | `elem_indices(x)` | 发全部等值索引数组 |
| `and xs` | `all_true()` | Bool 流全真 |
| `or xs` | `any_true()` | Bool 流任一真 |
| `all p xs` | `all(p)` | 全部满足谓词 |
| `any p xs` | `some(p)` | 任一满足谓词 |
| `sum xs` | `sum()` | 累加 |
| `product xs` | `product()` | 累乘 |
| `maximum xs` | `maximum()` | 最大值 |
| `minimum xs` | `minimum()` | 最小值 |
| `maximumBy cmp xs` | `maximum_by_cmp(cmp)` | 按比较函数求最大 |
| `minimumBy cmp xs` | `minimum_by_cmp(cmp)` | 按比较函数求最小 |
| `length xs` | `count()` | 计数 |
| `null xs` | `is_empty()` | 判空 |
| `reverse xs` | `reverse()` | 收集后反转 |
| `lines s` | `lines(s)`（自由函数） | 按换行切分行流 |
| `words s` | `words(s)`（自由函数） | 按空白切分词流 |
| `unlines xs` | `unlines()` | 行流用 `\n` 连接（末尾补 `\n`） |
| `unwords xs` | `unwords()` | 词流用空格连接 |

### Itor 层（可控制迭代器）

`Itor` 层除上述语义外，还提供：`Node` 链表构造、`send/send_value` 插队、
`restart` 重放、`history_len` 历史、`zip4-7 / zip_with4-7 / unzip4-7` 多路拉链、
`chunks_of` 分块、`subsequences / permutations` 子序列与排列、`at` 索引访问、
`take_while_end / drop_while_end` 尾部条件等（详见源码 `rx/ops_itor_haskell.mbt`）。

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

## rhop（vools-rhop 协议复刻）

> `rhop/` 包复刻 [vools-rhop 0.9.0](https://github.com/) 的对外 API：双方对等镜像任务中继协议。
> 本节按文件分组列出**全部公开 API**（签名取自 `rhop/pkg.generated.mbti`，`moon info` 生成）。
> 目标可用性标记：`三目标` = wasm/js/native；`js` = 仅 js 有真实实现，其余目标返回可诊断 `Err` / `available()=false`。
> 逐符号与 vools 的对照见 `fist-mbt/docs/2026-10-27-rhop-vools-parity-matrix.md`。

### 常量

| 常量 | 值 | 文件 | 说明 |
|---|---|---|---|
| `CLIP_FILE` | `"clipboard.txt"` | `clipboard.mbt` | 剪贴板交换文件缺省名 |
| `ENV_RHOP_KEY` | `"RHOP_KEY"` | `key.mbt` | 密钥环境变量名（另有 camelCase 别名 `env_rhop_key`） |
| `SECRET_PREFIX` | `"RHOP-ENC:"` | `key.mbt` | 秘密串前缀（别名 `secret_prefix`） |
| `NPU_MARKER_DEFAULT` | `"NPU_MARKER"` | `signer.mbt` | NPU 签名缺省 marker |
| `SHA256_BLOCK_SIZE` / `SHA256_DIGEST_SIZE` / `MD5_DIGEST_SIZE` | 64 / 32 / 16 | `digest.mbt` | 摘要尺寸常量 |
| `SYNC_MANIFEST_NAME` | `".sync_manifest.json"` | `sync_folder.mbt` | 目录同步清单文件名 |

### core.mbt —— 协议基础模型（三目标）

```moonbit
pub(all) enum Side { Requester; Executor }
pub fn Side::other(Self) -> Self
pub fn Side::to_string(Self) -> String            // "requester" / "executor"
pub fn Side::parse(String) -> Result[Self, String]

pub(all) enum TaskStatus { Pending; Claimed; Running; Done; Failed; Cancelled }
pub fn TaskStatus::to_string(Self) -> String      // "pending" … "cancelled"
pub fn TaskStatus::parse(String) -> Result[Self, String]
pub fn TaskStatus::can_transition(Self, Self) -> Bool
pub fn TaskStatus::is_terminal(Self) -> Bool
pub fn TaskStatus::all() -> Array[Self]           // 增量：全矩阵测试/计数用
```

流转表与 vools `core.py` 逐条一致：`Pending→{Claimed,Cancelled}`、`Claimed→{Running,Cancelled}`、`Running→{Done,Failed}`，其余终态。

### digest.mbt —— 摘要与派生（纯 MoonBit，三目标）

```moonbit
pub fn sha256(Bytes) -> Bytes                     // 32 字节
pub fn sha256_hex(Bytes) -> String                // 64 位小写 hex
pub fn sha256_hex_of_utf8(String) -> String
pub fn md5(Bytes) -> Bytes                        // 16 字节（仅签名对齐用，非安全用途）
pub fn md5_hex(Bytes) -> String
pub fn md5_hex_of_utf8(String) -> String
pub fn hmac_sha256(Bytes, Bytes) -> Bytes         // key 超 64 字节自动折叠
pub fn hmac_sha256_hex(Bytes, Bytes) -> String
pub fn pbkdf2_hmac_sha256(Bytes, Bytes, Int32, Int32) -> Bytes       // (password, salt, iterations, dk_len)
pub fn pbkdf2_hmac_sha256_hex(Bytes, Bytes, Int32, Int32) -> String
pub fn bytes_of_utf8(String) -> Bytes             // 增量
pub fn utf8_text(Bytes) -> String                 // 容错解码（U+FFFD 替换）
pub fn bytes_from_hex(String) -> Result[Bytes, String]              // fixture 消费
```

**边界语义**：`iterations < 1` 或 `dk_len <= 0` 返回零长度 `Bytes`（不 panic；vools 抛 `ValueError`）。

### json_canonical.mbt —— 两套 JSON 规范口径（三目标）

```moonbit
pub fn canonical_json(Json) -> String                  // ensure_ascii=false（envelope checksum 用）
pub fn canonical_json_utf8(Json) -> Bytes
pub fn canonical_json_ascii(Json) -> String            // ensure_ascii=true（signer preimage 用）
pub fn canonical_json_ascii_utf8(Json) -> Bytes
pub fn canonical_object(Array[(String, Json)]) -> Json // 便捷构造（输出按键升序）
```

口径 = Python `json.dumps(x, sort_keys=True)`：键按码点升序、分隔符 `", "` / `": "`、控制字符按 CPython 规则转义；
`ensure_ascii=false` 时非 ASCII 原样，`true` 时转 `\uXXXX`（U+FFFF 以上输出代理对）。
**已知限制**：浮点与 Python `repr` 不保证同形（`1.0`→`"1"`），语料只用 int/字符串/布尔/null/嵌套；解析侧用 `preserve_number_repr=true`。

### envelope.mbt —— 任务信封（三目标）

```moonbit
pub struct Envelope {
  task_id : String; status : TaskStatus; payload : Json;
  result : Json?; error : String?; side : Side; version : Int32;
  created_at : String; updated_at : String; hops_seen : Array[String];
  signature : String?; checksum : String
}
pub fn Envelope::new(String, TaskStatus, Json, Side) -> Self                       // 自动算 checksum
pub fn Envelope::new_full(String, TaskStatus, Json, Side, result? : Json, error? : String,
  version? : Int32, created_at? : String, updated_at? : String, hops_seen? : Array[String],
  signature? : String, checksum? : String) -> Self
pub fn Envelope::compute_checksum(Self) -> String
pub fn Envelope::to_rhop_bytes(Self) -> Bytes                                       // 规范 JSON（含 checksum）
pub fn Envelope::from_rhop_bytes(Bytes) -> Result[Self, String]                     // 校验 checksum
pub fn Envelope::to_dict(Self) -> Json                                              // 无 v 键、含 checksum
pub fn Envelope::from_dict(Json) -> Result[Self, String]                            // checksum 缺省自动重算
pub fn Envelope::with_result(Self, Json?) -> Self
pub fn Envelope::with_updated_at(Self, String) -> Self
pub fn Envelope::with_hops_seen(Self, Array[String]) -> Self
pub fn Envelope::with_status(Self, TaskStatus) -> Self                              // 增量
pub fn Envelope::with_signature(Self, String?) -> Self                              // 增量
```

**checksum 规则**：`"sha256:" + hex(sha256(canonical_json({v:1, task_id, status, payload, result, error, side, version,
created_at, updated_at, hops_seen, signature})))`——不含 `checksum` 自身；未知字段也参与校验（与 vools `pop("checksum")` 后 re-dump 同口径）。
`from_rhop_bytes` 对坏 JSON / 非法 UTF-8 / checksum 不匹配 / 缺必填字段 / 非法 status|side 全部返回 `Err(中文原因)`。

### signer.mbt —— 签名（三目标）

```moonbit
pub trait AbstractSigner {
  fn sign(Self, String, Json) -> String?            // None = 当前环境无法签名
  fn verify(Self, String, Json, String) -> Bool
}
pub struct FileHashSigner {}
pub fn FileHashSigner::new() -> Self
pub fn FileHashSigner::signature(Self, String, Json) -> String      // 增量便捷
pub struct NPUSigner { marker : String; serial_provider : () -> String? }
pub fn NPUSigner::new(String) -> Self
pub fn NPUSigner::with_default_marker() -> Self
pub fn NPUSigner::with_serial_provider(Self, () -> String?) -> Self
pub fn NPUSigner::marker(Self) -> String
pub fn NPUSigner::has_serial(Self) -> Bool
```

- `FileHashSigner`：`"sha256:" + hex(sha256(preimage))`，preimage = `{"result":…,"task_id":…}` 键升序 + **ensure_ascii=True**。
- `NPUSigner`：`"<marker>:<serial>:<md5(preimage)>"`；序列号由注入 provider 提供，缺省 `None` ⇒ `sign()` 返回 `None`（**不做硬件调用、不伪造签名**）。
- 与 envelope 的口径差异是 vools 事实，不是笔误（见上一节两套 JSON）。

### integrity.mbt —— 完整性校验（三目标）

```moonbit
pub struct IntegrityChecker {}
pub fn IntegrityChecker::new() -> Self
pub fn IntegrityChecker::verify(Envelope, Bytes) -> (Bool, String)      // 只校验 raw（env 参数保留以对齐 vools）
pub fn IntegrityChecker::verify_bytes(Bytes) -> (Bool, String)
pub fn IntegrityChecker::checksum_match(Envelope) -> Bool               // 序列化→反序列化比对
pub fn integrity_verify(Envelope, Bytes) -> (Bool, String)              // 便捷
pub fn integrity_verify_bytes(Bytes) -> (Bool, String)
pub fn integrity_checksum_match(Envelope) -> Bool
```

### key.mbt —— 密钥与校验结果（三目标；path 分支仅 js）

```moonbit
pub struct VerifyResult { ok : Bool; payload : Json?; reason : String }   // reason: OK/MALFORMED/BAD_TOKEN/NOT_JSON
pub fn VerifyResult::new(Bool, Json?, String) -> Self
pub fn VerifyResult::pass(Json) -> Self
pub fn VerifyResult::fail(String) -> Self
pub fn VerifyResult::to_string(Self) -> String
pub fn is_secret(String) -> Bool
pub fn load_key(source? : String, path? : String, env_name : String) -> Result[String, String]   // 优先级 source > path > env
pub fn load_key_from_path(String) -> Result[String, String]              // 仅 js
pub fn load_key_from_env(String) -> Result[String, String]
```

### crypto.mbt —— Fernet 信封加密（js 有真实实现）

```moonbit
pub struct RhopCrypto { key : String }
pub fn RhopCrypto::new(String) -> Self
pub fn RhopCrypto::from_key(String) -> Self
pub fn RhopCrypto::from_path(String) -> Result[Self, String]             // 仅 js
pub fn RhopCrypto::from_env(String) -> Result[Self, String]
pub fn RhopCrypto::key_material(Self) -> String
pub fn RhopCrypto::encrypt_json(Self, Json) -> String                    // {"v":1,"alg":"fernet","ct":…}；失败返回 ""
pub fn RhopCrypto::encrypt_json_result(Self, Json) -> Result[String, String]   // 增量：可诊断失败
pub fn RhopCrypto::encrypt_json_text(Self, String) -> String
pub fn RhopCrypto::encrypt_secret(Self, String) -> String                // "RHOP-ENC:" + token
pub fn RhopCrypto::decrypt_secret(Self, String) -> Result[String, String]
pub fn RhopCrypto::decrypt_verify(Self, String) -> VerifyResult
```

**Fernet 口径**（与 VText/vools 对齐）：`salt = sha256(key)[:16]`；`FK = base64url(PBKDF2-SHA256(key, salt, 200000, 32))`；
token = `0x80 | ts_be8 | iv16 | ciphertext | hmac32`（AES-128-CBC + HMAC-SHA256）；`ct` 再 base64url 编码一次。
非 js 目标：结构/校验逻辑可用，加解密返回 `""` 或 `BAD_TOKEN`（显式失败）。

### watch.mbt —— 文件监控（js / native）

```moonbit
pub struct RhopWatcher { … }
pub fn RhopWatcher::new(String, RhopCrypto) -> Self
pub fn RhopWatcher::with_extensions(Self, Array[String]) -> Self         // 缺省 [".rhop"]
pub fn RhopWatcher::skip_existing(Self, Bool) -> Self
pub fn RhopWatcher::start(Self) -> Result[Unit, String]                  // wasm 返回可诊断 Err
pub fn RhopWatcher::stop(Self) -> Unit                                   // 幂等
pub fn RhopWatcher::observe(Self) -> @rx.Observable[(String, VerifyResult), String]
pub fn RhopWatcher::process_file(Self, String) -> VerifyResult?          // 增量：手动处理单文件
pub fn RhopWatcher::extensions(Self) -> Array[String]
pub fn RhopWatcher::bad_files(Self) -> Int32
pub fn RhopWatcher::is_started(Self) -> Bool
```

复用 `@monitor.watch_folder` + `@rx.PublishSubject`：只推 `ok=true` 的解密结果，坏文件计数后跳过、不中断流。

### transport_base.mbt —— 传输抽象（三目标）

```moonbit
pub(open) trait SharedPath {
  fn available(Self) -> Bool
  fn write_text(Self, String, String) -> Result[Unit, String]           // 建议原子写
  fn read_text(Self, String) -> Result[String, String]
  fn exists(Self, String) -> Bool
  fn remove(Self, String) -> Result[Unit, String]                        // 不存在视为成功
  fn name(Self) -> String
  fn root(Self) -> String?
}
pub(open) trait OnlineChannel {
  fn available(Self) -> Bool
  fn send(Self, String, String) -> Result[Unit, String]
  fn receive(Self, String) -> Result[String, String]
  fn name(Self) -> String
}
pub struct TransportSelection { transport : String; label : String; is_online : Bool; reason : String }
pub fn TransportSelection::new(String, String, Bool, String) -> Self
pub fn TransportSelection::to_json(Self) -> Json
pub fn TransportSelection::to_string(Self) -> String
pub struct SharedPathView { write_view : &SharedPath; read_view : &SharedPath }
pub fn SharedPathView::write_name(Self) -> String
pub fn SharedPathView::read_name(Self) -> String
pub struct EndpointSharedPath { view : &EndpointView }
pub fn EndpointSharedPath::new(&EndpointView) -> Self
pub fn make_shared_path(String, String?) -> Result[SharedPathView, String]
pub fn make_shared_path_from_views(&SharedPath, &SharedPath?) -> SharedPathView
```

### transport_local.mbt —— 本地介质（js 真实 IO）

```moonbit
pub struct LocalSharedPath { root : String }
pub fn LocalSharedPath::new(String) -> Self
pub fn normalize_path(String) -> String
pub fn join_shared(String, String) -> String
pub fn write_text_atomic(String, String, String) -> Result[Unit, String]   // tmp + rename
pub fn read_text_at(String, String) -> Result[String, String]
```

### transport_endpoint.mbt —— 端点视图（仅 js）

```moonbit
pub(open) trait EndpointView {
  fn kind(Self) -> String
  fn name(Self) -> String
  fn available(Self) -> Bool
  fn exists(Self, String) -> Bool
  fn read_text(Self, String) -> Result[String, String]
  fn write_text(Self, String, String) -> Result[String, String]
  fn remove(Self, String) -> Result[Unit, String]
}
pub struct LocalEndpoint { … };   pub fn LocalEndpoint::new(String) -> Self
pub fn LocalEndpoint::path(Self) -> String
pub struct FileUrlEndpoint { … }; pub fn FileUrlEndpoint::new(String) -> Result[Self, String]
pub fn FileUrlEndpoint::url(Self) -> String
pub struct HttpEndpoint { … }     // WebDAV 风格 PUT/GET/DELETE
pub fn HttpEndpoint::new(String, String?, Int32) -> Self          // (base_url, token?, timeout_ms)
pub fn HttpEndpoint::base(Self) -> String
pub fn HttpEndpoint::url_of(Self, String) -> String
pub fn parse_endpoint(String) -> Result[&EndpointView, String]     // 裸路径 / file:// / http(s)://
pub fn is_file_url(String) -> Bool
pub fn file_url_to_path(String) -> Result[String, String]
pub fn http_request(String, String, String?, String, Int32) -> Result[HttpResp, String]
pub struct HttpResp { status : Int32; body : String }
```

> 「URL 形态 ≠ 联网」：`file://` 与 `http(s)://` 都属 shared path 兜底层，不参与「在线优先」判定。

### transport_selector.mbt / online.mbt / relay.mbt —— 通道与中转

```moonbit
pub fn select_transport(Array[&OnlineChannel], &SharedPath?) -> TransportSelection
pub fn any_online_available(Array[&OnlineChannel]) -> Bool

pub struct GitChannel { … }    // available() 真跑 git ls-remote；send/receive 无凭据返回可诊断 Err
pub fn GitChannel::new(String) -> Self
pub fn GitChannel::with_branch(Self, String) -> Self
pub fn GitChannel::with_timeout(Self, Int32) -> Self
pub fn GitChannel::remote(Self) -> String
pub struct SftpChannel { … }   // available() 做 TCP 探测
pub fn SftpChannel::new(String, Int32, String) -> Self             // (host, port, remote_dir)
pub fn SftpChannel::with_username(Self, String) -> Self
pub fn SftpChannel::with_timeout(Self, Int32) -> Self

pub struct RelayServer { … }   // 子进程起 HTTP 中转（避免同进程事件循环互堵）
pub fn RelayServer::new(String, Int32, String?, Int32) -> Self     // (host, port, token?, ttl_ms)
pub fn RelayServer::start(Self) -> Result[Unit, String]
pub fn RelayServer::stop(Self) -> Unit
pub fn RelayServer::url(Self) -> String
pub fn RelayServer::port(Self) -> Int32
pub fn RelayServer::alive(Self) -> Bool
pub fn RelayServer::process_alive(Self) -> Bool
pub struct RelayChannel { … }
pub fn RelayChannel::new(String, Int32, String?, Int32) -> Self
pub fn RelayChannel::base(Self) -> String
```

### session.mbt —— 会话与通道链（三目标）

```moonbit
pub(all) enum Role { Send; Recv; Relay }
pub fn Role::parse(String) -> Result[Self, String]
pub fn Role::to_string(Self) -> String
pub fn Role::lower(Self) -> String
pub struct Session { role : Role; shared : SharedPathView?; online : Array[&OnlineChannel];
                     relay : RelayChannel?; crypto : RhopCrypto?; name : String }
pub fn Session::new(Role, SharedPathView?, Array[&OnlineChannel], RelayChannel?, RhopCrypto?, String) -> Self
pub fn Session::empty(Role) -> Self
pub fn Session::available(Self) -> Bool
pub fn Session::select(Self) -> TransportSelection
pub fn Session::send_package(Self, String, Json) -> Result[Json, String]
pub fn Session::recv_package(Self, String) -> Result[Json, String]
pub fn Session::reverse(Self) -> Self
pub fn Session::describe(Self) -> Json
pub fn Session::has_shared(Self) -> Bool; pub fn Session::has_relay(Self) -> Bool
pub fn Session::has_crypto(Self) -> Bool; pub fn Session::online_count(Self) -> Int32
pub fn Session::role(Self) -> Role;      pub fn Session::name(Self) -> String
```

通道链：`relay > online > shared`；`send_package` 回执 `{status, transport, filename, payload}` 与 vools 同形。

### config.mbt —— 配置（file 分支仅 js）

```moonbit
pub struct RhopConfig { key : String; role : Role; sftp : Json?; online : Json?;
                        shared : Json?; relay : Json?; name : String }
pub fn RhopConfig::new(String, Role, Json?, Json?, Json?, Json?, String) -> Self
pub fn RhopConfig::from_dict(Json) -> Result[Self, String]
pub fn RhopConfig::from_file(String) -> Result[Self, String]          // 仅 js
pub fn RhopConfig::to_dict(Self) -> Json                              // password/key_path → "***"
pub fn RhopConfig::build_crypto(Self) -> RhopCrypto
pub fn RhopConfig::build_online(Self) -> Result[Array[&OnlineChannel], String]
pub fn RhopConfig::build_shared(Self) -> Result[SharedPathView?, String]
pub fn RhopConfig::build_relay(Self) -> Result[RelayChannel?, String]
pub fn RhopConfig::build_session(Self, role? : Role) -> Result[Session, String]
pub fn RhopConfig::action_cfg(Self) -> Json
pub fn RhopConfig::has_key(Self) -> Bool; pub fn RhopConfig::name(Self) -> String
pub fn RhopConfig::role(Self) -> Role
pub fn load_config(Json) -> Result[RhopConfig, String]
pub fn _key_from_cfg(Json?) -> Result[String, String]                 // vools 私有名公开化
```

### interact.mbt / actions.mbt —— 交互与动作（三目标）

```moonbit
pub fn interact(RhopConfig, String, Json?, String, request_filename? : String) -> Result[Json, String]  // mode: execute/request/roundtrip
pub fn handle_request(RhopConfig, String, session? : Session) -> Result[Json, String]                   // 回传 res_ 前缀
pub fn run_action(String, Json, Json?) -> Json
pub fn omega_unwrap(Json) -> Json
pub fn register_action(String, (Json, Json?) -> Json) -> Unit
pub fn list_actions() -> Array[String]
```

内置动作 `jump.probe`（离线，不联网）；未知动作返回结构化错误 JSON。

### mirror.mbt —— 镜像库（仅 js，`node:sqlite`）

```moonbit
pub struct StaleVersionError { task_id : String; local_version : Int32; incoming_version : Int32 }
pub fn StaleVersionError::new(String, Int32, Int32) -> Self
pub fn StaleVersionError::task_id(Self) -> String
pub fn StaleVersionError::to_string(Self) -> String
pub fn is_stale_version_error(String) -> Bool
pub struct MirrorDB { … }
pub fn MirrorDB::open(String) -> Result[Self, String]
pub fn MirrorDB::open_temp() -> Result[Self, String]
pub fn MirrorDB::upsert_task(Self, Envelope) -> Result[Unit, String]        // 乐观锁冲突 → Err(stale_version: …)
pub fn MirrorDB::get_task(Self, String) -> Envelope?                         // try_get_task 返回 Result
pub fn MirrorDB::list_tasks(Self, status? : TaskStatus, limit? : Int32) -> Array[Envelope]
pub fn MirrorDB::update_status(Self, String, TaskStatus, Int32, result? : Json, error? : String,
                               signature? : String) -> Result[Int32, String]
pub fn MirrorDB::claim_task(Self, String, String) -> Result[Envelope, String]
pub fn MirrorDB::claim_next(Self, String) -> Result[Envelope?, String]
pub fn MirrorDB::count_by_status(Self) -> Json                               // count_by_status_full / try_count_by_status
pub fn MirrorDB::pending_count(Self) -> Int32
pub fn MirrorDB::log_sync(Self, String, String, String, Bool, error? : String, bytes_xfer? : Int32) -> Result[Unit, String]
pub fn MirrorDB::pending_sync(Self, since? : String) -> Array[Json]
pub fn MirrorDB::sync_log_count(Self) -> Int32
pub fn MirrorDB::raw_run(Self, String, Json) -> Result[Unit, String]
pub fn MirrorDB::is_open(Self) -> Bool; pub fn MirrorDB::path(Self) -> String
pub fn MirrorDB::close(Self) -> Unit
```

### requester.mbt / executor.mbt / daemon.mbt —— 业务 API（仅 js）

```moonbit
pub struct Requester { … }
pub fn Requester::new(RhopConfig) -> Result[Self, String]
pub fn Requester::from_config_dir(RhopConfig, String) -> Result[Self, String]
pub fn Requester::from_mirror_path(RhopConfig, String, String) -> Result[Self, String]
pub fn Requester::submit(Self, String, Json) -> Result[String, String]      // (task_id, payload) → task_id
pub fn Requester::get_result(Self, String) -> Json?
pub fn Requester::wait_result(Self, String, Int32, Int32) -> Json?          // (task_id, timeout_ms, poll_ms)
pub fn Requester::list_tasks(Self, status? : TaskStatus) -> Array[Json]
pub fn Requester::cancel(Self, String) -> Result[Unit, String]
pub fn Requester::mirror(Self) -> MirrorDB; pub fn Requester::data_dir(Self) -> String
pub fn Requester::close(Self) -> Unit

pub struct Executor { … }
pub fn Executor::new(RhopConfig) -> Result[Self, String]
pub fn Executor::claim(Self) -> Result[Envelope?, String]
pub fn Executor::execute(Self, Envelope) -> Result[Json, String]
pub fn Executor::execute_next(Self) -> Result[Json, String]
pub fn Executor::report_result(Self, String, Json) -> Result[Unit, String]
pub fn Executor::report_failure(Self, String, String) -> Result[Unit, String]
pub fn Executor::list_pending(Self) -> Array[Json]
pub fn Executor::mirror(Self) -> MirrorDB; pub fn Executor::worker_id(Self) -> String
pub fn Executor::close(Self) -> Unit

pub struct RelayDaemon { … }
pub fn RelayDaemon::new(RhopConfig) -> Result[Self, String]
pub fn RelayDaemon::from_config_dir(RhopConfig, String, side? : Side, worker_id? : String,
                                    poll_interval_ms? : Int32) -> Result[Self, String]
pub fn RelayDaemon::start(Self, Int32) -> Result[Json, String]
pub fn RelayDaemon::stop(Self) -> Unit
pub fn RelayDaemon::run_once(Self) -> Result[Json, String]
pub fn RelayDaemon::process_inbox(Self) -> Result[Json, String]
pub fn RelayDaemon::push_local(Self) -> Result[Json, String]
pub fn RelayDaemon::pull_remote(Self) -> Result[Json, String]
pub fn RelayDaemon::rounds(Self) -> Int32; pub fn RelayDaemon::side(Self) -> Side
pub fn RelayDaemon::mirror(Self) -> MirrorDB; pub fn RelayDaemon::is_running(Self) -> Bool
pub fn RelayDaemon::data_dir(Self) -> String; pub fn RelayDaemon::close(Self) -> Unit
```

### sync_folder.mbt —— 目录同步（仅 js）

```moonbit
pub struct SyncFolder { … }
pub fn SyncFolder::new(String, String, String) -> Self          // (source, target, pattern)
pub fn SyncFolder::with_recursive(Self, Bool) -> Self
pub fn SyncFolder::sync_once(Self) -> Json                       // 幂等（manifest 去重）
pub fn SyncFolder::run_forever(Self, Int32, Int32) -> Json       // (rounds, poll_ms)
pub fn SyncFolder::stop(Self) -> Unit
pub fn SyncFolder::rounds(Self) -> Int32
pub fn SyncFolder::manifest_path(Self) -> String
pub fn sync_glob_match(String, String) -> Bool                    // pattern 匹配（* / ? / **）
```

### clipboard.mbt —— 剪贴板共享（状态机三目标；真实 IO 仅 js）

```moonbit
pub(open) trait ClipboardBackend {
  fn name(Self) -> String
  fn read(Self) -> String          // 失败返回 ""
  fn write(Self, String) -> Bool
}
pub struct CommandClipboardBackend { … }
pub fn CommandClipboardBackend::new(String, String, String, Bool) -> Self   // (name, read_argv_json, write_argv_json, strip_crlf)
pub fn CommandClipboardBackend::backend_name(Self) -> String
pub fn get_clipboard_backend() -> &ClipboardBackend?
pub fn get_clipboard_backend_name() -> String?
pub fn read_clipboard(backend? : &ClipboardBackend) -> String
pub fn write_clipboard(String, backend? : &ClipboardBackend) -> Bool
pub fn last_read_reason() -> String
pub fn set_clipboard_backend_probe(() -> &ClipboardBackend?) -> Unit        // 测试钩子
pub fn reset_clipboard_backend_probe() -> Unit
pub fn reset_clipboard_backend_cache() -> Unit
pub struct ClipboardFileSync { … }
pub fn ClipboardFileSync::new(String, role? : String, filename? : String,
                              backend? : &ClipboardBackend, writer? : String,
                              auto_detect? : Bool) -> Result[Self, String]   // role: push / pull
pub fn ClipboardFileSync::sync_once(Self) -> Json          // {changed, reason, text_len?, from_writer?}
pub fn ClipboardFileSync::sync_rounds(Self, Int32) -> Json // {rounds, changes}
pub fn ClipboardFileSync::run_forever(Self, poll_interval_ms? : Int32) -> @rx.Observable[Json, String]
pub fn ClipboardFileSync::role(Self) -> String; pub fn ClipboardFileSync::path(Self) -> String
pub fn ClipboardFileSync::writer(Self) -> String
pub fn ClipboardFileSync::rounds(Self) -> Int32; pub fn ClipboardFileSync::changes(Self) -> Int32
pub fn ClipboardFileSync::last_text(Self) -> String?
```

**协议语义**（与 vools 逐条对齐）：交换文件 `{"text","updated_at","writer"}` 原子写；
push 比「剪贴板 vs 文件」，pull 比「文件 vs 上次/本机」；reason 原文短语：`内容一致` / `内容未变化` /
`无可用剪贴板后端` / `交换文件不存在或未初始化` / `剪贴板写入失败` / `文件写入失败: …`。
`text_len` 按码点计数（对齐 Python `len`）。后端探测：Windows PowerShell / Linux wl-paste|xclip / macOS pbpaste。

### 基础设施原语（rhop_js.mbt 导出，供上层复用）

```moonbit
pub fn rhop_fs_read_text(String) -> Result[String, String];   pub fn rhop_fs_write_text(String, String) -> Result[Unit, String]
pub fn rhop_fs_exists(String) -> Bool;                        pub fn rhop_fs_remove(String) -> Result[Unit, String]
pub fn rhop_fs_mkdir_p(String) -> Result[Unit, String];       pub fn rhop_fs_list_dir(String) -> Array[String]
pub fn rhop_fs_list_files_recursive(String) -> Array[String];  pub fn rhop_fs_copy(String, String) -> Result[Unit, String]
pub fn rhop_fs_move(String, String) -> Result[Unit, String];   pub fn rhop_fs_parent(String) -> String
pub fn rhop_fs_digest_file(String) -> Result[Json, String];    pub fn rhop_join(String, String) -> String
pub fn rhop_db_open(String) -> Result[Int32, String];          pub fn rhop_db_run(Int32, String, Json) -> Result[Unit, String]
pub fn rhop_db_all(Int32, String, Json) -> Result[Array[Json], String];  pub fn rhop_db_close(Int32) -> Unit
pub fn rhop_ensure_data_dirs(String) -> Result[Unit, String]
pub fn rhop_now_iso() -> String;  pub fn rhop_sleep_ms(Int32) -> Unit
pub fn uri_encode(String) -> String;  pub fn uri_decode(String) -> String
```

### 既有协议类型（非 vools 对照面）

```moonbit
pub trait RhopCipher { fn alg_name(Self) -> String; fn encrypt(Self, String) -> String; fn decrypt(Self, String) -> String? }
pub struct RhopCipherNone {}; pub fn RhopCipherNone::new() -> Self          // ct = base64(明文)，仅测试
pub struct RhopPacket { id; source; kind; payload; at }
pub fn RhopPacket::new(String, String, String, Json, Int64) -> Self
pub fn RhopPacket::to_json_string(Self) -> String
pub fn RhopPacket::from_json_text(String) -> Result[Self, String]
pub struct RhopEnvelope { v : Int32; alg : String; ct : String }
pub fn RhopEnvelope::encode(Int32, String, String) -> String
pub fn RhopEnvelope::decode(String) -> Result[Self, String]
```

### P2：`rhop_task`（任务队列）

> vools `task/` 子包（230 个公开符号）的 MoonBit 移植，分两批：**P2a**（数据/配置/密文，三目标纯逻辑）
> 与 **P2b**（存储/队列/心跳/执行/同步，js 依赖 `node:sqlite`）。
> 测试：`test-suit/rhop_task` **wasm/native 46 例、js 99 例**（含与真 vools Heartbeat 的双向互操作用例）。

**P2a（已落地）**

```moonbit
// task_models.mbt —— 状态与记录
pub(all) enum TaskState { … }                       // 与 @rp.TaskStatus 显式桥接
pub fn TaskState::to_status(Self) -> @rp.TaskStatus
pub fn TaskState::from_status(@rp.TaskStatus) -> TaskState
pub fn TaskState::parse(String) -> Result[Self, String]
pub fn TaskState::is_terminal(Self) -> Bool;   pub fn TaskState::is_active(Self) -> Bool
pub fn TaskState::is_claimable(Self) -> Bool;  pub fn TaskState::can_transition(Self, Self) -> Bool
pub(all) struct TaskRecord { … }
pub fn TaskRecord::new(String) -> Self
pub fn TaskRecord::with_type/with_value/with_deps/with_priority/with_state/with_max_retries/
  with_timeout_min/with_retry_delay_min/with_payload/with_tags/with_queue/with_owner/
  with_scheduled_at/with_created_at(…) -> Self
pub fn TaskRecord::validate(Self) -> Result[Unit, String]
pub fn TaskRecord::to_dict(Self) -> Json;  pub fn TaskRecord::from_dict(Json) -> Result[Self, String]
pub fn utcnow_iso() -> String;  pub fn parse_iso(String) -> Int64?;  pub fn to_iso(String) -> String?
pub fn iso_add_seconds(String, Double) -> String;  pub fn utcnow_seconds() -> Int64
pub fn task_record_from_json_text(String) -> Result[TaskRecord, String]

// task_config.mbt —— 配置与角色
pub(all) enum TaskRole { … }
pub fn normalize_role(String) -> Result[TaskRole, String]
pub(all) struct TaskConfig { … }
pub fn TaskConfig::from_dict(Json) -> Result[Self, String]
pub fn TaskConfig::from_json_text(String) -> Result[Self, String]
pub fn TaskConfig::from_file(String) -> Result[Self, String]        // 仅 js
pub fn TaskConfig::to_dict(Self, mask : Bool) -> Json               // mask=true 脱敏
pub fn TaskConfig::describe(Self) -> Json
pub fn TaskConfig::build_crypto(Self) -> @rp.RhopCrypto?            // 复用 Batch B
pub fn TaskConfig::worker_id(Self) -> String
pub fn TaskConfig::plaintext_findings(Self) -> Array[SecretFinding]
pub fn load_task_config(String) -> Result[TaskConfig, String]
pub fn default_queue() -> Json;  pub fn default_exec() -> Json

// task_secrets.mbt —— 密文解析与脱敏
pub(all) struct SecretResolver { … }
pub fn SecretResolver::new(…);  pub fn SecretResolver::with_warner(…)
pub fn SecretResolver::resolve(Self, Json) -> Result[Json, String]
pub fn SecretResolver::flag_plaintext(Self) -> Unit
pub fn SecretResolver::findings(Self) -> Array[SecretFinding]
pub(all) struct SecretFinding / SecretField
pub fn find_secret_fields(Json) -> Array[SecretField]
pub fn is_sensitive_leaf(String) -> Bool
pub fn mask_value(String, Int) -> String;  pub fn mask_value_default(String) -> String
pub fn resolve_config_secrets(Json, …) -> Result[(Json, Array[SecretFinding]), String]
```

**P2b（已落地，js 依赖 sqlite）**

```moonbit
// task_store.mbt —— SQLite 存储（表名白名单 + 句柄注册表）
pub(all) struct TaskStoreSpec { … }
pub fn TaskStoreSpec::for_kind(String, String) -> Result[Self, String]   // 仅 sqlite 形态
pub fn schema_sql(String) -> String
pub struct SqliteTaskStore { … }
pub fn SqliteTaskStore::open(TaskStoreSpec) -> Result[Self, String]
pub fn SqliteTaskStore::init_schema(Self) -> Result[Unit, String]
pub fn SqliteTaskStore::insert_tasks(Self, Array[TaskRecord]) -> Result[Int32, String]
pub fn SqliteTaskStore::claim_next(Self, String, String, Double?) -> Result[TaskRecord?, String]
pub fn SqliteTaskStore::set_state(Self, String, TaskState, Int32?, Bool, Json, String) -> Result[Bool, String]
pub fn SqliteTaskStore::update_fields(Self, String, Json, String) -> Result[Bool, String]
pub fn SqliteTaskStore::clean_stale_locks(Self, String) -> Result[Int32, String]
pub fn SqliteTaskStore::requeue(Self, String, String) -> Result[Bool, String]
pub fn SqliteTaskStore::set_cancel_requested(Self, String, Bool, String) -> Result[Bool, String]
pub fn SqliteTaskStore::get_task(Self, String) -> Result[TaskRecord?, String]
pub fn SqliteTaskStore::require_task(Self, String) -> Result[TaskRecord, String]
pub fn SqliteTaskStore::list_tasks(Self, TaskState?, Int32) -> Result[Array[TaskRecord], String]
pub fn SqliteTaskStore::all_task_names(Self) -> Result[Array[String], String]
pub fn SqliteTaskStore::count_by_state(Self) -> Result[Map[String, Int32], String]
pub fn SqliteTaskStore::active_tasks(Self) -> Result[Array[TaskRecord], String]
pub fn SqliteTaskStore::is_all_done(Self) -> Result[Bool, String]
pub fn SqliteTaskStore::summary(Self) -> Result[Json, String]
pub fn SqliteTaskStore::apply_task(Self, TaskRecord) -> Result[String, String]
pub fn SqliteTaskStore::describe(Self) -> Json
pub fn SqliteTaskStore::table(Self) -> String;  pub fn SqliteTaskStore::path(Self) -> String
pub fn SqliteTaskStore::is_closed(Self) -> Bool;  pub fn SqliteTaskStore::close(Self) -> Unit

// task_queue.mbt —— 队列编排（加密载荷 + sha 校验）
pub(all) struct TaskQueue { … }
pub fn TaskQueue::new(SqliteTaskStore, @rp.RhopCrypto?, Double, Bool, Int32) -> Self
pub fn TaskQueue::from_config(SqliteTaskStore, TaskConfig) -> Self
pub fn TaskQueue::submit(Self, Array[TaskRecord], String) -> Result[Int32, String]
pub fn TaskQueue::claim(Self, String, String) -> Result[TaskRecord?, String]
pub fn TaskQueue::mark_running(Self, String, String) -> Result[Bool, String]
pub fn TaskQueue::mark_done(Self, String, Json, String) -> Result[Bool, String]
pub fn TaskQueue::mark_failed(Self, String, String, String) -> Result[Bool, String]
pub fn TaskQueue::cancel(Self, String, String) -> Result[Bool, String]
pub fn TaskQueue::retry_failed(Self, String, String) -> Result[Bool, String]
pub fn TaskQueue::requeue(Self, String, String) -> Result[Bool, String]
pub fn TaskQueue::list_tasks(Self, TaskState?, Int32) -> Result[Array[TaskRecord], String]
pub fn TaskQueue::status_counts(Self) -> Result[Map[String, Int32], String]
pub fn TaskQueue::decrypt_payload(Self, TaskRecord) -> Result[Json, String]
pub fn TaskQueue::verify_payload_sha(Self, TaskRecord) -> Bool          // 增量
pub fn TaskQueue::crypto_enabled(Self) -> Bool;  pub fn TaskQueue::store_of(Self) -> SqliteTaskStore
pub fn TaskQueue::close(Self) -> Unit

// task_heartbeat.mbt —— 心跳（vools 同形纯文本 + 三级兼容读 + 泵）
pub(all) struct HeartbeatSnapshot { … };  pub(all) struct Heartbeat { … }
pub fn Heartbeat::new(&@rhop.SharedPath?, String, Double, Double, String, String) -> Self
pub fn Heartbeat::from_config(&@rhop.SharedPath?, TaskConfig) -> Self
pub fn Heartbeat::beat(Self, String?, include_worker~ : Bool = false) -> Result[Unit, String]
    // 写 vools 同形纯文本 `<ISO.%fZ>`（微秒；MoonBit ms 精度补 000）；
    // include_worker=true 时写 `<ts> <worker_id>`（vools 默认 False，本项目同）
pub fn Heartbeat::mark_closed(Self, String?) -> Result[Unit, String]
    // 写字面量 closed_token（默认 "closed"，与 vools 同名常量一致），不是 JSON
pub fn Heartbeat::read(Self) -> Result[HeartbeatSnapshot?, String]
    // 三级兼容：① 整串 == closed_token ⇒ 停机哨兵；② JSON 存量（历史版本）；
    // ③ 纯文本 ISO（秒 / 微秒都收，`<ts>` 或 `<ts> <worker>`）
pub fn Heartbeat::is_alive(Self, Int64?) -> Bool
pub fn Heartbeat::check(Self, Int64?) -> Result[(Bool, String), String]
pub fn Heartbeat::clear(Self) -> Result[Unit, String]
pub fn Heartbeat::filename(Self) -> String;  pub fn Heartbeat::stale_after_sec(Self) -> Double
pub fn Heartbeat::max_future_skew_sec(Self) -> Double        // 默认 60.0（vools 同值）
pub fn Heartbeat::with_max_future_skew(Self, Double) -> Self  // ≤0 回落 60s
    // 未来时间戳超出容差 ⇒ fail-closed 判 dead（与 vools 一致）；容差也可从 queue.heartbeat.max_future_skew_sec 读
pub struct HeartbeatPump { … }
pub fn HeartbeatPump::new(Heartbeat) -> Self
pub fn HeartbeatPump::start(Self) -> Result[Unit, String]
pub fn HeartbeatPump::stop(Self) -> Unit
pub fn HeartbeatPump::shutdown(Self) -> Result[Unit, String]
pub fn HeartbeatPump::is_running(Self) -> Bool;  pub fn HeartbeatPump::last_ok(Self) -> Bool

// task_exec.mbt —— 执行策略与处理器注册表
pub(all) struct ExecPolicy { … }
pub fn ExecPolicy::new(Array[String], Bool, Double) -> Self
pub fn ExecPolicy::default() -> Self
pub fn ExecPolicy::from_config(TaskConfig) -> Self
pub fn ExecPolicy::allows(Self, String) -> Bool
pub(all) struct ExecResult { … }                                        // 增量：结构化执行结果
pub fn register_handler(String, (Json) -> Result[Json, String]) -> Unit
pub fn get_handler(String) -> ((Json) -> Result[Json, String])?
pub fn list_handlers() -> Array[String];  pub fn clear_handlers() -> Unit
pub fn detect_language(Json) -> String                                  // 增量
pub fn run_payload(ExecPolicy, Json) -> ExecResult

// task_sync.mbt —— 任务同步（加密导出包）
pub(all) struct TaskSync { … }
pub fn TaskSync::new(SqliteTaskStore, @rp.RhopCrypto?, String) -> Self
pub fn TaskSync::peer(Self) -> String
pub fn TaskSync::pending_count(Self) -> Result[Int32, String]
pub fn TaskSync::pending_tasks(Self, Int32) -> Result[Array[TaskRecord], String]
pub fn TaskSync::export_pending(Self, Int32, String) -> Result[Json, String]
pub fn TaskSync::import_pack(Self, Json) -> Result[Json, String]
pub fn TaskSync::mark_synced(Self, Array[String], String) -> Result[Int32, String]
pub fn TaskSync::export_and_mark(Self, Int32, String) -> Result[(Json, Int32), String]   // 增量
```

**P2 已知缺口与偏差（务必与「已对齐」区分）**

| 类 | 项 | 说明 |
|---|---|---|
| ⛔ 未实现 | Postgres 后端 | 仅 SQLite；`TaskStoreSpec::for_kind` 只接受 sqlite 形态 |
| ⛔ 未实现 | `queue.file_channel` 大载荷落文件 | 配置项保留，实际内联存储 |
| ⚠️ 预留 | `tasks_executions` 表 | 已建表但不写入执行明细 |
| ⚠️ 未接线 | `write_retries` / `retry_backoff` | 遇 `database is locked` 直接 `Err`，无自动退避重试 |
| ⚠️ 未应用 | exec 的 `workdir` / `env` / `shell:true` | 仅按语言白名单 spawn；显式不支持 shell（安全取舍） |
| ⚠️ 简化 | 同步冲突 | 仅 `version` 新者胜，无 field merge / 墓碑 |
| ⛔ 未复刻 | `task/cli.py` / `task/daemon.py` / `task/local_runner.py` | 命令行、task 守护、本机执行快捷路径 |
| ~~B1~~ ✅ 已解决 | 心跳文件格式 | 已按 vools 字节级对齐：`beat` 写纯文本 `<ISO.%fZ>`（`include_worker~` 默认 false）、`mark_closed` 写字面量 `"closed"`、`read` 三级兼容；**真 vools Heartbeat 双向互操作 6/6**（T0r15）|
| ~~B2~~ ✅ 已解决 | 未来时间戳判定 | `max_future_skew_sec` 默认 **60s**（vools 同值）+ `with_max_future_skew`，超容差 **fail-closed** 判 dead（T0r15）|
| B5 偏差 | 结果截断 | 用自定义 `__truncated__` 结构，vools 用尾部截断+省略号 |

**复用而非重造**：载荷加密用 Batch B 的 `@rp.RhopCrypto`；摘要用 Batch A 的 `@rp.sha256_hex_of_utf8`；
心跳/同步落盘用 Batch B 的 `@rp.SharedPath` 原子写；配置与密文解析复用 P2a 的 `TaskConfig` / `SecretResolver`；
`TaskState` 与 `@rp.TaskStatus` 通过 `to_status` / `from_status` 显式桥接（任务队列与信封状态机同源）。

### 跨实现对齐要点（实现时务必遵守）

1. **checksum 只覆盖 envelope 自身字段**（含 `v:1`，不含 `checksum`）；未知字段参与校验。
2. **两套 JSON 口径**：envelope → `canonical_json`（非 ASCII 原样）；signer preimage → `canonical_json_ascii`。
3. **整数不要写成浮点**：构造 `Json` 用 `Json::number(1.0)`（输出 `1`）；解析外部字节用 `preserve_number_repr=true`。
4. **时间**：`@env.now()`（epoch ms）+ 民用历换算，ISO 形如 `2026-10-28T01:23:45Z`。
5. **错误**：一律 `Result[_, String]`，文本保留可诊断短语；不要 panic。
6. **目标可用性**：平台强依赖项集中在 `#cfg(target="js")`；非 js 分支必须有同签名的可诊断降级实现。

