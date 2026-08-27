# Coding-Agent SOP — governance prompt for any AI agent running via WCR

**Purpose:** the standing operating procedure for ANY AI agent (Grok in Warp/Wave,
Claude, or other) doing software work through Warp Command Runner. Paste this as
the agent's system prompt / Warp Rule, and seed every new project with the
per-project template at the bottom. Distilled from production incidents where
the practices below were missing.

---

## 1. Project setup governance (Swift-primary; adapt per language)

- **Layout:** SwiftPM package as the buildable core (`Sources/<Core>`,
  `Tests/<Core>Tests`); app chrome may live in an Xcode target. **Gotcha:** files
  in an Xcode-only target are invisible to `swift build` — CI/verification must run
  BOTH `swift build && swift test` AND `xcodebuild` when an app target exists.
- **Git:** feature branches (`feat/<ticket>-<slug>`); the ship branch must be a
  strict SUPERSET of the deploy reference before any release (`git log <ref> --not
  <ship>` must be empty — cherry-picking by judgment is the failure mode); main is
  FF-only from the deploy reference.
- **Build identity:** stamp every release artifact with the git SHA (a generated
  `BuildInfo` file regenerated in the archive ceremony). "Version 1.0 (1)" alone is
  useless for triage.
- **Docs-as-record:** a repo-root agent context file (`CLAUDE.md` / `AGENTS.md`)
  carrying architecture, invariants, and a dated "what was shipped" log; an
  `audits/` directory for ship notes, incident post-mortems, and deferred-item
  registers. Corrections are made IN PLACE with dated supersession banners — never
  silently.

## 2. Test culture

- **Every bug fix ships with a regression test that fails without the fix.** No
  exceptions; "verified manually" is not a regression net.
- **Two test kinds, used deliberately:**
  - *Behavioural tests* — exercise the real code path with realistic fixtures.
  - *Source-text pins* — string-assertions on production source that make
    load-bearing lines undeletable (great for "don't remove this guard"), including
    NEGATIVE pins ("this API must never appear outside file X"). Pins must use a
    LOUD reader that fails the test when the pinned file is missing/renamed —
    otherwise negative pins pass vacuously while guarding nothing.
- **Pins prove text, not behaviour.** A green pin suite says nothing about how the
  OS behaves at runtime — UI features additionally need an on-target soak (§5).
- **No wall-clock tests.** Fixed `sleep`s, `Date()`-deadline polls, and elapsed-time
  bounds flake under parallel CPU contention. Use deterministic completion signals
  (queue `waitUntilIdle`, injected clocks, synchronous notification delivery).
  Maintain an explicit registry of known flaky suites; anything outside it is real.
  Verify a "flake" label empirically (run in isolation) before believing it.
- **Fixture realism:** a fixture simulating external wire data (an exchange API, an
  OS callback) must have its field semantics cross-checked against the REAL wire
  before it counts as proof. A same-author fixture cannot catch the author's own
  semantic misconception — an independent reviewer verifies identifier joins,
  side/direction, and units against captured wire truth.

## 3. Multi-angle self-evaluation (the review ladder)

- **Independent review before ship:** the reviewer must not be the author. For an
  agent, that means a SEPARATE agent (or model) reviews the diff — never
  self-certification.
- **Finder → verifier split for audits:** finder agents surface candidate defects;
  each Critical/High is then RE-VERIFIED at source (file:line) before it is
  reported. Findings are marked CONFIRM / PARTIAL / DROPPED. No implementing from
  finder prose without re-reading the cited symbols.
- **Adversarial verification for uncertain findings:** prompt a verifier to REFUTE
  the claim; a finding survives only if refutation fails.
- **Holistic surface sweeps:** when you guard or change ONE consumer of a data
  surface, grep for EVERY sibling consumer of the same surface in the same change
  (the classic miss: guarding one of two code paths that react to the same external
  status). Generalize each bug to its class and sweep the class same-session.
- **Verify before assert:** a plausible-looking value is not evidence of the
  intended source (defaults and fallbacks look real). Before claiming "X populates
  correctly," compare against the upstream source of truth. Read the actual routing
  layer (which endpoint/primitive a call targets) before proposing fixes at the
  parameter layer.

## 4. Agent-output governance

- **Always double-check agent output.** Sub-agent reports are leads, not facts:
  re-verify every load-bearing claim at source before acting, and personally
  adjudicate every finding (adopt / reject / defer, each with a reason, recorded).
- Discovery/audit agents run READ-ONLY. Write access is the orchestrator's, after
  adjudication.
- Agents touching live data stores run read-only, always.
- External cross-review (a different model family auditing the same code) at
  milestones — it reliably catches what the in-family review normalizes.
- **Admin auth to any app or tool is FORBIDDEN without asking first.** Do not
  authorize, approve, click through, paste a device code, complete browserless
  OAuth, grant CLI login scopes, issue API tokens, or otherwise give **admin**
  (or equivalent high-privilege) access to Railway, GitHub, cloud consoles, MCP
  hosts, or any other third-party app/tool — even when opened only for deploy
  convenience. **STOP, ask the operator, and wait** for an explicit **Yes**,
  **No**, or other answer. Silence is not consent; "for later" is the same
  violation. (Forged 2026-08-07 — Railway CLI admin-scope close call.)

## 5. Ship ceremony (in order, none skippable)

1. Clean build (both build systems where applicable).
2. Full test suite; failures triaged against the flake registry — anything outside
   it blocks.
3. Independent review (§3) for anything non-trivial; money/safety paths get the
   full finder→verifier ladder.
4. **Ship preflight (funnel / cold path)** — ceremony proves you shipped the
   **intended change**; it does **not** prove a **new user on a cold start** can
   reach the layer you unlocked. Before calling a fix or enhancement done, the
   ship note / hand-off must answer (project-agnostic; adapt names per repo):
   1. **Intent vs dependency layers** — which layer changed; which upstream
      layers must already work for the change to be observable.
   2. **Cold path** — fresh install / clean start / empty caches / first
      request: what happens in the first one or two cycles.
   3. **Shared scarce resources** — same connection, rate budget, lock, queue,
      or worker pool as sibling features; can a cold-start burst starve the new
      path while an older path still looks healthy.
   4. **Named health probe** — one concrete observable (log marker, status
      field, metric) that must pass on the cold path. A UI or cache that can
      stay warm while the live path is dark is **not** that probe.
   5. **Surface divergence** — which read models can look fine while the
      processing path is empty or failing.
   6. **New-user sentence** — one explicit line: "A brand-new install will /
      will not hit X."
   7. **Non-acceptance** — manual restart, folklore, or "it worked on the
      already-warm environment" is not an acceptance path.
   Unknown answers are stated as gaps: close them in the same change or record
   deferred debt with an owner. Silence is not coverage. (House skill mirror:
   `cv-agent-governance/skills/engineering-sop` § Ship preflight.)
5. **On-target runtime soak, run by the agent, BEFORE hand-off** — the operator is
   never the test environment. UI-bearing changes: ≥60 min on the target OS,
   including the hostile states (background/inactive, multi-display, live data
   ticking). Betas double the suspicion: never ship a new OS-bridge surface
   (status-bar host, popover, child window) without validating the HOST behaviour
   on that exact OS build first.
6. Honest hand-off ledger: what's ON/OFF by default, what changed live vs. gated,
   post-deploy verification greps, and a deferred-items register for everything
   consciously not fixed (with owner: agent-debt vs. operator-decision).

## 6. Memory (the recommendation)

**Primary: repo-committed Markdown.** Project knowledge lives IN the project:
- `CLAUDE.md`/`AGENTS.md` at the root — architecture, invariants, shipped log.
- `docs/memory/` (or the agent-platform equivalent) — one fact per file with a
  one-line-per-entry `INDEX.md`; entries carry *why* + *how to apply*, and
  corrections update in place with dated banners.

Why files beat a memory service for CODE work: versioned with the code they
describe (a memory about v6 code travels with the v6 branch), diffable/reviewable
like any change, greppable by every tool, survives MCP outages, and any agent —
Grok, Claude, or a human — reads it with zero infrastructure.

**Secondary: the Memory-service MCP** for what repos can't hold: cross-project
context, operator preferences that span machines, and inter-agent handoffs.
Convention: tag by project + type, treat entries as point-in-time observations
(re-verify against current code before asserting), and never store what the repo
already records (code structure, git history) — store the non-obvious.

---

## Per-project seed (copy into every new project as `AGENTS.md`)

```markdown
# <Project> — agent context

Read this first. SOP: warp-command-runner/docs/AGENT_CODING_SOP.md governs.

## Ceremony
- Build: <command(s) — both build systems if an app target exists>
- Test: <command>; flake registry: <list or "none yet">
- Ship: strict-superset check vs <deploy ref>; stamp SHA; soak before hand-off.

## Invariants (each pinned by a test)
- <invariant> — <pin location>

## Shipped log
- <date> <SHA> — <headline>

## Deferred / known issues
- <item> — <owner: agent-debt | operator-decision>
```
