# RX-MBT Test Report

## Environment

| Item | Value |
|---|---|
| Generated at | 2026-08-01 19:23:44 |
| moon version | moon 0.1.20260724 (5f1406a 2026-07-24) |
| Test target | wasm |
| Total tests | 155 |
| Passed | 155 |
| Failed | 0 |

**Result: PASS (all green)**

## Per-package stats

| Package | Tests |
|---|---|
| vicTop/RX-MBT/rx | 7 |
| vicTop/RX-MBT/test-suit/aggregation | 37 |
| vicTop/RX-MBT/test-suit/composite | 21 |
| vicTop/RX-MBT/test-suit/core | 15 |
| vicTop/RX-MBT/test-suit/create | 10 |
| vicTop/RX-MBT/test-suit/filter | 24 |
| vicTop/RX-MBT/test-suit/math_conditions | 21 |
| vicTop/RX-MBT/test-suit/stress | 10 |
| vicTop/RX-MBT/test-suit/transform | 10 |
| **Total** | **155** |

## Test listing

### vicTop/RX-MBT/rx

| # | Test name |
|---|---|
| 1 | of 发射单值并完成 |
| 2 | from_iter 发射全部值 |
| 3 | range 发射正确序列 |
| 4 | empty 立即完成 |
| 5 | error 发射错误不发射值 |
| 6 | repeat 重复发射 |
| 7 | 订阅可取消（幂等） |

### vicTop/RX-MBT/test-suit/aggregation

| # | Test name |
|---|---|
| 1 | aggregation: count 统计个数 |
| 2 | aggregation: count_events 每 n 个发一次 |
| 3 | aggregation: reduce 累积出最终结果 |
| 4 | aggregation: collect 收集成数组 |
| 5 | aggregation: to_list 别名 collect |
| 6 | aggregation: sum 累加 |
| 7 | aggregation: sum_direct 从 seed 累加 |
| 8 | aggregation: average 求均值 |
| 9 | aggregation: minimum 求最小值 |
| 10 | aggregation: maximum 求最大值 |
| 11 | aggregation: min 自由函数 |
| 12 | aggregation: max 自由函数 |
| 13 | aggregation: mean 求均值 |
| 14 | aggregation: median 求中位数（偶数取中间平均） |
| 15 | aggregation: variance 求总体方差 |
| 16 | aggregation: std 求标准差 |
| 17 | aggregation: quantile 求分位数 |
| 18 | aggregation: n_unique 去重计数 |
| 19 | aggregation: arg_min 返回最小值的索引 |
| 20 | aggregation: arg_max 返回最大值的索引 |
| 21 | aggregation: cum_prod 累积乘积 |
| 22 | aggregation: cum_mean 累积均值 |
| 23 | aggregation: rolling_sum 滑动窗口求和 |
| 24 | aggregation: rolling_mean 滑动窗口均值 |
| 25 | aggregation: rolling_min 滑动窗口最小值 |
| 26 | aggregation: rolling_max 滑动窗口最大值 |
| 27 | aggregation: rolling_count 滑动窗口计数 |
| 28 | aggregation: sort 收集排序 |
| 29 | aggregation: top_k 取最大 k 个 |
| 30 | aggregation: bottom_k 取最小 k 个 |
| 31 | aggregation: to_map 收集成映射 |
| 32 | aggregation: to_set 收集去重 |
| 33 | aggregation: sum_by 按 key_mapper 累加为 Double |
| 34 | aggregation: average_by 按 key_mapper 求均值 |
| 35 | aggregation: minimum_by 按 key_mapper 求最小值 |
| 36 | aggregation: maximum_by 按 key_mapper 求最大值 |
| 37 | aggregation: reduce_no_seed 首元素作初始值 |

### vicTop/RX-MBT/test-suit/composite

| # | Test name |
|---|---|
| 1 | composite: start_with 前置发射前缀 |
| 2 | composite: concat 串接两个流 |
| 3 | composite: merge 合并两个流 |
| 4 | composite: merge 自由函数版 |
| 5 | composite: zip 按位置配对 |
| 6 | composite: combine_latest 任一源新值时组合 |
| 7 | composite: with_latest_from a 发值时带 b 最新值 |
| 8 | composite: amb 先发射者胜出 |
| 9 | composite: amb 先完成者胜出，另一方后续值被忽略（回归） |
| 10 | composite: end_with 完成前追加后缀 |
| 11 | composite: iif 条件为真选 then 分支 |
| 12 | composite: iif 条件为假选 otherwise 分支 |
| 13 | composite: sequence_equal 相等返回 true |
| 14 | composite: sequence_equal 不等返回 false |
| 15 | composite: zip 方法版配对 |
| 16 | composite: zip 双方都有值时立即配对发射（Subject 热流回归） |
| 17 | composite: zip 一方完成且缓冲耗尽即终止（不等挂起的另一源） |
| 18 | composite: zip 一方完成但缓冲有值则等另一方配对（Rx 标准语义） |
| 19 | composite: zip 任一源错误时立即终止并取消对方订阅（回归） |
| 20 | composite: amb a 胜出后 b 订阅被取消，b 后续值不转发（回归） |
| 21 | composite: concat 进入第二段后 dispose 可取消第二段订阅（回归） |

### vicTop/RX-MBT/test-suit/core

| # | Test name |
|---|---|
| 1 | run 立即消费并原样返回 |
| 2 | debug 透传所有值 |
| 3 | all 全满足发 true |
| 4 | ReplaySubject with_buffer_size 只重放最近 N 个 |
| 5 | PublishSubject 完成后新订阅者立即收到完成信号 |
| 6 | BehaviorSubject 出错后新订阅者立即收到错误且不重放当前值 |
| 7 | CurrentThreadScheduler 同步执行任务 |
| 8 | cum_sum 累积求和逐值发出 |
| 9 | cum_min 累积最小值逐值发出 |
| 10 | cum_max 累积最大值逐值发出 |
| 11 | abs 逐元素取绝对值 |
| 12 | curry_map 返回可组合函数并应用 |
| 13 | ReplaySubject 终止后 on_next 不再缓冲（回归：内存泄漏修复） |
| 14 | delay_on 源完成时挂起延迟值不丢失（回归：complete 也延迟） |
| 15 | timeout_on 源完成后挂起 timer 不误触发错误（回归） |

### vicTop/RX-MBT/test-suit/create

| # | Test name |
|---|---|
| 1 | create: of 发射单值并完成 |
| 2 | create: from_iter 发射全部值并完成 |
| 3 | create: empty 立即完成不发射值 |
| 4 | create: never 不发射不完成 |
| 5 | create: error 只触发错误回调 |
| 6 | create: repeat 重复发射指定次数 |
| 7 | create: from_range 发射半开区间序列 |
| 8 | create: from_range_with_step 按步长发射 |
| 9 | create: from_callable 调用函数并发射结果 |
| 10 | create: start 等价 from_callable |

### vicTop/RX-MBT/test-suit/filter

| # | Test name |
|---|---|
| 1 | filter: 只放行满足谓词的值 |
| 2 | filter: take 取前 n 个后完成 |
| 3 | filter: skip 跳过前 n 个 |
| 4 | filter: first 取第一个值 |
| 5 | filter: last 取最后一个值 |
| 6 | filter: take_while 谓词为假即停 |
| 7 | filter: skip_while 跳过满足谓词的前缀 |
| 8 | filter: skip_last 跳过最后 n 个 |
| 9 | filter: take_last 只取最后 n 个 |
| 10 | filter: element_at 取第 index 个 |
| 11 | filter: distinct 全局去重 |
| 12 | filter: distinct_by 按键去重 |
| 13 | filter: distinct_until_changed 去连续重复 |
| 14 | filter: distinct_until_changed_by 按键去连续重复 |
| 15 | filter: skip_until 触发前不放行 |
| 16 | filter: take_until 触发后即停 |
| 17 | filter: contains 命中返回 true |
| 18 | filter: contains 未命中返回 false |
| 19 | filter: includes 命中返回 true |
| 20 | filter: element_at 命中后不发错误（回归） |
| 21 | filter: element_at 越界发错误 |
| 22 | filter: take 取够后上游被取消，热流后续值不转发（回归） |
| 23 | filter: contains 命中后上游被取消，后续值不转发（回归） |
| 24 | filter: element_at 命中后上游被取消，后续值不转发（回归） |

### vicTop/RX-MBT/test-suit/math_conditions

| # | Test name |
|---|---|
| 1 | math: drop_none 丢弃 None |
| 2 | math: fill_none 用默认值替换 None |
| 3 | math: clamp 夹取到区间内 |
| 4 | math: abs 取绝对值 |
| 5 | conditions: every 全满足发 true |
| 6 | conditions: every 不满足发 false |
| 7 | conditions: some 命中发 true |
| 8 | conditions: some 未命中发 false |
| 9 | conditions: all 全满足发 true |
| 10 | conditions: find 返回首个匹配值 |
| 11 | conditions: find_index 返回匹配索引 |
| 12 | conditions: find_index 未找到发 -1 |
| 13 | conditions: is_empty 空流发 true |
| 14 | conditions: is_empty 非空流发 false |
| 15 | error: backpressure_error 带 max_size 透传（同步模型） |
| 16 | error: backpressure_buffer 带 buffer_size 透传（同步模型） |
| 17 | error: backpressure_drop 透传（同步模型） |
| 18 | error: backpressure_latest 透传（同步模型） |
| 19 | error: catch_error 出错时切换到备用流 |
| 20 | error: on_error_return 出错时发射兜底值 |
| 21 | error: retry 出错重试后成功 |

### vicTop/RX-MBT/test-suit/stress

| # | Test name |
|---|---|
| 1 | stress: 10 万元素 map+filter+reduce 链 |
| 2 | stress: 5 万元素 take_while + skip_while + count |
| 3 | stress: 20 个操作符长链（map 连续嵌套） |
| 4 | stress: 多订阅者（一个流 50 个订阅者） |
| 5 | stress: PublishSubject 高压（10 万次 on_next） |
| 6 | stress: ReplaySubject 缓冲重放（1 万条重放给迟到订阅者） |
| 7 | stress: distinct 处理 5 万重复元素 |
| 8 | stress: to_set + count 大量重复 |
| 9 | stress: 嵌套 flat_map 展开 1 万条 |
| 10 | stress: 递归重试 + catch_error 错误路径不泄漏 |

### vicTop/RX-MBT/test-suit/transform

| # | Test name |
|---|---|
| 1 | transform: map 对每个值应用映射 |
| 2 | transform: filter_map 保留 Some 丢弃 None |
| 3 | transform: flat_map 平铺内部流 |
| 4 | transform: scan 累积并发出中间结果 |
| 5 | transform: scan 多次订阅各自独立（冷流语义） |
| 6 | transform: concat_map 串行平铺 |
| 7 | transform: switch_map 切换到最新内部流 |
| 8 | transform: flat_map_latest 别名 switch_map |
| 9 | transform: group_by 按键分组 |
| 10 | transform: curry_map 柯里化映射 |

---
Generated by scripts/gen_test_report.ps1

