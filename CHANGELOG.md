# Changelog

All notable changes to agnova are documented here.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-06-18

### Added
- **`execute --until <phase>`** stops the install after a named phase (`partition|encryption|format|mount|base|packages|configure|bootloader|user|security|firstboot|cleanup`). Enables a clean disk-only run (`--until mount`) for loopback/VM testing without needing the AGNOS base-system artifacts. (`src/cli.cyr`, `execute_all` in `src/executor.cyr`)
- **Mount options are now honored at execution time.** New pure helper `mount_flags_from_options(options)` (`src/helpers.cyr`) parses a `vec<Str>` of mount options — one-per-element or comma-separated, mount(8) style — into combined `MS_*` flag bits (`ro`/`nosuid`/`nodev`/`noexec`/`remount`/`bind`/`move`; no-flag tokens like `rw`/`defaults` contribute 0). `_exec_mount` now passes these flags to `sys_mount` instead of a hard-coded `0`. 7 unit tests added. (Data-string options such as `subvol=` are still not threaded — agnova emits only flag/`defaults` options at mount time.)
- **Plan-generation benchmark harness** (`tests/agnova.bcyr`). Replaces the no-op stub with real `bench_new`/`bench_run` timings over the pure planning layer. Baseline on the default Desktop config (x86_64): `full_execution_plan` ≈ 67 µs/call, `total_ops_count` ≈ 66 µs, `validate_config` ≈ 1.7 µs, `default_packages` ≈ 4.5 µs. Run with `cyrius bench tests/agnova.bcyr`.

### Fixed
- **Failures were attributed to the wrong install phase.** `execute_all` advanced the orchestrator's phase *after* running each phase's ops, so `current_phase` lagged by one — `agnova_fail_phase` then logged the error against the previous phase *and* read its recoverability (e.g. a base-system failure showed `ERROR [Mounting filesystems]` and was treated as recoverable when `INSTALL_BASE` is non-recoverable). The executor now mirrors each `PhaseOps`'s own phase via new `agnova_set_phase` before running its ops, and lands on `PHASE_COMPLETE` after a full run. Found via the loopback e2e run. (`src/executor.cyr`, `src/orchestrator.cyr`)
- **Executor could not run any command (`rc=127`).** `_exec_with_stdin` passed the bare binary name (e.g. `parted`) to `execve`, which does not search `PATH`, and handed the child an empty environment — so every `Command` op failed with exit 127. Found by actually running `agnova execute` against a loopback device. Added `_resolve_binary`, which resolves a bare name to an absolute path across `/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`, and the child now gets a `PATH` env. (`src/executor.cyr`)
- **Loop-device partition naming.** `partition_device` only added the `p` separator for `nvme`/`mmcblk`, so a loop target yielded `/dev/loop01` instead of `/dev/loop0p1`, breaking format/mount on loopback. `loop` is now handled too (correct for loopback targets and the planned loopback install mode; no effect on physical-disk targets). (`src/partitioning.cyr`)

### Changed
- **Whole tree reformatted to `cyrfmt` canonical style, and a format gate added to CI.** All `src/*.cyr` and `tests/*` files now pass `cyrfmt --check`; the CI `build` job runs it on every push/PR. (No semantic change — build + 306 tests unaffected.)
- **CI now enforces a CHANGELOG entry per PR** (`.github/workflows/ci.yml`). A new `changelog` job fails any pull request whose diff doesn't touch `CHANGELOG.md`.
- **`cyrius.cyml` stdlib deps gain `bench` + `fnptr`**, and `lib/bench.cyr` is vendored into `./lib/` (consistent with the project's vendored stdlib) so `cyrius bench` resolves against the 6.2.21 snapshot. The main binary build is unaffected (bench symbols are dead-code-eliminated).

## [0.2.0] - 2026-06-18

### Added
- **`system_op_display(op)`** (`src/types.cyr`) — completes the rust-old port. The Rust `impl fmt::Display for SystemOp` (types.rs:524-544) was the one symbol an evidence-based re-review found unported; it now reproduces all six variant forms byte-for-byte (`"{desc}: {bin} {args}"`, `write {path}`, `mkdir {path}`, `symlink {link} -> {target}`, `mount {dev} on {mp}`, `umount {mp}`).
- **Test coverage for previously-untested code paths.** Suite: 253 → 299 tests, 0 failures. Added:
  - `system_op_display` (all 6 variants) and a `partition_device` both-substring regression.
  - 9 security-relevant validation checks: missing `/dev/` prefix, the post-`/dev/` suffix allowlist, the kernel-param dangerous-*character* path, empty/over-length hostname, over-length username, the no-root-partition guard, and the permissive-trust + allow-firewall warnings.
  - 10 planner-branch checks: `mkfs.btrfs`/`mkfs.xfs`/`mkswap` formatting, MBR `mklabel msdos`, swap `swapon` and encrypted-root `/dev/mapper` mount paths, the IMA-policy branch (on/off), Server + Minimal first-boot service lists, UUID v4 version/variant bit-stamping, and fstab column structure (separators, dump/pass numbers).

### Fixed
- **`partition_device` latent double-separator** (`src/partitioning.cyr`) — a device string matching *both* `nvme` and `mmcblk` appended two `p` separators (`...pp1`) instead of one. Unreachable on real hardware but a divergence from rust-old; now uses a single flag so exactly one `p` is emitted. Regression test added.

### Verified
- **Full rust-old → Cyrius port re-audit.** Module-by-module behavioral comparison (types, helpers, validation, partitioning, rootfs, lib/orchestrator) confirms the port is faithful: package lists, install-time estimates, the non-recoverable phase set, all shell-injection character sets, GRUB/systemd-boot configs, nftables/IMA/sysctl, fstab, and kernel cmdline all match the Rust source. Sole gap was `Display for SystemOp` (now closed).

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
