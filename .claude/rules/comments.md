---
description: What a code comment may say, and how to cull one safely.
paths:
  - "lib/**"
  - "workers/src/**"
---

Code says what; git says when. A comment that repeats either rots the day the code moves.

**Write only a why** — the constraint, trap or decision that makes the code look odd, wasteful or
wrong without it. "Budget SoCs fit ~2 decoders, so the pool caps at 2" is a why.

- Three lines at most. Longer belongs in `docs/<area>.md`; leave a one-line pointer.
- `///` is one line, and only on a declaration another feature imports, saying what the signature
  does not.
- Never a banner or divider, never commented-out code.
- No history: no dates, build numbers, names, "used to", "no longer". A history word inside a why
  ("no longer polls because Play throttles it") is fine.
- A TODO carries an owner or a reason.

**Deleting existing comments:** a block goes whole or stays whole — never reword, move or merge one.
Delete a what, a when, dead code, a banner, an ownerless TODO, boilerplate, or a why that `docs/`
already holds (grep first). Keep a why, a pointer, a cross-feature `///` that adds information, and
anything you are unsure of. Never touch `// ignore:`, `ignore_for_file`, `dart format off/on`,
`coverage:`, `eslint-`, `@ts-`, or a comment that is the only body of `{}` (an empty-catch lint).

Prove every cull with `tools/comment-guard/`: `inventory.mjs` → decisions → `apply.mjs` →
`verify.mjs`. The non-comment token stream must match HEAD; a RED file is reverted, never
hand-patched.
