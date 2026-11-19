# dsh-task-chime-badge

[![ci](https://github.com/todrinkcho/dsh-task-chime-badge/actions/workflows/ci.yml/badge.svg)](https://github.com/todrinkcho/dsh-task-chime-badge/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/dsh-task-chime-badge.svg)](https://www.npmjs.com/package/dsh-task-chime-badge)

「跑完了叫我」 — a "tell me when it's done" for the DeepSeek Harness Windows desktop shell: a chime when a turn finishes, plus a colored dot on the harness taskbar button that stays until you read it.

| Moment | Sound | Taskbar button |
| --- | --- | --- |
| A turn finishes and nothing else is running | one "ding" | green dot |
| The agent asks you a question / waits for an approval | two-note "ding-dong" | amber dot |
| You focus the window (= you read it) | — | dot cleared; an unanswered question brings the amber dot back when you look away |

The dot is a Windows taskbar **overlay icon** (`ITaskbarList3::SetOverlayIcon`). Windows 11 paints it in the upper-right corner of the button, which is what makes it read as a little unread bubble; Explorer owns the exact position, the app cannot move it. There is no unread-count API on Windows, so this is a dot, not a number.

Turns started from an IM bot (WeChat, Feishu, DingTalk, ... through dsh-im) **do not** ring the desktop: otherwise a bot answering in a group chat would chime at you all day. Turns started in the desktop window, or woken by a goal round, a teammate message or a background job, still notify.

Windows only — the badge needs the desktop shell's taskbar button. In a browser (`dsh web`) the chime still plays but there is nothing to badge.

## Install

Requirements: Windows 10/11 and the DeepSeek Harness desktop app. Node 18+ (ships with DSH). No admin rights, no build step, no dependencies.

**From npm** — nothing to download. Open **Plugins** in the sidebar, click **Add plugin**, type `dsh-task-chime-badge` in the package field (a version is optional, e.g. `dsh-task-chime-badge@1.0.0`), then click **Install**. Or ask your agent to run `plugin_manager` with `install_bundle` and the same name. A freshly published version takes a few minutes to reach a mirror registry such as npmmirror; if the install says the package is missing, pick the official npm registry in the dialog's **Registry** selector and retry.

**From the release zip** — download `dsh-task-chime-badge-1.0.0.zip` from [Releases](https://github.com/todrinkcho/dsh-task-chime-badge/releases/latest), unzip it (the archive contains one top-level `dsh-task-chime-badge/` folder), then install that folder as a bundle:

- **GUI** — **Plugins** → **Add plugin**, and pick the folder; or
- **Agent** — ask your agent to run `plugin_manager` with `install_bundle` and the folder's absolute path.

**From git** — `git clone https://github.com/todrinkcho/dsh-task-chime-badge.git`, then one of the two ways above.

Check that the row **Task chime and badge** is enabled in **Plugins**, then start a turn and switch to another window to see the green dot. This is a Host-only bundle: there is nothing on npm, the checkout itself is the package (`dsh.bundle.patch` points at `cordis.patch.yml`).

## Configuration

Edit the `config` block in `cordis.patch.yml` (or the plugin's row in Plugin Manager):

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch |
| `chimeOnDone` | `true` | Play the "ding" when a turn finishes |
| `chimeOnAsk` | `true` | Play the chime when the agent waits for you |
| `watchApprovals` | `true` | Count approval prompts as "waiting for you" too |
| `ignoreImTurns` | `true` | Skip the notification for turns started by an IM bot |
| `imRpcIdPrefixes` | see below | RPC id prefixes that mark a prompt as coming from an IM channel |
| `quietMs` | `900` | How long everything must stay idle before "finished" is announced (debounces back-to-back tool calls) |
| `processName` | `DeepSeek Harness` | Window process to badge; only change it if you renamed the install |
| `helperPollMs` | `350` | Helper polling interval; lower reacts faster, costs more battery |
| `debug` | `true` | Write `plugin.log` / `helper.log` |

Default `imRpcIdPrefixes`: `feishu`, `weixin`, `dingtalk`, `wecomapp`, `wecom`, `qq`, `slack`, `telegram`, `discord`, `whatsapp`, `imessage`, `matrix`, `email`, `office`, `im`. Prompts typed in the desktop window carry a bare UUID with no channel prefix, so they never match.

## Logs

Both files live in `%USERPROFILE%\.dsh\cache\task-chime-badge\` and are truncated when they pass 256 KB:

- `plugin.log` — the Host half's decisions (which agent started/finished, when "finished" was announced, command sequence numbers).
- `helper.log` — what the helper actually did (which window it found, which overlay it painted, whether the WAV played, focus changes).

Set `debug: false` to stop writing them.

## How it works

- `index.js` (Host half) listens to four seams:
  - `agent/status` keeps the set of running agents; when the last one turns idle and stays quiet for `quietMs`, the turn counts as finished.
  - `session/event` follows `turn/start` / `user/message` / `turn/end` and records the `source.rpcId` of every real prompt in the open turn, so a turn that came only from IM can be skipped. A turn with no prompt of its own (goal round, subagent, background job) still notifies.
  - `user-questions/request` and `approval/request` are wrapped around `next()`: the amber dot goes up while the user is being asked and clears when the answer settles.
- Every state change writes one small JSON file, `%USERPROFILE%\.dsh\cache\task-chime-badge\command.json`, with a timestamp-based `seq` (written to a temp file, then renamed, so a reader never sees half a command).
- `helper/taskbar-helper.ps1` is one long-lived, hidden PowerShell process. It polls the command file, paints the overlay through the COM interface `ITaskbarList3`, plays the WAV through `winmm!PlaySound`, watches the foreground window, and exits by itself once the Host process is gone. No sockets, no network, no admin rights, no changes to your system sounds.
- The two chimes are synthesized WAVs (`assets/done.wav`, `assets/ask.wav`), so the plugin neither depends on nor modifies your Windows sound scheme.

## Limitations

- Windows desktop shell only. `ITaskbarList3` needs a real taskbar button; a browser tab has none.
- Overlay dot, not an unread count — Windows has no badge-count API for taskbar buttons.
- No dot while the window is focused (that counts as read), but the chime still plays. Switch to another window to see the dot.
- A full-screen app (F11 in a browser, games) covers the whole taskbar, so the dot is hidden until you leave full screen.
- The badge lives on the taskbar button: if the window is folded into the tray or the taskbar is hidden, there is no button to paint.
- Explorer restart is handled (the COM object is re-created on failure), but a restart of the harness itself is what replaces the helper.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| No chime, no dot | `plugin.log` — was the turn announced? Is `enabled` true? Is the window actually going idle? |
| Chime but never a dot | `helper.log` for `no taskbar window` — the window may be minimized to tray, the taskbar hidden, or `processName` wrong |
| Two chimes for one turn | Another copy of the plugin is installed and running |
| Nothing at all, no logs | The plugin did not activate: check its row in **Plugins**, then restart the app |

## Uninstall

Disable or remove the bundle in **Plugins**. The helper exits together with the Host process; nothing is left behind except the two log files under `%USERPROFILE%\.dsh\cache\task-chime-badge\`, which you can delete.

## License

[MIT](LICENSE)
