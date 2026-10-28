run: completed
verdict: fail
base: card:b1c71a24d301d37cd9b04f59f655c11aca5b55bde6051fe4b5b4d14c0c8efc37
blocker: 0
major: 2
minor: 0

2. major — check 2 — The explicit empty-string argument is ambiguous: “names are printed verbatim” supports `bash greet.sh ""` producing `hello, `, while “the world by default” supports `hello, world` — `.ai_context/tasks/livecard/pair/001-card.md:50-52` — add a human Decision stating the exact output.
5. major — check 5 — S3 does not say what command installs greet.sh or where — `.ai_context/tasks/livecard/pair/001-card.md:56` — add and cite a `§Install` notes section.

Claim 1 — confirmed — the named greeting works — command `bash greet.sh Ada`; output `hello, Ada`.

Commands run:

- `bash greet.sh Ada`
- `sed -n '1,240p' .ai_context/tasks/livecard/pair/001-card.md`
