# agnova

> The guided OS installer for [AGNOS](https://github.com/MacCracken/agnosticos).

`agnova` partitions disks, optionally encrypts the root volume with LUKS, deploys the AGNOS base system, installs mode-specific packages, lays down the sovereign bootloader (gnoboot by default; systemd-boot / GRUB 2 optional), creates the initial user, configures network/locale/security, and prepares first-boot — all from a single command.

The installer is **plan-first**: every action is materialized as a `SystemOp` descriptor and the orchestrator can dump the entire plan before touching disk. Destructive execution is gated behind an explicit `--i-mean-it` flag.

- **Type**: Binary (Cyrius)
- **License**: GPL-3.0-only
- **Toolchain**: Cyrius 6.4.39
- **Version**: 0.5.0

## Build

```sh
cyrius deps                                    # resolve stdlib deps
cyrius build src/main.cyr build/agnova        # compile
./build/agnova version                         # smoke test
```

## Usage

```
agnova <COMMAND> [OPTIONS]

COMMANDS:
  plan        Build + print the install plan (no side effects)
  validate    Run config validation; print errors + warnings
  execute     Execute the plan (DESTRUCTIVE — requires --i-mean-it)
  version     Print agnova + cyrius toolchain version
  help        Print this help

OPTIONS:
  -d, --device DEV         Target block device (e.g. /dev/sda)
  -u, --user NAME          Username for the new user account
  -m, --mode MODE          server|desktop|minimal|custom (default: desktop)
      --hostname NAME      Hostname (default: agnos)
  -t, --target ROOT        Target root mount point (default: /mnt)
  -b, --bootloader BL      gnoboot|systemd|grub2 (default: gnoboot)
      --locale L           System locale (default: en_US.UTF-8)
      --timezone TZ        System timezone (default: UTC)
      --encrypt            Enable LUKS root encryption
      --passphrase PASS    LUKS passphrase (required for execute if --encrypt)
  -v, --verbose            Print every operation, not just per-phase summaries
      --i-mean-it          Required to actually execute (DESTRUCTIVE)
      --help               Print this help
```

### Examples

Inspect the plan for a default Desktop install on `/dev/sda`:

```sh
agnova plan --device /dev/sda --user alice
```

Full per-operation dump (every parted/mkfs/mount/write call):

```sh
agnova plan --device /dev/nvme0n1 --user alice --mode server --encrypt --verbose
```

Validate a config without printing the plan:

```sh
agnova validate --device /dev/sda --user alice --hostname agnos-laptop
```

Execute (will partition + format `/dev/sda`, ALL DATA LOST):

```sh
agnova execute --device /dev/sda --user alice --i-mean-it
```

## Architecture

13 ordered install phases, each materialized as a `PhaseOps { phase, description, operations: vec<SystemOp> }`. `SystemOp` is a tagged union over six action variants (Command / WriteFile / MakeDir / Symlink / Mount / Unmount). The library never touches disk itself — `executor.cyr` is the sole side-effect surface, gated behind the CLI's `--i-mean-it` flag.

- `src/types.cyr` — enums, structs, `SystemOp` variants, factories, `IsoConfig`
- `src/helpers.cyr` — pure generators (machine-id v4, fstab, hostname, kernel params)
- `src/validation.cyr` — 28 config checks with shell-injection guards
- `src/partitioning.cyr` — partition / format / encryption phase planners
- `src/rootfs.cyr` — mount / install / bootloader / user / network / locale / security / first-boot / cleanup planners
- `src/orchestrator.cyr` — `AgnovaInstaller` state machine (phase advancement, recoverable vs non-recoverable failures)
- `src/executor.cyr` — `SystemOp` dispatchers (fork+exec, file I/O, mount/umount syscalls)
- `src/cli.cyr` — flag parsing + subcommand dispatch
- `src/main.cyr` — thin entry point

See [docs/architecture/overview.md](docs/architecture/overview.md) for the data flow + module map, and [docs/adr/](docs/adr/) for design decisions.

## License

GPL-3.0-only. See [LICENSE](LICENSE).
