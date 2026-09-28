# Architecture

omaSearch is a `keepLoaded` Omarchy overlay (plugin id `io.github.5h3rd1l.omasearch`). The shell summons `Overlay.qml`, which never talks to an AI API itself: it runs helper scripts and paints what they print.

```
omarchy-shell shell toggle io.github.5h3rd1l.omasearch '{}'
        │
        ▼
 Overlay.qml            layer-shell overlay (namespace "omasearch")
   │
   ├─ Claude (warm)     python3 ask.py --serve [--session id] [--detailed] [--safe]
   │                      in:  {"prompt", "image"?} and {"approve", "allow", "always"} lines
   │                      out: ready / delta / tool / tool_result / approve / done / exit
   │
   ├─ other agents      python3 ask.py --agent <id> [--session id] --ask   (prompt on stdin)
   ├─ recent chats      ask.py --recent-claude,  ask.py --load-claude <id>
   ├─ chat titles       ask.py --title            ({"q", "a"} on stdin)
   ├─ pickers           ask.py --list / --select / --models / --select-model
   └─ clipboard         open_chat.py --copy       (text on stdin)
```

## Overlay.qml

The UI and all state. `open` / `close` / `toggle` / `dismiss` are the IPC surface.

| Piece | What it does |
| --- | --- |
| `serveProc` | The warm Claude process for the current chat; restarts (resuming the session) on a new model, New chat, or a Detailed / Safe change |
| `askProc` | One `ask.py --ask` per message for agents without a warm mode |
| `rowsModel` | The chat as rows: `you`, `text` (markdown answer), `tool` (steps as JSON), `approve`, `error` |
| `ChatText` | Read-only, selectable text; selecting copies, a click copies the whole piece |
| `history`, `claudeRecent` | Saved chats (`history.json`) merged with Claude's own sessions into the recent list |
| `GlassSheen` | The glass finish (sheen and rim) on the card, pill, menus and toast |
| `pasteProc` | Ctrl+V: saves a clipboard image into `~/.cache/omasearch/shots` for the next message |

State lives in `~/.local/state/omasearch/` (0700): `history.json` (chats, pins, hidden sessions, earlier questions), `settings.json`, `position.json`, plus `agent` and `models.json` written by `ask.py`.

## AskModel.js

Shared helpers (`.pragma library`): the agent table (keep `PROVIDERS` in sync with `ask.py`), markdown → blocks → rich-text segments, code highlighting from the theme palette, link handling, and parsing / merging of saved and Claude chats. Every string from a file or helper is clipped and validated before the UI uses it.

## ask.py

One JSON object per call on stdout (`--serve` streams JSON lines instead). The question is always on stdin, never argv.

- `--serve` drives `claude -p --input-format stream-json --output-format stream-json` and turns its events into the overlay's small event set. With `--safe` it passes `--permission-prompt-tool stdio`; each `can_use_tool` request becomes an `approve` event and waits for the overlay's answer. Images must come from the private shots folder, are checked by their first bytes (PNG, JPEG, WebP, GIF), and are deleted after reading.
- `--ask` runs the agent CLI once. Safe mode never bypasses approvals: Claude denies anything that would prompt, Codex runs read-only, OpenCode uses its plan agent.
- `--recent-claude` lists omaSearch's own Claude chats: print-mode (`sdk-cli`) sessions in the `$HOME` project folder, reading only the start of each file. `--load-claude` rebuilds one as overlay rows.
- `--title` names a chat with one Haiku call (`--no-session-persistence`).

## open_chat.py

`--copy` puts text from stdin on the clipboard with `wl-copy`, so text never appears on a command line.

## Theme

Colours come from `Color.menu` and `Style`; code colours come from the theme's `colors.toml` palette. Don't hard-code colours.
