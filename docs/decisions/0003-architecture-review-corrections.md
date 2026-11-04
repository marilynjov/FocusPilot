# Architecture review corrections

Date: 2026-10-13. Status: accepted by owner on 2026-10-13. Platform behavior marked "validate" remains unproven until its spike.

Second review of the full design set, including decision 0002. Each finding lists the change made to the documents. The owner accepted all proposals below on 2026-10-13.

## Process, ownership and enforcement

| Finding | Change |
|---|---|
| "Single SQLite writer" is an in-process actor, but the Safari extension handler and Chrome native host are separate processes that may run while the app is quit | Cross-process contract: app publishes a compiled policy snapshot; helpers read it and append to an observation inbox; only the app writes authoritative data ([Architecture](../ARCHITECTURE.md#process-model)) |
| Process ownership after login, window close or quit was undefined | Proposal: one menu-bar-resident process registered as a login item; no separate daemon/XPC agent until a spike requires it |
| Extensions depended on the app for exception/session expiry | Policy carries absolute session end and exception expiries; each extension evaluates it locally on every wake. Behavior without the app follows session mode (confirmed below) |
| DNR cannot close an already loaded page or stop buffered media | Candidate: content script on blocked domains enforces expiry in-page; on activation, existing matching tabs are redirected (validate, especially Safari) |
| Chrome worker lifecycle assumptions were unverified | Recorded documented behavior: 30 s idle termination; an open `connectNative()` port keeps the worker alive (Chrome 105+); alarms ≥30 s, may be late, fire after wake; restart persistence documented from Chrome 150 |
| Engine was described as a component with I/O arrows | Engine is a pure function of state and an injected clock, producing compiled policy and effects; the coordinator delivers them and tracks acknowledgements |
| Unsupported browsers and profiles were an invisible bypass | Activity observer flags unsupported browsers frontmost during a session; acknowledgements are per Chrome profile; incognito/private permission is tracked |
| Diagram contradicted single-writer rule (`USAGE --> DB`, `ENGINE --> BRIDGE`) and omitted named components | Diagram corrected; coordinator named FocusCoordinator to match the architecture review |

## Data model

| Finding | Change |
|---|---|
| Deadline as instant + date-only flag invites midnight-UTC errors | Deadline is either `{localDate, timezone}` or `{instant, timezone}`, plus original text |
| Block rules were session-owned, but blocked sites are durable owner preferences | Split BlockRuleSet (owner-authored), Exception (scope, absolute expiry, shared across browsers) and CompiledPolicy (derived, versioned, acknowledged) |
| Domain-wide exceptions make YouTube all-or-nothing | Exceptions may be scoped to an exact URL as well as a domain |
| Launch set required by workspace rules had no field | `Resource.launchOrder` (null = not in launch set) |
| Pilot metrics had no storage, and 24 h raw retention would erase a baseline | Append-only Event table with aggregated counts/durations, no URLs or content |
| TraceOutbox duplicated ledger data and was listed as authoritative | Export reads ledger rows through a cursor; delivery state is operational, not authoritative |
| Default classification for unknown apps/domains was undefined | Unknown counts as ambiguous and triggers a purpose check-in (confirmed below) |

## AI usage and workload (refines decision 0002)

| Finding | Change |
|---|---|
| P0 accounting included concurrent reservations, cost-estimate versioning and per-task budgets for a call volume likely measured in cents/day | P0: serialized supervisor gateway (concurrency 1), ModelAttempt rows with usage and rate snapshot, daily admission cap. Reservations become necessary only if concurrency rises; per-task budget and urgent reserve move to P1 |
| The workload view's value is in external agents, which initial coverage shows as Unknown | Workload view leads with task, dependency and attention data, which need no token telemetry; usage is a supporting column |
| No concrete external usage source was identified | Claude Code documents OpenTelemetry token/cost metrics with a session ID; recorded as a candidate first adapter requiring a local authenticated OTLP receiver (validate) |
| Bespoke LangSmith REST mapping was the only export path | LangSmith documents OTLP ingestion; recorded as alternative to evaluate |
| Inspected Herdr commands include no interrupt command | Any "Interrupt turn" via Herdr would be input delivery and falls under explicit prompt authority until a dedicated mechanism is proven |
| Usage accounting and LangSmith export were listed as platform spikes | Moved to deterministic logic tests; external usage and interruption remain spikes |

## Product and validation

| Finding | Change |
|---|---|
| A baseline week needs measurement before blocking exists | Observe-only mode added at P0, ordered before blocking in the spike plan |
| Spike order was unspecified | First vertical slice: menu-bar app + Safari extension blocking one site + one timed exception surviving sleep and app quit |

## Open decisions raised

- Which sites are always-on versus scheduled versus session-only (owner configuration, not a design blocker).

## Confirmed by owner

- 2026-10-13: Storage library is GRDB.swift, chosen over SwiftData/Core Data for FTS5 search, WAL concurrent reads, SwiftUI observation and documented multi-process sharing. No dependency is added until implementation starts. See [Data and memory](../DATA_AND_MEMORY.md#storage-library).
- 2026-10-13: Unknown apps and sites count as ambiguous. In Coach mode a deterministic rule (not model confidence) asks their purpose once: For this task / Always fine / Distraction / Ask later. Answers are stored as ActivityClassification; Distraction needs confirmation before blocking. See [Experience](../EXPERIENCE.md#coach-behavior).
- 2026-10-13: When the app cannot update the policy, normal sessions stop blocking at the planned end; strict sessions keep blocking until the app reconnects. Exceptions always expire on time. See [Architecture](../ARCHITECTURE.md#enforcement-ownership).
- 2026-10-13: All proposals in this record are accepted.
- 2026-10-13: Supported platform is macOS 26 only; revisit if the app is ever used by others.
- 2026-10-13: No Apple Developer Program membership for now. Development uses locally signed builds and Safari's unsigned-extension setting; membership is reconsidered once the app is built. Developer ID distribution remains the eventual route.
- 2026-10-13: The iPhone blocker (Opal) stays separate from FocusPilot. Goal: when the owner opens distracting apps on the iPhone during focus time, FocusPilot finds out and tells the owner to return to the current action. No companion iOS app or Screen Time entitlement while there is no developer membership.
- 2026-10-13: Phone nudge: a Mac-controlled Focus mode plus iPhone Shortcuts automations and iCloud Drive files report distracting app use during focus time; strict sessions also return the iPhone to the Home Screen, normal sessions only notify. See [Architecture](../ARCHITECTURE.md#iphone-distraction-signal).
- 2026-10-13: Development proceeds in phases. Phase 1 is the platform spikes plus all P0 features, including the phone nudge.
- 2026-10-13: Documentation-only updates go directly to `main`; all code lands through reviewed pull requests.
- 2026-10-13: Work is split between the owner and agents. Every change lands through a reviewed pull request that the owner reads, understands and merges; tickets are sized for that.
- 2026-10-13: Some block rules are always active. Rule sets support always, scheduled, or session-only activation; always-on and scheduled rules are enforced by the extensions regardless of app state.
- 2026-10-14: Blocked Mac apps are hidden (not quit) when opened during an applicable rule, and a FocusPilot panel shows the current action and a timed exception for the whole app. App blocking works only while FocusPilot is running; protection status reports browsers and apps separately. See [Architecture](../ARCHITECTURE.md#enforcement-ownership).
- 2026-10-14: The Phase 1 interface reference is [docs/design/focuspilot-phase1-design.html](../design/focuspilot-phase1-design.html). The strict-session 60-second wait before an exception is a proposed value awaiting owner confirmation.
- 2026-10-14: Pausing a session does not move its planned end; the end stays the absolute instant the extensions already hold. Superseded 2026-11-02: a pause now stops the countdown (decision 0004).
- 2026-10-14: Strict sessions keep blocking during pauses and breaks; normal sessions lift session-only rules while paused or on a break. Always-on and scheduled rules are unaffected by either.
- 2026-10-14: Review process changed, superseding the two 2026-10-13 entries about the owner reading and merging every pull request. Code still lands only through pull requests. Claude merges a pull request after its tests pass and a separate reviewer agent with fresh context has checked it against the ticket, the design reference and the recorded decisions, and the findings are fixed. The owner reviews two things, without reading code: the behavior of Herdr agent features (what FocusPilot can see and do to agents) before those merge, and the look and feel of screens through screenshots or try-it steps. Every merge gets a plain-language summary.
- 2026-10-14 (from the PR #24 review, Claude's call under the new review process): owner data and derived cache live in separate SQLite files, so deleting a source and its cache entries is not one transaction. Delete cache rows after the owner commit, and treat cache rows whose source is missing or whose revision is older as invalid on read. A cache file that fails to open is deleted and rebuilt; it never blocks owner data.
- 2026-10-14 (assumption): the database lives in the unsandboxed `~/Library/Application Support/FocusPilot`. If the app is ever sandboxed, that path moves into the container and needs an explicit migration.
- 2026-10-14 (from the PR #24 review): `TaskRepository` is an actor, but actors are reentrant across `await`, so each logical change (including read-modify-write such as reordering or revision checks) runs inside a single `ownerDatabase.write` closure.
- 2026-10-14 (from the PR #26 review): the focus engine emits bare session policies; FocusCoordinator wraps every publish with schema version, revision and effective time, so extensions can reject stale or out-of-order policies (required by #15). A normal-session break publishes the break end, so extensions resume blocking on their own if the app is gone.
- 2026-10-14 (assumption): a break may run past the planned session end; the session then ends at the planned end. Still holds: breaks keep the planned end (decision 0004, 2026-11-02).
- 2026-10-14: Quick capture uses one field, as in the design reference: the app splits a trailing deadline phrase off the title and previews both before saving.
- 2026-10-14: Logo direction "Scope" (ring plus one dot), specified in [docs/design/focuspilot-logo.html](../design/focuspilot-logo.html): flat system blue app icon built with Icon Composer, and custom monochrome menu bar template images for idle (ring), focusing (ring and dot), paused (hollow dot) and observe-only (dashed ring). Proposed by Claude: the time next to the menu bar icon is a Settings option, off by default, so the item stays narrow on crowded menu bars.
- 2026-10-15: When the owner moves the pinned Now task out of Now, the first Next task becomes Now in the same write; if Next is empty, Now stays empty. Nothing else changes Now.
- 2026-10-15: Safari spike S1: an ad hoc signed app with a `group.` App Group triggers the macOS 15+ consent prompt on every container access. Shipping the App Group needs a Team ID prefix (paid developer account) or an authorizing profile; the spike's fallback is a shared folder through the extension's home-relative temporary exception (see #1).
- 2026-10-15: A project links to at most one Herdr workspace (or none). Projects can be imported from Herdr workspaces, and while FocusPilot runs, a new Herdr workspace with no project automatically becomes a linked project (once per workspace; unlinked or deleted projects are not recreated). FocusPilot only reads Herdr for this.
- 2026-10-15: Tasks can be added and read from Herdr panes (owner or agents) through a `focuspilot` CLI. Adds go straight to the end of Next in the workspace's linked project, marked "from Herdr" and undoable; the CLI can never change Now, order, deadlines, or existing tasks. Reads are limited to the caller workspace's project plus the current Now action.
- 2026-10-15: All user-facing text in FocusPilot is in English, placeholders included; typed capture input is still parsed in Spanish or English. (A Spanish-only request earlier the same day was withdrawn by the owner.)
- 2026-10-16: The strict-session early-end wait is confirmed at 60 seconds, after a confirmation; the owner can cancel and keep focusing.
- 2026-10-16: Herdr workspaces that already exist the first time FocusPilot sees a Herdr session are imported by the owner ("From Herdr…"), not auto-created; only workspaces that appear afterwards become projects automatically. Auto-sync never adopts an existing project by name.
- 2026-10-17: During a strict session, weakening a block rule (deleting it, loosening its activation or schedule, or allowing a blocked target) needs the same confirmation and 60-second wait as ending early; adding or tightening rules is immediate.
- 2026-10-17: The wrap-up sheet appears only when a session ends, not on pauses. Every wrap-up is kept as history per task; the latest one drives the next action and the return cue.
- 2026-10-20: Chrome first. Without a paid Apple developer account, Safari disables the unsigned FocusPilot extension whenever Safari quits, so FocusPilot enforces blocking through Chrome first (#16). #13 (FocusPilot's own Safari extension) is deferred. For now Safari is covered by an owner-chosen third-party blocker from the Mac App Store, shown in protection status as "external blocker, not verified". If that blocker exposes Shortcuts actions, FocusPilot may start and stop it with sessions (to be validated). Spike S3 passed in both browsers (#3).
- 2026-10-22: Chrome incognito: the owner turns on "Allow in Incognito" for the FocusPilot extension once; when it is off, protection status shows incognito as unprotected. FocusPilot does not disable incognito mode.
- 2026-10-22: Starting a strict session cancels exceptions granted before it (for apps and sites); an exception inside a strict session needs a reason, confirmation and the 60-second wait.
- 2026-10-26: Policy revision numbers, checksums and the compiled policy are diagnostics. The UI shows plain language ("Chrome has your latest rules" / "Chrome is updating…"), and the numbers sit behind a collapsed "Show technical details".
- 2026-10-26: Exceptions requested from Chrome are trusted only from a parent process signed by Google (Team ID check), not by path. No extra in-app confirmation per request; the strict wait and the notification still apply.
- 2026-10-26: Observe-only mode records raw activity (front app bundle ID; Chrome front-tab domain, never incognito or full URLs) only while observe-only is on, deleted after about 24 h; pilot events (sessions, resume time, blocked visits, exceptions) are kept. Nothing leaves the Mac. Turning observe-only off restores blocking immediately.

## Sources

- [Chrome service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)
- [chrome.alarms](https://developer.chrome.com/docs/extensions/reference/api/alarms)
- [LangSmith OpenTelemetry tracing](https://docs.langchain.com/langsmith/trace-with-opentelemetry)
- [Claude Code monitoring usage](https://code.claude.com/docs/en/monitoring-usage)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [GRDB.swift README](https://github.com/groue/GRDB.swift/blob/master/README.md)
