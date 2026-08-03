// 依赖验证工程：模拟第三方项目通过依赖声明引入 rx-mbt（GitHub 远程源，非本地路径）
// 对应命令：moon add vicTop-cw/RX-MBT（发布 mooncakes 后可用）
// 当前 rx-mbt 未发布 mooncakes，用 git 源 + commit 方式验证等价效果。

name = "vicTop-cw/rx-mbt-consumer"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/vicTop-cw/Rx-mbt"

license = "Apache-2.0"

keywords = ["reactive", "rx", "observable", "test"]

preferred_target = "wasm"

description = "rx-mbt 外部依赖引入验证工程：通过依赖声明（git 源）使用 vicTop-cw/RX-MBT"

deps = {
  "vicTop-cw/RX-MBT": {
    git = "https://github.com/vicTop-cw/Rx-mbt.git",
    commit = "cfcb36cfc20b5dcf8259a32eeaf397a36e8da494",
  },
}
