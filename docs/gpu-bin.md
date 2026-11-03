# gpu-bin.sh — unattended power-limit ladder and binning

`test/gpu-bin.sh` automates rungs 1–4 and 9 of the GPU diagnostic ladder for every NVIDIA GPU in a node. It climbs each card's power limit from the grade B floor to the card's default limit, survives GPUs falling off the bus by power-cycling itself through its own BMC, and writes one result row per card in the exact column order of the training tracker's GPU Ladder Log.

Physical rungs (reseat, riser and cable swaps, the swap test) are still done by hand.

## Requirements

- `fulltest.sh`, `code.sh` and `code.cu` in the same directory as `gpu-bin.sh` (or set `FULLTEST=`)
- `ipmitool`, with in-band IPMI working: `sudo ipmitool -I open mc info`
- The node idle: no miner, rental agent or container using the GPUs (the script refuses otherwise; `--force` overrides)
- **External GPU PSUs must power off with the main PSU.** If they are always-on, a chassis power cycle does not reset a dropped GPU.

## Usage

```bash
sudo ./test/gpu-bin.sh --dry-run       # show detected cards and their ladders
sudo ./test/gpu-bin.sh                 # start; continues across power cycles on its own
./test/gpu-bin.sh --status             # per-card progress
sudo ./test/gpu-bin.sh --resume        # continue a halted run after fixing the node
sudo ./test/gpu-bin.sh --reset         # discard state, remove the resume service
```

| Option | Default | Meaning |
|---|---|---|
| `--burn-duration S` | 600 | Stress seconds per ladder step |
| `--confirm-duration S` | 1800 | All-GPU confirm burn at the found ceilings |
| `--max-cycles N` | 8 | Power cycles allowed before the run halts |
| `--step-timeout S` | burn + 1200 | Kill a hung worker after S seconds |
| `--force` | off | Run even if GPU compute processes exist |

## Ladders

| Model | Steps (W) | Bands |
|---|---|---|
| RTX 5090 | 450, 500, 540, 550, 575 (600 on 600 W cards) | Default / Slightly degraded / Acceptable → A; Below threshold / Grade B → B; under 450 → C |
| RTX 4090 | 300, 450 | Default → A; Grade B → B; under 300 → C |
| RTX A4000 | 100, 140 | Default → A; Grade B → B; under 100 → C |
| Other | default only | "No bands set" |

The top step is always the card's own `power.default_limit`. The floor step runs `code memtest stress`; later steps run `code stress`.

## How a run works

1. **Discover** cards by UUID, serial and PCI bus ID. Indices are looked up again every round, because they can change after a drop or reboot.
2. **Warm-up**: one short serial fulltest at the floor, so parallel workers don't race to build tools.
3. **Climb rounds**: one `fulltest.sh --gpu N` worker per card at its current step, in parallel.
   - Pass → next step (or done at the default limit)
   - Test failure → ceiling = last passing step
   - Xid 79 / not visible / hung → **dropped**; ceiling = last passing step
   - `memtest` failure → grade C straight away
   - fulltest's power-anomaly remark (12V-2x6 connector signature) → stop climbing that card, inspect the cable
4. **Power cycle** when a card dropped or the driver stopped responding: `ipmitool -I open chassis power cycle`. A systemd unit (`gpu-bin-resume.service`) restarts the script after boot.
5. **Confirm**: all cards together at their ceilings for `--confirm-duration`. A card that drops here is stepped down one band and the confirm repeats after a cycle.
6. **Finish**: remove the resume service, restore `nvidia-runtime-policy.service` (power-saving presets), then check each grade A/B card against the limit the node will actually run it at. If a card's ceiling is lower (a grade B A4000 under the 140 W preset, for example), it runs `install/gpu-power-limit.sh --gpu-limit <idx>:<ceiling>` for that card. Then it writes `/opt/gpu-bin/results.csv` and re-enables `gpu-watchdog.timer`.

   Note: `gpu-power-limit.sh` rebuilds the policy service from the model preset plus these overrides. If the node had a custom `--override` base or earlier per-card limits, set them again. If the script isn't found (`GPU_POWER_LIMIT=` to point at it), the log prints the exact command to run by hand.

## Results file

`/opt/gpu-bin/results.csv` uses the tracker's GPU Ladder Log columns A–S, so rows paste straight in (paste as values):

| Column | Filled by gpu-bin.sh |
|---|---|
| Date, Node, GPU UUID / idx, PCI bus ID, Model, Serial | Yes (UUID; the current index is in Notes) |
| Failing test(s) | Yes (fulltest `[ FAIL ]` lines from the failing step) |
| Rung reached | 4 (power ladder), or 2 for a memtest failure |
| Default PL, Lowest passing PL, First failing PL, % of default | Yes |
| PCIe link, Fault follows, Ticket | No — rungs 5–7 and the ticket are manual |
| Grade, Band | Yes |
| Evidence path | Per-card step logs under `/opt/gpu-bin/logs/` |
| Notes | Final status, index, drop or connector notes, per-card limit applied, and "NOT for client service" for grade C |

## When it stops on its own (exit 2 / 3)

- **Two or more cards drop in the same round**: the shared power path (PSU, breakout, riser power) is suspected, not the cards. The cards stay at the same step. Fix the power path, then `--resume`.
- **Power-cycle limit reached**: inspect the node, then `--resume` (this resets the cycle count).

## Files

| Path | Contents |
|---|---|
| `/opt/gpu-bin/state/cards.tsv` | Per-card ladder state |
| `/opt/gpu-bin/state/run.env` | Phase, cycle count, options |
| `/opt/gpu-bin/logs/` | Script log, one fulltest log per card per step, warm-up and confirm logs |
| `/opt/gpu-bin/results.csv` | Final rows for the tracker |

## Testing

`bash test/gpu-bin-test.sh` runs the whole flow with mocked `nvidia-smi`, `fulltest.sh`, `ipmitool`, `journalctl` and `systemctl`. It covers a drop with a power cycle and resume, a 4090 that fails stress, a grade B A4000 getting its own power limit, the CSV column layout, and a two-card drop halt.

## Known limits

- An OS hang so complete that the script can't run `ipmitool` needs a manual power cycle. The BMC hardware watchdog would cover this case, but it isn't wired in yet.
- Dropped cards are not re-tested at their failing step after the cycle. The confirm burn is the re-check.
