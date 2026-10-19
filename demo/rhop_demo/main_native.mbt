///|
/// rhop_demo native 占位：端到端演示依赖 node fs.watch 与 node crypto，
/// 仅 js 目标可用。native 目标构建时不参与（见 moon.pkg options）。

fn main {
  println("rhop_demo: 本演示仅支持 js 目标（node 端到端），请使用 --target js 构建后以 node 运行")
}
