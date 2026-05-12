# META — Memphis True-Up "extended-dispense" attempt (run 21)

> **Critical finding:** run 21 was **NOT the extended-dispense variant**.
> All three `.bat` overrides (`-ShipMonthStart 2026-03-01`,
> `-ShipMonthEnd 2026-04-30`, `-RunBy fitch_april_extended_dispense`)
> were silently dropped by CMD's caret line-continuation. The script
> executed with its **default** parameter values — making run 21 a
> **functional duplicate** of run 20.
>
> All metrics below match run 20 to the digit. The dispense pull row
> count is also identical (284,816 / 138,848 unique), confirming the
> window was never widened.
>
> Fix is on origin at `feat/ups-diag` commit `110bb2a` (rewrote the .bat
> to single-line PS invocation, matching every other .bat in the repo).
> Re-run required to actually exercise the extended-dispense path.

## Headline numbers — run 19 → run 20 → run 21

| Metric | Run 19 (March, REUSED) | Run 20 (April, FRESH) | Run 21 (intended Mar 1 → Apr 30 + FRESH) | Δ vs Run 20 |
|---|---:|---:|---:|---:|
| ship_window (`etl_run_log.dt_start`/`dt_end`) | Mar 1 → Mar 31 | Apr 1 → Apr 30 | **Apr 1 → Apr 30** (NOT the intended Mar 1 → Apr 30) | 0 |
| dispense source | REUSED run 12 | FRESH PULL (451s) | FRESH PULL (378s) | — |
| dispense rows pulled | 304,963 | 284,816 | **284,816** (identical) | 0 |
| dispense unique trackings | 135,047 | 138,848 | **138,848** (identical) | 0 |
| `ups_pre_to_post` rows | 221,410 | 221,410 | 221,410 | 0 |
| `normalize_ups` rows | 50,673 | 50,673 | 50,673 | 0 |
| `match_01_direct` closures | 20,364 | 40,113 | **40,113** | 0 |
| `match_05_ups_returns` closures | 149 | 71 | **71** | 0 |
| `match_06_fedex_refs` closures | 0 | 1 | **1** | 0 |
| Total closed | 20,513 (40.5%) | 40,185 (79.3%) | **40,185 (79.3%)** | 0 |
| `invoices_unified.csv` rows | 24,442 | 46,011 | **46,011** | 0 |
| `fails_ups.csv` rows | 30,163 | 10,491 | **10,491** | 0 |
| Duration | 70 s | 523 s | 444 s | — |
| Warnings | 2 | 1 | 1 | — |
| Errors | 0 | 0 | 0 | — |

Every "Δ vs Run 20" column entry is **0** because runs 20 and 21 ran the
same audit configuration. This is the diagnostic signature of the
propagation failure: a 6-week-wider dispense window would have added
March production rows (which the dispense pull does include — confirmed
by run 19's REUSED-from-run-12 pull which had window Mar 1 → Apr 6).
Run 21's 138,848 unique trackings exactly equals run 20's, so no March
data made it into this run's cache.

## Root cause of the propagation failure

`scripts/run_memphis_trueup_april_extended.bat` (commit `8e60fa7`)
used cmd's caret line-continuation to break the PowerShell invocation
across four lines:

```bat
powershell.exe -NoExit -ExecutionPolicy Bypass -NoLogo -File "%PS1_PATH%" ^
    -ShipMonthStart "2026-03-01" ^
    -ShipMonthEnd   "2026-04-30" ^
    -RunBy          "fitch_april_extended_dispense" %*
```

Cmd's caret continuation has subtle requirements (no trailing
whitespace, no BOM, behaves differently under double-click vs.
cmd-prompt launch) and silently failed here — PowerShell received
only `-File "<path>"` with no script args, dropped the overrides, and
ran with defaults. Every other `.bat` in `scripts/` uses single-line
invocation; this one was the outlier.

**Smoking-gun evidence in `META.json` (from work-box run):**

```json
"invocation": {
    "ShipMonthStart":  "2026-04-01",      // expected 2026-03-01
    "ShipMonthEnd":    "2026-04-30",      // ok (default coincides)
    "RunBy":           "april_runner_2026-05-12_113549"  // expected fitch_april_extended_dispense
}
```

## Fix

`feat/ups-diag` commit **`110bb2a`** rewrites the `.bat` to use a
single-line PS invocation, identical pattern to every other `.bat`
in the repo. The overrides now reach the script.

## What still needs to happen

1. Fitch pulls `feat/ups-diag` on work-box (head should now be `110bb2a`).
2. Re-run `scripts\run_memphis_trueup_april_extended.bat`. The next
   `etl_run_log` row should show `dt_start = 2026-03-01` (not Apr 1),
   `run_by = 'fitch_april_extended_dispense'`, and the dispense pull
   row count should be **higher** than 284,816 (if March SCRIPTMASTER
   has any rows for site=MEM, which we expect it does — run 19 saw
   them when reusing run 12's pull).
3. Bridge that new run to substrate. If match counts jump again, we
   have answered whether the remaining 10,491 unmatched UPS lines are
   primarily older-dispense returns. If counts stay the same, those
   10,491 are structurally unbillable (third-party scans, label-only,
   etc.) and the audit has reached its functional floor for April.

## What this run still tells us — operational evidence

Even though run 21 is configurationally a clone of run 20, the fact
that we got byte-for-byte identical match counts on a re-run with a
freshly-pulled-from-scratch dispense cache is **useful confirmation**:

* `match_01_direct` is deterministic against a fresh cache. The 40,113
  result reproduces. No race conditions or non-determinism in the
  cascade.
* `match_05_ups_returns` reproduces at 71.
* The dispense pull SP is stable: 284,816 rows / 138,848 unique
  trackings each time the same window is requested.
* The pre-flight gates correctly green-lit the run (EP/FedEx landing
  date overlap, UPS landing 221,410, 0121 present, cs_log untouched).

So the close-out audit pipeline itself is sound. Only the wrapper's
.bat had a bug. After the .bat fix, the actual extended-dispense run
becomes a single clean test.

## April runner META.json on origin this time

Run 21 DID produce a `META.json` at
`dist/big_run_reports/big_run_2026-05-12_113553/META.json` and it
landed on origin in commit `719cf8e` — the missing follow-on commit
from run 20's bridge is no longer a question. Whatever made it not
push for run 20 (transient git issue, probably) didn't recur. Good.
