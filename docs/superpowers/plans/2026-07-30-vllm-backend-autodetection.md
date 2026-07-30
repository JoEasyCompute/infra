# vLLM Backend Autodetection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `--backend auto` the default and resolve exactly one usable NVIDIA or AMD backend before profile-independent command construction.

**Architecture:** Add a small backend detector ahead of existing backend defaults. Explicit backends bypass detection, while auto mode checks vendor inventory read-only and writes the resolved backend into the existing `BACKEND` variable so all downstream image, device, metadata, and lifecycle code remains unchanged.

**Tech Stack:** Bash, `nvidia-smi`, `rocminfo`, mocked shell regression harness.

## Global Constraints

- `--backend auto` is the default.
- NVIDIA detection requires `nvidia-smi` and at least one reported GPU index.
- AMD detection requires `rocminfo`, at least one `gfx*` agent, `/dev/kfd`, and `/dev/dri`.
- Mixed and undetected hosts fail with actionable explicit-backend guidance.
- Explicit `--backend nvidia|amd --dry-run` remains hardware-free.
- Profiles, pinned images, GPU selection, and tensor parallelism remain unchanged.
- Dry-run does not call Docker, download anything, or create files.

---

### Task 1: Lock Backend Resolution Behavior

**Files:**
- Modify: `test/vllm-benchmark-static-test.sh`
- Test: `test/vllm-benchmark-static-test.sh`

**Interfaces:**
- Consumes: existing fake vendor commands and `VLLM_BENCHMARK_DEVICE_ROOT`.
- Produces: NVIDIA-only, AMD-only, mixed, and undetected auto-backend regressions.

- [ ] **Step 1: Make existing command-inspection dry-runs explicit**

Add `--backend nvidia` to NVIDIA dry-run tests and retain `--backend amd` for
AMD tests so those cases continue to prove hardware-free explicit behavior.

- [ ] **Step 2: Add mocked auto-detection tests**

Use isolated fake `PATH` directories to prove:

```text
NVIDIA only -> Backend: nvidia
AMD only -> Backend: amd
both -> non-zero with explicit --backend guidance
neither -> non-zero before Docker or output creation
```

- [ ] **Step 3: Run the static suite and confirm red**

Run:

```bash
bash test/vllm-benchmark-static-test.sh
```

Expected: FAIL because the wrapper still defaults directly to NVIDIA.

---

### Task 2: Resolve Auto Before Existing Backend Defaults

**Files:**
- Modify: `test/vllm-benchmark-test.sh`
- Test: `test/vllm-benchmark-static-test.sh`

**Interfaces:**
- Consumes: requested `BACKEND`, vendor tools, and AMD device root.
- Produces: resolved `BACKEND` equal to `nvidia` or `amd`.

- [ ] **Step 1: Change the CLI default**

Initialize `BACKEND=auto`, list `auto|nvidia|amd` in help, and keep explicit
parser behavior unchanged.

- [ ] **Step 2: Implement vendor probes**

Add `nvidia_backend_detected` and `amd_backend_detected` functions. Vendor
probe failures return false without terminating under `set -e`.

- [ ] **Step 3: Implement `resolve_backend`**

For explicit values, return immediately. For `auto`, evaluate both probes and
set `BACKEND` only when exactly one succeeds. Reject unsupported values, mixed
hosts, and undetected hosts with distinct messages.

- [ ] **Step 4: Resolve before image defaults and validation**

Call:

```bash
resolve_backend
apply_backend_defaults
```

before argument validation and dry-run command rendering.

- [ ] **Step 5: Run syntax and lifecycle tests**

Run:

```bash
bash -n test/vllm-benchmark-test.sh test/vllm-benchmark-static-test.sh
bash test/vllm-benchmark-static-test.sh
```

Expected: PASS.

---

### Task 3: Update Documentation And Memory

**Files:**
- Modify: `README.md`
- Modify: `docs/vllm-benchmark-test.md`
- Modify: `docs/project-decisions.md`
- Modify: `.omx/project-memory.json`

**Interfaces:**
- Consumes: final CLI behavior.
- Produces: operator guidance for default detection and explicit dry-runs.

- [ ] **Step 1: Document auto selection**

Explain detection requirements, mixed-host failure, and explicit overrides.

- [ ] **Step 2: Update examples**

Use default auto mode for provisioned-host runs and explicit backends for
hardware-free dry-run examples.

- [ ] **Step 3: Record the decision**

Record that the resolved backend, rather than the requested `auto` value, is
persisted in metadata.

- [ ] **Step 4: Validate docs and memory**

Run:

```bash
python3 -m json.tool .omx/project-memory.json >/dev/null
rg -n "backend auto|autodetect|mixed" \
    README.md docs/vllm-benchmark-test.md docs/project-decisions.md .omx/project-memory.json
```

Expected: JSON parses and behavior is discoverable.

---

### Task 4: Final Verification And Review

**Files:**
- Review: all files changed in Tasks 1-3.

**Interfaces:**
- Consumes: implementation and documentation.
- Produces: fresh completion evidence.

- [ ] **Step 1: Run full static verification**

Run syntax, the full mocked lifecycle suite, JSON validation, and
`git diff --check`.

- [ ] **Step 2: Inspect explicit dry-runs**

Render both backend commands explicitly on the development host and confirm
profiles remain unchanged.

- [ ] **Step 3: Request independent review**

Review argument resolution, failure behavior under `set -euo pipefail`,
hardware-free test isolation, and documentation accuracy.

- [ ] **Step 4: Report hardware gap**

State that actual vendor detection and container execution still require real
NVIDIA and AMD hosts.
