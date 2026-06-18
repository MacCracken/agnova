# Changelog

All notable changes to agnova are documented here.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-06-18

### Changed
- **Cyrius toolchain bumped 5.7.12 → 6.2.21.** Build, lint, and `agnova version` now target the 6.2.21 cycc. `cyrius.cyml` pin and the version banner updated accordingly.

## [0.1.0]

### Added
- **Cyrius port from Rust scaffold** (3656 LOC of Rust → 2781 LOC of Cyrius). The entire library + a real CLI now run on the Cyrius 5.7.12 toolchain with no Rust dependency.
- **CLI**: `agnova plan|validate|execute|version|help` subcommands. `plan` prints the full install plan with optional per-operation detail (`--verbose`); `validate` runs the 28 config checks in isolation; `execute` is gated behind `--i-mean-it` to satisfy the "no silent destructive operations" rule from CLAUDE.md.
- **`SystemOp` executor** (`src/executor.cyr`) — first real side-effect implementation. Dispatches Command via fork+exec (with optional stdin pipe for LUKS passphrases), WriteFile via `sys_open`/`sys_write`/`sys_chmod`, MakeDir via shell-out to `mkdir -p`, Symlink via shell-out to `ln -sfT` (no `sys_symlink` wrapper in stdlib), Mount via `sys_mount`, Unmount via `sys_umount2`.
- **Orchestrator** (`src/orchestrator.cyr`) — `AgnovaInstaller` state machine with phase advancement, log accumulation, and recoverable vs non-recoverable failure handling. PHASE_PARTITION_DISK, PHASE_SETUP_ENCRYPTION, PHASE_FORMAT_FILESYSTEMS, PHASE_INSTALL_BASE, PHASE_INSTALL_BOOTLOADER are non-recoverable (mirrors Rust scaffold).
- **Validation** (`src/validation.cyr`) — 28 hard checks + 3 warning categories. Includes shell-injection guards on `target_device`, `username`, `hostname`, partition labels, and kernel command-line parameters.
- **Plan generation** for all 13 phases with byte-for-byte fidelity to the Rust scaffold's output (verified by hand-comparing fstab, kernel cmdline, parted args, mkfs args, bootloader entries).
- **RFC 4122-compliant UUID v4** machine-id generation via `/dev/urandom` + manual version/variant bit stamping.

### Changed
- **`luks_passphrase` lifted out of `DiskLayout`** onto the `AgnovaInstaller` orchestrator. The Rust version used `#[serde(skip)]` to keep it out of serialized state; Cyrius `#derive(Serialize)` has no skip attribute, so structural separation preserves the security intent.
- **`Option<u64>` (e.g. `PartitionSpec::size_mb`) split into two fields** (`size_mb` + `has_size`). Cyrius' `tagged_new` Option doesn't compose with `#derive(accessors)`/`#derive(Serialize)`.
- **`Option<String>` represented as empty `Str`** sentinel. Same reason as above; trivial to check (`str_len(s) == 0`) and serializes cleanly.
- **`f32` progress fields → `i64` basis points (0..10000)**. No `f32` in Cyrius and `#derive(Serialize)` doesn't emit `f64`.
- **`chrono::DateTime<Utc>` → `i64` unix seconds** via `lib/chrono.cyr::clock_epoch_secs()`.

### Removed
- The Rust source has been moved to `rust-old/` (preserving git history for reference). No Rust code is built or shipped.

### Notes
- The Rust scaffold's `tests/` directory contained 1398 lines of unit tests; porting them to `tests/agnova.tcyr` is tracked but not yet started.
- The executor is implemented but **has not been end-to-end tested against real hardware**. The code path is exercised by the CLI's `execute` subcommand only when `--i-mean-it` is passed; do not run on a system you care about until v0.2.0 or later when integration testing on disposable hardware is complete.
