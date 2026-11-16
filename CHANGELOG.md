# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.3] - 2026-11-15

### Fixed
- Fixed FFI annotation duplicate warnings in `monitor/fs_native.mbt` and `rhop/rhop_fs_native.mbt`
- Removed unused packages (`async`, `hashmap`, `ref`) from `monitor/moon.pkg`, `cmd/watch_server/moon.pkg`, `demo/rhop_demo/moon.pkg`
- Fixed JS compilation errors by restoring required packages

### Changed
- Updated test counts: native 645, js 888
- Updated README.md and DOC.md with latest test results

### Security
- No security changes in this release

## [0.4.2] - 2026-11-15

### Fixed
- Fixed FFI annotation duplicate warnings in `monitor/fs_native.mbt` and `rhop/rhop_fs_native.mbt`
- Removed unused packages (`async`, `hashmap`, `ref`) from `monitor/moon.pkg`, `cmd/watch_server/moon.pkg`, `demo/rhop_demo/moon.pkg`
- Fixed JS compilation errors by restoring required packages
- **Fixed wasm target build break**: `rhop/rhop_fs_native.mbt` was gated to `native` only while
  `rhop/transport_local.mbt` had lost its wasm fallback, leaving `fs_read_text` / `fs_remove` /
  `fs_exists` unbound (7 errors). The file is now built for `native` and `wasm` (it already
  carries `#cfg(not(target="native"))` stubs)
- **Fixed wasm target build break**: `extern "C"` is unsupported by the wasm backend, but the R3
  command-execution FFI was gated with `#cfg(not(target="js"))` which included wasm. Narrowed to
  `#cfg(target="native")` and added a diagnosable `Err` stub for `#cfg(target="wasm")`
- **Fixed cross-package visibility of trigger/monitor types** (blocking for downstream consumers):
  `pub` is package-private in MoonBit, so `TriggerEvent`, `Trigger`, `TriggerRegistry`, `EventBus`,
  `WatchEvent`, `FsError` and `FileStat` were not reachable from other modules. Promoted to
  `pub(all)`

### Changed
- Updated test counts: native 673, js 912, wasm 662, `moon check` 0 errors
- Updated README.md and DOC.md with latest test results

### Added
- Repository hygiene: ignore rules for root-level build/test logs, the `rhop_native_test/`
  runtime directory, the `.arts/` tool config and stray Python-side content
- `ISSUES-mcp-watcher-gap-audit.md` marked as superseded (its ISS-1/2/3 findings were resolved
  by the R2/R3 landing)

### Security
- No security changes in this release

### Known constraints for downstream consumers
- Generic types must be referenced across packages with a full type annotation, e.g.
  `let bus : @rx.EventBus[Int] = @rx.EventBus::new()`. Writing `@rx.EventBus[Int]::new()`
  directly fails with "Value EventBus not found in package `rx`"
- `monitor.watch_folder` has a **blocking subscription closure**; subscribers must run in a
  background async task
- `real_now()` returns the placeholder virtual clock until `install_real_clock()` is called

## [0.4.1] - 2026-11-15

### Fixed
- Fixed R3 command execution native implementation (ISS-1)
- Fixed test gate failures (ISS-2)
- Fixed zero-wait loop issue (ISS-3)
- Fixed ledger drift issue (ISS-4)

### Added
- C FFI implementation for `moonbit_cmd_run` in `rhop/rhop_fs_native_stubs.c`
- Support for Windows (CreateProcess) and POSIX (fork/exec) platforms
- Shared `FsError` type in `rhop/rhop_fs_types.mbt`

### Changed
- R3 command execution now uses C FFI with `FixedArray[Bytes]` parameter passing
- Protocol v2 for command execution results (exit_code + stdout + stderr)

## [0.4.0] - 2026-10-28

### Added
- Initial release of RX-MBT
- Observable/Observer/Subscription core types
- Subject (Publish/Behavior/Replay)
- Scheduler (CurrentThread/Immediate/Async/ThreadPool)
- Trigger mechanism with wildcard matching
- Itor/Node controllable iterators
- 60+ operators (map, filter, aggregate, combine, etc.)
- rhop protocol implementation (vools-rhop 0.9.0 parity)

### Changed
- Based on Rx-Rust patterns
- Pure MoonBit implementation, zero external dependencies

## [0.3.0] - 2026-09-15

### Added
- Initial prototype

---

For older versions, see the [CHANGELOG archive](CHANGELOG_ARCHIVE.md).

[0.4.2]: https://github.com/vicTop-cw/Rx-mbt/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/vicTop-cw/Rx-mbt/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/vicTop-cw/Rx-mbt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/vicTop-cw/Rx-mbt/releases/tag/v0.3.0