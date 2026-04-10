# Project Decisions

Human-readable summary of the current repo-level decisions that are also tracked in OMX memory.

This file is intended to help operators and future contributors understand the current stable paths, experimental lanes, and recent workflow decisions without needing OMX tooling.

---

## Stable vs Experimental Paths

### Stable

- `test/fulltest.sh`
  - Stable production GPU validation path.
  - Avoid heavy in-place flow refactors unless they have been validated on real Linux GPU hosts.

- `test/disktest.sh`
  - Current disk validation path.
  - Interactive by default on a TTY.
  - Supports `--non-interactive` for automation.

### Experimental

- `test/gpu-fulltest-v2.sh`
  - Experimental prepare-then-run variant of `test/fulltest.sh`.
  - Used as the safe lane for structural refactors to GPU validation flow.
  - Should be validated on real GPU hosts before replacing `test/fulltest.sh`.

---

## Current Decisions

### 1. Do not heavily restructure `test/fulltest.sh` in place

Reason:

- `fulltest.sh` is an operational validation script, so regression risk is more important than internal architectural neatness.
- If the GPU validation flow needs broader structural experimentation, do it in `test/gpu-fulltest-v2.sh` first.

### 2. `disktest.sh` is operator-first on TTYs

Current behavior:

- guided interactive mode on TTY by default
- `--non-interactive` preserved for automation
- interactive mode selection
- checkbox-style disk selection
- per-disk reports written under the run log directory

### 3. Build-tree permission problems should fail early

Current behavior in `fulltest.sh`:

- warns early if build trees or cloned repos are root-owned or otherwise unwritable
- gives ownership-fix guidance before later rebuild / clean steps fail more opaquely

---

## Operator Notes

### `disktest.sh`

Interactive disk picker controls:

- `↑` / `↓` — move
- `Space` — check / uncheck focused disk
- `Enter` — confirm selection
- `a` — select all / deselect all
- `q` — cancel

Per-disk reports are written under:

```text
<log-dir>/reports/
```

### `gpu-fulltest-v2.sh`

Current design goal:

1. detect
2. prepare selected tests
3. run selected tests
4. summarize prepare + test results separately

This script has mocked verification evidence for the prepare-then-run flow, but it should still be treated as experimental until exercised on real GPU hosts.

---

## Recent Validation Notes

- `disktest.sh`
  - verified with syntax checks and Dockerized Linux/Bash runs
  - interactive dry-run flow and health JSON/report output exercised

- `fulltest.sh`
  - permission warning refinements verified with syntax checks and Dockerized non-root unwritable-build scenarios

- `gpu-fulltest-v2.sh`
  - verified with syntax/help output
  - verified in a mocked container flow where prepare succeeds before execution
  - verified in a mocked container flow where prepare failure stops execution early

---

## Practical Guidance

- Use `test/fulltest.sh` for current real validation work.
- Use `test/gpu-fulltest-v2.sh` only for experimental flow evaluation.
- Keep changes to validation scripts small and evidence-driven unless working in the experimental lane.
