# Working on FocusPilot

Read README.md and the relevant design documents before editing. Phase 1 implementation is under way (owner decision, 2026-10-13): build what a ticket asks for, and do not add frameworks or dependencies beyond the recorded decisions (GRDB is the only storage dependency).

- Preserve user-configured folder boundaries. Never reorganize unrelated projects.
- Distinguish confirmed decisions, proposals, and platform assumptions requiring validation.
- Treat deadlines, priorities, current focus, and block policies as structured state, not inferred conversation memory.
- AI proposes changes; deterministic code validates authority and executes authorized actions.
- No autonomous prompts to other Herdr agents, approvals, pane closure, or focus changes by default.
- Native macOS interface: SwiftUI/AppKit. Chrome first for enforcement; Safari through an owner-chosen external blocker until a signed Safari extension is possible (decision 0003, 2026-10-20).
- All user-facing text is in English; capture input is parsed in Spanish or English (decision 0003, 2026-10-15).
- Cache derived values only; clearing caches must not remove tasks, preferences, deadlines, or focus rules.
- Preserve usage provenance and uncertainty; external Herdr agents are not automatically instrumented. Do not double-count request events, cumulative counters, or trace rollups.
- Native Swift orchestration; LangSmith is optional diagnostics, not the authoritative budget ledger. No LangGraph runtime is selected.
- Budget exhaustion never stops external agents automatically. Expose interruption only after capability validation; never label it pause without proven recovery.
- Use primary platform documentation for technical claims and record sources.
- Independent skeptical review is useful when explicitly requested; record findings and dispositions.
- Avoid adding unrelated dependencies or writing brittle tests for design documents.

## Review and merge

Code lands through pull requests only. A PR merges after its tests pass and an independent reviewer agent (fresh context) checks it against the ticket, `docs/design/` and the decision records, with findings fixed. The owner does not read code. Before merging, get the owner's sign-off on Herdr agent behavior (described in plain language) and on screens (screenshots or try-it steps). See decision 0003, 2026-10-14.

In this fork the owner is the fork owner, the only collaborator (decision 0004). Small documentation-only fixes, such as wording or broken links, may be committed straight to `main`; anything that changes code, tests, the schema, or a decision goes through a pull request as above.

Commits and pull requests carry no Claude attribution: no `Co-Authored-By: Claude` trailer and no "Generated with Claude Code" line (owner decision, 2026-11-02).

## Agent skills

### Issue tracker

GitHub Issues in the `marilynjov/FocusPilot` fork, via `gh`. See `docs/agents/issue-tracker.md`. The fork's `upstream` remote is `SantiagoM99/FocusPilot`: fetch from it to pick up Santiago's work, but never push, open pull requests, or file issues there unless the owner asks (decision 0004).

### Triage labels

Default five labels (needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` glossary at the root (created when terms get resolved) and decision records in `docs/decisions/`. See `docs/agents/domain.md`.
