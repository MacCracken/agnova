# ADR 0001: Port agnova from Rust scaffold to Cyrius

- **Status**: Accepted
- **Date**: 2026-04-26
- **Author**: Robert MacCracken

## Context

The original agnova scaffold (commit `4729df8`) was 3,656 LOC of Rust: pure planner code that materialized the install pipeline as `Vec<SystemOp>` descriptors. The Rust version compiled, had ~1,400 LOC of unit tests, and exercised a clean serde-based configuration API.

The AGNOS project as a whole is migrating its first-party tooling to **Cyrius** — a sovereign self-hosting systems language that bootstraps from a 29 KB binary seed with no Rust, LLVM, or Python in the toolchain. Sister projects `ark` (package manager) and `kavach` (security/sandboxing) are already ported (currently public at 0.8.0).

Continuing to ship agnova in Rust would have meant:
1. Carrying a full Rust toolchain dependency for AGNOS first-party tooling
2. Diverging from the rest of the ecosystem on type system, build process, and stdlib
3. Doubling maintenance: `ark`/`kavach` in Cyrius, agnova in Rust

## Decision

Port agnova to Cyrius 5.7.12 using `cyrius port` to scaffold and then a module-by-module manual translation. Move the Rust source to `rust-old/` for reference and git history. Build a real CLI on top of the planner (the Rust scaffold had only a library, no entry point).

### Translation rules established during the port

| Rust construct | Cyrius representation |
|---|---|
| `enum E { A, B }` (no payload) | `enum E { PREFIX_A = 0; PREFIX_B = 1; }` — prefix to avoid global namespace collisions |
| `enum E { A(x, y), B(z) }` (payload) | Tag enum + per-variant `#derive(accessors)` struct + factory fn returning `tagged_new(TAG, &payload_struct)` from `lib/tagged.cyr` |
| `Option<String>` | `Str` field; empty `Str` (`str_len(s) == 0`) is the `None` sentinel |
| `Option<u64>` | Two `i64` fields: `value` + `has_value` (0/1). Cannot use Cyrius `Option` (tagged) inside derived structs |
| `Vec<T>` | `vec` ptr from `lib/vec.cyr`; `vec_new`/`vec_push`/`vec_get`/`vec_len` |
| `f32` / `f64` | `i64` basis points (0..10000 for 0.0..1.0). No `f32`; `#derive(Serialize)` doesn't emit `f64` |
| `chrono::DateTime<Utc>` | `i64` unix seconds via `lib/chrono.cyr::clock_epoch_secs()` |
| `String` | `Str` (struct from `lib/str.cyr`); annotate fields `: Str` so `#derive(Serialize)` quotes them properly |
| `bool` | `i64` (0/1). No bool primitive |
| `impl Display for E` | `fn e_str(e) { ... return "..."; }` returning a cstr literal |
| `impl Default for T` | `fn t_default() { ... }` factory |
| `#[serde(skip)]` | **Move the field out of the serialized struct entirely** (e.g., agnova's `luks_passphrase` lives on the orchestrator, not on `DiskLayout`) |
| `bail!(msg)` (anyhow) | `return Err(Str-cast-to-i64)` from `lib/tagged.cyr`, then `is_ok(r)` / `payload(r)` at the call site |

### Deliberate simplifications

- **No JSON serialization in production paths.** `#derive(Serialize)` is wired up on flat structs that have it for free, but no subcommand consumes it. Vec fields and nested struct pointers don't roundtrip cleanly through derive; we sidestep the issue by not serializing.
- **Mount options simplified to flags=0.** Agnova only ever emits `["defaults"]` — translating to `MS_*` flag bits + comma-separated data is unnecessary today. Documented as a v0.2.0 cleanup item.
- **`luks_passphrase` is held by the orchestrator, not `DiskLayout`.** Mirrors `#[serde(skip)]` semantics structurally instead of via attribute. Side benefit: the planner's `plan_encryption_ops(cfg, luks_passphrase)` signature makes the dependency explicit at the type level.

## Consequences

### Positive

- **Sovereign toolchain.** Build is `cyrius build`; no rustc, no cargo registry, no LLVM. Matches `ark`/`kavach`/`shakti`/etc.
- **2,781 LOC of Cyrius** vs **3,656 LOC of Rust** (excl. tests; incl. ~100-line CLI smoke that didn't exist in Rust). Net-negative LOC because Cyrius doesn't need `Display`/`Default`/`Debug`/`Clone` impl boilerplate.
- **`#derive(accessors)`** generates type-safe getters/setters; eliminates ~150 hand-written field accessors.
- **`#derive(Serialize)`** generates `Type_to_json(p, sb)` and `Type_from_json_str(s)` for all-scalar/all-Str structs, ready when we want machine-readable status output.
- **The planner is genuinely pure** — building a plan never opens a file, never spawns a process, never touches a syscall outside the test harness. Refactoring confidence is high.
- **A real CLI now exists** (Rust scaffold had only a library). `agnova plan --verbose` is immediately useful for debugging install configs.

### Negative / costs

- **No closures / iterator chains.** Every transformation is a hand-rolled `while` loop. Sorting partitions by mount-depth requires a manual `(idx, depth)` 16-byte struct + insertion sort. ~100 extra LOC across the planners.
- **`#derive(Serialize)` doesn't handle `vec` or pointer fields.** For real JSON of complex structs (e.g., serializing an `InstallResult` containing a `vec<InstallError>`), we'll need manual `_to_json` writers. Deferred to v0.2.0+.
- **No `&&` / `||` mix in same condition.** Every conditional with multiple terms is a nested `if`. Verbose but consistent.
- **No string interpolation, no `format!`.** Every dynamic string is a `str_builder_new() + str_builder_add_*() + str_builder_build()` chain. ~5x the lines of equivalent Rust `format!` calls.
- **`cyrius check` defaults to standalone** (no stdlib resolution). Easy gotcha — `cyrius build` or `cyrius check --with-deps` is what you want.
- **The Cyrius stdlib's `args.cyr::args_init()`** stores `&buf` from a stack-allocated buffer into a global; works in practice but is technically dangling. We materialize argv into a heap array immediately after parsing to dodge the issue.
- **No `getrandom` syscall wrapper** in stdlib `syscalls.cyr`. We read from `/dev/urandom` for UUID generation (portable + clean).
- **No `sys_symlink` wrapper.** Shell-out to `ln -sfT` from the executor. Fine; symlinks are install-time, perf-irrelevant.

### Reversible?

The Rust source remains intact in `rust-old/` and the original commit (`4729df8`) is on `main`. The git history is preserved. If the Cyrius port hits an irrecoverable wall (toolchain instability, missing primitive, perf disaster on real installs), we can `git revert` the port and resume Rust development with no data loss. The cost would be the LOC of the CLI we wrote on top of the planner — about 700 LOC of CLI + executor work.

## Status of the port (post-decision)

- ✅ Library: complete + builds clean
- ✅ CLI: complete (plan / validate / execute / version / help) + builds clean
- ✅ Executor: implemented; **not yet end-to-end tested on hardware**
- ⏳ Test suite: not yet ported (1398 LOC of Rust tests pending)
- ⏳ Hardware integration test: gates the v0.2.0 release

See [docs/development/roadmap.md](../development/roadmap.md) for the v0.2.0 / v1.0 plan.
