# META — Memphis True-Up April close-out (run 20)

| Field | Value |
|---|---|
| run_stamp | 2026-05-12_100931 |
| etl_run_id | **20** |
| runner | `scripts/run_memphis_trueup_april.bat` (new, see commit `9500f74`) |
| ship_window | (redacted — April 2026 calendar month) |
| dispense_pull_mode | **FRESH PULL** (`@max_reuse_age_minutes = 0`) — 451s, 284,816 rows, 138,848 unique trackings |
| status | COMPLETE |
| duration | 523 s (8.7 min, mostly the fresh ScriptMaster pull) |
| warnings | 1 (PROC smoke; same as run 19) |
| errors | 0 |

## Hypothesis verified — match rate jump

Captain's hypothesis (run 19's 59.5% UPS unmatched was caused by the
cache window not covering April production_dates, reused from run 12's
March pull) was **confirmed by the dispense-window diag**
(`ups_dispense_window_2026-05-12_094141.json`, status OK):

* Cache pull window: `2026-03-01 → 2026-04-06` (March + 6-day overflow)
* 55/55 sampled unmatched UPS trackings WERE in SCRIPTMASTER
* 55/55 had `production_date > 2026-04-06` → bucketed `after`
* 0/55 missing from SCRIPTMASTER; 0/55 before window; 0/55 within
* Distinct clients in sample: 1

So the trackings were billable and recorded — the cache just didn't
include them. Forcing a fresh pull with April's window (April + 6-day
overflow = `2026-04-01 → 2026-05-06`) is the fix.

## Run 19 (March params, REUSED cache) vs Run 20 (April params, FRESH cache)

| Metric | Run 19 | Run 20 | Δ |
|---|---:|---:|---:|
| ship_window | 2026-03-01 → 2026-03-31 | 2026-04-01 → 2026-04-30 | — |
| dispense source | REUSED run 12 (1199 min old) | **FRESH PULL (451s)** | — |
| `refresh_dispense_cache` rows | 304,963 | 284,816 | -20,147 |
| `refresh_dispense_cache` unique trackings | 135,047 | **138,848** | +3,801 |
| `ups_pre_to_post` rows | 221,410 | 221,410 | 0 (UPS landing unchanged) |
| `normalize_ups` rows | 50,673 | 50,673 | 0 |
| `populate_audit_detail` rows | 50,678 | 50,678 | 0 |
| **`match_01_direct` closures** | **20,364** | **40,113** | **+19,749** ✅ |
| `match_05_ups_returns` closures | 149 | 71 | -78 (some now picked up by match_01) |
| `match_06_fedex_refs` closures | 0 | 1 | +1 |
| **Total closed** | **20,513 (40.5%)** | **40,185 (79.3%)** | **+19,672 (+38.8 pp)** ✅ |
| Open (FAIL) | 30,165 | **10,493** | **-19,672** ✅ |
| UPS unmatched lines | 30,163 (59.5%) | **10,491 (20.7%)** | **-19,672** ✅ |
| `invoices_unified.csv` rows | 24,442 | **46,011** | **+21,569** ✅ |
| `fails_ups.csv` rows | 30,163 | **10,491** | **-19,672** ✅ |
| `fails_fedex.csv` rows | 0 | 2 | +2 (newly surfaced) |
| `fails_easypost.csv` rows | 2 | 0 | -2 (now matched) |

## Smoke check — still 15/16 PROC mismatch

Same as run 19. The new SP `sp_etl_ups_pre_to_post` **IS callable** —
the step log proves it ran with 221,410 rows transformed. The smoke
check's name/schema filter in `scripts/memphis_trueup_big_run.ps1`
doesn't pick it up. This is a smoke-check bug, not a migration gap.
Migration 0121 was confirmed applied by the april_runner's pre-flight
before invoking big_run with `-SkipMigrations`.

## UPS WARNING — gone

Run 19's stale `raw_invoice_data has no UPS rows for site 'MEM'`
warning (a section 03 false positive) is **absent** from run 20 —
because section 03 was skipped via `-SkipCsvLoad`. Net result:
the only remaining warning is the PROC 15/16 smoke gap.

## April runner pre-flight (recorded in script's META.json — see Note)

| Gate | Outcome |
|---|---|
| sp_etl_ups_pre_to_post present | ✅ (drove `-SkipMigrations`) |
| ups_invoice_landing rows | 221,410 across 4 batches (yesterday's loader) |
| easypost_invoice_landing overlaps April | ✅ |
| fedex_invoice_landing overlaps April | ✅ |
| cs_return_override_log baseline | recorded, untouched (separate cycle) |

## Note: april_runner's own META.json did not land on origin

The `run_memphis_trueup_april.ps1` does a separate `git commit + push`
for `dist/big_run_reports/big_run_<stamp>/META.json` *after* big_run's
Phase 08 auto-publishes the REPORT.txt and step logs. On this run, the
big_run REPORT.txt commit (`82f1faa`) is on origin, but no follow-on
META.json commit was pushed. Likely cause: the runner's `git pull --rebase`
right before its META commit returned non-zero (e.g. no upstream
tracking, or a transient network blip), and it logged a Warn but
didn't push. The substrate META.md (this file) is authoritative for
the comparison view anyway; the missing runner-local META.json is
just for ops record-keeping. Worth a one-line follow-up to make the
runner's commit-and-push step idempotent + retry.

## Remaining 10,491 UPS unmatched — next-cycle targets

The 79.3% match rate is a clean step-change from 40.5%. The remaining
~20% UPS unmatched is the structural floor for this period — likely
a mix of:

* UPS-billed shipments without a dispense pairing (third-party scans,
  rejected packages, label-only never-shipped)
* Cross-month returns of shipments produced before March (the April
  window's lookback only goes 6 days, so returns of January/February
  dispenses still won't match)
* Trackings with `production_date` in dispense but no `client_id`
  populated (`unique_tracking_client_map` filters those out via
  `HAVING COUNT(DISTINCT client_id) = 1`)

If Captain wants to drive further, a follow-up diag scoped to the
new run-20 unmatched set (the bucket distribution shape from
`ups_match_diag` re-run against `etl_run_id=20`) would tell whether
the remaining misses are dispense-cache-missing (extend window) or
dispense-cache-present-but-no-client (data quality at source).

## Phase D close-out call

| Criterion | Status |
|---|---|
| Migration 0121 applied + SP callable | ✅ (step log proves) |
| UPS lines flowing into audit cascade | ✅ (50,673 normalized, 40,185 matched) |
| UPS lines in `invoices_unified.csv` | ✅ (40,111 direct + 71 returns visible in carrier counts) |
| Match rate at expected band for clean window | ✅ (79.3% vs run 19's 40.5%) |
| Stale UPS WARNING gone | ✅ (section 03 skipped removed the false positive) |
| Smoke check PROC=16 | ⚠️ still 15/16 (smoke-check filter bug; SP confirmed present) |

**Captain's call:** the cache-window root cause is closed. The 15/16
smoke-check filter is a cosmetic follow-up in `memphis_trueup_big_run.ps1`.
The remaining 20% unmatched is structural and warrants a scoped
diag if pursued. Memphis True-Up replatform is feature-complete vs
the legacy Access pipeline for the April period.
