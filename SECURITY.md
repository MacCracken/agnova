# Security policy

## Reporting a vulnerability

Email **robert.maccracken@gmail.com** with subject prefix `[agnova security]`. Please **do not** open a public GitHub issue for security reports until a fix is shipped.

A response acknowledging the report will follow within 7 days.

## Supported versions

agnova is pre-1.0; only the latest released version receives security updates. Once v1.0 ships, this policy will be updated to commit to a longer support window.

## Scope

agnova partitions disks, sets up LUKS encryption, installs system packages, and configures the bootloader — the entire surface is security-relevant. Reports of particular interest:

- **Shell injection** via any field passed to `parted`, `mkfs.*`, `cryptsetup`, `mount`, `useradd`, `chroot`, `bootctl`, `grub-install`, `xorriso`, etc. Validation in `src/validation.cyr` should catch these at config time; a bypass is high-severity.
- **LUKS passphrase handling** — `luks_passphrase` is held only by the orchestrator and piped via stdin to `cryptsetup`. Reports of leakage to disk, logs, env vars, or the planner output are high-severity.
- **Kernel command-line injection** — `validate_config` rejects `init=`, `rd.break`, `single`, `rescue`, `break=`, and the shell metacharacters `| ; & ` `` ` `` ` \n`. Bypass is high-severity.
- **Privilege escalation** via the `--user` / `--passphrase` paths.
- **Plan/execute divergence** — any case where `agnova plan` shows one set of operations but `agnova execute` performs a different set is a correctness + security bug.

## Out of scope

- Destruction of data on a device the operator explicitly named with `--device` and `--i-mean-it`. That's the documented behavior, not a vulnerability.
- Bugs that require local root access to exploit (you already have full control).
- Vulnerabilities in dependencies (Cyrius stdlib, the kernel, parted, mkfs, etc.) — please report those upstream.
