# Contributing to agnova

Thanks for considering a contribution. agnova is the AGNOS guided OS installer; changes here can corrupt disks, so contributions are reviewed conservatively.

## Before you start

- Read [docs/architecture/overview.md](docs/architecture/overview.md) — understand the plan/execute split and the `SystemOp` tagged union before changing anything in `src/`.
- Read [CLAUDE.md](CLAUDE.md) — the project's working agreement, especially the "DO NOT" section (no destructive ops without confirmation, no `gh` CLI, etc.).
- Skim the latest [CHANGELOG.md](CHANGELOG.md) to see what's recently shipped.

## Build & test

```sh
cyrius deps                                  # resolve stdlib deps (one-time)
cyrius build src/main.cyr build/agnova      # build
cyrius lint src/main.cyr                     # lint (must report 0 errors)
./build/agnova plan --device /dev/sda --user test    # smoke
```

End-to-end testing requires disposable hardware or a loopback file. Do **not** test `agnova execute` on a host you care about.

## Working loop (per CLAUDE.md)

1. Make the change
2. `cyrius lint <touched files>` — must be clean
3. Add tests for new behavior (when the test suite exists; v0.2.0+)
4. Update `CHANGELOG.md` with a one-line entry under `[Unreleased]`
5. Update relevant docs (`docs/architecture/overview.md` if module shape changed; new ADR in `docs/adr/` if a hard-to-reverse decision was made)

## Commits & PRs

- The user (Robert MacCracken) handles all git operations. Don't push, don't open PRs without explicit instruction.
- Commit messages follow the Cyrius repo style: short imperative subject, optional body explaining the *why*, not the *what*.

## Reporting bugs

Open an issue on GitHub with: agnova version (`agnova version`), Cyrius toolchain version, the exact command run, the full output, and the relevant section of the install log if execution failed.

## License

By contributing, you agree your work is released under [GPL-3.0-only](LICENSE).
