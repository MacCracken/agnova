# agnova roadmap

## Status

**v0.7.0 (current)** — the **sovereign native install arc** landed. `--disk-backend=native-file|native-block` now shapes a whole, configured, bootable base system entirely in-process: GPT + FAT32 ESP + a sovereign multi-group ext2 root + base-system tarball extraction (`.tar`/`.gz`/`.xz`/`.bz2`/`.zst`, via the shared sankoch cursor) + all config files written straight into the ext2 image — with **zero host tools** (no `parted`/`mkfs`/`tar`/`unzstd`/`chroot`/`grub` fork-exec). A production AGNOS kernel boots the agnova-written medium to `/bin/agnsh` (the 0.6.0 arc-closer). The default **shell** backend is unchanged and stays the proven reference. A full native run completes its 8 emitted phases with 0 errors (`scripts/native-base-smoke.sh`). Still shell-only: user accounts, `ark` package install, service enablement — and the shell-path full-matrix e2e (LUKS execution, bootloader-on-VM) remains the v1.0 bar.

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

## Completed — sovereign native install arc (v0.5.0 → v0.7.0)

The 0.3.0 status deferred a *complete* multi-phase install to v0.7.0, expecting a **shell** run to `PHASE_COMPLETE` that would need a VM with AGNOS artifacts (a base tarball staged on disk, `ark` on `PATH`, `cryptsetup`, `bootctl`/`grub-install`). The arc took the **sovereign** route instead — a native backend that lays the whole base system down **in-process, no host tools** — so the goal (a complete run that writes a configured, bootable base system) is met without any of those externals.

- [x] **Native disk backend** (v0.5.0) — `--disk-backend=shell|native-file|native-block`. Structured disk ops (`OP_PARTITION_DISK`/`OP_FORMAT_FS`/`OP_STAGE_FILE`) route to an in-process backend (`disk_backend.cyr`) that writes a GPT + FAT32 ESP by raw sector I/O (`diskfmt.cyr`, vendored + parameterized from the gptwr proof), no `parted`/`mkfs.vfat`/`mcopy`. The same binary runs on the Linux host (`native-file`, file-offset I/O into a loop image) and on agnos (`native-block`, `sys_blk_*` behind the arm-gate); one target-gated I/O seam. Proven by `sgdisk`/`fsck.fat`/`mcopy` + a ring-3 agnos GPT-write smoke.
- [x] **Sovereign ext2 root** (v0.6.0 → v0.6.1) — a journal-less multi-group ext2 mkfs+populate engine (any size; per-group SB+GDT backups; direct/single/double-indirect files to ~4.29 GiB; `lost+found`; symlinks), so the **root filesystem** is written natively, not just the ESP. A production kernel boots the agnova-written medium and execs `/bin/agnsh` from the agnova-written root (the arc-closer boot proof). Every field validated by `e2fsck -fn`/`dumpe2fs`/`debugfs`.
- [x] **Base-system extraction into the root** (v0.6.1 → v0.7.0) — this *is* the deferred `INSTALL_BASE` tar-extract, done sovereignly: `--base-tarball <archive>` untars a whole base system into the ext2 root through the shared **sankoch** tar cursor, which sniffs + inflates `.tar`/`.gz`/`.xz`/`.bz2`/`.zst` in RAM — replacing the shell path's `tar -xf base-system.tar.zst --zstd`, with no `tar`/`unzstd` and no temp file. With no tarball, a single `/bin/agnsh` is staged (minimal boot-to-shell payload).
- [x] **Config files into the image** (v0.7.0) — `/etc/fstab`, `hostname`, `hosts`, `resolv.conf`, `machine-id`, `locale.conf`, the `/etc/localtime` symlink, `nftables.conf`, IMA policy, sysctl hardening, and the `/etc/agnos/first-boot` marker are written straight into the ext2 image (no mount, no host fs). The shared config planners (`plan_network_ops`/`plan_locale_ops`/`plan_security_ops`) are reused with an empty `target_root` so they emit root-relative paths; `execute_op` routes their `OP_WRITE_FILE`/`OP_MAKE_DIR`/`OP_SYMLINK` to the native ext2 sink (`df_ext2_write_mem`/`df_ext2_mkdir_p`/`df_ext2_symlink_p`).
- [x] **Full native run proven** (v0.7.0) — `scripts/native-base-smoke.sh`: a `.tar.zst` base + all config land in an e2fsck-clean ext2 (byte-identical large file, preserved symlinks, fresh machine-id), no shell-out; the native run completes **8/8 emitted phases, 0 errors**.

## Still open — was the rest of the deferred pass

- [ ] **Native user accounts / packages / services** — the native plan deliberately omits `useradd`/`usermod` (needs sovereign `/etc/passwd`,`/shadow`,`/group` gen), `ark` package install into the offline image, and `chroot argonaut enable` service enablement. These are the residual gap between a native disk-shaped base and a fully-configured install.
- [ ] **Shell-path full-matrix e2e** — a *complete* `agnova execute` on the **shell** backend to `PHASE_COMPLETE`, `errors: 0`, across UEFI+BIOS × encrypted+unencrypted × all 4 modes, on a VM with AGNOS media. Still needs real-`cryptsetup` LUKS execution (the planner ops + executor stdin-pipe are implemented and unit-covered; only *execution* is unverified) and `bootctl`/`grub-install` writing to a UEFI ESP validated. Satisfying it also satisfies the v1.0 "one full install succeeds end-to-end" criterion.
- [ ] **Sovereign LUKS** — an in-process LUKS (argon2id keyslot + AES-XTS sector layer + LUKS2 header, wired into `diskfmt`'s `df_write`/`df_read` seam) is a cross-repo crypto-boundary feature to be scoped in **sigil**, not a disk-format concern (see CHANGELOG 0.6.1 notes). It would give the native path encrypted-root parity with the shell path's `cryptsetup`.

## Future (unscheduled)

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
