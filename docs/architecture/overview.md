# agnova architecture

## Consumers

End users running the AGNOS installer on new hardware (live USB → guided install).

## Design philosophy

**Plan first, execute second.** Every action the installer can perform is described as a `SystemOp` value. The library has zero side effects — building an `InstallConfig` and calling `full_execution_plan()` produces a `vec<PhaseOps>` of pure data structures. Only `executor.cyr` translates those descriptors into real syscalls / subprocess calls, and only the CLI's `execute` subcommand (with explicit `--i-mean-it`) ever invokes it.

This separation gives us:
- **Trivial dry-run**: `agnova plan --verbose` dumps the entire install as ordered shell-equivalent commands
- **Easy testing**: planners are pure; tests assert plan shape without touching disk
- **Safe iteration**: structural changes (new phases, new ops) are reviewable as plan diffs before they're executable

## Module map

```
src/
├── types.cyr         (687 LOC)  enums + structs + SystemOp + factories + IsoConfig
├── helpers.cyr       (166 LOC)  machine-id, fstab, hostname, kernel params
├── validation.cyr    (406 LOC)  28 hard checks + 3 warning categories
├── partitioning.cyr  (271 LOC)  parted / mkfs / cryptsetup planners
├── rootfs.cyr        (990 LOC)  mount, packages, bootloader, user, network, locale, security, first-boot, cleanup planners
├── orchestrator.cyr  (156 LOC)  AgnovaInstaller state machine
├── executor.cyr      (254 LOC)  SystemOp dispatchers (the only side-effect surface)
├── cli.cyr           (488 LOC)  flag parsing + subcommand dispatch
└── main.cyr          ( 22 LOC)  thin entry point
```

Total: ~3,440 LOC of Cyrius (vs 3,656 LOC of Rust scaffold, excluding tests).

### Dependency graph (compilation order, leaf at top)

```
types
  ├── helpers       (uses Str, vec, SecurityConfig accessors)
  ├── validation    (uses InstallConfig accessors, enum values)
  ├── partitioning  (uses SystemOp factories, DiskLayout, PartitionSpec)
  └── rootfs        (uses everything above + helpers + partitioning::partition_device)
        └── orchestrator  (uses AgnovaInstaller state + InstallProgress + InstallError)
              └── executor    (uses SystemOp accessors, AgnovaInstaller log/errors)
                    └── cli         (uses every public symbol)
                          └── main  (calls cli_main)
```

`include "src/<name>.cyr"` from `main.cyr` in dependency order — Cyrius does textual inclusion, so file order matters.

## Data flow

1. **CLI parses flags** → `_config_from_flags(h)` builds an `InstallConfig` from `--device`, `--user`, `--mode`, etc.
2. **Validation** → `validate_config(cfg)` returns `Ok(warnings)` or `Err(message)` (tagged-union via `lib/tagged.cyr`).
3. **Plan generation** → `full_execution_plan(cfg, target_root, luks_passphrase)` returns `vec<PhaseOps>`. Each phase is independent; the orchestrator runs them sequentially.
4. **For `plan` subcommand**: pretty-print every `PhaseOps` (and every `SystemOp` inside if `--verbose`).
5. **For `execute` subcommand**: build an `AgnovaInstaller`, then `execute_all(inst, plans)` walks each phase. Per op:
   - dispatch on `tag(op)` → call `_exec_<variant>(payload(op))`
   - on failure, check `op_is_fatal(op)`; fatal ops record an error via `agnova_fail_phase()` and abort, non-fatal ones log a warning and continue
   - between phases, `agnova_advance_phase()` ratchets the state forward (refuses to advance past non-recoverable errors)

## Install phases (in execution order)

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
| 8  | Installing bootloader | 6 (systemd-boot) or 7 (GRUB2) | **no** |
| 9  | Creating user | 2 | yes |
| 10 | Setting up security | 4 (nftables + IMA + sysctl) | yes |
| 11 | Preparing first boot | 8 (Desktop) / 7 (Server) / 4 (Minimal) | yes |
| 12 | Cleaning up | 3 (or 4 with LUKS close) | yes |
| 13 | Installation complete | 0 | yes |

Default `agnova plan --device /dev/sda --user X` produces **62 operations** across 13 phases.

## SystemOp tagged union

`SystemOp` is the heart of the design. It's a sum type over six side-effect descriptors:

```
SystemOp = OP_COMMAND   | SystemOp_Command   { binary: Str, args: vec<Str>, description: Str, fatal, stdin: Str }
         | OP_WRITE_FILE| SystemOp_WriteFile { path: Str, content: Str, mode, owner: Str }
         | OP_MAKE_DIR  | SystemOp_MakeDir   { path: Str, mode, parents }
         | OP_SYMLINK   | SystemOp_Symlink   { target: Str, link: Str }
         | OP_MOUNT     | SystemOp_Mount     { device: Str, mount_point: Str, fs_type: Str, options }
         | OP_UNMOUNT   | SystemOp_Unmount   { mount_point: Str }
```

Cyrius lacks Rust's enum-with-payload syntax, so each variant is its own `#derive(accessors)` struct, and the union is realized as `tagged_new(TAG, &payload_struct)` from `lib/tagged.cyr`. Read with `tag(op)` + `payload(op)` and the auto-generated accessors (`SystemOp_Command_binary(p)`, etc.).

See [docs/adr/0001-port-to-cyrius.md](../adr/0001-port-to-cyrius.md) for the full reasoning behind the port and the design decisions made along the way.

## What's NOT here yet

- **Test suite** — the Rust scaffold's 1398 LOC of unit tests have not been ported to `tests/agnova.tcyr`. Smoke testing happens via the CLI itself (`agnova plan --verbose`).
- **Resumable installs** — the orchestrator records phase progression in memory but does not checkpoint to disk. A crash during execution requires a restart from PHASE_VALIDATE_CONFIG.
- **Hardware detection** — no probing of disk layout, RAM size, CPU features. The user supplies `--device` explicitly.
- **TUI / interactive mode** — flag-driven only.
- **JSON status output** — `#derive(Serialize)` is wired up on flat structs (`SecurityConfig`, `InstallProgress`, `InstallError`, `IsoConfig`) but no subcommand emits machine-readable status yet.
