# network-batch.sh

SSH-orchestrated batch helper for `network-test.sh`.

This script is intended for client acceptance and fleet validation where you want to:

- limit a run to the first `N` clients
- test neighbour chains
- test parallel disjoint pairs
- rotate pairings across multiple rounds
- stay within a rack / pod / switch group
- test across selected groups
- run the same validation within every discovered group automatically
- export the planned matrix before execution

The script lives at:

- `test/network-batch.sh`

It is implemented in Python 3 and wraps:

- `test/network-test.sh`

---

## Requirements

| Requirement | Notes |
|---|---|
| `python3` | Required to run the helper |
| `ssh` | Used for remote orchestration |
| Passwordless SSH | Recommended for batch runs |
| `sudo` on remote nodes | Needed to run `network-test.sh` |
| `network-test.sh` on remote nodes | Default remote path: `/opt/provision/network-test.sh` |

---

## Host File Format

Each non-comment line is:

```text
ssh_host [target_ip] [group]
```

Example:

```text
node01 10.0.0.11 rack-a
node02 10.0.0.12 rack-a
node03 10.0.0.13 rack-b
node04 10.0.0.14 rack-b
```

Field meaning:

- column 1: SSH endpoint
- column 2: optional network target IP passed to `network-test.sh`
- column 3: optional grouping label such as rack, pod, or switch domain

Defaults:

- if column 2 is omitted, `ssh_host` is reused as `target_ip`
- if column 3 is omitted, the group is `default`

---

## Usage

```bash
./test/network-batch.sh --hosts FILE [OPTIONS]
```

Main options:

| Option | Description |
|---|---|
| `--mode chain` | Sequential `1 -> 2 -> 3 -> 4` |
| `--mode pairs` | Parallel disjoint pairs `1 -> 2`, `3 -> 4`, `5 -> 6` |
| `--mode rotate` | Multiple rounds of rotated disjoint pairs |
| `--clients N` | Use only the first `N` hosts from the file |
| `--rounds N` | Limit rotation rounds |
| `--group-mode all` | Ignore groups |
| `--group-mode within` | Only allow same-group pairs |
| `--group-mode across` | Only allow cross-group pairs |
| `--groups a,b,c` | Filter the host list to selected groups |
| `--within-each-group` | Run the selected mode separately within each discovered group |
| `--port PORT` | iperf3 port passed through to `network-test.sh` |
| `--duration SEC` | Duration per client run |
| `--stress` | Add `--stress` to `network-test.sh` |
| `--remote-script PATH` | Remote path to `network-test.sh` |
| `--ssh-user USER` | SSH username |
| `--server-warmup SEC` | Wait after starting each remote server |
| `--result-dir DIR` | Summary output directory |
| `--export-plan-json PATH` | Export planned matrix as JSON |
| `--export-plan-csv PATH` | Export planned matrix as CSV |
| `--plan-only` | Export plan and exit without running batches |
| `--dry-run` | Print the commands that would be run |

---

## Examples

### Chain test on the first 12 hosts

```bash
./test/network-batch.sh --hosts hosts.txt --clients 12 --mode chain --dry-run
```

### Parallel pairs on the first 24 hosts

```bash
./test/network-batch.sh --hosts hosts.txt --clients 24 --mode pairs --stress --dry-run
```

### Rotated pairings across selected groups

```bash
./test/network-batch.sh --hosts hosts.txt --mode rotate \
  --group-mode across --groups rack-a,rack-b \
  --rounds 3 --dry-run
```

### Run within each discovered group automatically

```bash
./test/network-batch.sh --hosts hosts.txt --mode rotate \
  --group-mode within --within-each-group \
  --rounds 2 --dry-run
```

### Export the matrix and stop

```bash
./test/network-batch.sh --hosts hosts.txt --mode rotate \
  --group-mode across --groups rack-a,rack-b \
  --rounds 2 --plan-only \
  --export-plan-json ./logs/network-batch/network-plan.json \
  --export-plan-csv ./logs/network-batch/network-plan.csv
```

---

## Execution Model

For each allowed pair, the helper:

1. starts `network-test.sh --server` on the destination host over SSH
2. waits `--server-warmup` seconds
3. runs `network-test.sh --client <target>` on the source host over SSH
4. stops the remote server process

In `pairs` and `rotate` modes, client-side executions for a batch are launched in parallel.

---

## Group Behaviour

### `--group-mode within`

Only same-group pairs are allowed.

Useful for:

- rack-local validation
- pod-local validation
- same-switch validation

### `--group-mode across`

Only cross-group pairs are allowed.

Useful for:

- rack-to-rack validation
- uplink / spine validation
- cross-pod validation

### `--within-each-group`

This requires `--group-mode within`.

Instead of filtering to one group and running the helper multiple times manually, the script:

- discovers all selected groups
- runs the selected mode independently inside each group
- skips groups with fewer than 2 hosts

---

## Plan Export

Plan export is intended for client review and sign-off before execution.

### JSON

`--export-plan-json` writes an array of objects including:

- `group`
- `round`
- `mode`
- `label`
- `src_host`
- `src_group`
- `dst_host`
- `dst_group`
- `target_ip`
- `allowed`
- `skip_reason`
- `port`
- `duration`
- `stress`

### CSV

`--export-plan-csv` writes the same information in flat tabular form.

### `--plan-only`

When `--plan-only` is used, the script:

- exports JSON and/or CSV if requested
- writes the normal summary file under `--result-dir`
- exits before any remote batch execution

---

## Output

The helper writes:

- a summary text file under `./logs/network-batch/` by default
- optional JSON / CSV plan exports wherever you specify

Recommended stable export paths:

```bash
./logs/network-batch/network-plan.json
./logs/network-batch/network-plan.csv
```

---

## Recommended Workflows

### First-pass rack validation

```bash
./test/network-batch.sh --hosts hosts.txt --mode rotate \
  --group-mode within --within-each-group \
  --rounds 2 --dry-run
```

### Cross-rack validation

```bash
./test/network-batch.sh --hosts hosts.txt --mode rotate \
  --group-mode across --groups rack-a,rack-b \
  --rounds 2 --dry-run
```

### Client sign-off package

```bash
./test/network-batch.sh --hosts hosts.txt --mode rotate \
  --group-mode across --groups rack-a,rack-b \
  --rounds 2 --plan-only \
  --export-plan-json ./logs/network-batch/network-plan.json \
  --export-plan-csv ./logs/network-batch/network-plan.csv
```

---

## See Also

- `docs/network-test.md`
- `docs/client-acceptance-test-kit.md`

