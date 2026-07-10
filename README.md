# agnova

> The guided OS installer for [AGNOS](https://github.com/MacCracken/agnosticos).

`agnova` partitions disks, optionally encrypts the root volume with LUKS, deploys the AGNOS base system, installs mode-specific packages, lays down the sovereign bootloader (gnoboot by default; systemd-boot / GRUB 2 optional), creates the initial user, configures network/locale/security, and prepares first-boot — all from a single command.

The installer is **plan-first**: every action is materialized as a `SystemOp` descriptor and the orchestrator can dump the entire plan before touching disk. Destructive execution is gated behind an explicit `--i-mean-it` flag.

- **Type**: Binary (Cyrius)
- **License**: GPL-3.0-only
- **Toolchain**: Cyrius 6.4.43
- **Version**: 0.7.0

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

  Native (sovereign) backend — shape the disk entirely in-process, no host tools:
      --disk-backend B     shell|native-file|native-block (default: shell)
      --base-tarball PATH  Base-system archive extracted into the ext2 root
                           (.tar / .gz / .xz / .bz2 / .zst; envelope sniffed)
      --gnoboot-src PATH   BOOTX64.EFI source staged into the ESP
      --kernel-src PATH    Kernel source staged into the ESP (\boot\agnos)
      --agnsh-src PATH     /bin/agnsh source (used when --base-tarball is absent)
      --until PHASE        Stop after PHASE (e.g. bootloader)
      --scratch-base LBA   Write into the disk tail at LBA (imaging affordance)
      --disk-sectors N     Override the layout disk size (sectors)
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

13 ordered install phases, each materialized as a `PhaseOps { phase, description, operations: vec<SystemOp> }`. `SystemOp` is a tagged union over nine action variants — six shell/file (Command / WriteFile / MakeDir / Symlink / Mount / Unmount) plus three structured disk ops (PartitionDisk / FormatFs / StageFile). On the default **shell** backend the library never touches disk itself — `executor.cyr` shells out (parted/mkfs/tar/grub) and is the sole side-effect surface. On a **native** backend (`--disk-backend native-file|native-block`) it shapes the disk entirely in-process — GPT + FAT32 ESP + sovereign multi-group ext2 root + base-system extraction + config, no host tools. Both are gated behind the CLI's `--i-mean-it` flag.

- `src/types.cyr` — enums, structs, `SystemOp` variants, factories, `IsoConfig`
- `src/helpers.cyr` — pure generators (machine-id v4, fstab, hostname, kernel params)
- `src/validation.cyr` — 28 config checks with shell-injection guards
- `src/partitioning.cyr` — partition / format / encryption phase planners (shell)
- `src/rootfs.cyr` — mount / install / bootloader / user / network / locale / security / first-boot / cleanup planners (shell)
- `src/diskfmt.cyr` — sovereign disk builders: GPT, FAT32 ESP, multi-group ext2 writer + sankoch untar sink (raw sector I/O)
- `src/disk_backend.cyr` — native backend selector + op handlers (partition / format / stage / ext2 file-sink), no fork-exec
- `src/disk_plan.cyr` — the native (sovereign) install-plan builder (reuses the config planners for the ext2 root)
- `src/orchestrator.cyr` — `AgnovaInstaller` state machine (phase advancement, recoverable vs non-recoverable failures)
- `src/executor.cyr` — `SystemOp` dispatchers (shell fork+exec + file I/O, or the native ext2 sink on a native backend)
- `src/cli.cyr` — flag parsing + subcommand dispatch
- `src/main.cyr` — thin entry point

See [docs/architecture/overview.md](docs/architecture/overview.md) for the data flow + module map, and [docs/adr/](docs/adr/) for design decisions.

## License

GPL-3.0-only. See [LICENSE](LICENSE).
