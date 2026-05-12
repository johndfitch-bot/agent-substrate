# META — Memphis True-Up April close-out, FINAL (run 23)

> **Result: 99.78% match rate. Memphis True-Up replatform feature-complete
> for the April 2026 period.**
>
> The extended-dispense fix (`-ShipMonthStart 2026-03-01` + fresh cache)
> actually applied this run. ship_window in `etl_run_log.dt_start/dt_end`
> reads `2026-03-01 → 2026-04-30`. Dispense pull row count is 541,610
> (almost double the 284,816 from April-only runs 20/21/22), confirming
> the wider window was honored.

| Field | Value |
|---|---|
| run_stamp | 2026-05-12_124153 |
| etl_run_id | **23** |
| runner | `scripts/run_memphis_trueup_april_extended.bat` (fixed in commit `110bb2a`) |
| ship_window | (redacted — March + April 2026) |
| dispense_pull_mode | **FRESH PULL** (`@max_reuse_age_minutes = 0`) — 870s, 541,610 rows, 252,973 unique trackings |
| status | COMPLETE |
| duration | 940 s (15.7 min, mostly the wider dispense pull) |
| warnings | 1 (PROC smoke; same as every other recent run — smoke-filter bug, SP confirmed present) |
| errors | 0 |

## Headline comparison

| Metric | Run 20 (Apr-only, FRESH) | **Run 23 (Mar+Apr, FRESH)** | Δ |
|---|---:|---:|---:|
| ship_window | Apr 1 → Apr 30 | **Mar 1 → Apr 30** | wider |
| dispense rows pulled | 284,816 | **541,610** | **+256,794 (+90%)** |
| dispense unique trackings | 138,848 | **252,973** | **+114,125 (+82%)** |
| `match_01_direct` closures | 40,113 | **50,384** | **+10,271** |
| `match_05_ups_returns` closures | 71 | **184** | +113 |
| `match_06_fedex_refs` closures | 1 | 0 | -1 (noisy at this scale) |
| **Total closed** | **40,185 (79.3%)** | **50,568 (99.78%)** | **+10,383 (+20.5 pp)** ✅ |
| Open (FAIL) | 10,493 | **110** | **-10,383 (-99.0%)** ✅ |
| UPS unmatched lines | 10,491 | **110** | **-10,381 (-99.0%)** ✅ |
| **`invoices_unified.csv` rows** | 46,011 | **58,398** | **+12,387 (+26.9%)** ✅ |
| `fails_ups.csv` rows | 10,491 | **110** | **-10,381 (-99.0%)** ✅ |
| `fails_fedex.csv` rows | 2 | 0 | -2 ✅ |
| `fails_easypost.csv` rows | 0 | 0 | 0 |
| Duration | 523 s | 940 s | +417 s (wider pull is the cost) |

## Classifier prediction vs actual recovery

The classifier (`ups_trueup_classifier_2026-05-12_121441.json`, against run
22 ≈ run 20) predicted:

* **Bucket A_pre_window**: 10,309 rows / $69,642.79 / 99.6% concentrated
  in 2026-03 production. *Predicted recovery if dispense window widened
  to include March: ~10,268 (the March-only subset of A).*
* **Bucket E_not_in_cf_ops**: 182 rows / $1,469.71. *Predicted floor —
  cannot be matched without a dispense record.*

Actual run-23 outcome:

| Bucket | Predicted recovery | Actual recovery | Variance |
|---|---:|---:|---|
| A_pre_window (Mar dispenses) | ~10,268 → matched | **10,381 matched** | +113 (the match_05 returns also benefited from the wider cache) |
| E_not_in_cf_ops (floor) | 182 unmatched | **110 unmatched** | -72 (some E-bucketed trackings matched via secondary references — likely match_05's CF order number path picking up previously-bucketed-as-E rows that DID have CF order references in dispense for non-tracking columns) |

The classifier slightly under-predicted recovery; reality was even better
because the wider cache let `match_05_ups_returns` resolve more return-
reference shipments. Total unmatched at the floor: **110 rows / $987.70**
— well under the classifier's $1,469.71 prediction.

## UPS dollar flow (audit accounting)

Run 23 by carrier × match_type (total UPS dollars conserved — wider cache
moved $ from UNMATCHED → MATCHED, didn't change UPS-billed total):

| Carrier | match_type | Lines | Dollars |
|---|---|---:|---:|
| EasyPost | DIRECT | 2 | $5.83 |
| FedEx | DIRECT | 3 | $31.52 |
| UPS | **DIRECT** | **50,379** | **$339,422.49** |
| UPS | **RETURN REF** | **184** | **$1,120.59** |
| UPS | **(UNMATCHED)** | **110** | **$987.70** ← structural floor |
| TOTAL UPS | — | 50,673 | $341,530.78 |

Compared to run 20's UPS breakdown (40,111 DIRECT + 71 RETURN REF + 10,491
UNMATCHED = $270,022.38 + $395.90 + $71,112.50 = $341,530.78 — same total
billed): **$70,124.80 moved from UNMATCHED into MATCHED** (now bills back
to clients with markup), **leaving $987.70 as the structural floor**.

## What the 110 remaining unmatched lines are

Per the classifier, bucket E (not in CF_OPS SCRIPTMASTER) at $1,469.71
was the predicted floor. Actual floor came in lower at **$987.70 / 110
lines**, average $8.98/row. These are UPS-billed shipments where:

* The tracking number doesn't appear in `CF_OPS.cf_memphis.SCRIPTMASTER`
  at all (third-party scans, label-only-never-shipped, returns of
  shipments not dispensed by this pharmacy)
* They have no CF order reference either (otherwise `match_05_ups_returns`
  would have caught them)

These are genuinely unbillable to client accounts at the line level. The
audit's `fails_ups.csv` (110 rows) captures them for ops eyes; the
dollar magnitude is small enough that absorbing them is operationally
cheaper than chasing them down.

## Smoke check — still 15/16 PROC mismatch

Same warning every run since 0121 shipped. `sp_etl_ups_pre_to_post` IS
callable (step log line 86 in REPORT.txt shows it ran with 221,410 rows
this run, identical to runs 20/21/22). The smoke-check query in
`scripts/memphis_trueup_big_run.ps1` has a name/schema filter that
doesn't catch the new SP. Cosmetic — does not affect audit outcome.

## Phase D close-out call

| Criterion | Run 19 (Mar, REUSED) | Run 20 (Apr, FRESH) | **Run 23 (Mar+Apr, FRESH)** |
|---|---|---|---|
| Migration 0121 applied + SP callable | ✅ | ✅ | ✅ |
| UPS lines flowing into audit cascade | ✅ (50,673 normalized) | ✅ | ✅ |
| UPS lines in `invoices_unified.csv` | ✅ (some) | ✅ (40k+ direct) | ✅ **50,563 UPS** |
| Match rate at expected band | 40.5% (capped by stale cache) | 79.3% (April-only cache) | **99.78%** ✅ |
| Stale UPS WARNING gone | n/a | ✅ | ✅ |
| Smoke check PROC=16 | ⚠️ 15/16 | ⚠️ 15/16 | ⚠️ 15/16 (cosmetic) |

**Memphis True-Up April 2026 close-out: READY.** Match rate matches what
the Access pipeline historically produced for similar windows; structural
floor of ~$1k unmatched is normal operational baseline.

## Cosmetic / cleanup items (none blocking)

* Smoke-check filter in `memphis_trueup_big_run.ps1` should be widened to
  include `sp_etl_ups_pre_to_post` (one-line fix; turns 15/16 warning
  into clean smoke pass).
* The 110 fails_ups.csv rows could get a brief ops investigation if
  Finance cares to chase $988 — but at $8.98/row average, probably
  not worth the labor.
* The bat-shim caret-continuation lesson (run 21/22 propagation failure,
  fixed in commit `110bb2a`) is worth capturing in a developer note:
  "all .bat shims invoking PowerShell must use single-line invocation;
  caret continuation is unreliable under double-click launches."

## Runner META.json — still not consistently landing on origin

Same observation as runs 20 and 22: the `run_memphis_trueup_april.ps1`
wrapper's separate META.json commit didn't land on origin for run 23
either. big_run's REPORT.txt auto-publish (commit `3063f06`) is on
origin; the wrapper's follow-on META commit is not. The wrapper's
`git pull --rebase + git add + git commit + git push` sequence has a
silent-failure mode worth investigating — but the substrate META.md
(this file) carries the comparison view authoritatively, so it's a
nice-to-have for ops record-keeping, not a blocker.
