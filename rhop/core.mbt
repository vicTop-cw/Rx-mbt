// ============================================================================
// rhop · 协议基础模型（对齐 vools-rhop `core.py`）
//
// 双方对等镜像任务中继协议：只有需求端 / 执行端两方，无控制端。
// 纯逻辑文件，无 #cfg 分支，wasm / js / native 三目标天然可用。
// ============================================================================

///|
/// 参与方（vools `Side`）。
///
/// 只有两方、无控制端：需求端提交任务等结果，执行端领任务、执行、回结果。
/// `to_string` 输出与 vools 一致的**小写字面量**（`"requester"` / `"executor"`），
/// 该字面量同时是信封 `side` 字段的落盘/传输表示。
#derive(Eq, Debug)
pub(all) enum Side {
  /// 需求端：提交任务，等结果
  Requester
  /// 执行端：领任务，执行，回结果
  Executor
}

///|
pub extend Side with Eq::{not_equal, equal}
///|
pub extend Side with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 对端：`Requester` ↔ `Executor`（vools `Side.other`）。
pub fn Side::other(self : Side) -> Side {
  match self {
    Requester => Executor
    Executor => Requester
  }
}

///|
/// 序列化为 vools 字面量：`"requester"` / `"executor"`。
pub fn Side::to_string(self : Side) -> String {
  match self {
    Requester => "requester"
    Executor => "executor"
  }
}

///|
/// 从字面量解析，「未知值」返回 `Err`（中文原因），不做静默回落。
pub fn Side::parse(text : String) -> Result[Side, String] {
  match text {
    "requester" => Ok(Requester)
    "executor" => Ok(Executor)
    _ =>
      Err(
        "Side: 无法识别的字面量 \{text}（期望 requester/executor）",
      )
  }
}

///|
/// 任务状态机（vools `TaskStatus`）。
///
/// 合法流转（逐条照抄 core.py 的 `_TRANSITIONS`）：
///
/// ```text
/// PENDING ──► CLAIMED ──► RUNNING ──► DONE
///    │            │            │
///    │            │            └──► FAILED
///    │            │
///    └────────────┴──► CANCELLED
/// ```
///
/// 除下列边的其余组合一律非法：`PENDING→{CLAIMED,CANCELLED}`、
/// `CLAIMED→{RUNNING,CANCELLED}`、`RUNNING→{DONE,FAILED}`。
#derive(Eq, Debug)
pub(all) enum TaskStatus {
  /// 需求端已提交，任务端未领
  Pending
  /// 任务端已领，准备执行
  Claimed
  /// 任务端正在执行
  Running
  /// 任务端执行完成，结果已写回
  Done
  /// 任务端执行失败
  Failed
  /// 需求端取消
  Cancelled
}

///|
pub extend TaskStatus with Eq::{not_equal, equal}
///|
pub extend TaskStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// 序列化为 vools 字面量：`"pending"` / `"claimed"` / `"running"` /
/// `"done"` / `"failed"` / `"cancelled"`。
pub fn TaskStatus::to_string(self : TaskStatus) -> String {
  match self {
    Pending => "pending"
    Claimed => "claimed"
    Running => "running"
    Done => "done"
    Failed => "failed"
    Cancelled => "cancelled"
  }
}

///|
/// 从字面量解析，未知值返回 `Err`（中文原因）。
///
/// 信封反序列化依赖本函数：非法 `status` 必须变成可诊断错误，而不是被
/// 静默归到某个默认状态。
pub fn TaskStatus::parse(text : String) -> Result[TaskStatus, String] {
  match text {
    "pending" => Ok(Pending)
    "claimed" => Ok(Claimed)
    "running" => Ok(Running)
    "done" => Ok(Done)
    "failed" => Ok(Failed)
    "cancelled" => Ok(Cancelled)
    _ => {
      let msg = "TaskStatus: 无法识别的字面量 \{text}（期望 pending/claimed/running/done/failed/cancelled）"
      Err(msg)
    }
  }
}

///|
/// 当前状态能否流转到 `next`（vools `TaskStatus.can_transition`）。
///
/// 查表语义与 core.py 的 `_TRANSITIONS` 完全一致；返回 `false` 即非法流转。
pub fn TaskStatus::can_transition(self : TaskStatus, next : TaskStatus) -> Bool {
  match (self, next) {
    (Pending, Claimed) | (Pending, Cancelled) => true
    (Claimed, Running) | (Claimed, Cancelled) => true
    (Running, Done) | (Running, Failed) => true
    _ => false
  }
}

///|
/// 是否终态（vools `TaskStatus.is_terminal`）。
///
/// 终态 = 流转表里出边为空集的状态：`Done` / `Failed` / `Cancelled`。
pub fn TaskStatus::is_terminal(self : TaskStatus) -> Bool {
  match self {
    Done | Failed | Cancelled => true
    Pending | Claimed | Running => false
  }
}

///|
/// 全部状态，按 vools 声明顺序（pending, claimed, running, done, failed,
/// cancelled）。用于遍历状态机矩阵的测试与镜像库按状态计数。
pub fn TaskStatus::all() -> Array[TaskStatus] {
  [Pending, Claimed, Running, Done, Failed, Cancelled]
}
