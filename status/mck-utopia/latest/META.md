# META — Memphis True-Up April close-out with CS overrides (run 24)

> **Match rate: 99.83% — up from run 23's 99.78%.** The Fresenius CS-override
> load (293 trackings inserted at commit `88cf5d7`) actually fired on this
> audit run via `match_04_cs_override`. Net win: +24 closures, +$117.53
> client-billable cost moved from absorbed-loss into matched-with-markup.
>
> **The win is real but ~10× smaller than the original projection.** I had
> projected +280-290 closures based on "293 inserted → most will match" —
> that was wrong. Reality: only 28 of the 293 corresponded to UPS rows that
> were still unmatched after run 23's match_01_direct + match_05_ups_returns.
> The remaining 265 overrides are dormant (the trackings either matched
> earlier in the cascade or aren't in run 24's audit_detail at all). See
> "Why the projection was off" below.

| Field | Value |
|---|---|
| run_stamp | 2026-05-12_152152 |
| etl_run_id | **24** |
| runner | `scripts/run_memphis_trueup_april_extended.bat` |
| ship_window | (redacted — March + April 2026) |
| dispense_pull_mode | FRESH PULL — 676s, 541,610 rows, 252,973 unique trackings |
| status | COMPLETE |
| duration | 741 s (12.4 min) |
| warnings | 1 (PROC smoke; cosmetic, every run since 0121) |
| errors | 0 |

## Run 23 → Run 24 comparison

| Step | Run 23 | Run 24 | Δ |
|---|---:|---:|---:|
| `refresh_dispense_cache` rows | 541,610 | 541,610 | 0 (same window) |
| `refresh_dispense_cache` unique trackings | 252,973 | 252,973 | 0 |
| `ups_pre_to_post` rows | 221,410 | 221,410 | 0 (UPS landing unchanged) |
| `normalize_ups` rows | 50,673 | 50,673 | 0 |
| `populate_audit_detail` | 50,678 | 50,678 | 0 |
| `match_01_direct` | 50,384 | 50,384 | 0 (dispense cache unchanged) |
| `match_02_ep_pretransit` | 0 | 0 | 0 |
| `match_03_ep_returns` | 0 | 0 | 0 |
| **`match_04_cs_override`** | **0** | **28** | **+28** ✅ |
| `match_05_ups_returns` | 184 | 180 | -4 (cannibalized by match_04 firing first) |
| `match_06_fedex_refs` | 0 | 0 | 0 |
| **Total closed** | 50,568 (99.78%) | **50,592 (99.83%)** | **+24 (+0.05 pp)** |
| Open (FAIL) | 110 | **86** | **-24** |
| **UPS UNMATCHED dollars** | $987.70 | **$870.17** | **-$117.53** |
| `invoices_unified.csv` rows | 58,398 | **58,422** | +24 |
| `fails_ups.csv` rows | 110 | **86** | -24 |
| `detail_costplus.csv` rows | 58,394 | 58,418 | +24 |

## Net win in dollars (closure breakdown)

| Source | Run 23 | Run 24 | Δ dollars |
|---|---:|---:|---:|
| `UPS (UNMATCHED)` | $987.70 | $870.17 | **-$117.53** moved off the absorbed-loss line |
| `UPS DIRECT MATCH` | $339,422.49 | $339,422.49 | 0 (unchanged) |
| `UPS RETURN REF MATCH` | $1,120.59 | $1,093.94 | -$26.65 (cannibalized to match_04) |
| `UPS CS-OVERRIDE MATCH` (new bucket) | $0.00 | **$144.18** | **+$144.18** newly captured |

Math: +$144.18 (new match_04) - $26.65 (lost from match_05) = +$117.53 net
moved from UNMATCHED into matched. Conservation check: total UPS billed
$341,530.78 (unchanged across run 23 / run 24); only the bucket split
shifted.

At Fresenius's default 5% markup, the recovered $117.53 carrier cost flows
to client billings as roughly **$123.41** in additional invoiced revenue.

## Why the projection was off (~280 expected, 28 delivered)

The original projection ("293 overrides → ~280-290 match_04 closures") was
wrong in its assumption about applicability. Reality:

| Override bucket | Count | Notes |
|---|---:|---|
| Inserted into cs_return_override_log | **293** | from `fresenius_overrides_2026-05-12_151746.json` |
| Of which: applicable to run 24's unmatched UPS set | **28** | the rows match_04 actually closed |
| Of which: already closed by an earlier matcher (match_01_direct) | unknown but large | match_04 only fires on rows where `is_closed = 0` |
| Of which: not in run 24's audit_detail at all | unknown but large | Fresenius's list spans multiple periods; only April-billed lines appear in this run's audit |

The 265 "dormant" overrides aren't a problem — they're a feature. They sit
in `cs_return_override_log` and will fire automatically on any **future**
audit run that produces unmatched UPS rows for those trackings (e.g., a
re-bill, a delayed return invoice, a different month's run where the
tracking surfaces).

What this tells us about the original 110 residual:
* **28 lines / $117.53 (25%)** were Fresenius returns curated by the
  ops list — recoverable via the override mechanism, now closed.
* **82 lines / $870.17 (75%)** remain unmatched. These are either:
  * Non-Fresenius UPS returns that need their own client's override list
  * Fresenius returns not on the curated list (gap in ops tracking)
  * The 7 anomalous (malformed-length) trackings from the load — those
    won't match anything because the override row's `carrier_shipment_id`
    differs from the canonical UPS tracking format
  * Genuine never-dispensed UPS-billed shipments (third-party scans,
    label-only never shipped, etc.)

## New structural floor

**86 UPS lines / $870.17** is the new residual. At avg $10.12/line, this
is consistent with returns + misc UPS small-package costs. The audit
pipeline itself has nothing more to give without more override data or
additional match strategies.

## Phase D final close-out

| Criterion | Run 19 | Run 20 | Run 23 | **Run 24** |
|---|---|---|---|---|
| Match rate | 40.5% | 79.3% | 99.78% | **99.83%** |
| `match_04_cs_override` | 0 | 0 | 0 | **28** |
| `match_05_ups_returns` | 149 | 71 | 184 | 180 |
| UPS unmatched | 30,163 | 10,491 | 110 | **86** |
| UPS unmatched dollars | ~$202,742 | ~$71,113 | $987.70 | **$870.17** |
| `invoices_unified.csv` rows | 24,442 | 46,011 | 58,398 | **58,422** |

**Audit pipeline is feature-complete vs Access for the April 2026 period.**
Further closures would require: extending the Fresenius override list with
the other ~75% of residual trackings, OR new override lists from other
clients ([REDACTED-OTHER-CLIENT], etc.), OR a new match strategy. None of those are blocking
this period's close-out.

## Where the 28 closures came from (informational)

The 28 newly-closed lines are all from Fresenius (client_id=5) via the
`CUSTOMER SERVICE LOG MATCH` match_type. Their `carrier_shipment_id` values
overlap with Fresenius's curated returns list AND were in run 23's
fails_ups.csv. They now flow into `invoices_unified.csv` with Fresenius's
default markup (cost+5% per `carrier_trueup.client.markup_pct` for
client_id=5, unless overridden in `client_invoice_rates_zone` — Fresenius
is `billing_model=1` cost+, not zone).

## Cosmetic items (unchanged from prior runs, none blocking)

* PROC smoke 15/16 — same warning since 0121 shipped, smoke-filter bug
  not catching `sp_etl_ups_pre_to_post` even though step log proves it
  ran (`ups_pre_to_post  rows=221410`). One-line fix in
  `scripts/memphis_trueup_big_run.ps1` queue for a follow-up cleanup PR.
* The 7 anomalous trackings loaded into cs_return_override_log will
  never fire match_04 — their carrier_shipment_id values don't appear
  in any legitimate UPS invoice. They take 7 rows in the table but
  cause no harm. Worth cleaning up if Fitch provides corrected forms;
  otherwise they're just inert clutter.
* The runner's own META.json didn't push to origin again for this run
  (same pattern as runs 20 and 23). big_run's REPORT.txt auto-publish
  (commit `2e045ac`) landed; the wrapper's separate META.json commit
  didn't. Worth investigating the wrapper's git-push step under load,
  but the substrate META.md is authoritative anyway.
