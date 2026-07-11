# agnova architecture

## Consumers

End users running the AGNOS installer on new hardware (live USB → guided install).

## Design philosophy

**Plan first, execute second.** Every action the installer can perform is described as a `SystemOp` value. The library has zero side effects — building an `InstallConfig` and calling `full_execution_plan()` (shell) or `plan_native_disk_ops()` (native) produces a `vec<PhaseOps>` of pure data structures. Only `executor.cyr`'s `execute_op` turns those descriptors into real effects — shelling out to host tools on the default backend, or delegating to the in-process `disk_backend` handlers on a native backend — and only the CLI's `execute` subcommand (with explicit `--i-mean-it`) ever invokes it.

This separation gives us:
- **Trivial dry-run**: `agnova plan --verbose` dumps the entire install as ordered shell-equivalent commands
- **Easy testing**: planners are pure; tests assert plan shape without touching disk
- **Safe iteration**: structural changes (new phases, new ops) are reviewable as plan diffs before they're executable

## Module map

```
src/
├── types.cyr         (828 LOC)  enums + structs + SystemOp (9 variants) + factories + IsoConfig
├── diskfmt.cyr      (1276 LOC)  sovereign GPT + FAT32-ESP + multi-group ext2 builders + sankoch untar sink (raw sector I/O)
├── disk_backend.cyr  (239 LOC)  native backend selector + op handlers (partition / format / stage / ext2 file-sink), no fork-exec
├── helpers.cyr       (225 LOC)  machine-id, fstab, hostname, kernel params
├── validation.cyr    (415 LOC)  28 hard checks + 3 warning categories
├── partitioning.cyr  (278 LOC)  parted / mkfs / cryptsetup planners (shell backend)
├── rootfs.cyr       (1071 LOC)  mount, packages, bootloader, user, network, locale, security, first-boot, cleanup planners (shell)
├── disk_plan.cyr      (80 LOC)  native install-plan builder (reuses the shared config planners for the ext2 root)
├── orchestrator.cyr  (170 LOC)  AgnovaInstaller state machine
├── executor.cyr      (325 LOC)  SystemOp dispatchers (shell side effects, or the native ext2 sink on a native backend)
├── cli.cyr           (580 LOC)  flag parsing + subcommand dispatch
└── main.cyr          ( 35 LOC)  thin entry point
```

Total: ~5,520 LOC of Cyrius. The ported library core (everything but the native disk backend) is ~3,930 LOC against the 3,656 LOC Rust scaffold; the sovereign native disk backend — `diskfmt` + `disk_backend` + `disk_plan`, ~1,595 LOC — is new work with no Rust counterpart (`diskfmt` is vendored from the gptwr proof tool and parameterized).

### Dependency graph (compilation order, leaf at top)

```
types
  ├── diskfmt       (sovereign GPT/FAT32/ext2 builders + untar sink; one target-gated I/O seam)
  │     └── disk_backend  (native backend selector + native op handlers; calls df_* only)
  ├── helpers       (uses Str, vec, SecurityConfig accessors)
  ├── validation    (uses InstallConfig accessors, enum values)
  ├── partitioning  (uses SystemOp factories, DiskLayout, PartitionSpec)
  └── rootfs        (uses everything above + helpers + partitioning::partition_device)
        └── disk_plan     (native install-plan builder; reuses plan_network/locale/security_ops)
              └── orchestrator  (uses AgnovaInstaller state + InstallProgress + InstallError)
                    └── executor    (SystemOp dispatch; routes native ops to disk_backend handlers)
                          └── cli         (uses every public symbol; `--disk-backend` wiring)
                                └── main  (calls cli_main)
```

`diskfmt` + `disk_backend` are included right after `types` (before the shell planners) because the native op handlers depend on nothing past `diskfmt`; `disk_plan` is included after `rootfs` so it can reuse the shared config planners (`plan_network_ops` / `plan_locale_ops` / `plan_security_ops`).

`include "src/<name>.cyr"` from `main.cyr` in dependency order — Cyrius does textual inclusion, so file order matters.

## Data flow

1. **CLI parses flags** → `_config_from_flags(h)` builds an `InstallConfig` from `--device`, `--user`, `--mode`, etc.
2. **Validation** → `validate_config(cfg)` returns `Ok(warnings)` or `Err(message)` (tagged-union via `lib/tagged.cyr`).
3. **Plan generation** → `full_execution_plan(cfg, target_root, luks_passphrase)` returns `vec<PhaseOps>`. Each phase is independent; the orchestrator runs them sequentially.
4. **For `plan` subcommand**: pretty-print every `PhaseOps` (and every `SystemOp` inside if `--verbose`).
5. **For `execute` subcommand**: build an `AgnovaInstaller`, then `execute_all(inst, plans)` walks each phase. Per op:
   - dispatch on `tag(op)` in `execute_op` → call `_exec_<variant>(payload(op))`
   - on a **native backend** (`get_disk_backend() != DISK_BACKEND_SHELL`), `execute_op` first routes the structured disk ops (`OP_PARTITION_DISK` / `OP_FORMAT_FS` / `OP_STAGE_FILE`) and the config `OP_WRITE_FILE` / `OP_MAKE_DIR` / `OP_SYMLINK` ops to the in-process `disk_backend` handlers instead of shelling out — same `SystemOp` values behind the same seam, different side-effect surface (the shell planners are untouched)
   - on failure, check `op_is_fatal(op)`; fatal ops record an error via `agnova_fail_phase()` and abort, non-fatal ones log a warning and continue
   - between phases, `agnova_advance_phase()` ratchets the state forward (refuses to advance past non-recoverable errors)

## Two backends: shell vs native

The same `PhaseOps` plan can be fulfilled two ways, selected by `--disk-backend`:

- **`shell`** (default) — the library never touches disk itself. `executor.cyr` translates each `SystemOp` into real syscalls or subprocesses (`parted` / `mkfs.*` / `tar` / `cryptsetup` / `bootctl` / `grub-install`, plus `sys_mount` / file writes). This is the proven, host-tool-dependent path; the plan comes from the shell planners in `partitioning.cyr` + `rootfs.cyr`.
- **`native-file` / `native-block`** — the disk is shaped **entirely in-process, with zero host tools** (no `parted` / `mkfs` / `tar` / `unzstd` / `chroot` / `grub` fork-exec). The plan comes from `disk_plan.cyr::plan_native_disk_ops`, and `execute_op` routes its ops to the `disk_backend.cyr` handlers, which drive `diskfmt.cyr`'s sovereign builders:
  - **GPT** — protective MBR + primary/backup header + 128-entry array (CRC32, UTF-16 names): a sized FAT32 ESP (partition 0) + an ext2 root filling to the last usable LBA (partition 1).
  - **FAT32 ESP** — BPB + FSInfo + dual FAT + `\EFI\BOOT` / `\boot` tree, with the bootloader + kernel staged in by cluster-chain writes.
  - **Sovereign multi-group ext2 root** — a journal-less mkfs (any size, per-group SB+GDT backups, double-indirect files, `lost+found`, symlinks) that the AGNOS kernel reads directly.
  - **Base-system extraction** — `--base-tarball <archive>` is untarred into the ext2 root through the shared **sankoch** tar cursor, which sniffs and inflates `.tar` / `.gz` / `.xz` / `.bz2` / `.zst` in RAM. With no tarball, a single `/bin/agnsh` is staged (the minimal boot-to-shell payload).
  - **Config into the image** — `/etc/fstab`, `hostname`, `hosts`, `resolv.conf`, `machine-id`, `locale.conf`, the `/etc/localtime` symlink, `nftables.conf`, IMA policy, sysctl hardening, and the `first-boot` marker are written straight into the ext2 image via `df_ext2_write_mem` / `df_ext2_mkdir_p` / `df_ext2_symlink_p` — no mount, no host fs. The shared config planners (`plan_network_ops` / `plan_locale_ops` / `plan_security_ops`) are reused with an empty `target_root`, so they emit root-relative paths (`/etc/fstab`, not `<mnt>/etc/fstab`).

`native-file` does file-offset sector I/O into a loopback image — the Linux-host proving target, which exercises 100% of the format logic on the dev box (validated by `sgdisk` / `fsck.fat` / `e2fsck` / `debugfs`). `native-block` drives `sys_blk_*` behind the arm-gate — the AGNOS-on-AGNOS target. The single target-gated seam is `diskfmt`'s sector primitive (`df_write` / `df_read`); everything else is target-agnostic.

**Still shell-only (deliberately omitted from the native plan):** user accounts (`useradd`/`usermod` → sovereign `/etc/passwd`,`/shadow`,`/group` gen is a follow-on), package install (`ark` into the offline image), and service enablement (`chroot argonaut enable`). Encryption, mount, packages, user, and cleanup phases are not emitted by `plan_native_disk_ops` — a native run completes 8 emitted phases with 0 errors.

## Install phases (in execution order)

The op counts below are the **shell** backend's full 13-phase plan. The **native** plan (`plan_native_disk_ops`) emits a leaner 8 phases — partition, format, install-base, network, locale, security, first-boot, bootloader — skipping the shell-only encryption / mount / packages / user / cleanup phases (see [Two backends](#two-backends-shell-vs-native)).

| # | Phase | Ops (Desktop, unencrypted) | Recoverable? |
|---|---|---|---|
| 0  | Validating configuration | 0 | yes |
| 1  | Partitioning disk | 5 | **no** |
| 2  | Setting up encryption | 0 (or 2 if `--encrypt`) | **no** |
| 3  | Formatting filesystems | 2 | **no** |
| 4  | Mounting filesystems | 4 | yes |
| 5  | Installing base system | 20 (mkdirs + tar + ark) | **no** |
| 6  | Installing packages | 1 (ark per mode) | yes |
| 7  | Configuring system | (network + locale, 7 ops) | yes |
| 8  | Installing bootloader | 4 (gnoboot, default) / 6 (systemd-boot) / 7 (GRUB2) | **no** |
| 9  | Creating user | 2 | yes |
| 10 | Setting up security | 4 (nftables + IMA + sysctl) | yes |
| 11 | Preparing first boot | 8 (Desktop) / 7 (Server) / 4 (Minimal) | yes |
| 12 | Cleaning up | 3 (or 4 with LUKS close) | yes |
| 13 | Installation complete | 0 | yes |

Default `agnova plan --device /dev/sda --user X` produces **60 operations** across 13 phases (the sovereign gnoboot bootloader phase is 4 ops vs systemd-boot's 6).

## SystemOp tagged union

`SystemOp` is the heart of the design. It's a sum type over nine side-effect descriptors — six shell/file ops plus three structured disk ops that the native backend fulfills in-process:

```
SystemOp = OP_COMMAND      | SystemOp_Command      { binary: Str, args: vec<Str>, description: Str, fatal, stdin: Str }
         | OP_WRITE_FILE   | SystemOp_WriteFile    { path: Str, content: Str, mode, owner: Str }
         | OP_MAKE_DIR     | SystemOp_MakeDir      { path: Str, mode, parents }
         | OP_SYMLINK      | SystemOp_Symlink      { target: Str, link: Str }
         | OP_MOUNT        | SystemOp_Mount        { device: Str, mount_point: Str, fs_type: Str, options }
         | OP_UNMOUNT      | SystemOp_Unmount      { mount_point: Str }
         | OP_PARTITION_DISK | SystemOp_PartitionDisk { layout }                                  # native: write GPT
         | OP_FORMAT_FS    | SystemOp_FormatFs     { part_index, spec, device: Str }              # native: FAT32 / ext2
         | OP_STAGE_FILE   | SystemOp_StageFile    { src_path: Str, dst_fat_path: Str, target_fs } # native: stage / untar
```

The three structured disk ops carry a `target_fs` / partition selector rather than a shell command; on the `shell` backend they never appear (the shell planners emit `Command`/`WriteFile`/… only), and on a native backend `execute_op` routes them to the `disk_backend` handlers. `op_untar_ext2(src)` is `op_stage_file(src, "/", STAGE_TARGET_UNTAR)`.

Cyrius lacks Rust's enum-with-payload syntax, so each variant is its own `#derive(accessors)` struct, and the union is realized as `tagged_new(TAG, &payload_struct)` from `lib/tagged.cyr`. Read with `tag(op)` + `payload(op)` and the auto-generated accessors (`SystemOp_Command_binary(p)`, etc.).

See [docs/adr/0001-port-to-cyrius.md](../adr/0001-port-to-cyrius.md) for the full reasoning behind the port and the design decisions made along the way.

## What's NOT here yet

- **Test suite** — the Rust scaffold's 1398 LOC of unit tests have not been ported to `tests/agnova.tcyr`. Smoke testing happens via the CLI itself (`agnova plan --verbose`).
- **Resumable installs** — the orchestrator records phase progression in memory but does not checkpoint to disk. A crash during execution requires a restart from PHASE_VALIDATE_CONFIG.
- **Hardware detection** — no probing of disk layout, RAM size, CPU features. The user supplies `--device` explicitly.
- **TUI / interactive mode** — flag-driven only.
- **JSON status output** — `#derive(Serialize)` is wired up on flat structs (`SecurityConfig`, `InstallProgress`, `InstallError`, `IsoConfig`) but no subcommand emits machine-readable status yet.
