# Claude Code hooks for FocusPilot

Claude Code can run a command when certain things happen in a session. These are its hooks. With the hooks below, Claude Code tells FocusPilot when a session starts, when it is working, when it needs you, and when it has finished. This works in any terminal, Warp included, and without Herdr. It is step 1 of [decision 0005](../decisions/0005-agent-connections.md).

FocusPilot only listens. It never answers Claude, approves anything, sends a prompt or stops a session. It reads no usage, token or cost figures from hooks.

## Before you start

1. In FocusPilot, open **Settings › General** and turn on **Agent monitoring**. It is off by default. While it is off, FocusPilot refuses every report, and the hook shows "agent monitoring is off".
2. The hooks call the `focuspilot` command, which ships inside the app. **Settings › General › Claude Code hooks** shows the hooks block with the full path to the command already filled in. Its **Copy** button is the easiest way to get it. To use the plain block below instead, put the command on your PATH once:

   ```sh
   ln -s ~/Applications/FocusPilot.app/Contents/Helpers/focuspilot ~/.local/bin/focuspilot
   ```

## The hooks block

Add this to `~/.claude/settings.json`. If the file already has a `"hooks"` object, add these four events to it rather than replacing it. FocusPilot never edits this file itself.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "focuspilot agent report --from-claude-hook SessionStart", "async": true }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "focuspilot agent report --from-claude-hook UserPromptSubmit", "async": true }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "focuspilot agent report --from-claude-hook Notification", "async": true }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "focuspilot agent report --from-claude-hook Stop", "async": true }] }
    ]
  }
}
```

The command reads the JSON that Claude Code sends to the hook on stdin, so `jq` is not needed.

## What each hook reports

| Claude Code event | FocusPilot shows | Message kept |
|---|---|---|
| `SessionStart` (a new, resumed, cleared or compacted session) | Working | none |
| `UserPromptSubmit` (you sent a prompt) | Working | none; your prompt is never stored |
| `Notification` of type `permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` or `quota_auto_resume_stale` | **Needs you**: the raccoon peeks at once with **Go to agent** and plays the soft sound, and a notification arrives. This happens during focus blocks too, strict sessions included. | Claude's notification text |
| Other `Notification` types, such as `idle_prompt` (sent a minute after a finished turn) | nothing | |
| `Stop` (Claude finished responding) | Ready, and the result goes to the Review queue. While a day plan block is running, it waits there until the next break. | `last_assistant_message`, up to 2,000 characters |
| `Stop` while background tasks are still running | Working ("Waiting for 1 background task") | |

The agent's label is the session's title if it has one, otherwise "Claude Code · <folder name>". To name it yourself, add `--name <label>` to the commands.

An agent that has said nothing for 30 minutes while working, or for 2 hours while waiting for you, shows as **Unknown**. Unknown is never shown as done.

### Which task

FocusPilot links an agent to a task when it first hears from it. It does this only when a folder says which task:

- If you linked an earlier agent in the same folder, or a parent folder, to a task by hand, the new agent follows that link.
- If the folder is inside a project's Herdr workspace folder, and that project's task is Now, the agent is linked to the Now task.

The closest folder wins. Otherwise the agent appears under **Not linked to a task** in any task's Agent panel. Use **Link Here** to link it. A result from an agent with no task stays on the agent and does not go to the Review queue.

## Try it in Warp

1. Turn on **Agent monitoring** and copy the hooks block from **Settings › General**, as above. Paste it into `~/.claude/settings.json` and save the file.
2. In Warp, `cd` into a project folder and run `claude`. Hooks are read when a session starts, so start a new one.
3. In FocusPilot, select a task and look at its **Agent** panel. "Claude Code · <folder>" appears under **Not linked to a task**, marked Working. Click **Link Here**.
4. Ask Claude to do something that needs your permission, such as running a shell command, and look away from Warp for about six seconds. Claude Code waits that long before it sends a permission notification. The raccoon peeks in: "Claude Code · <folder> needs you". Its **Go to agent** button brings Warp to the front. A notification arrives too, and clicking it does the same.
5. Approve the request in Warp and let Claude finish. The Agent panel shows Ready with Claude's last message, and the result is in the Review queue.
6. Turn **Agent monitoring** off and send another prompt. Claude Code shows a hook error saying that agent monitoring is off. Nothing is recorded, and Claude carries on as usual.

**What Go to agent can do in Warp:** it brings Warp to the front, but not the agent's own tab. Warp documents no way for another app to pick an existing tab (see Sources below). When Warp is the terminal, the Agent panel also has **New Warp Tab Here**. That button opens a new tab in the agent's folder through Warp's documented URL. It is a new tab, not the agent's own. In Terminal and iTerm2, Go to agent selects the agent's exact tab by its terminal device. The first time, macOS asks whether FocusPilot may control that app (Automation). If you decline, Go to agent still brings the app to the front.

## Known limits

- After you approve a permission request, the agent still shows **Needs you** until Claude finishes its turn, because no hook reports that the approval happened.
- Reports are not queued while FocusPilot is closed. The hook fails quietly, with a hook error, and the next report after FocusPilot opens brings the agent up to date.
- Hooks run with `"async": true`, so Claude never waits for FocusPilot. FocusPilot's hook commands never print to stdout and never exit with status 2. On `Stop`, status 2 would keep Claude from stopping.
- The terminal app comes from `TERM_PROGRAM` and the tab from the process's controlling terminal. Claude Code's documentation says hooks inherit its environment. Neither value is named there, so both were checked in practice: `TERM_PROGRAM=WarpTerminal` was seen in a Warp shell. Whether they reach a hook in your setup is one of the things to confirm in the try-it steps.

## Sources

Checked on 2026-11-03:

- Claude Code hooks reference, <https://code.claude.com/docs/en/hooks>. It covers:
  - the event names `SessionStart`, `UserPromptSubmit`, `Notification` and `Stop`;
  - the settings format (`hooks` › event › `[{ matcher, hooks: [{ type: "command", command, async }] }]`; `Stop` and `UserPromptSubmit` take no matcher, and a `Notification` hook without a matcher receives every type);
  - the common stdin fields `session_id`, `cwd` and `hook_event_name`, with `message` and `notification_type` for Notification, `last_assistant_message` and `background_tasks` for Stop, and `session_title`;
  - the notification types and when they fire (`permission_prompt` after about six seconds without typing; `idle_prompt` about 60 seconds after a finished turn);
  - that hooks inherit Claude Code's environment;
  - exit codes (2 blocks; on Stop it keeps Claude going; other nonzero codes are non-blocking errors);
  - that stdout JSON or plain text can act as a decision or as context;
  - `async` hooks.
- Warp URI scheme, <https://docs.warp.dev/features/uri-scheme>. It documents `warp://action/new_tab?path=<folder>` and says the scheme cannot target or control a tab that is already open.
- iTerm2 AppleScript, <https://iterm2.com/documentation-scripting.html>. A session has `tty`, and windows, tabs and sessions each have `select`.
- Terminal's scripting dictionary, `/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.sdef`. A tab has `tty` and a writable `selected`, and a window has a writable `frontmost`.
- Apple: [NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) and [errAEEventNotPermitted (-1743)](https://developer.apple.com/documentation/coreservices/errAEEventNotPermitted).
