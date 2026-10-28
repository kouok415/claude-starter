---
name: verify
description: Prove a change works in <APP> by running it as a user does (<GUI | CLI | VM guest | pipeline>). Use before committing a behavior change, before saying done, and to reproduce a bug.
---
<!-- Claude Code runs this skill before every commit: only steps that finish
     in a few minutes belong here. Slower paths are separate lanes in
     .claude/done-lanes. Keep it model-invocable: no invocation switch
     in the frontmatter. -->

Surface: <what the user touches>. Cannot reach: <fresh VM, live broker, …>;
claims there stay NOT VERIFIED.

## Launch
<cmd from an empty data dir>; ready = <a real action succeeds>, not "process up". Teardown: <cmd>.
## Doctor
<read-only checks: right build, port/display/VM is ours, data present>. Run first and after any surprise.
## Drive
One `features/<name>.md` per journey: user path, exact commands/selectors, observable end state.
- desktop: <launch + CDP/xdotool + screenshot> · CLI: <fresh tmp HOME/PTY per run>
- VM: <boot snapshot, run inside the guest; host-side stand-ins don't count>
- pipeline: <fixed fixture window; print rows/trades/errors/NaN; /number-check any metric>
## Evidence
<artifacts/verify/DATE/>: action, resulting state, side effects (files, rows, messages, orders NOT sent).
A dry-run counts only once you've observed what it skips.
## Proof rules
- Real user path; no internal setters, test-only endpoints, or mocks except at a production boundary.
- A check never seen failing proves nothing: run each new check once against a known-bad state; keep that output.
- Not evidence: `bash -n`, `--help`/`--list-*`, grepping strings our own scripts print, a selftest the same agent wrote.
- Journey fails: product bug → report; recipe drift → fix the recipe in its own commit. Never weaken a journey.
- Stand-in (container for VM, paper for live, sample for full data): list the steps it skipped; those stay unverified.
## Cleanup
Kill only recorded PIDs, never by name. Evidence must survive; check it.
## Helpers
Script a drive only after doing it by hand twice: one file, invocation shown here, no framework.

Lane: <the done-lanes lane this mirrors, e.g. smoke>.
Proven: <date · commit · feature · evidence record id>. Blank = draft.
<!-- Source: adapted from pstack v0.15.31 (skills/create-verification-skill/SKILL.md, skills/maintain-verification-skill/SKILL.md). MIT — see NOTICE. -->
