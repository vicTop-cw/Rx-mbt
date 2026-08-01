// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "vicTop/RX-MBT"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/vicTop-cw/Rx-mbt"

license = "Apache-2.0"

keywords = ["reactive", "rx", "observable", "observer", "stream"]

preferred_target = "wasm"

description = "Rx-Rust 的 MoonBit 复刻：基于 Observer 模式的响应式编程库（Observable / Subject / Scheduler / 操作符），零外部依赖。"
