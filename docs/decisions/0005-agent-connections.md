# Agent connections beyond Herdr

Date: 2026-11-03. Status: proposed by the fork owner on 2026-11-03; the owner's answers below are confirmed, the rest is proposed until the owner accepts this record. Items marked "validate" are unproven platform assumptions and need a primary source or a spike before they are built. In this fork, "owner" means the fork owner (decision 0004).

## Why

Phase 1 links agents to tasks only through Herdr panes (decision 0003). The owner does not use Herdr: they run Claude Code in the Warp terminal and may use other AI tools. FocusPilot cannot read Warp's tabs or any other terminal's contents, so it has to hear from the agents themselves.

The aim is one idea of a linked agent, fed by several connections, so a new tool is an adapter, not a new feature.

## Rules that do not change

- FocusPilot reports and reminds. It never prompts, answers, approves, interrupts or stops an agent on the owner's behalf (AGENTS.md).
- Agent monitoring is a setting, off by default (decision 0004, 2026-11-02). With it off, FocusPilot runs no agent commands and refuses reports with a clear message.
- Every report keeps its provenance: which connection sent it and how sure it is. A process seen running is not "working"; no report for a while is "Unknown", never "done".
- No usage, token or cost figures are inferred from these connections (decision 0002).
- Everything an agent sends is untrusted input: validated, size-capped, never executed or rendered as markup.

## The agent model

An agent link has: a source (one of the connections below), a label, a working folder, optionally a task, a state (Working, Needs you, Ready, Failed, Unknown), the last message, and when it last reported. It is matched to a task by its folder or linked by hand, as Herdr links are. Finished results go to the Review queue; while a day plan is active they wait until the next break (D8).

## Connections

| # | Connection | Covers | What FocusPilot learns | Status |
|---|---|---|---|---|
| 1 | Herdr | Agents in Herdr panes | Working, blocked, done; jump to the pane | Exists (Phase 1) |
| 2 | Generic command: `focuspilot agent report …` and `focuspilot run --task <id> -- <command>` | Any command-line agent or script | Started, needs you, finished, exit status, a short message | Proposed, first |
| 3 | Claude Code hooks calling #2 | Claude Code in any terminal, Warp included | Session started, needs input, turn finished, last message | Proposed, first; validate event names and payloads against Claude Code's hooks documentation |
| 4 | FocusPilot as an MCP server | AIs that speak MCP: Claude Code, Claude Desktop, Cursor, Codex and others | The AI reports its status only (owner, 2026-11-03) | Proposed, second; validate each client's MCP support |
| 5 | Cursor hooks | Cursor's agent | Started, needs you, stopped | Proposed, third; validate that Cursor offers agent hooks and their events |
| 6 | Codex `notify` | OpenAI Codex command-line tool | Turn finished | Proposed, third; validate the setting and its payload |
| 7 | Cloud agents through GitHub | Claude Code on the web, Codex cloud, Copilot coding agent | Pull request opened, checks passed or failed, ready for review | Proposed, later, if the owner uses cloud agents |
| 8 | Process watcher | Any agent process, no setup | Only "an agent is running", with no state | Proposed, fallback only |

Connections 3, 5 and 6 are thin: each tool's hook calls the generic command (#2), so there is one validated entry point. MCP (#4) feeds the same model with status reports only.

## Going back to the agent's workspace

Clicking an agent in the Agent panel, or its notification, or the raccoon's bubble, should bring the owner to where that agent runs. A click is an owner action, so this is allowed. What each place permits differs:

| Where the agent runs | What a click can do | Status |
|---|---|---|
| Herdr | Focus the agent's pane | Exists (Phase 1, manual navigation) |
| Warp | For an agent started with **Start Claude Code** (task's Agent panel): raise that agent's own Warp window, found by its title through Accessibility. Otherwise bring Warp to the front, and offer a new tab in the agent's folder. | Validated 2026-11-10 (owner's Mac spike; docs.warp.dev/terminal/sessions/launch-configurations and docs.warp.dev/terminal/more-features/uri-scheme): `warp://action/new_window?path=` opens a window in a folder; a launch configuration in `~/.warp/launch_configurations/<name>.yaml` (directory created if missing), opened with `warp://launch/<name>`, opens a window whose tab runs its commands in its `cwd` (absolute, per the docs); the tab's `title:` becomes the window's title and stays fixed even when the program sets its own title, but follows the active tab if the owner opens another tab there; AXRaise on the window with that title, then bringing Warp forward, raises it. Warp still has no way to pick an existing tab and no AppleScript dictionary. Still to confirm in the owner's try-it: that `claude` itself starts from the configuration (only `echo`/`printf` were tried), that Warp uses a configuration rewritten under the same name, and that the window keeps its title while Claude Code sets its own. Warp calls launch configurations legacy in favour of Tab Configs. |
| Terminal and iTerm2 | Bring the exact tab forward through AppleScript, matched by the terminal device the hook reports | Validate; needs the owner's Automation permission |
| Cursor and VS Code | Open or focus the window for the agent's folder (their command-line tool or URL scheme) | Validate |
| Cloud agents | Open the pull request in the browser | Proposed |

To make this possible, each report carries what the hook knows about where it runs: the terminal app (`TERM_PROGRAM`), its session or terminal device when available, and the working folder. FocusPilot picks the best action it supports and falls back to bringing the app forward.

Warp, as built (2026-11-10): Start Claude Code writes `focuspilot-task-<id>.yaml`, whose one tab is titled `FocusPilot · <task title> (<id>)`, the number keeping two tasks with the same title apart, runs in the task's folder (where an agent linked to it last reported from, else its project's Herdr workspace folder, else one the owner chooses) and runs `env FOCUSPILOT_TASK=<id> claude`. `focuspilot agent report`, hooks included, reads `FOCUSPILOT_TASK` when no `--task` is given, so the agent reports already linked; the owner's own link or unlink still wins, and only an open task is linked. The title and folder are escaped double-quoted YAML values, the command holds only fixed text and the task's number, and a folder with shell or path-expanding characters is refused (spaces are allowed). Go to agent reads the title back from that file, so renaming the task doesn't lose the window, and looks for a window only when the file exists, so an agent FocusPilot never started asks for nothing. The files of tasks that are done or gone are removed. This needs FocusPilot turned on in System Settings › Privacy & Security › Accessibility: the first click in a launch asks macOS to show its request, and otherwise Warp comes forward with a notice saying where to turn it on. An unsigned or ad-hoc signed rebuild of the app may make macOS ask again, since the signature changes. Nothing runs without the owner's click, and the button is off while agent monitoring is off.

Notifications: FocusPilot's notifications are currently delivered quietly (provisional authorization). Clicking one already reaches the app; with the target above it would open the workspace instead. Banner notifications need the owner's permission, asked once.

## Order of work (replaces D17's scope)

1. Generic command (#2), Claude Code hooks setup (#3) with a copy-paste snippet, the agent model, the Agent panel and Review queue for non-Herdr agents, and click-to-workspace for Warp and Terminal/iTerm2 as far as validated. Agent monitoring setting (D8) covers all sources. **Built 2026-11-03 (D17, #24)**, awaiting the owner's try-out. The setup is in [docs/agents/claude-code-hooks.md](../agents/claude-code-hooks.md) and the checks in [VALIDATION_PLAN.md](../VALIDATION_PLAN.md). As built:
   - The Agent monitoring setting covers reported agents only. Herdr does not read it until D8.
   - Warp is brought forward. A new tab in the agent's folder is a separate button, since Warp documents no way to reach an existing tab.
2. MCP server (#4).
3. Cursor and Codex adapters (#5, #6) after validation.
4. GitHub cloud agents (#7) and the process watcher (#8) if the owner wants them.

## Confirmed by owner

- 2026-11-03: Claude Code is the tool in use today, but FocusPilot should support as many connections as possible; the order of work above stands.
- 2026-11-03: When an agent needs the owner, the raccoon says so right away, during focus blocks too, strict sessions included, since agents usually work on the current task. It peeks with the agent's label and a button to go to its workspace, with the soft sound. Finished results still wait in the Review queue as above.
- 2026-11-03: An AI connected through MCP only reports its status. It does not read or change the plan or tasks and does not propose tasks.
- 2026-11-10 (owner chose): Warp cannot select an existing tab, so FocusPilot starts each Claude Code agent in its own named Warp window (a launch configuration) and Go to agent raises that window through Accessibility.
