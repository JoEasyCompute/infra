# gpu-bin.sh — unattended power-limit ladder and binning

`test/gpu-bin.sh` automates rungs 1–4 and 9 of the GPU diagnostic ladder for every NVIDIA GPU in a node. It climbs each card's power limit from the grade B floor to the card's default limit, survives GPUs falling off the bus by power-cycling itself through its own BMC, and writes one result row per card in the exact column order of the training tracker's GPU Ladder Log.

Physical rungs (reseat, riser and cable swaps, the swap test) are still done by hand.

## Runs, servers and USB sticks

Every run gets a **run ID** (`yyyy-mm-dd-hh-mm`, plus `-2`, `-3`… when two start in the same minute) and its own folder, **per server**:

```text
/opt/gpu-bin/
├── all-results.csv                         # every finished row, all servers, all runs
└── <server-serial>/
    ├── active-run                          # run ID in progress (absent when idle)
    └── 2026-11-03-14-05/
        ├── results_<server>_<run>.csv      # this run's rows (tracker columns A–S)
        ├── apply-on-host_<server>_<run>.sh # only when per-card limits are needed
        ├── logs/                           # per-card per-step fulltest logs, warm-up, confirm
        └── state/
```

- The **server** is identified by its DMI system serial, then the baseboard serial, then the BMC MAC. Hostname is the last resort, because every server booted from the same stick has the same hostname.
- The **PCI bus ID** column also shows the **physical slot**, for example `00000000:25:00.0 (SLOT3)`. It comes from SMBIOS (`dmidecode -t slot`) or `lspci` "Physical Slot", walking up through risers and PCIe switches. It's blank if the board doesn't publish slot names.
- **USB / live boot:** when `/` is on a USB or removable device, or the kernel was booted with `boot=casper`/`boot=live`, per-card limits are **not applied**. They would land on the stick, not on the server's own OS. The script writes `apply-on-host_<server>_<run>.sh` instead, listing index, bus ID, slot, model, serial and UUID per card. Run it from the infra repo root on the server's own OS after checking that the indices match. Override with `--apply-limits` / `--record-limits`.
- **Moving the stick:** a server only resumes its own active run. Booting the stick in another server leaves the first server's unfinished run untouched, and it continues when the stick goes back. If none of a run's GPUs are visible (cards swapped), the run halts instead of producing a results file full of "missing" cards.
- **Live ISO without persistence:** refused. If `/opt/gpu-bin` is on overlay, tmpfs or ramfs, the state, logs and resume service would vanish at the first power cycle. Use a full install on the stick, or give the live image a persistent partition and bake in the resume service.

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
| `--apply-limits` / `--record-limits` | auto | Apply per-card limits at finish, or only write the apply-on-host script (auto: record only on USB/live boot) |

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
6. **Finish**: clear the server's active run, remove the resume service (unless another server on the same stick still has an active run), set **every card back to its own default power limit** (`power.default_limit`), and restart `nvidia-runtime-policy.service` if it's installed so a host-disk server returns to its power-saving presets. Then it checks each grade A/B card's ceiling against the **fleet preset** for its model, read from `GPU_PRESET_MODELS` / `GPU_PRESET_WATTS` in `install/gpu-power-limit.sh` (or the card default for a model with no preset). If the ceiling is lower (a grade B A4000 under the 140 W preset, for example), it runs `install/gpu-power-limit.sh --gpu-limit <idx>:<ceiling>` for that card on a host-disk boot, or only writes the apply-on-host script on a USB boot. Then it writes the run's results CSV, appends it to `all-results.csv`, and re-enables `gpu-watchdog.timer`.

   Note: `gpu-power-limit.sh` rebuilds the policy service from the model preset plus these overrides. If the node had a custom `--override` base or earlier per-card limits, set them again. If the script isn't found (`GPU_POWER_LIMIT=` to point at it), the log prints the exact command to run by hand.

## Results file

`results_<server>_<run>.csv` (and `all-results.csv`) use the tracker's GPU Ladder Log columns A–S, so rows paste straight in (paste as values):

| Column | Filled by gpu-bin.sh |
|---|---|
| Date / run ID | Run ID `yyyy-mm-dd-hh-mm` |
| Node / server | Server serial (DMI) |
| GPU UUID / idx, PCI bus ID, Model, Serial | Yes (UUID; bus ID plus physical slot; the current index is in Notes) |
| Failing test(s) | Yes (fulltest `[ FAIL ]` lines from the failing step) |
| Rung reached | 4 (power ladder), or 2 for a memtest failure |
| Default PL, Lowest passing PL, First failing PL, % of default | Yes |
| PCIe link, Fault follows, Ticket | No — rungs 5–7 and the ticket are manual |
| Grade, Band | Yes |
| Evidence path | Per-card step logs under `/opt/gpu-bin/logs/` |
| Notes | Final status, index, drop or connector notes, per-card limit applied, and "NOT for client service" for grade C |

## Power limits after the run

| How the run ends | Power limit left on each card |
|---|---|
| Finished, booted from USB (no policy service on the stick) | The card's own default (5090 575/600 W, 4090 450 W, A4000 140 W) |
| Finished, host disk with `nvidia-runtime-policy.service` | Default first, then the service re-applies the fleet presets |
| Halted (exit 2 / 3, or GPUs not found) | Same reset as a finished run, for every card still visible |
| Power cycle mid-run | The driver starts every card at its default after boot anyway |

Limits set with `nvidia-smi -pl` don't survive a reboot. When a server boots its own OS after a USB run, it starts at the defaults, or at whatever that OS's own policy service applies.

A 5090 graded "Acceptable" at 540 W gets **no** per-card limit. Its ceiling is above the 450 W fleet preset, so an override would only raise its power. Only cards whose ceiling is below the preset get one.

## When it stops on its own (exit 2 / 3)

- **Two or more cards drop in the same round**: the shared power path (PSU, breakout, riser power) is suspected, not the cards. The cards stay at the same step. Fix the power path, then `--resume`.
- **Power-cycle limit reached**: inspect the node, then `--resume` (this resets the cycle count).

## Files

| Path | Contents |
|---|---|
| `<server>/<run>/state/cards.tsv` | Per-card ladder state (incl. physical slot) |
| `<server>/<run>/state/run.env` | Phase, cycle count, options, apply mode |
| `<server>/<run>/logs/` | Script log, one fulltest log per card per step, warm-up and confirm logs |
| `<server>/<run>/results_<server>_<run>.csv` | This run's rows for the tracker |
| `<server>/<run>/apply-on-host_<server>_<run>.sh` | Per-card limits to apply on the server's own OS |
| `all-results.csv` | Every finished row across servers and runs |

## Testing

`bash test/gpu-bin-test.sh` runs the whole flow with mocked `nvidia-smi`, `fulltest.sh`, `ipmitool`, `journalctl` and `systemctl`. It covers a drop with a power cycle and resume, a 4090 that fails stress, a grade B A4000 getting its own power limit, the CSV column layout, run IDs and server serials, slot lookup through a riser bridge, USB mode recording instead of applying limits, a stick moved to another server mid-run, a two-card drop halt, and power limits returning to card defaults on finish and on halt (38 checks).

## Known limits

- An OS hang so complete that the script can't run `ipmitool` needs a manual power cycle. The BMC hardware watchdog would cover this case, but it isn't wired in yet.
- Dropped cards are not re-tested at their failing step after the cycle. The confirm burn is the re-check.
