# Marketplace listing (do not auto-file)

Paste into a new issue on [omacom/omarchy-plugin-marketplace](https://github.com/omacom/omarchy-plugin-marketplace).

**Title:** `[Plugin]: omaSeek`

**Repository URL:** `https://github.com/5h3rd1l/omaSeek`

**Category:** `Productivity`

**Tags:** `ai`, `search`, `claude`, `quickshell`, `hyprland`

**Maintainer notes:**

> Overlay plugin. Questions go to the user's already-installed agent CLI on stdin (never argv) via `python3 -I -S ask.py`. For Claude, one `claude -p` stream-json process runs per chat; safe mode (default on) routes every permission request to the overlay for Allow / Deny, and when the user turns it off Claude runs with `--dangerously-skip-permissions`. Saved chats and settings live in `~/.local/state/omaseek` (0700); pasted images in `~/.cache/omaseek/shots`, deleted after sending. Recent chats also read the user's own Claude session files for omaSeek's print-mode sessions. New chats get a title from one `claude -p --model haiku --no-session-persistence` call. No sudo, no downloads, no writes to user config; the key and blur rule are documented, not installed.
