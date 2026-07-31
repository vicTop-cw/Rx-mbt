# RX-MBT

Rx-Rust 的 MoonBit 复刻：基于 Observer 模式的响应式编程库，纯 MoonBit 实现，零外部依赖。

## 启动与测试

```bash
moon check      # 类型检查
moon test       # 运行全部测试
```

## 核心抽象

| 类型 | 说明 |
|---|---|
| `Observable[T, E]` | 可观察对象（冷流），包装订阅函数，每次 `subscribe` 重新执行 |
| `Observer[T, E]` | 观察者，承载 `on_next` / `on_error` / `on_completed` 三个回调 |
| `Subscription` | 订阅句柄，`dispose()` 幂等取消订阅 |
| `Clock` | 虚拟时钟，时间类操作符基于它实现，`advance_time(ms)` 推进 |

## 创建类工厂

`from_iter` / `of` / `repeat` / `empty` / `never` / `error` / `range` / `from_range` / `from_range_with_step` / `from_callable` / `start` / `interval` / `timer`

## 操作符

**转换类**：`map` / `filter_map` / `flat_map` / `flat_map_latest` / `scan` / `concat_map` / `switch_map` / `group_by`

**过滤类**：`filter` / `take` / `skip` / `first` / `last` / `take_while` / `skip_while` / `skip_n_events` / `take_n_events` / `skip_last` / `take_last` / `element_at` / `distinct` / `distinct_by` / `distinct_until_changed` / `distinct_until_changed_by` / `skip_until` / `take_until` / `contains` / `includes` / `sort` / `top_k` / `bottom_k` / `drop_none` / `fill_none` / `clamp`

**聚合类**：`count` / `reduce` / `collect` / `to_list` / `sum` / `average` / `minimum` / `maximum` / `min` / `max` / `mean` / `median` / `variance` / `std` / `quantile` / `n_unique` / `arg_min` / `arg_max` / `cum_prod` / `cum_mean` / `rolling_sum` / `rolling_mean` / `rolling_min` / `rolling_max` / `rolling_count` / `to_map` / `to_set`

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
