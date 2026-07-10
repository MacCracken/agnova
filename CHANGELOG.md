# Changelog

All notable changes to agnova are documented here.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-07-10 — sovereign native install: whole base system + config, zero host tools

### Added
- **The native install plan now lays down a whole, configured, bootable base system — with zero
  host tools.** `--disk-backend=native-file|native-block` previously fulfilled only the disk-shaping
  slice (GPT + FAT32 ESP + ext2 root + staging `/bin/agnsh`); it now runs a complete install
  in-process, no `tar` / `mkfs` / `parted` / `unzstd` / `chroot` / `grub` fork-exec:
  - **Base-system extraction** — `--base-tarball <archive>` extracts a full base system
    (`.tar` / `.tar.gz` / `.tar.xz` / `.tar.bz2` / `.tar.zst`, envelope sniffed) into the ext2 root
    via the sankoch cursor (`op_untar_ext2` → `STAGE_TARGET_UNTAR` → `df_ext2_untar`). Replaces the
    shell path's `tar -xf base-system.tar.zst --zstd`. When unset, the single-`/bin/agnsh` stage is
    kept (minimal boot-to-shell payload).
  - **Config files written straight into the ext2 image** — `/etc/fstab`, `/etc/hostname`,
    `/etc/hosts`, `/etc/resolv.conf`, `/etc/machine-id`, `/etc/locale.conf`, the `/etc/localtime`
    symlink, `/etc/nftables.conf`, IMA policy, sysctl hardening, and the `/etc/agnos/first-boot`
    marker. On a native backend `execute_op` routes `OP_WRITE_FILE` / `OP_MAKE_DIR` / `OP_SYMLINK`
    to a native ext2 sink (`df_ext2_write_mem` / `df_ext2_mkdir_p` / `df_ext2_symlink_p`) — no mount,
    no host fs. The shared config planners (`plan_network_ops` / `plan_locale_ops` /
    `plan_security_ops`) are reused with an empty `target_root` so they emit root-relative paths.
  - gnoboot needs no boot config (it opens `\boot\agnos` by fixed path), so the staged kernel makes
    the disk bootable as-is.
  - `scripts/native-base-smoke.sh` proves the full path: a `.tar.zst` base + all config files land
    in an e2fsck-clean ext2 with a byte-identical large file, preserved symlinks, and a fresh
    machine-id — no shell-out. A full native run completes 8/8 emitted phases, 0 errors.
  - **Residual (still shell-only, deliberately omitted from the native plan):** user accounts
    (`useradd`/`usermod` → sovereign `/etc/passwd`,`/shadow`,`/group` gen is a follow-on capability),
    package install (`ark` into the offline image), and service enablement (`chroot argonaut enable`).

### Changed
- `plan_native_disk_ops` moved from `src/disk_backend.cyr` to a new `src/disk_plan.cyr`, included
  after `helpers`/`rootfs` so it can reuse the shared config planners. `disk_backend.cyr` keeps the
  backend selector, source vars, and native op handlers (which depend on nothing past `diskfmt`).

## [0.6.1] - 2026-07-10 — complete multi-group ext2 + shared sankoch tar (incl. .tar.zst)

Rounds out the sovereign ext2 root writer (multi-block-group, double-indirect, lost+found,
symlinks) and consolidates tar extraction onto sankoch's shared cursor, which unlocks
`.tar.xz` / `.tar.bz2` / `.tar.zst` — so a native install can lay down `base-system.tar.zst`.

### Changed
- **ext2 tar extraction now uses sankoch's shared tar cursor.** `df_ext2_untar` /
  `df_ext2_untar_mem` dropped agnova's own ustar parser (~60 lines: `df_parse_octal`,
  `df_tar_pad`, `df_src_skip`, `df_ext2_untar_core`, the header buffer) in favour of sankoch 2.5.x's
  `tar_open_auto` + `tar_next` cursor — one implementation shared with takumi. agnova supplies only
  the ext2 sink (`df_ext2_resolve` → `df_ext2_mkdir` / `df_ext2_add_file_sz` / `df_ext2_add_symlink`)
  and, as a rootfs writer, keeps absolute symlink targets (they resolve inside the installed root).
  **Bonus: `.tar.xz` / `.tar.bz2` / `.tar.zst` now extract into ext2** (the cursor sniffs + inflates
  every envelope) — so the sovereign base-system install can consume `base-system.tar.zst`.
  `scripts/untar-gz-smoke.sh` now proves all four compressed envelopes → ext2, e2fsck-clean +
  byte-identical + symlinks preserved.

### Added
- **Multi-block-group ext2** — `df_format_ext2` now writes a fs of any size (groups of 32768
  blocks, a full SB + GDT backup in every group — no sparse_super, so e2fsck verifies each).
  Group-aware inode locator + block/inode allocators that skip per-group metadata; per-group
  free-block / free-inode / used-dirs counters persisted into the GDT and re-synced to all backups
  after every op. A 512 MiB root is 4 groups; a 1.5 GiB install root is 12 groups — both e2fsck-clean.
- **Double-indirect files** — the file writer allocates data blocks one at a time (group-aware,
  non-contiguous) and routes them through direct[0..11], a single-indirect block, and a
  double-indirect tree (`i_block[13]`), so files up to ~4.29 GiB are supported (past the kernel
  reader's 2 GiB `i_size` cap). A 9 MiB double-indirect file round-trips byte-identical.
- **lost+found** — inode 11 is created as a proper directory at mkfs, linked from `/`.
- **Symlinks** — `df_ext2_add_symlink` writes fast symlinks (target < 60 B stored inline in the
  i_block area, `i_blocks=0`).
- **tar (ustar) extraction** — `df_ext2_untar` populates the root from a tarball (regular files
  incl. indirect, nested directories, symlinks), replacing the "loose file tree" assumption. A
  shared path resolver (`df_ext2_resolve`) `mkdir -p`'s parents; a size-bounded streaming reader
  stops exactly at each member (no over-read into padding).
- **gzip (.tar.gz) extraction** — `df_ext2_untar_gz` inflates the archive in RAM via sankoch and
  untars from memory (`df_ext2_untar_mem`) — no `gunzip`, no temp file, works on the agnos target.
  New deps: `sankoch`, `thread`.
- **Validation harnesses**: `scripts/ext2-format-smoke.sh` (multi-group + lost+found +
  direct/single/double-indirect + deep-path staging), `scripts/untar-smoke.sh` (ustar files/dirs/
  symlinks), `scripts/untar-gz-smoke.sh` (.tar.gz) — all checked by `e2fsck -fn` / `dumpe2fs` /
  `debugfs` with byte-identical extraction. The arc-closer boot smoke confirms the multi-group
  root still boots to `/bin/agnsh` on the real kernel.

### Notes
- **Triple-indirect (>4.29 GiB files)** is bounded by the AGNOS kernel's ext2 reader, which caps
  `i_size` at 2 GiB (`agnos/kernel/core/ext2.cyr:220`) — double-indirect already exceeds that, so
  larger files are moot until the kernel grows 64-bit `i_size` + `large_file`. Filed as a kernel
  item (`agnos/docs/development/issues/2026-07-10-ext2-large-file-64bit-isize.md`).
- **zstd tarballs** are not extractable: sankoch implements LZ4 / DEFLATE / zlib / gzip / bzip2 but
  parks Zstandard, so no sovereign zstd decompressor exists yet. `.tar` and `.tar.gz` cover the
  base-system need.
- **LUKS root encryption** is a sigil (crypto-boundary) concern, not a disk-format one. sigil's
  `luks.cyr` today drives `cryptsetup` (the Linux-host path); a *sovereign* in-process LUKS
  (argon2id keyslot + AES-XTS sector layer + LUKS2 header, then wired into diskfmt's `df_write` /
  `df_read` seam) is a real cross-repo security feature to be scoped in sigil.

## [0.6.0] - 2026-07-10 — sovereign ext2 root: agnova installs AGNOS natively and boots what it wrote

Closes the AGNOS native-install arc. agnova now writes the **whole boot medium** — GPT + FAT32 ESP
+ a journal-less **ext2 root** — with no `parted`/`mkfs.fat`/`mkfs.ext2`/`mcopy`, and a production
kernel boots that medium to `/bin/agnsh`. The 0.5.0 backend shaped the ESP only; 0.6.0 adds the
root filesystem, so a native install is now end-to-end.

### Added
- **Sovereign ext2 root writer** (`src/diskfmt.cyr`) — a journal-less ext2 mkfs + populate engine,
  so agnova now writes the **root filesystem** natively, not just the ESP. Classic ext2 (4096-byte
  blocks, single block-group, 128-byte dynamic-rev inodes, `FILETYPE` feature only, no journal/csum):
  `df_format_ext2` (empty fs), `df_ext2_add_file` (direct + single-indirect, ~4 MiB cap),
  `df_ext2_mkdir` (nested dirs, parent-link + `used_dirs` accounting), `df_ext2_lookup` +
  `df_ext2_stage` (absolute-path staging, intermediate dirs auto-created). Every field validated by
  the reference `e2fsck -fn` / `dumpe2fs` / `debugfs`, and staged files proven byte-identical.
- **`native_format` ext2 dispatch** — `FS_EXT4` (the root) now formats a sovereign journal-less
  ext2 (the kernel reads it either way) instead of returning `E_NOT_IMPL`; `FS_VFAT` still → FAT32,
  `xfs`/`btrfs` still fall to the shell path. **`native_stage` root arm** (`target_fs=1`) streams a
  file into the ext2 root via `df_ext2_stage`. The native plan now emits a root-format op +
  a `PHASE_INSTALL_BASE` op staging `/bin/agnsh` (source `--agnsh-src`).
- **`--agnsh-src`** flag (base-system payload staged into the ext2 root).
- **Full-native install proof** (`scripts/native-disk-smoke.sh`, extended): one `agnova execute`
  writes GPT + FAT32 ESP + ext2 root + all staging with **no** `parted`/`mkfs.fat`/`mkfs.ext2`/`mcopy`
  — validated by `sgdisk`, `fsck.fat` + `mcopy`, and `e2fsck` + `debugfs` (root clean, `/bin/agnsh`
  byte-identical).
- **Arc-closer boot proof** (`agnos/scripts/agnova-boot-smoke.sh`): a production kernel boots the
  agnova-written medium and kybernet execs `/bin/agnsh` from the agnova-written ext2 root — AGNOS
  installs AGNOS natively and boots what it wrote.

### Changed
- **Toolchain pin 6.4.39 → 6.4.43** (latest; `cyrius lib sync --full` to re-materialize the full
  lib snapshot incl. the agnos syscall variant). No agnova-facing API change — the 6.4.40–6.4.43
  deltas are async-runtime / aarch64 / Windows-IOCP only, none of which agnova uses.

## [0.5.0] - 2026-07-10 — dual-target native disk backend: agnova shapes a disk with no shell-out

Phase 5 of the AGNOS native-install arc. agnova now partitions, formats, and stages an ESP
**natively** — no `parted`/`mkfs.fat`/`mcopy` — via the same gptwr-proven on-disk format logic,
and the **same binary runs on agnos** (writing through `sys_blk_*`) as well as on the Linux
host. The Linux-hosted shell path stays the default and is byte-identical to before.

### Added
- **Structured disk ops** `OP_PARTITION_DISK` / `OP_FORMAT_FS` / `OP_STAGE_FILE` (`types.cyr`)
  dispatched under `execute_op` to a new **native disk backend** (`src/disk_backend.cyr`) —
  behind the existing SystemOp seam, so the shell planners are untouched (ADR-0002).
- **`src/diskfmt.cyr`** — sovereign GPT + FAT32 + file-staging builders (vendored from the
  gptwr proof tool, parameterized): a byte-accurate protective MBR + primary/backup GPT header
  + 128-entry array (CRC32, UTF-16 partition names), a FAT32 ESP (BPB + FSInfo + dual FAT +
  `\EFI\BOOT` / `\boot` tree, parametric volume label), and streamed cluster-chain file staging.
  Validated by `sgdisk` + `fsck.fat` + byte-identical `mcopy` (`scripts/native-disk-smoke.sh`).
- **`--disk-backend=shell|native-file|native-block`** plus `--gnoboot-src` / `--kernel-src`
  (ESP payload sources) and `--scratch-base` / `--disk-sectors` (bounded-image / QEMU-proof mode).
- **Dual-target build**: Linux (shell + `native-file` file-offset sector I/O) and agnos
  (`native-block`, `sys_blk_*` behind the `BLK_RW_ARM_MAGIC` gate). The whole Linux shell/mount
  surface is `#ifndef CYRIUS_TARGET_AGNOS`-compiled-out; one target-gated I/O seam in `diskfmt`.
- **agnos install-slice proof**: `agnos/scripts/agnova-install-smoke.sh` — the real `--agnos`
  agnova binary runs ring-3 on agnos, enumerates the NVMe, arms the gate, and writes a valid
  GPT via `sys_blk_*` (sgdisk-clean, no faults).

### Changed
- **Toolchain pin 6.3.35 → 6.4.39** (for the `sys_blk_*` wrappers), `cyrius lib sync --full` to
  materialize the agnos syscall variant into `lib/`. `main.cyr` uses a bare `_entry()` call
  (agnos argv capture). Source-file opens go through `io.cyr`'s portable `xopen`.
- **CI lint hardened** to fail on warnings / untracked deferrals (`.github/workflows/ci.yml`).

### Notes
- The native path is **ESP-only**: `mkfs.ext4`/xfs/btrfs for the root filesystem, the
  base-system tarball, LUKS, and `mount` remain on the shell backend (`native_format` returns
  `E_NOT_IMPL` for non-VFAT). A full agnos-on-agnos install still needs those to land.

## [0.4.1] - 2026-07-03 — sovereign reconciliation: gnoboot default + zugot-resolvable packages

### Changed
- **Bootloader default reconciled to sovereign `gnoboot`** (`src/types.cyr`,
  `src/cli.cyr`, `src/rootfs.cyr`). AGNOS boots via **gnoboot** (a PE32+ EFI
  Application, replaces GRUB/systemd-boot), so agnova now defaults there. New
  `BOOT_GNOBOOT` enum + `bt_str`, `--bootloader gnoboot|systemd|grub2` (default
  `gnoboot`), and a `plan_bootloader_ops` gnoboot branch that mirrors the
  canonical `agnosticos/scripts/install-media.sh` ESP layout: stage
  `/usr/lib/gnoboot/BOOTX64.EFI` → `ESP/EFI/BOOT/BOOTX64.EFI` and the kernel →
  `ESP/boot/agnos`, no GRUB/bootctl, no loader config (gnoboot needs none —
  UEFI firmware loads it directly and it loads the kernel from the ESP).
  systemd-boot/grub2 are kept as fallback options (interop seam), not deleted.
  `gnoboot` added to the base package set (resolves to the new zugot recipe).
  Suite green (313/0, +gnoboot bt_str/default/ops tests). The default `plan`
  drops from **62 → 60 operations** (the gnoboot bootloader phase is 4 ops vs
  systemd-boot's 6); the CI plan smoke (`.github/workflows/ci.yml`) + the
  architecture doc op-count were updated, and the smoke now also asserts
  `bootloader: gnoboot`.
- **`default_packages` reconciled against zugot recipe names** (`src/rootfs.cyr`) —
  the names agnova hands to `ark install <name>` must resolve in nous's zugot
  RecipeDb, but the ported list carried Debian-slanted names that didn't exist as
  recipes. Now every name resolves (verified against the 535-recipe corpus, 0
  unresolved):
  - **Mapped to the real AGNOS project recipe:** `linux-kernel`→`agnos-kernel`,
    `agnos-init`→`kybernet`, `agnos-sys`→`agnosys`, `agnos-common`→`agnostik`,
    `nano`→`cyim`, `evince`→`zathura`, `fail2ban`→`phylax`, `fonts-noto`→`noto-fonts`.
  - **`*-server` variants collapsed to the base project** (`hoosh-server`/
    `daimon-server` → the `hoosh`/`daimon` already in base — server-vs-base is a
    runtime mode, not a separate package).
  - **Dropped toward a lean sovereign base** (non-sovereign Debian tools with no
    AGNOS equivalent, added back on demand not baked in): `systemd` (kybernet is
    the init), `zsh`, `iputils` (iproute2 covers it), `tmux`, `xdg-utils`,
    `nautilus`, `fonts-jetbrains-mono`, `prometheus-node-exporter`.
  Every name resolves against the zugot corpus. (The bootloader default is
  reconciled to gnoboot in this same 0.4.1 release — see the entry above.)

## [0.4.0] - 2026-07-02 — cyrius 6.3.35 migration + base install drives real ark (`--dir`)

### Changed
- **Toolchain: cyrius pin `6.2.21` → `6.3.35`** (current toolchain). Suite green (308
  passed) on 6.3.35; `lib/` re-vendored. The `agnova version` banner's toolchain line
  updated to match (`src/cli.cyr`).

### Fixed
- **Stack smash in `run_command`'s waitpid (`src/executor.cyr`).** The wait-status
  buffer was `var stbuf[1]` — 1 u64 slot (8 B) under the pre-6.3.13 heap-local model,
  but 1 **byte** on the stack since cyrius 6.3.13 moved function-local `var X[N]` onto
  the stack, so `waitpid`'s 4-byte status write (read back via `load32`) overran it.
  Sized to `var stbuf[8]`. (`buf[16]` UUID / `pipefd[16]` pipe buffers are correctly
  byte-sized and unaffected.)
- **Base-system `.ark` install now drives the real `ark` binary (`src/rootfs.cyr`).**
  The base fallback shelled a never-existent `ark-install.sh --root <t> --packages
  <dir>`; neither the script nor a `--packages` flag exists in ark. It now calls
  `ark install --apply --no-confirm --root <target> --dir /run/agnos/installer/packages/`
  (ark's batch `--dir` mode, **requires ark ≥ 1.3.0**), which installs every
  pre-staged base `.ark` into the target root and records them in the target's own
  package DB. (The mode/extra name-based `ark install <names>` calls still await the
  sovereign producer chain to resolve base names → `.ark`s.)

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
