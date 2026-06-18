# agnova roadmap

## Status

**v0.2.0 (current)** — rust-old port complete and re-verified; toolchain on Cyrius 6.2.21. Library + CLI build clean, plan generation byte-equivalent to the Rust scaffold, executor implemented but not yet run end-to-end on hardware.

## Completed (v0.1.0)

- [x] Rust scaffold ported to Cyrius 5.7.12 (`cyrius port`)
- [x] All 7 enums (`InstallMode`, `Filesystem`, `PartitionFlag`, `BootloaderType`, `TrustEnforcementMode`, `FirewallDefault`, `InstallPhase`)
- [x] All ~13 config/result structs with `#derive(accessors)` for clean field access
- [x] `SystemOp` tagged union over 6 variants + factory fns
- [x] `IsoConfig` + `iso_build_command`
- [x] Pure helpers: `generate_machine_id()` (RFC 4122 v4), `generate_hostname_config()`, `generate_fstab()`, `default_kernel_params()`
- [x] `validate_config(cfg)` — 28 hard checks + 3 warning categories with shell-injection guards
- [x] `partition_device()` for SCSI / NVMe / MMC naming
- [x] All 13 phase planners (`plan_*_ops()`) producing `vec<SystemOp>` per phase
- [x] `full_execution_plan(cfg, target, passphrase)` and `total_ops_count`
- [x] `kernel_cmdline(cfg)` merging explicit + security-derived params + root device
- [x] `default_packages(mode)` with full base + per-mode package lists
- [x] `AgnovaInstaller` state machine (phase advance, fail, log, result)
- [x] `executor.cyr` with all 6 `SystemOp` dispatchers (sys_mount/umount2/chmod/open/write/close + fork/exec, plus shell-out to mkdir -p / ln -sfT / chown for ergonomics)
- [x] CLI: `plan`, `validate`, `execute` (gated by `--i-mean-it`), `version`, `help`
- [x] `--verbose` flag for per-op plan dump
- [x] CI workflow runs `cyrius deps` + `cyrius build`
- [x] `cyrius lint` — clean (5 long-line warnings only)

## Completed (v0.2.0) — rust-old port

- [x] Complete the `rust-old/` → Cyrius port and retire `rust-old/` as historical reference only. Evidence-based module-by-module re-audit (types/helpers/validation/partitioning/rootfs/lib) confirmed byte-for-byte parity; the lone gap — `Display for SystemOp` — is now ported as `system_op_display` with tests. `partition_device` double-separator edge case fixed. Test suite 253 → 299 (all previously-untested validation checks and planner branches now covered).

## Backlog (v0.3.0)

- [ ] **End-to-end hardware test** of executor on disposable hardware (loopback file or VM).
- [ ] CHANGELOG entry per-PR enforced in CI
- [ ] `cyrius fmt --check` in CI (figure out the right invocation)
- [ ] Fix the 5 `line exceeds 120 characters` lint warnings (cosmetic only)
- [ ] Wire `--passphrase` into LUKS encryption ops (currently flag is parsed but stdin-piping path needs validation)
- [ ] Mount options: parse `vec<Str>` options into MS_* flag bits (currently passed as `0` to `sys_mount`; agnova only ever emits `["defaults"]` so the simplification is safe today, but bug-prone if extended)
- [ ] Bench harness — `tests/agnova.bcyr` should exercise plan-generation throughput (microseconds per `full_execution_plan` call)

## Future (v0.4.0)

- [ ] **Resumable installs** — checkpoint `AgnovaInstaller` state to `/run/agnos/installer/state.json` after each phase advance; on restart, resume from last completed phase
- [ ] **Hardware detection** — probe `/sys/block` for disks, `/proc/cpuinfo` for arch, `/sys/firmware/efi` for UEFI
- [ ] **Interactive TUI** mode — guide users through device selection, mode, encryption, user setup without flags
- [ ] **JSON status output** — `agnova plan --json` and `agnova execute --status-fd 3` for programmatic consumption (e.g., installer-shell integrations)
- [ ] **Loopback install mode** — `--device /tmp/agnos.img --create-image=8G` writes to a sparse file, useful for VM/CI testing
- [ ] **Custom partition layouts** — flag-driven (`--swap-mb 4096 --home /dev/sdb1`) or config-file-driven
- [ ] **Multi-disk** — separate `/`, `/home`, `/boot` on different devices
- [ ] **`--dry-run` for `execute`** — same flag-validation pipeline as `execute` but stops short of side effects (currently `plan` covers most of this need)

## v1.0 criteria

- [ ] One full install from `agnova execute` succeeds end-to-end on real hardware (UEFI + BIOS, encrypted + unencrypted, all 4 modes)
- [ ] Test suite ports the Rust scaffold's coverage and adds executor-path coverage via loopback
- [ ] Resumable installs proven across simulated kernel panic mid-install
- [ ] All 5 long-line lint warnings cleaned up; `cyrius lint` is 0/0
- [ ] CHANGELOG follows Keep a Changelog strictly; every PR adds an entry
- [ ] `docs/architecture/overview.md` reflects every public symbol's contract
- [ ] An ADR exists for every interface decision that's hard to reverse (currently 1 — the port itself)
