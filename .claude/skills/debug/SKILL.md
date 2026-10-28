---
name: debug
description: Bug, crash, wrong output, failing test, red lane, flaky check, regression, "it worked before" — find the cause from runtime evidence before changing code. Use before writing any fix, after a fix attempt fails, and when a check goes red with no proven cause.
---

# /debug — no fix before a reproduction and a causal chain

1. Reproduce on the user's surface (the `verify` skill or the lane), twice.
   Can't → instrument each boundary (input, output, env, cwd, PATH, the
   stdin each child sees), run once, read where it breaks. State
   inspection may confirm the symptom, never inject it. No repro → no fix;
   report what you tried.
2. Before concluding, check the environment: which tree/branch, mounts,
   active account, market or session hours, stale build or cache. A
   failure only after restart → suspect persisted state.
3. No fix until you can state trigger → each step → symptom, with
   file:line for each step.
4. One hypothesis, one minimal change, one run. Never edit "to see if it
   helps". Revert everything a refuted hypothesis motivated; never stack
   fixes.
5. Fix where the bad value originates. A guard, retry, clamp or swallowed
   error is masking unless that state is legitimate. Fix the pattern, not
   one instance.
6. Done = the same repro on the same surface fails before and passes
   after, twice; paste both outputs. Unit tests alone are not absence of
   the bug; the wrong surface or an inconclusive run is not a pass.
7. Two failed fixes → write their shared premise (inside `/task`: notes
   §Tried) and test it. Three → stop and report what was tried, why each
   failed, and what comes next. Never "try harder" on the same premise.
8. Known traps: heredoc / `while read` children (ssh, docker exec) swallow
   stdin — give them `</dev/null`; one client per CDP pipe; unique temp
   paths; exclude yourself from `pgrep`; a child with a different cwd/env.

## Output

    Repro: `<command>` → "<failing output>" (×2)
    Chain: <trigger> → <step, file:line> → … → <symptom>
    Fix: <commit> — <one line: where the bad value originated>
    After: `<same command>` → "<passing output>" (×2)

<!-- Source: adapted from Superpowers v7.0.1 (skills/systematic-debugging/SKILL.md); Compound Engineering v3.31.1 (skills/ce-debug/SKILL.md); pstack v0.15.31 (skills/poteto-mode/playbooks/bug-fix.md, skills/poteto-mode/playbooks/runtime-forensics.md). MIT — see NOTICE. -->
