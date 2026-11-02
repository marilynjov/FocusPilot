# Day planner, quick timer and raccoon companion

Date: 2026-11-01. Status: direction confirmed by the fork owner on 2026-11-01. Items marked "proposed" still need confirmation, and items marked "validate" are unproven platform assumptions. In this fork, "owner" means the fork owner (Marilyn): owner decisions and the sign-offs AGENTS.md asks for go to her. Earlier records (0001–0003) use "owner" for Santiago.

This fork (`marilynjov/FocusPilot`) extends FocusPilot from a focus assistant built around Herdr agents into an assistant that organizes the whole working day. It keeps everything Phase 1 built: tasks and deadlines, focus sessions, app hiding, Chrome enforcement, wrap-up and Herdr status.

## Why build on FocusPilot

Most of what the day planner needs already exists and was hard to get right: hiding blocked Mac apps (T5b), Chrome enforcement with timed exceptions (T7a, T8), session end without the app (T7b), focus sessions and wrap-up (T4, T12), and Spanish/English capture parsing (T2). The missing pieces are additions on top of these, not a different foundation.

## The day loop

1. The owner describes the day in plain language, e.g. "I work 9 to 5, lunch is 12 to 1 as always, I have three tasks and the first is the most important."
2. The assistant proposes a day plan: an ordered timeline of blocks (task, break, lunch, wrap-up), each with a start and end and, for task blocks, the block rules that apply.
3. Nothing starts until the owner approves the plan. The owner can also edit blocks by hand.
4. When a task block starts, it runs a focus session with its block rules (hidden apps, blocked sites). Breaks and lunch lift session-only rules in normal sessions; strict sessions and always-on or scheduled rules keep blocking (decision 0003, 2026-10-14).
5. If a block runs over, the assistant proposes a change to the rest of the day. The owner accepts or keeps the plan.
6. At the end of the day, a review shows what was done, compares estimated and actual time, and moves unfinished work to tomorrow.

This follows the existing rule: AI proposes; deterministic code validates and executes. A plan is structured state (blocks, times, rules), not conversation memory.

## Confirmed by owner

- 2026-11-01: Build in this fork on top of FocusPilot rather than starting over. Santiago's repository is `upstream`; this fork does not push, open pull requests, or file issues there unless the owner asks.
- 2026-11-01: The day loop above, including approval before anything starts and plan changes only on approval.
- 2026-11-01: A quick timer the owner starts by hand ("this won't take more than 20 minutes"), separate from the plan, with presets and a custom length.
- 2026-11-01: A virtual pet companion, a pixel-art raccoon, that shows time left, warns before blocks end, and reacts to plan events.
- 2026-11-01: Herdr agent monitoring becomes a setting the owner turns on or off. With it off, the app does not run Herdr commands.
- 2026-11-01: Additions: replanning when a block runs over, estimated vs. actual tracking, breaks inside long blocks and buffers between tasks, a parking lot for stray thoughts during focus, an end-of-day review, a menu bar countdown, and focus stats.
- 2026-11-01: Compact views: a menu bar countdown with a small menu, a mini floating panel, and a raccoon-only mode.
- 2026-11-02: Raccoon art comes from the owner's "Raccoon Pet: poses & emotions" sheet (20 named poses such as Idle, Working, Waiting). Each pose is split into layers: body, head, a closed-eyes head for blinking, objects that never move (laptop, sign, wall, ledge and paws), floating effects (hearts, zzz, steam) and the floor shadow. The shadow never moves sideways except under the walking pose, and walking swings four separate legs. This replaces the earlier proposal of whole-pose crossfades.
- 2026-11-02: Color palettes, each with light and dark versions that follow the Mac's appearance by default: Raccoon (warm), Neutral, Colorful (pastel in light mode), Forest, and System (based on the Phase 1 macOS look, with a softer, brown-free dark mode). Exact colors are on screen 7 of the design canvas.

## Proposed

- Agent monitoring is off by default for a new install.
- Working hours and a daily fixed block such as lunch are owner preferences stored in the app. Calendar sync stays a release exclusion ([Product](../PRODUCT.md#release-exclusions)).
- The raccoon has three presence modes: stays on screen, peeks in for reminders only, and off. It lives in a borderless, transparent, always-on-top window that lets clicks pass through except on its speech bubble (validate on macOS 26, including full-screen apps and multiple displays).
- Real frame-by-frame animation, if wanted later, is drawn from one base sprite. The macOS accessibility setting Reduce motion turns all raccoon motion off.
- Raccoon moments: peek in at 10 minutes left, work alongside during focus, walk in 2 minutes before a break, coffee during breaks, nap at lunch, celebrate a finished block, cheer with "You got this" when a blocked site is opened, and change poses between blocks.
- Quick timer presets: 10, 20, 30 and 45 minutes; the raccoon warns at 2 minutes left.
- Stats count only time in planned blocks and quick timers, never total screen time, and show what was done next to the time (from wrap-ups and finished blocks), because time in a block is not proof of output ([Product](../PRODUCT.md#principles), principle 8). The planner may propose a buffer from past estimate accuracy ("big tasks take you about 20% longer"); it never changes plans without approval.

## Conflicts with earlier decisions

- Coaching was planned only after the quiet focus loop is reliable, behind an experiment flag ([Product](../PRODUCT.md#first-release-scope)). The raccoon's warnings are coaching. Proposed: they ship as an opt-in mode and follow Coach-style suppression and cooldowns.
- The first model calls require local AI usage accounting and a daily admission cap ([Feature matrix](../FEATURE_MATRIX.md), decision 0003). The AI planner ticket includes them.
- Herdr status is P0 in the [Feature matrix](../FEATURE_MATRIX.md), and decision 0003 (2026-10-15/16) creates projects automatically from new Herdr workspaces. With agent monitoring off, the app runs no Herdr commands, so workspace sync also pauses. Proposed: existing projects and links are kept, sync resumes when monitoring is turned back on, and the `focuspilot` command still adds and reads tasks but without a Herdr project link.
- The product definition centers on Herdr agents. In this fork the day plan is the center and Herdr is optional; [Product](../PRODUCT.md) needs a revision once this record is accepted.

## Open decisions

- Which model provider and model the planner uses, and whether the owner supplies an API key.
- Whether the owner owns usage rights to the raccoon sprite sheets, which were AI-generated, before any public release.
- Default length of breaks inside long blocks and of the buffer between tasks.
- Which palette a new install starts with.

## Mockups

The owner's design canvas (private link, updated 2026-11-02) has seven screens: plan my day (approval), today (focus, quick timer, agent monitoring switch, raccoon mode), raccoon on the desktop, compact views, stats with estimated vs. actual time, raccoon moods (all 20 poses animated), and color palettes with agent monitoring on.
