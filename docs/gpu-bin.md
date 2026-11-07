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
        ├── results_<server>_<run>.txt      # the same results, one readable block per card
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
sudo ./test/gpu-bin.sh --expect-gpus 6 # same, and report fitted GPUs the driver can't see
./test/gpu-bin.sh --status             # per-card progress; when idle, the latest results report
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
| `--expect-gpus N` | none | GPUs fitted in the server; each one the driver can't see gets a "not detected" row (grade C) |
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
   - `memtest` failure on its own → grade C straight away
   - fulltest's power-anomaly remark (12V-2x6 connector signature) → stop climbing that card, inspect the cable
   - **Two or more cards fail (any test, memtest included) or drop at the floor in the same round** → none of them is graded yet. Each is **re-tested alone** at the floor (ladder rung 2). A card that passes alone goes back on the ladder, with a note, and the run records a node note: "check PSU/riser power under full-node load". A card that fails or drops alone is grade C. A card that drops during the warm-up triggers a power cycle before testing, so it still gets its real test.
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


### Readable report

`results_<server>_<run>.txt` has the same results for reading on screen, printed at the end of the run and by `--status` when no run is active. The CSV stays as it is, for pasting into the tracker.

```text
gpu-bin results: server BR80S…, run 2026-11-03-15-16 (finished 2026-11-03 19:42:10)
Cards: 6   grade A: 1   grade B: 1   grade C: 4 (incl. 2 not detected)
NODE NOTE: cards failed the floor together but passed alone — check PSU/riser power under full-node load
Tracker rows: /opt/gpu-bin/…/results_….csv

GPU 1  00000000:41:00.0  NVIDIA GeForce RTX 5090  serial …
  Grade:    A   Band: Acceptable
  Ceiling:  540 W of 575 W (94%)   first fail 550 W
  Failing:  -
  Status:   dropped (rung 4)
  Notes:    failed the floor only alongside other cards
            passed alone — check node PSU/riser power under full load
            fell off bus / hung at 550W
  UUID:     GPU-…
  Evidence: /opt/gpu-bin/…/logs/GPU-…_*.log

NOT DETECTED (1 of 2)
  Grade:    C   Band: Not detected
  Notes:    6 GPUs expected, 4 visible: not on PCIe or not seen by the driver
            check slot / riser / power / BIOS bifurcation
```

*(Illustrative.)* One block per card with a blank line between them; each note on its own line.
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

- **Two or more cards drop *above their floor* in the same round** (cards that had already passed a lower step): the shared power path (PSU, breakout, riser power) is suspected, not the cards. The other cards' results from that round are kept. Drops at the floor are re-tested alone instead (see above). The cards stay at the same step. Fix the power path, then `--resume`.
- **Power-cycle limit reached**: inspect the node, then `--resume` (this resets the cycle count).

## Files

| Path | Contents |
|---|---|
| `<server>/<run>/state/cards.tsv` | Per-card ladder state (incl. physical slot) |
| `<server>/<run>/state/run.env` | Phase, cycle count, options, apply mode |
| `<server>/<run>/logs/` | Script log, one fulltest log per card per step, warm-up and confirm logs |
| `<server>/<run>/results_<server>_<run>.csv` | This run's rows for the tracker |
| `<server>/<run>/results_<server>_<run>.txt` | The same results, readable |
| `<server>/<run>/apply-on-host_<server>_<run>.sh` | Per-card limits to apply on the server's own OS |
| `all-results.csv` | Every finished row across servers and runs |

## Testing

`bash test/gpu-bin-test.sh` runs the whole flow with mocked `nvidia-smi`, `fulltest.sh`, `ipmitool`, `journalctl` and `systemctl`. It covers a drop with a power cycle and resume, a 4090 that fails stress, a grade B A4000 getting its own power limit, the CSV column layout, run IDs and server serials, slot lookup through a riser bridge, USB mode recording instead of applying limits, a stick moved to another server mid-run, a two-card drop halt, power limits returning to card defaults on finish and on halt, and a copy of the BR80S5402800219 node (6 fitted, 4 visible, three cards failing the floor together, including a shared-round memtest failure, re-tested alone), the readable report, and fulltest's PCI-order GPU numbering (63 checks).

## Reading a run's log

`<server>/<run>/logs/gpu-bin.log` has one line per decision:

| Line | Meaning |
|---|---|
| `Step: … at 450W: code memtest stress` | A card starts a ladder step |
| `PASS` / `TOP` | Passed this step / passed its own default limit (done) |
| `FAIL: … (<test>)` | Failed a test at this step; ceiling = last passing step |
| `DROP: … (last pass: …)` | Fell off the bus or hung |
| `ISOLATE: …` | Failed or dropped at the floor alongside other cards; will be re-tested alone |
| `SOLO PASS` / `SOLO FAIL` / `SOLO DROP` | Result of that solo re-test; only a solo failure grades the card C |
| `NODE NOTE: …` | A card failed only alongside others: check PSU / riser power under full-node load |
| `CONNECTOR: …` | 12V-2x6 power-anomaly flag from the all-GPU confirm burn: inspect that card's cable |
| `Cold power cycle n/8` | The node power-cycled itself to recover; the run resumes after boot |
| `HALT: …` | Stopped for a person (shared power suspected, cycle limit, or the run's GPUs not visible) |

### Case study: BR80S5402800219 (2026-11-03)

6 RTX 5090s fitted, 4 visible. Two runs before the fixes graded every visible card C:

- **14:04:** GPU 0 (`41:00.0`) fell off the bus at 450 W. Cards 1–3 passed `code` and `memtest` but got a stress FAIL. That FAIL came from fulltest, not the cards (see "fulltest.sh fixes" below).
- **15:16:** GPU 0 dropped again. This time cards 1–3 *failed memtest*, the same cards that passed memtest an hour earlier. That's collateral from the neighbouring card falling off the bus, not three cards' VRAM going bad together.

After the fixes, each card is re-tested alone before grading, and the run behaved as expected. The lesson for the ladder: **when several cards fail in one parallel run while one drops, no result from that round counts until each card has been re-tested alone.**

## Missing GPUs

A card that doesn't enumerate on PCIe at all (absent from both `nvidia-smi -L` and `lspci`) can't be found by any software check. Pass `--expect-gpus N` with the number fitted. The results then get one row per missing card, "not detected", grade C, with a note to check the slot, riser, power and BIOS bifurcation.

## fulltest.sh fixes this depends on

Found on BR80S5402800219 (2026-11-03): three 5090s at 450 W were failed by fulltest, not by the cards.

- `stress_hard_failure_detected` matched the plain word `Xid`, including fulltest's own power-anomaly advice text ("...precursor to Xid 79..."). Combined with gpu-fryer's Gflops-check exit 1 (a known false positive on power-capped cards), every card got a hard stress FAIL. It now matches only real kernel lines (`NVRM: Xid`, `Xid (PCI:`, `fallen off the bus`). Fixed in both `fulltest.sh` and `gpu-fulltest-v2.sh`.
- The burn telemetry file was shared by all fulltest processes in `test/build/`, so parallel single-GPU runs compared each card against the others' data. It is now per GPU target (`_burn_telemetry_gpu<N>.csv`).
- `fulltest.sh --gpu N` set `CUDA_VISIBLE_DEVICES=N` without `CUDA_DEVICE_ORDER=PCI_BUS_ID`. CUDA numbers GPUs "fastest first" by default, `nvidia-smi` by PCI bus, so on a mixed node (for example one 600 W 5090 among 575 W cards) the stress could run on a different card from the one gpu-bin limited and watched. Both fulltest scripts now set PCI order (2026-11-07).
- As a result, the 12V-2x6 power-anomaly check (which compares a card with its peers) only applies in gpu-bin's all-GPU confirm burn. gpu-bin reads it from there and marks flagged cards "connector".

## Known limits

- An OS hang so complete that the script can't run `ipmitool` needs a manual power cycle. The BMC hardware watchdog would cover this case, but it isn't wired in yet.
- Dropped cards are not re-tested at their failing step after the cycle. The confirm burn is the re-check.
