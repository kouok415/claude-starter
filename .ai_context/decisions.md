<!--
purpose: Append-only log of design decisions (Architecture Decision Records).
mutability: append-only. Never edit or delete existing entries.
            If a decision is reversed, write a NEW entry that supersedes it.
format: each entry uses the template below. Most recent at the bottom.
do-not: don't put tentative ideas here (use state.md). don't paste implementation
        details (those live in code or knowledge/). keep entries to the
        decision and its rationale, not the work that followed.
teams:  if concurrent writers cause merge conflicts, switch to
        decisions/NNN-<slug>.md (one file per ADR) and note it in INDEX.md.
-->

# Architecture Decision Records

Each entry records a decision that shapes the project. New entries go at the
bottom. Existing entries are immutable; to change a past decision, write a
new entry that references and supersedes the old one.

---

## Template

```markdown
## ADR-NNN: <short title>

- **Date:** YYYY-MM-DD
- **Status:** Accepted | Superseded by ADR-NNN | Deprecated
- **Context:** What forced this decision? What was the situation?
- **Decision:** What did we decide?
- **Rationale:** Why this option over alternatives?
- **Alternatives considered:** What else was on the table, and why rejected.
- **Consequences:** What does this make easier? Harder? What are we
  committing to?
```

---

<!-- Add new ADRs below this line. Numbering starts at ADR-001. -->
