# META — Memphis True-Up big-run snapshot

| Field | Value |
|---|---|
| run_stamp | 2026-05-12_080758 |
| etl_run_id | 19 |
| ship_window | (redacted — prior calendar month) |
| status | COMPLETE |
| duration | 88 s |
| warnings | 2 |
| errors | 0 |

## Smoke checks

| Object | Found | Expected | Status |
|---|---|---|---|
| TABLE | 9 | 9 | OK |
| VIEW | 2 | 2 | OK |
| PROC | **15** | **16** | **MISMATCH** |

PROC count is off by one **but the new SP IS callable** — the step log
shows `ups_pre_to_post` ran successfully with 221,410 rows (see below).
Smoke check expectation was bumped to 16 in `scripts/memphis_trueup_big_run.ps1`
to anticipate Phase B's new `sp_etl_ups_pre_to_post`, but the smoke
query's name/schema filter doesn't catch it. The migration itself is
correctly applied (`0121_memphis_trueup_ups_pre_to_post.sql : OK` in
section 01) and the SP runs end-to-end. Bug is in the smoke check,
not the data.

## UPS pipeline (Phase D verification)

| Step | Yesterday (run 18) | Today (run 19) | Phase D criterion |
|---|---|---|---|
| `ups_pre_to_post` rows | (step did not exist) | **221,410** | ✅ non-zero |
| `normalize_ups` rows | 0 | **50,673** | ✅ non-zero |
| `match_05_ups_returns` closures | 0 | **149** | ✅ non-zero |
| `invoices_unified.csv` row count | 3 | **24,442** | ✅ UPS lines present |
| UPS lines through cascade | 0 | 50,673 (= 20,361 direct + 149 returns + 30,163 unmatched) | ✅ UPS data flowing |

## UPS WARNING in SUMMARY section

**Still present** in run 19's REPORT.txt:
> `raw_invoice_data has no UPS rows for site 'MEM'. The audit will run without UPS data. Load via the existing UTOPIA UPS chain (sp_etl_ups_*) first if needed.`

This is a **false positive** — the warning is emitted by section 03
(CSV LOAD) which probes `raw_invoice_data` BEFORE the audit run. At
that point the table is correctly empty, because `ups_pre_to_post` (a
step inside the audit run) is what populates it. The handoff doc
flagged this exact false positive as a cosmetic follow-up: "After
Phase D verifies, edit the warning to point at the Lion's Upload
Invoices tab instead." The data flow is correct; the warning is
stale text. Worth a one-line fix in `memphis_trueup_big_run.ps1`
but not a Phase D blocker.

## Match cascade outcome (run 19)

| Match step | Closures | Notes |
|---|---|---|
| `match_01_direct` | 20,364 | 20,361 UPS direct + 3 FedEx direct |
| `match_02_ep_pretransit` | 0 | (no client-billed EP pre-transit) |
| `match_03_ep_returns` | 0 | |
| `match_04_cs_override` | 0 | |
| `match_05_ups_returns` | 149 | UPS return-reference matches |
| `match_06_fedex_refs` | 0 | v2 prefix + ship_method=FEDEX% |
| **Total closed** | **20,513** of 50,678 (40.5%) | |
| **Open (FAIL)** | **30,165** | 30,163 UPS + 2 EasyPost |

UPS unmatched rate is ~59.5% — high but expected; the handoff doc
acknowledged UPS shipment-id alignment is messier than EasyPost/FedEx.
The remaining open lines export to `fails_ups.csv` (30,163 rows) for
manual reconciliation downstream.

## Phase D close-out readiness

| Criterion | Status |
|---|---|
| Migration 0121 applied | ✅ |
| PROC=16 in smoke check | ⚠️ smoke check filter bug; SP IS present |
| `ups_pre_to_post` step non-zero | ✅ 221,410 |
| `normalize_ups` non-zero | ✅ 50,673 |
| `match_05_ups_returns` non-zero | ✅ 149 |
| UPS lines in `invoices_unified.csv` | ✅ visible in carrier counts |
| Spot-check UPS rows for `billing_model=1` + markup math | ⏳ not visible in REPORT.txt; needs export CSV |
| No UPS WARNING in SUMMARY | ⚠️ stale warning still present (false positive) |

**Captain's call needed:** is the smoke-check PROC=15 vs 16 a soft
warning (filter bug, SP confirmed present) or a hard block? And is
the stale UPS WARNING enough to defer Phase D close-out, or do we
close on the data and ship the warning fix as a follow-up cosmetic?
