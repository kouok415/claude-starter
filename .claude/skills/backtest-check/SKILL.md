---
name: backtest-check
description: Backtest, strategy evaluation, signal research, walk-forward or out-of-sample result — integrity checks for look-ahead, survivorship, data snooping, zero trades, costs and calendar errors. Use when changing a backtest engine or data layer and before reporting any strategy metric. Only for backtests and strategy evaluation.
---

# /backtest-check — is the backtest measuring the strategy?

Run each check; every one ends in a line `<n> <check>: pass | fail | n/a — <evidence>`.

1. **Look-ahead.** Shift or truncate the future data (drop everything
   after date D) and rerun up to D: every output dated ≤ D must be
   byte-identical. Any change is look-ahead.
2. **Universe and a control.** Build the universe as-of each date,
   delisted and renamed names included. Run a zero-edge control (random
   or shuffled entries, same costs) beside the strategy; the strategy's
   edge is its margin over the control, not over zero.
3. **Pre-registration.** Thresholds, parameters and the evaluation window
   sit in a commit dated before the first out-of-sample byte was read.
   Never re-tune after looking; a re-tune spends the window — say so.
4. **Work count.** Count trades, rows, symbols and days that reached the
   strategy. Zero or near-zero activity is a failed run, not a result.
5. **Costs.** Commission, spread/slippage and borrow per name, charged on
   both legs of every round trip, sign-checked — a cost never adds to P&L.
6. **Clock and calendar.** A timezone, session, holiday-calendar, bar-size
   or corporate-action change → re-derive every per-period quantity
   (returns, annualisation, dividends, expiries) and diff against before.
7. **Broker safety.** Verifies and tests never place orders: stub the
   broker. Paper or live success means broker-confirmed state read back
   (order status, positions, account mode), not "ok" from our code.
8. Then `/number-check` every number you report.

Any `fail` → the result is not reported as a result; it is a defect in the
backtest. `n/a` needs a reason.

<!-- Rules from the claude-starter fleet failure taxonomy (2026-10-23): DQ01–DQ06, DQ09. -->
