# agnova roadmap

## Status

**v0.3.0 (current)** — executor disk path validated on real (loopback) hardware: partition → format → mount run clean end-to-end. Three execution-only bugs found and fixed (PATH/exec, loop-device naming, phase attribution). Mount-option `MS_*` parsing, `execute --until <phase>` staging, a plan-generation benchmark harness, and CI gates (CHANGELOG-per-PR, `cyrfmt --check`) added. 307 tests, lint + fmt clean. Full multi-phase install pass (base tarball, packages, LUKS, bootloader) deferred to v0.7.0 — needs a VM with AGNOS artifacts.

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

## Completed (v0.3.0)

- [x] **End-to-end executor disk path validated on real (loopback) hardware** — partition (GPT, ESP+root, boot/esp flags) → format (`mkfs.vfat`/`mkfs.ext4`) → mount all execute clean (`phases completed: 4/14, errors: 0`). The run found + fixed three execution-only bugs: PATH resolution in `_exec_with_stdin` (`rc=127`), loop-device partition naming (`/dev/loop0p1`), and phase/recoverability misattribution in `execute_all`.
- [x] `execute --until <phase>` — staged execution; `--until mount` gives a clean disk-only pass without AGNOS artifacts.
- [x] Mount options: `mount_flags_from_options` parses `vec<Str>` options (one-per-element or comma-separated) into `MS_*` flag bits; `_exec_mount` threads them into `sys_mount`. (Data-string options like `subvol=` not threaded — agnova emits only flag/`defaults` options today.)
- [x] Bench harness — `tests/agnova.bcyr` exercises plan-generation throughput (`full_execution_plan`, `total_ops_count`, `validate_config`, `default_packages`) via `cyrius bench`. Baseline µs/call in CHANGELOG.
- [x] CHANGELOG entry per-PR enforced in CI (`changelog` job fails PRs whose diff omits `CHANGELOG.md`).
- [x] `cyrfmt --check` in CI — whole tree reformatted to cyrfmt canonical + a `Format check` step in the `build` job. (The `cyrius fmt` wrapper mangles args; the `cyrfmt` binary is invoked directly.)
- [x] ~~Fix the 5 `line exceeds 120 characters` lint warnings~~ — already clean; `cyrius lint` is 0 warnings across `src/` and `lib/`.

## Deferred to v0.7.0 — full multi-phase install pass

The disk path (partition/format/mount) is proven. A *complete* `agnova execute` (no `--until`) reaching `PHASE_COMPLETE` with `errors: 0` is **blocked on AGNOS runtime artifacts that don't exist on a dev box** — so it's deferred to v0.7.0. **What is needed to close it:**

- **A VM (or real machine) running AGNOS-built media**, since the install shells out to AGNOS tooling and expects AGNOS files in place. Specifically:
  - **Base-system tarball** present at `/run/agnos/installer/base-system.tar.zst` — the `INSTALL_BASE` phase `tar`-extracts it (this is exactly where the dev-box run stops). Produced by the AGNOS image build (zugot recipes).
  - **`ark` package manager** on `PATH` — `INSTALL_PACKAGES` runs `ark` (and `plan_install_base_ops` references `ark-install.sh`).
- **LUKS/cryptsetup execution validated** — run `execute --encrypt --passphrase … --i-mean-it` against a loopback/VM and confirm the stdin-piped `cryptsetup luksFormat` + `open` work. The planner ops and the executor's stdin-pipe are implemented and unit-covered; only *real-cryptsetup execution* is unverified. (Closes the old "wire `--passphrase`" item — CLI side is done; this is the remaining execution check.)
- **Bootloader install validated on a UEFI VM** — `bootctl install` (systemd-boot) and `grub-install` (GRUB) actually writing to the ESP.
- **Full matrix** — `execute` to `PHASE_COMPLETE`, `errors: 0`, across UEFI+BIOS × encrypted+unencrypted × all 4 modes. Satisfying this also satisfies the v1.0 "one full install succeeds end-to-end" criterion.

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
- [x] `cyrius lint` is 0/0 across `src/` and `lib/`
- [ ] CHANGELOG follows Keep a Changelog strictly; every PR adds an entry
- [ ] `docs/architecture/overview.md` reflects every public symbol's contract
- [ ] An ADR exists for every interface decision that's hard to reverse (currently 1 — the port itself)
