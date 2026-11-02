# FocusPilot

Working name for a native macOS focus assistant. Phase 1 implementation has started; see [BUILDING.md](BUILDING.md) to build, run and test it.

FocusPilot helps its owner choose a concrete next action, work across Herdr and browser tools, and return from distraction. It supports existing project folders and creates new task environments only under user-configured parent folders.

## Design documents

- [Product](docs/PRODUCT.md): problem, principles, scope, and release gates.
- [Feature matrix](docs/FEATURE_MATRIX.md): priorities and acceptance criteria.
- [Architecture](docs/ARCHITECTURE.md): components, authority, integration boundaries, and feasibility questions.
- [Data and memory](docs/DATA_AND_MEMORY.md): task model, durable memory, retrieval, retention, and caches.
- [AI usage and workload](docs/AI_USAGE_AND_WORKLOAD.md): token efficiency, local budgets, optional LangSmith, external-agent usage and urgent-task recommendations.
- [Experience](docs/EXPERIENCE.md): native visual direction, screens, and user flows.
- [Visual design board](docs/DESIGN_BOARD.svg): static layout studies for planning, focus, blocking, and workspace setup.
- [Phase 1 interface](docs/design/focuspilot-phase1-design.html): screens, states and SwiftUI component spec for Phase 1 (open in a browser).
- [Logo](docs/design/focuspilot-logo.html): app icon and menu bar glyph construction (open in a browser).
- [AI Workload visual study](docs/AI_WORKLOAD_BOARD.svg): agent/task usage, uncertainty and urgent-work recommendations.
- [Workspace rules](docs/WORKSPACE_RULES.md): existing environments and new folder/workspace provisioning.
- [Validation plan](docs/VALIDATION_PLAN.md): platform spikes and product experiments before implementation.
- [Decision log](docs/decisions/0001-initial-design.md): accepted choices and open decisions.
- [Observability decision](docs/decisions/0002-ai-observability-and-workload.md): native orchestration, local accounting and LangSmith boundaries.
- [Review corrections](docs/decisions/0003-architecture-review-corrections.md): accepted process model, enforcement ownership, data-model fixes and owner constraints.
- [Day planner and companion](docs/decisions/0004-day-planner-and-companion.md): this fork's direction: approved day plans, quick timer, raccoon companion, optional agent monitoring.
- [Product critique](docs/reviews/PRODUCT_REVIEW.md) and [architecture critique](docs/reviews/ARCHITECTURE_REVIEW.md): independent adversarial reviews.

## Current constraints

Mac-only. SwiftUI and AppKit for the app. Chrome is enforced first (decision 0003, 2026-10-20); FocusPilot's own Safari extension is deferred (#13), and Safari is covered for now by an owner-chosen third-party blocker shown as not verified. Herdr is a source of task execution state. Tasks and deadlines are managed in the app initially. Data is local by default; a remote model would receive explicitly selected context. Files remain within the owner's folder structure.

## Next step

Resolve the release-blocking platform spikes in the validation plan, then prototype the planning window, focus panel, and distraction page. Review the flows before implementing a broad supervisor.

## Status

This repository contains specifications, not validated claims of platform compatibility or bypass-resistant blocking. Proposed thresholds are starting hypotheses for testing.
