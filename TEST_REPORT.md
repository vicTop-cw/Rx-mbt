# RX-MBT Test Report

## Environment

| Item | Value |
|---|---|
| Generated at | 2026-10-15 10:49:46 |
| moon version | moon 0.1.20260920 (914d7da 2026-09-20) |
| Test target | wasm |
| Total tests | 400 |
| Passed | 400 |
| Failed | 0 |

**Result: PASS (all green)**

## Per-package stats

| Package | Tests |
|---|---|
| vicTop-cw/RX-MBT/rx | 28 |
| vicTop-cw/RX-MBT/test-suit/aggregation | 37 |
| vicTop-cw/RX-MBT/test-suit/composite | 22 |
| vicTop-cw/RX-MBT/test-suit/core | 19 |
| vicTop-cw/RX-MBT/test-suit/create | 10 |
| vicTop-cw/RX-MBT/test-suit/filter | 26 |
| vicTop-cw/RX-MBT/test-suit/haskell | 81 |
| vicTop-cw/RX-MBT/test-suit/itor | 136 |
| vicTop-cw/RX-MBT/test-suit/math_conditions | 21 |
| vicTop-cw/RX-MBT/test-suit/stress | 10 |
| vicTop-cw/RX-MBT/test-suit/transform | 10 |
| **Total** | **400** |

## Test listing

### vicTop-cw/RX-MBT/rx

| # | Test name |
|---|---|
| 1 | 精确匹配：仅命中同名事件 |
| 2 | 单段通配：task.* 命中 task.done / task.fail，不命中多段 task.a.b |
| 3 | 多段通配：task.** 命中任意 task. 前缀的多段事件 |
| 4 | priority：高优先先执行，同优先按注册序 |
| 5 | once：触发一次后自动注销，再次 fire 不再执行 |
| 6 | condition：条件不满足则不执行 |
| 7 | fire_with_key：同 key 只触发一次，不同 key 各自触发 |
| 8 | unregister：注销后不再触发，重复注销返回 false |
| 9 | clear：清空触发器与幂等键，后续 fire 无效果 |
| 10 | trigger_count / has_trigger：注册与注销后数量与匹配状态正确 |
| 11 | fire_at：事件携带指定时刻与自增序号 |
| 12 | 中间多段通配：a.**.b 匹配 a.x.b，不匹配 a.x（无 b 结尾） |
| 13 | 多段通配匹配零段：a.**.b 匹配 a.b，也匹配 a.c.d.b |
| 14 | 纯多段通配 **：匹配任意事件名（含单段与多段） |
| 15 | 单段通配不跨越段边界：a.* 不匹配 a.b.c，也不匹配 a |
| 16 | 纯单段通配 *：匹配单段事件，不匹配多段事件 |
| 17 | 空事件名：纯 ** 命中，精确名不命中 |
| 18 | 通配混合回溯：*.*.b 命中三段 a.c.b，不命中两段 a.b / 四段 a.c.d.b |
| 19 | reset_dedup_keys：清幂等键后同 key 可再次触发，触发器保留 |
| 20 | of 发射单值并完成 |
| 21 | from_iter 发射全部值 |
| 22 | range 发射正确序列 |
| 23 | empty 立即完成 |
| 24 | error 发射错误不发射值 |
| 25 | repeat 重复发射 |
| 26 | 订阅可取消（幂等） |
| 27 | fired_count：fire 后内部计数器递增 |
| 28 | fired_count：condition 不满足不递增，once 注销后计数保留 |

### vicTop-cw/RX-MBT/test-suit/aggregation

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

### vicTop-cw/RX-MBT/test-suit/composite

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
| 22 | composite: with_latest_from a 完成后 b 订阅被取消（回归） |

### vicTop-cw/RX-MBT/test-suit/core

| # | Test name |
|---|---|
| 1 | run 立即消费并原样返回 |
| 2 | debug 透传所有值 |
| 3 | all 全满足发 true |
| 4 | ReplaySubject with_buffer_size 只重放最近 N 个 |
| 5 | PublishSubject 完成后新订阅者立即收到完成信号 |
| 6 | BehaviorSubject 出错后新订阅者立即收到错误且不重放当前值 |
| 7 | ReplaySubject 完成后新订阅者不重放历史、仅收到完成信号（回归） |
| 8 | ReplaySubject 出错后新订阅者不重放历史、仅收到错误（回归） |
| 9 | CurrentThreadScheduler 同步执行任务 |
| 10 | cum_sum 累积求和逐值发出 |
| 11 | cum_min 累积最小值逐值发出 |
| 12 | cum_max 累积最大值逐值发出 |
| 13 | abs 逐元素取绝对值 |
| 14 | curry_map 返回可组合函数并应用 |
| 15 | ReplaySubject 终止后 on_next 不再缓冲（回归：内存泄漏修复） |
| 16 | delay_on 源完成时挂起延迟值不丢失（回归：complete 也延迟） |
| 17 | timeout_on 源完成后挂起 timer 不误触发错误（回归） |
| 18 | timer_on 延迟触发一次并完成 |
| 19 | interval_on 按周期发射递增计数 |

### vicTop-cw/RX-MBT/test-suit/create

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

### vicTop-cw/RX-MBT/test-suit/filter

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
| 25 | filter: skip_until 触发后 trigger 订阅被取消（回归） |
| 26 | filter: take_until 触发后源流被取消（回归） |

### vicTop-cw/RX-MBT/test-suit/haskell

| # | Test name |
|---|---|
| 1 | haskell: iterate 无限迭代配合 take 截断 |
| 2 | haskell: repeat_infinite 无限重复配合 take 截断 |
| 3 | haskell: cycle 无限循环数组配合 take 截断 |
| 4 | haskell: unfoldr 展开（递减到 0 结束） |
| 5 | haskell: unfoldr 立即结束（空流） |
| 6 | haskell: reverse 收集后反转 |
| 7 | haskell: intersperse 元素间插入分隔符 |
| 8 | haskell: intersperse 单元素流不插分隔符 |
| 9 | haskell: intercalate 数组流用分隔数组连接 |
| 10 | haskell: zip_with 双流合并映射 |
| 11 | haskell: zip_with 一方完成后提前终止 |
| 12 | haskell: zip3 三流拉链 |
| 13 | haskell: unzip 拆分为两列 |
| 14 | haskell: transpose 矩阵转置 |
| 15 | haskell: span 满足谓词的最长前缀与剩余 |
| 16 | haskell: break_pred 前缀不满足谓词 |
| 17 | haskell: split_at 前 n 个与剩余 |
| 18 | haskell: partition 满足与不满足两路 |
| 19 | haskell: not_elem 不含目标发 true |
| 20 | haskell: not_elem 含目标发 false |
| 21 | haskell: delete_first 删除第一个匹配 |
| 22 | haskell: group_adjacent 相邻相等分组 |
| 23 | haskell: group_adjacent_by 相邻满足谓词分组 |
| 24 | haskell: is_prefix_of 是前缀 |
| 25 | haskell: is_prefix_of 非前缀 |
| 26 | haskell: is_suffix_of 是后缀 |
| 27 | haskell: is_infix_of 包含子序列 |
| 28 | haskell: is_infix_of 不含子序列 |
| 29 | haskell: foldr 右折叠（减法验证方向） |
| 30 | haskell: scanr 右扫描结果列表 |
| 31 | haskell: product 累乘 |
| 32 | haskell: product 空流不发值 |
| 33 | haskell: fold_map 映射后累积 |
| 34 | haskell: sort_by 按比较函数排序（自定义规则） |
| 35 | haskell: sort_on 按键投影排序 |
| 36 | haskell: maximum_by_cmp 按比较函数求最大 |
| 37 | haskell: minimum_by_cmp 按比较函数求最小 |
| 38 | haskell: find_indices 收集所有满足索引 |
| 39 | haskell: elem_index 等值查找索引 |
| 40 | haskell: elem_index 找不到发 -1 |
| 41 | haskell: elem_indices 收集所有等值索引 |
| 42 | haskell: lookup 按键查找发值 |
| 43 | haskell: lookup 找不到发 None |
| 44 | haskell: Itor::fold 消费迭代器累加 |
| 45 | haskell: Itor::fold 空迭代器返回 seed |
| 46 | haskell: tail 丢弃首元素 |
| 47 | haskell: tail 空流不发值 |
| 48 | haskell: init 丢弃末元素 |
| 49 | haskell: scanl1 无种子左扫描 |
| 50 | haskell: scanl1 减法验证累积方向 |
| 51 | haskell: scanr1 无种子右扫描 |
| 52 | haskell: foldr1 无种子右折叠 |
| 53 | haskell: foldr1 单元素直接发该元素 |
| 54 | haskell: map_accum_l 带状态左映射 |
| 55 | haskell: map_accum_r 带状态右映射 |
| 56 | haskell: all_true 全真发 true |
| 57 | haskell: all_true 遇 false 早停发 false |
| 58 | haskell: any_true 任一真发 true |
| 59 | haskell: any_true 全假发 false |
| 60 | haskell: take_while_end 尾部连续满足的最长后缀 |
| 61 | haskell: drop_while_end 去掉尾部满足段 |
| 62 | haskell: inits 全部前缀 |
| 63 | haskell: tails 全部后缀 |
| 64 | haskell: strip_prefix 匹配发剩余 |
| 65 | haskell: strip_prefix 不匹配发 None |
| 66 | haskell: strip_suffix 匹配发剩余 |
| 67 | haskell: delete_first_by 按谓词删除第一个 |
| 68 | haskell: is_subsequence_of 是子序列 |
| 69 | haskell: is_subsequence_of 非子序列 |
| 70 | haskell: nub_by 两两比较去重 |
| 71 | haskell: unzip3 拆分三元组 |
| 72 | haskell: union 并集 |
| 73 | haskell: intersect 交集 |
| 74 | haskell: difference 差集 |
| 75 | haskell: insert 有序插入 |
| 76 | haskell: insert 插入开头与末尾 |
| 77 | haskell: insert_by 自定义比较插入 |
| 78 | haskell: lines 按换行切分 |
| 79 | haskell: words 按空白切分 |
| 80 | haskell: unlines 行连接 |
| 81 | haskell: unwords 词连接 |

### vicTop-cw/RX-MBT/test-suit/itor

| # | Test name |
|---|---|
| 1 | Node: 值读写与 next 链 |
| 2 | Node: from_iter 基本链 |
| 3 | Node: from_iter 空迭代器返回 None |
| 4 | Node: to_iter 按序产出 |
| 5 | Node: to_iter 单节点 |
| 6 | Node: 无限惰性链表可安全取前 N 个 |
| 7 | Node: to_itor 转 Itor 并迭代 |
| 8 | Node: to_itor 无限流可 stop 终止 |
| 9 | Itor: 全量迭代 |
| 10 | Itor: from_array 全量迭代 |
| 11 | Itor: 耗尽后状态为 Stopped |
| 12 | Itor: 直接 next 逐个取值 |
| 13 | Itor: call 返回独立副本，互不影响 |
| 14 | Itor: 暂停期间不推进，恢复后继续 |
| 15 | Itor: 紧急插队单节点 |
| 16 | Itor: 紧急插队整条链表 |
| 17 | Itor: send_value 插队单个值 |
| 18 | Itor: send_values 插队多个值 |
| 19 | Itor: 条件插队（历史长度达 3 时插入单节点） |
| 20 | Itor: 条件插队整条链表 |
| 21 | Itor: 条件永不满足则不插队 |
| 22 | Itor: 停止后插队无效（静默忽略） |
| 23 | Itor: 链式调用返回自身 |
| 24 | Itor: restart 重放历史并继续源 |
| 25 | Itor: 耗尽后 restart 仍可重放全部历史 |
| 26 | Itor: set_history_max 保留最近 N 条（N=3） |
| 27 | Itor: set_history_max(-1) 完全保留 |
| 28 | Itor: set_history_max(0) 不保留历史 |
| 29 | Itor: 自定义历史策略（完全丢弃历史） |
| 30 | Itor: stop 提前终止（不产出剩余值） |
| 31 | Itor: do_iter 副作用遍历 |
| 32 | Itor: do_iter 带 pre_f 与 sub_f |
| 33 | Itor: 插队链保留后续源（懒加载链） |
| 34 | Itor: 多副本独立迭代 from_array |
| 35 | Itor: restart 后新插队立即生效 |
| 36 | haskell-itor: iterate 无限迭代配合 take 截断 |
| 37 | haskell-itor: repeat 无限重复配合 take 截断 |
| 38 | haskell-itor: cycle 无限循环数组配合 take 截断 |
| 39 | haskell-itor: cycle 空数组立即结束 |
| 40 | haskell-itor: unfoldr 展开递减到 0 结束 |
| 41 | haskell-itor: unfoldr 立即结束 |
| 42 | haskell-itor: replicate 重复 n 次 |
| 43 | haskell-itor: replicate 0 次为空 |
| 44 | haskell-itor: map 逐元素变换 |
| 45 | haskell-itor: filter 保留偶数 |
| 46 | haskell-itor: filter 全不满足为空 |
| 47 | haskell-itor: take 前 n 个 |
| 48 | haskell-itor: take 超过长度取全部 |
| 49 | haskell-itor: take n<=0 为空 |
| 50 | haskell-itor: drop 跳过前 n 个 |
| 51 | haskell-itor: drop 超过长度为空 |
| 52 | haskell-itor: drop n<=0 原样透传 |
| 53 | haskell-itor: take_while 取满足前缀 |
| 54 | haskell-itor: drop_while 跳过满足前缀 |
| 55 | haskell-itor: scan 含初始 seed 的累积 |
| 56 | haskell-itor: scan 空迭代器只发 seed |
| 57 | haskell-itor: reverse 反转 |
| 58 | haskell-itor: reverse 空迭代器为空 |
| 59 | haskell-itor: intersperse 元素间插入分隔 |
| 60 | haskell-itor: intersperse 单元素不插 |
| 61 | haskell-itor: concat_map 展平 |
| 62 | haskell-itor: zip_with 双迭代器合并 |
| 63 | haskell-itor: zip_with 一方耗尽提前结束 |
| 64 | haskell-itor: zip 配对元组 |
| 65 | haskell-itor: tail 去掉首元素 |
| 66 | haskell-itor: tail 单元素为空 |
| 67 | haskell-itor: init 去掉尾元素 |
| 68 | haskell-itor: nub 去重保序 |
| 69 | haskell-itor: sort_by 按比较函数排序 |
| 70 | haskell-itor: sort_on 按键投影排序 |
| 71 | haskell-itor: foldr 右折叠（减法验证方向） |
| 72 | haskell-itor: length 计数 |
| 73 | haskell-itor: null 空与非空 |
| 74 | haskell-itor: sum 累加 |
| 75 | haskell-itor: sum 空迭代器为默认值 |
| 76 | haskell-itor: product 累乘 |
| 77 | haskell-itor: product 空迭代器为 None |
| 78 | haskell-itor: any / all 判定 |
| 79 | haskell-itor: elem / not_elem 包含判定 |
| 80 | haskell-itor: find 找到与找不到 |
| 81 | haskell-itor: find_index 下标 |
| 82 | haskell-itor: maximum / minimum 极值 |
| 83 | haskell-itor: head / last 首尾 |
| 84 | haskell-itor: to_array 收集 |
| 85 | haskell-itor: lookup 关联查找 |
| 86 | haskell-itor: lookup 找不到返回 None |
| 87 | haskell-itor: elem_index / elem_indices |
| 88 | haskell-itor: find_indices 满足谓词下标 |
| 89 | haskell-itor: map_accum_l 左累积映射 |
| 90 | haskell-itor: map_accum_r 右累积映射 |
| 91 | haskell-itor: partition 满足与不满足两路 |
| 92 | haskell-itor: span 前缀与剩余 |
| 93 | haskell-itor: break_pred 前缀不满足谓词 |
| 94 | haskell-itor: split_at 前 n 与剩余 |
| 95 | haskell-itor: group_adjacent 相邻相等分组 |
| 96 | haskell-itor: is_prefix_of / is_suffix_of / is_infix_of |
| 97 | haskell-itor: inits 全部前缀 |
| 98 | haskell-itor: tails 全部后缀 |
| 99 | haskell-itor: concat 展平 Itor[Itor] |
| 100 | haskell-itor: intercalate 数组流插入分隔 |
| 101 | haskell-itor: 变换链组合 map -> filter -> take |
| 102 | haskell-itor: 变换后仍可 stop 终止 |
| 103 | haskell-itor: 变换后仍可 restart 重放 |
| 104 | haskell-itor2: foldl1 无种子左折叠 |
| 105 | haskell-itor2: foldl1 空迭代器返回 None |
| 106 | haskell-itor2: foldr1 无种子右折叠 |
| 107 | haskell-itor2: foldr1 空迭代器返回 None |
| 108 | haskell-itor2: all_true / any_true 短路判定 |
| 109 | haskell-itor2: maximum_by / minimum_by 自定义比较 |
| 110 | haskell-itor2: maximum_by / minimum_by 空迭代器返回 None |
| 111 | haskell-itor2: sort 默认自然序 |
| 112 | haskell-itor2: scanl1 无种子左扫描 |
| 113 | haskell-itor2: scanr 右扫描 |
| 114 | haskell-itor2: scanr1 无种子右扫描 |
| 115 | haskell-itor2: strip_prefix / strip_suffix 剥离前后缀 |
| 116 | haskell-itor2: is_subsequence_of 子序列判定 |
| 117 | haskell-itor2: at 按下标取元素 |
| 118 | haskell-itor2: nub_by 自定义谓词去重 |
| 119 | haskell-itor2: delete_first 删除首个匹配 |
| 120 | haskell-itor2: delete_first_by 自定义谓词删除 |
| 121 | haskell-itor2: difference 列表差集 |
| 122 | haskell-itor2: union 并集 |
| 123 | haskell-itor2: intersect 交集 |
| 124 | haskell-itor2: insert 有序插入 |
| 125 | haskell-itor2: insert_by 自定义比较插入 |
| 126 | haskell-itor2: group_adjacent_by 自定义谓词分组 |
| 127 | haskell-itor2: transpose 转置 |
| 128 | haskell-itor2: subsequences 子序列枚举 |
| 129 | haskell-itor2: permutations 排列枚举 |
| 130 | haskell-itor2: chunks_of 按大小分块 |
| 131 | haskell-itor2: fold_map 映射折叠 |
| 132 | haskell-itor2: zip3 三路配对 |
| 133 | haskell-itor2: zip_with3 三路合并 |
| 134 | haskell-itor2: unzip 拆分二元组 |
| 135 | haskell-itor2: unzip3 拆分三元组 |
| 136 | haskell-itor2: 新增变换操作链式组合 |

### vicTop-cw/RX-MBT/test-suit/math_conditions

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

### vicTop-cw/RX-MBT/test-suit/stress

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

### vicTop-cw/RX-MBT/test-suit/transform

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

