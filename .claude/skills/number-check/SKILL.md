---
name: number-check
description: Vet a measured number before reporting or acting on it — a backtest or strategy result, P&L, fill or quote, benchmark, speedup or regression, metric, or eval score. Eight questions answered from runs, not from reading code, including a hard possible range and an outside-source cross-check (broker, data vendor); the verdict names what limits the number and rules out what else it could be measuring. Use before a number goes into a report, journal entry, commit, PR, or decision, or when the user says /number-check or 「檢查數字」.
---

# /number-check — vet a number before it travels

A number is a claim. Before it lands in a report, a journal entry, a commit
message, or a decision, answer the questions below with evidence from runs.
A guess from reading the code is not evidence.

## First

- Write the sentence you expect to ship, number included ("the filter
  lifts expectancy from 0.02R to 0.11R over 2020–2026"). The questions
  test that sentence.
- Read the script that produced the number: what it counts, what it
  times, what it silently drops.

## The questions

1. **Did the work happen?** Count it: trades taken, rows processed,
   requests that reached the server, samples inside the window. A
   strategy that never trades, a filter that drops every row, or a result
   nothing consumed yields a number for work that never ran.
2. **Did anything fail quietly?** Count errors, NaN or empty rows,
   skipped dates or symbols, timeouts, retries. Outputs must be correct,
   not just present. If the script does not report these counts, add them.
3. **Is it possible, and is it too good?** First the hard range: a
   probability in [0, 1], a price above 0, an unlevered loss no worse than
   −100%, a fill inside that bar's low–high, a count no larger than its
   population, a timestamp inside the session. Outside it → a bug; stop.
   Then the arithmetic against a ceiling: bandwidth, cores, market hours,
   the share of the run the changed part takes, the edge the method could
   plausibly find. A result past a ceiling usually means lookahead,
   survivorship, a cache, or a bug.
4. **Does it reproduce?** Several runs, seeds, or out-of-sample windows;
   report the median and the range. A gap smaller than the run-to-run or
   window-to-window spread is no measurable difference.
5. **Is the comparison fair?** Both sides use the same data, period,
   costs, and settings, each tuned the way it would really run. A tuned
   candidate against a default baseline compares configurations, not
   methods.
6. **What limits it?** Name the bound — data, a parameter, a cost, a
   lock, one core — from a measurement. If you cannot say why it is not
   twice as good, you do not yet know what you measured.
7. **Does it matter end to end?** Set a component result against the
   whole it serves: a 2× faster step that takes 1% of the run saves under
   1%; a better signal that costs eat is not an edge.
8. **Does an outside source agree?** Prices, P&L, fills, marks, Greeks,
   volumes: compare against an independent source — the broker's
   statement or mark, the data vendor's quote for the same symbol and
   timestamp, an exchange settlement. Same instrument, time and units
   (per share vs per contract, currency, adjusted vs raw). Name the source
   and the gap; a gap beyond the spread or rounding is a finding, not noise.

## Report

- Verdict first: better / worse / no measurable difference / inconclusive.
- Then the number with its unit, the run or window count, the range, the
  work count from Q1, the limiter from Q6, and the outside-source gap
  from Q8 (or why no outside source exists).
- **Inconclusive** when Q1 or Q2 could not be checked, a side ran
  untuned, the limiter is unknown, or an outside source existed for Q8
  and was not checked — name the gap. Inconclusive is not a pass.
- Keep the evidence with the number: the exact command next to the
  result; long run logs go in a linked file, not pasted (S2).

<!-- Q3 range and Q8 from the claude-starter fleet failure taxonomy (2026-10-23): DQ07. -->
