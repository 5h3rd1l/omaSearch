#!/usr/bin/python3
"""One-shot overlay answer for omaSearch.

Prints a single JSON object on stdout (capped), then exits.

  ask.py --info    metadata for `omarchy default agent`
  ask.py --ask     short answer; prompt on stdin (NUL- or EOF-terminated)
  ask.py --list    installed agents the overlay's logo menu offers
  ask.py --select <id>  remember <id> as omaSearch's agent (until changed again)
  ask.py --serve [--session <id>]  keep one Claude process warm for a chat:
                   {"prompt": "..."} lines in on stdin; JSON event lines out
                   (ready / delta / done / exit), streamed as Claude writes
  ask.py --models <agent>              models the model menu offers for <agent>
  ask.py --select-model <agent> <model>  remember <model> for <agent> ("" = CLI default)
  ask.py --title              short title for a chat; {"q", "a"} JSON on stdin
  ask.py --recent-claude       omaSearch's recent Claude chats (its print-mode sessions in $HOME)
  ask.py --load-claude <id>    one of those chats rebuilt as overlay rows, to reopen it
  --agent <id>     (before --info/--ask) use this agent for this call only
  --session <id>   (before --ask) continue that Claude/Codex/OpenCode session;
                   --ask reports the session id so a chat can continue in a terminal
  --detailed       (with --ask / --serve) fuller answers instead of short ones
  --safe           (with --ask / --serve) no command runs unapproved: --serve asks
                   the overlay ({"kind": "approve"} out, {"approve", "allow"} in);
                   --ask denies anything that needs approval
  --temp           (with --ask / --serve) a temporary chat: Claude and Codex save no
                   session to disk, and no session id is reported back
"""

from __future__ import annotations

import base64
import json
import os
import re
import signal
import subprocess
import threading
import time
import uuid
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bounded import MAX_CHILD_BYTES, MAX_PROMPT_BYTES, read_nofollow, read_stdin_prompt, run_bounded

PROMPT_INTRO = "You are a desktop assistant in a small overlay on the user's Omarchy (Arch Linux + Hyprland) laptop."

PROMPT_BASE = PROMPT_INTRO + """ The user is mid-task.

You can run shell commands and edit files to do what they ask. sudo may work, but it can ask for a password you can't type; if it does, say so. When they ask you to do something (install, uninstall, change a setting, find a file), do it rather than explaining how.

Your reply is shown as Markdown: paragraphs, bullet and numbered lists, **bold**, `inline code`, fenced code blocks and links all render."""

SHORT_RULES = """Rules:
- Keep it short: a few sentences, or a short list when that reads better. The answer, or what you did and the result.
- Be concrete. Put exact commands in code blocks; give key names and next steps when relevant.
- No preamble and no headings.
- Ask a question only when the request is ambiguous and a wrong guess would be destructive.
- If you are unsure, say so in one sentence and give the best next step."""

DETAILED_RULES = """Rules:
- Answer fully: explain the why as well as the what. Use headings, lists and code blocks where they help.
- Be concrete. Put exact commands in code blocks; give key names and next steps.
- Ask a question only when the request is ambiguous and a wrong guess would be destructive.
- If you are unsure, say so and give the best next step."""

# Set from --detailed / --safe / --temp (see main).
DETAILED = False
SAFE = False
TEMP = False


def system_prompt() -> str:
    """The overlay's instructions: short answers, or fuller ones with --detailed."""
    return PROMPT_BASE + "\n\n" + (DETAILED_RULES if DETAILED else SHORT_RULES)




PROVIDERS = {
    "grok": {"id": "grok", "name": "Grok", "web": "https://grok.com", "binary": "grok", "can_ask": True},
    "claude": {"id": "claude", "name": "Claude", "web": "https://claude.ai/new", "binary": "claude", "can_ask": True},
    "gemini": {"id": "gemini", "name": "Gemini", "web": "https://gemini.google.com/app", "binary": "gemini", "can_ask": True},
    "copilot": {"id": "copilot", "name": "Copilot", "web": "https://copilot.microsoft.com", "binary": "copilot", "can_ask": True},
    "codex": {"id": "codex", "name": "Codex", "web": "https://chatgpt.com", "binary": "codex", "can_ask": True},
    "opencode": {"id": "opencode", "name": "OpenCode", "web": "https://opencode.ai", "binary": "opencode", "can_ask": True},
    "crush": {"id": "crush", "name": "Crush", "web": "https://crush.xyz", "binary": "crush", "can_ask": True},
    "pi": {"id": "pi", "name": "Pi", "web": "", "binary": "pi", "can_ask": True},
    "omp": {"id": "omp", "name": "Oh My Pi", "web": "", "binary": "omp", "can_ask": True},
}

ALIASES = {
    "claude-code": "claude",
    "gemini-cli": "gemini",
    "github-copilot": "copilot",
    "open-code": "opencode",
    "oh-my-pi": "omp",
}

AGENT_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,31}$")
# Error text is collapsed to one short line.
MAX_SUMMARY_CHARS = 720
# The chat card scrolls, so answers may be longer and keep their markdown.
MAX_STREAM_CHARS = 20000
# A tool call's full input / output, shown when its row is expanded.
MAX_TOOL_CHARS = 4000
# Quick answers: Claude's own default effort can be very high (xhigh on Opus
# thinks for ~10s before the first word). The terminal keeps the user's effort.
QUICK_EFFORT = "low"
CHILD_ENV_KEYS = ("HOME", "PATH", "USER", "LANG", "LC_ALL", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME",
                  "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_SESSION_TYPE",
                  "XDG_CURRENT_DESKTOP", "DISPLAY")
MAX_CHAT_BYTES = 32000
# Agents whose overlay answers are real, resumable CLI sessions.
SESSION_AGENTS = ("claude", "codex", "opencode")
SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
# Commands (installs, updates) can take a while.
ASK_TIMEOUT_SEC = 600
AGENT_FILE = os.path.expanduser("~/.config/omarchy/defaults/agent")
# omaSearch's own choice from the logo menu; wins over the system default.
SELECTED_FILE = os.path.expanduser("~/.local/state/omasearch/agent")
# Model menu choice per agent, e.g. {"claude": "sonnet"}; missing = the CLI's default.
MODELS_FILE = os.path.expanduser("~/.local/state/omasearch/models.json")
MODELS_CACHE_DIR = os.path.expanduser("~/.cache/omasearch")
MODELS_CACHE_SEC = 24 * 3600
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$")
# Claude Code resolves these aliases to the latest model of each family.
CLAUDE_MODELS = [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
BASH = ["/usr/bin/bash", "--noprofile", "--norc"]


def emit(payload: dict, exit_code: int = 0) -> None:
    """Write one JSON object to stdout and exit."""
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    raise SystemExit(exit_code)


def canonical_agent(raw: str) -> str:
    """Allowlist an agent id; reject traversal and shell metacharacters."""
    ident = (raw or "").strip().lower()
    ident = ALIASES.get(ident, ident)
    if not ident or ident in (".", "..") or "/" in ident or "\\" in ident:
        return ""
    if not AGENT_RE.fullmatch(ident):
        return ""
    return ident


def default_agent() -> str:
    """Read `omarchy default agent` through a nofollow descriptor."""
    try:
        raw = read_nofollow(AGENT_FILE, max_bytes=256)
    except PermissionError:
        return ""
    if raw is None:
        return ""
    try:
        text = raw.decode("utf-8", "strict").strip()
    except UnicodeDecodeError:
        return ""
    return canonical_agent(text.split()[0] if text else "")


def provider_for(agent: str) -> dict:
    """Return the provider record for a canonical agent id."""
    known = PROVIDERS.get(agent)
    if known:
        return dict(known)
    return {"id": agent, "name": "AI", "web": "", "binary": "", "can_ask": False}


def result(provider: dict, **extra) -> dict:
    """Build the JSON payload the overlay parses."""
    payload = {
        "ok": False,
        "agent": provider["id"],
        "name": provider["name"],
        "web": provider["web"],
        "canAsk": bool(provider.get("can_ask")),
        "summary": "",
        "error": "",
        "code": "",
    }
    payload.update(extra)
    return payload


def tidy_summary(text: str) -> str:
    """Collapse CLI output to one short line (used for error text)."""
    body = " ".join(str(text or "").replace("\r", "\n").split())
    if body.startswith("```"):
        parts = body.split("```")
        if len(parts) >= 3:
            body = parts[1]
            if " " in body:
                first, rest = body.split(" ", 1)
                if first.isalpha():
                    body = rest
    if len(body) <= MAX_SUMMARY_CHARS:
        return body
    clipped = body[: MAX_SUMMARY_CHARS + 1]
    period = clipped.rfind(". ")
    if period >= 160:
        return clipped[: period + 1].strip()
    return clipped[:MAX_SUMMARY_CHARS].rstrip() + "…"


def wrapped_prompt(prompt: str) -> str:
    """Prefix the user question with the short-answer instructions."""
    return system_prompt() + "\n\nQuestion: " + prompt


def login_argv(argv: list[str]) -> list[str]:
    """Run an allowlisted CLI via a constant bash -c; prompt stays on stdin."""
    return [*BASH, "-c", 'exec "$1" "${@:2}"', "omasearch", *argv]


def binary_on_path(binary: str) -> bool:
    """True if the allowlisted binary name resolves on PATH."""
    if not binary or not AGENT_RE.fullmatch(binary):
        return False
    try:
        proc = run_bounded([*BASH, "-c", 'command -v -- "$1"', "omasearch", binary], max_bytes=4096, timeout=8)
    except (ValueError, OSError):
        return False
    return proc.returncode == 0 and bool((proc.stdout or b"").strip())


def invoke_for(agent: str, prompt: str, model: str = "") -> tuple[list[str], bytes] | None:
    """Headless argv plus stdin payload. Prompt never appears in argv."""
    invoked = base_invoke_for(agent, prompt)
    if invoked and model and MODEL_RE.fullmatch(model):
        argv, stdin_data = invoked
        flag = {"claude": "--model", "codex": "-m", "opencode": "-m"}.get(agent)
        if flag:
            # Right after the subcommand, before any positional / "--" argument.
            at = 2 if agent in ("codex", "opencode") else 1
            argv = argv[:at] + [flag, model] + argv[at:]
        invoked = (argv, stdin_data)
    return invoked


def session_invoke(agent: str, prompt: str, model: str, session: str) -> tuple[list[str], bytes, str]:
    """argv, stdin and session id for a resumable ask; follow-ups send only the new message."""
    raw = prompt.encode("utf-8")
    wrapped = wrapped_prompt(prompt).encode("utf-8")
    model_args = ["--model" if agent == "claude" else "-m", model] if model and MODEL_RE.fullmatch(model) else []
    if agent == "claude":
        sid = session or str(uuid.uuid4())
        # Safe mode can't ask anyone here, so anything that needs approval is denied.
        perms = (["--permission-mode", "default", "--permission-prompts", "none"] if SAFE
                 else ["--dangerously-skip-permissions"])
        argv = ["claude", "-p", *model_args, "--output-format", "text", *perms,
                "--effort", QUICK_EFFORT, "--append-system-prompt", system_prompt()]
        if TEMP:
            # Temporary chat: nothing saved, so nothing to resume later.
            return argv + ["--no-session-persistence"], raw, ""
        argv += ["--resume", sid] if session else ["--session-id", sid]
        return argv, raw, sid
    if agent == "codex":
        if session:
            sandbox = ["-c", 'sandbox_mode="read-only"'] if SAFE else ["--dangerously-bypass-approvals-and-sandbox"]
            return ["codex", "exec", "resume", "--json", "--skip-git-repo-check", *sandbox,
                    *model_args, session, "-"], raw, session
        sandbox = ["--sandbox", "read-only"] if SAFE else ["--dangerously-bypass-approvals-and-sandbox"]
        ephemeral = ["--ephemeral"] if TEMP else []
        return ["codex", "exec", "--json", "--skip-git-repo-check", *sandbox, *ephemeral, *model_args], wrapped, ""
    # opencode
    # The build agent can run commands; --auto approves them (no prompts here).
    # Safe mode uses the read-only plan agent instead.
    agent_args = ["--agent", "plan"] if SAFE else ["--agent", "build", "--auto"]
    argv = ["opencode", "run", *agent_args, "--format", "json", *model_args]
    if session:
        argv += ["-s", session]
    return argv, raw if session else wrapped, session


def parse_events(agent: str, text: str) -> tuple[str, str, str]:
    """Answer, session id and error from codex / opencode JSON event lines."""
    answer, sid, error = [], "", ""
    for line in text.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        if agent == "codex":
            if ev.get("type") == "thread.started":
                sid = str(ev.get("thread_id") or "")
            item = ev.get("item") or {}
            if ev.get("type") == "item.completed" and item.get("type") == "agent_message":
                answer.append(str(item.get("text") or ""))
            if ev.get("type") == "turn.failed":
                error = str((ev.get("error") or {}).get("message") or "")
        else:
            sid = sid or str(ev.get("sessionID") or "")
            part = ev.get("part") or {}
            if ev.get("type") == "text" and part.get("text"):
                answer.append(str(part["text"]))
            if ev.get("type") == "error":
                err = ev.get("error")
                error = str(err.get("message") if isinstance(err, dict) else err or "")
    return "\n".join(a for a in answer if a).strip(), sid, error


def base_invoke_for(agent: str, prompt: str) -> tuple[list[str], bytes] | None:
    """Headless argv plus stdin payload, without a model override."""
    raw = prompt.encode("utf-8")
    wrapped = wrapped_prompt(prompt).encode("utf-8")
    if agent == "grok":
        return [
            "grok",
            "--output-format", "plain",
            "--permission-mode", "plan",
            "--no-subagents",
            "--no-plan",
            "--disable-web-search",
            "--max-turns", "1",
            "--tools", "",
            "--system-prompt-override", system_prompt(),
            "--prompt-file", "/dev/stdin",
        ], raw
    if agent == "claude":
        return [
            "claude",
            "-p",
            "--output-format", "text",
            "--max-turns", "1",
            "--tools", "",
            "--append-system-prompt", system_prompt(),
        ], raw
    if agent == "gemini":
        return ["gemini", "--approval-mode", "plan", "-p", ""], wrapped
    if agent == "codex":
        return ["codex", "exec", "--skip-git-repo-check", "-s", "read-only"], wrapped
    if agent == "crush":
        return ["crush", "run"], wrapped
    if agent == "opencode":
        # `run` reads the message from stdin; the plan agent cannot edit files.
        return ["opencode", "run", "--agent", "plan"], wrapped
    if agent == "copilot":
        # Piped stdin is the prompt; without --allow-* flags no tool may run.
        return ["copilot", "-s"], wrapped
    if agent in ("pi", "omp"):
        return [
            agent,
            "--print",
            "--no-tools",
            "--system-prompt", system_prompt(),
            "--",
            "/dev/stdin",
        ], raw
    return None


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def strip_ansi(text: str) -> str:
    """Remove terminal color / cursor escapes from CLI output."""
    return ANSI_RE.sub("", text)


def is_install_shim(path: str) -> bool:
    """Omarchy's ~/.local/bin launchers install the agent on first run; not installed yet."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(4096)
    except OSError:
        return False
    return head.startswith(b"#!") and b"mise use -g" in head


def is_installed(binary: str) -> bool:
    """True if a real (non-shim) executable for binary is on PATH."""
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        path = os.path.join(folder or ".", binary)
        if os.path.isfile(path) and os.access(path, os.X_OK) and not is_install_shim(path):
            return True
    return False


def installed_agents() -> list[dict]:
    """Agents with an overlay backend that are actually installed."""
    return [
        {"id": ident, "name": info["name"]}
        for ident, info in PROVIDERS.items()
        if info.get("can_ask") and is_installed(info["binary"])
    ]


def selected_agent() -> str:
    """The agent picked in the logo menu, if it is still installed."""
    try:
        raw = read_nofollow(SELECTED_FILE, max_bytes=64)
    except PermissionError:
        return ""
    if raw is None:
        return ""
    agent = canonical_agent(raw.decode("utf-8", "replace").strip())
    if agent in PROVIDERS and is_installed(PROVIDERS[agent]["binary"]):
        return agent
    return ""


def save_selected(agent: str) -> bool:
    """Remember the logo-menu choice across overlay opens and restarts."""
    try:
        os.makedirs(os.path.dirname(SELECTED_FILE), mode=0o700, exist_ok=True)
        tmp = SELECTED_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(agent + "\n")
        os.replace(tmp, SELECTED_FILE)
    except OSError:
        return False
    return True


def read_models_file() -> dict:
    """Saved model choices, {agent: model}."""
    try:
        raw = read_nofollow(MODELS_FILE, max_bytes=8192)
        data = json.loads(raw.decode("utf-8")) if raw else {}
    except (PermissionError, ValueError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def selected_model(agent: str) -> str:
    """The model picked for agent, or "" for the CLI's own default."""
    model = read_models_file().get(agent, "")
    return model if isinstance(model, str) and MODEL_RE.fullmatch(model) else ""


def save_model(agent: str, model: str) -> bool:
    """Remember the model menu choice for agent ("" clears it)."""
    data = read_models_file()
    if model:
        data[agent] = model
    else:
        data.pop(agent, None)
    try:
        os.makedirs(os.path.dirname(MODELS_FILE), mode=0o700, exist_ok=True)
        tmp = MODELS_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, MODELS_FILE)
    except OSError:
        return False
    return True


def fetch_models(agent: str) -> list[dict]:
    """Ask the agent's CLI which models it offers."""
    if agent == "claude":
        return [{"id": i, "name": n} for i, n in CLAUDE_MODELS]
    if agent == "codex":
        proc = run_bounded(login_argv(["codex", "debug", "models"]), max_bytes=4_000_000, timeout=30)
        catalog = json.loads((proc.stdout or b"{}").decode("utf-8", "replace"))
        entries = catalog.get("models", []) if isinstance(catalog, dict) else catalog
        return [
            {"id": m["slug"], "name": m.get("display_name") or m["slug"]}
            for m in entries
            if isinstance(m, dict) and m.get("visibility") == "list" and MODEL_RE.fullmatch(str(m.get("slug", "")))
        ]
    if agent == "opencode":
        proc = run_bounded(login_argv(["opencode", "models"]), max_bytes=1_000_000, timeout=30)
        lines = strip_ansi((proc.stdout or b"").decode("utf-8", "replace")).split()
        return [{"id": l, "name": l} for l in lines if "/" in l and MODEL_RE.fullmatch(l)]
    return []


def models_for(agent: str) -> list[dict]:
    """Model list for the menu, cached for a day; a stale cache beats nothing."""
    cache = os.path.join(MODELS_CACHE_DIR, f"models-{agent}.json")
    cached = None
    try:
        with open(cache, encoding="utf-8") as fh:
            cached = json.load(fh)
        if time.time() - os.path.getmtime(cache) < MODELS_CACHE_SEC:
            return cached
    except (OSError, ValueError):
        pass
    try:
        models = fetch_models(agent)
    except (OSError, ValueError, KeyError, TypeError):
        models = []
    if not models:
        return cached or []
    try:
        os.makedirs(MODELS_CACHE_DIR, mode=0o700, exist_ok=True)
        with open(cache + ".tmp", "w", encoding="utf-8") as fh:
            json.dump(models, fh)
        os.replace(cache + ".tmp", cache)
    except OSError:
        pass
    return models


def tidy_stream(text: str) -> str:
    """Final text of an answer: keep paragraphs, lists and code, cap length."""
    body = str(text or "").replace("\r", "").strip()
    body = re.sub(r"\n{3,}", "\n\n", body)
    return body if len(body) <= MAX_STREAM_CHARS else body[:MAX_STREAM_CHARS].rstrip() + "…"


def describe_tool(block: dict) -> str:
    """One line for a tool call: "Bash · sudo pacman -Rns foo"."""
    name = str(block.get("name") or "Tool")
    args = block.get("input") or {}
    detail = ""
    if isinstance(args, dict):
        for key in ("command", "file_path", "path", "url", "pattern", "query", "description"):
            if args.get(key):
                detail = str(args[key])
                break
    detail = " ".join(detail.split())
    if len(detail) > 140:
        detail = detail[:139] + "…"
    return f"{name} · {detail}" if detail else name


def clip_tool_text(text: str) -> str:
    """Tool input / output for the expanded view: no escapes, capped with a note."""
    body = strip_ansi(str(text or "").replace("\r\n", "\n").replace("\r", "\n")).rstrip()
    if len(body) <= MAX_TOOL_CHARS:
        return body
    rest = body[MAX_TOOL_CHARS:].count("\n") + 1
    return body[:MAX_TOOL_CHARS].rstrip() + f"\n… {rest} more line{'s' if rest != 1 else ''}"


def tool_input_text(block: dict) -> str:
    """What the tool was given: the command for Bash, else one "key: value" per line."""
    args = block.get("input") or {}
    if not isinstance(args, dict):
        return clip_tool_text(str(args))
    if args.get("command"):
        return clip_tool_text(str(args["command"]))
    lines = []
    for key, value in args.items():
        if key == "description":
            continue
        if not isinstance(value, str):
            value = json.dumps(value, ensure_ascii=False)
        lines.append(f"{key}: {value}")
    return clip_tool_text("\n".join(lines))


def tool_output_text(content) -> str:
    """A tool_result's content (a string, or a list of text / image parts)."""
    if isinstance(content, list):
        parts = []
        for part in content:
            if isinstance(part, dict):
                parts.append(str(part.get("text") or "") if part.get("type") == "text" else f"[{part.get('type') or 'data'}]")
        content = "\n".join(p for p in parts if p)
    return clip_tool_text(str(content or ""))


# Images the overlay attaches ({"prompt", "image"}): pasted with Ctrl+V and
# saved in its private folder; read once, then deleted.
SHOTS_DIR = os.path.expanduser("~/.cache/omasearch/shots")
MAX_IMAGE_BYTES = 5 * 1024 * 1024   # Claude's per-image limit
IMAGE_EXTS = (".png", ".jpg", ".webp", ".gif")


def image_type(data: bytes) -> str:
    """Media type from the file's first bytes ("" if it isn't an image Claude takes)."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return ""


def read_shot(path: str) -> tuple[bytes, str] | None:
    """An image from the overlay's own folder only, with its media type; removed after reading."""
    real = os.path.realpath(path)
    if not real.startswith(os.path.realpath(SHOTS_DIR) + os.sep) or not real.endswith(IMAGE_EXTS):
        return None
    data = read_nofollow(real, MAX_IMAGE_BYTES)
    try:
        os.unlink(real)
    except OSError:
        pass
    kind = image_type(data or b"")
    return (data, kind) if kind else None


def serve(session: str) -> None:
    """Keep one Claude process running for a chat, so answers start at once.

    The overlay starts this when it opens (Claude boots while you type) and
    writes {"prompt": ..., "image": ...} lines; each answer streams back as
    delta events and ends with a done event. Follow-ups reuse the same process
    and session. With --safe, every command Claude wants to run is sent to the
    overlay as an approve event and waits for {"approve": id, "allow": ...}.
    """
    lock = threading.Lock()
    write_lock = threading.Lock()
    pending = {}                  # approval request id -> tool input
    allow_all = {"on": False}     # "Always" for the rest of this chat

    def out(obj: dict) -> None:
        with lock:
            sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    if not is_installed("claude"):
        out({"kind": "exit", "error": "Claude CLI is not installed."})
        return
    sid = session or str(uuid.uuid4())
    # Safe mode: Claude asks this process (the SDK host) before each command.
    perms = (["--permission-mode", "default", "--permission-prompt-tool", "stdio"] if SAFE
             else ["--dangerously-skip-permissions"])
    argv = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", *perms, "--effort", QUICK_EFFORT,
            "--append-system-prompt", system_prompt()]
    model = selected_model("claude")
    if model:
        argv += ["--model", model]
    if TEMP:
        # Temporary chat: the session lives only in this process.
        argv += ["--no-session-persistence"]
    else:
        argv += ["--resume", sid] if session else ["--session-id", sid]
    env = {k: os.environ[k] for k in CHILD_ENV_KEYS if k in os.environ}
    proc = subprocess.Popen(login_argv(argv), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True, env=env)

    def stop(*_args) -> None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            pass
        os._exit(0)

    def send(obj: dict) -> bool:
        with write_lock:
            try:
                proc.stdin.write((json.dumps(obj) + "\n").encode("utf-8"))
                proc.stdin.flush()
                return True
            except OSError:
                return False

    def answer(request_id: str, allow: bool) -> None:
        # Reply to Claude's can_use_tool request.
        tool_input = pending.pop(request_id, None)
        if tool_input is None:
            return
        result = ({"behavior": "allow", "updatedInput": tool_input} if allow
                  else {"behavior": "deny", "message": "The user denied this in the omaSearch overlay."})
        send({"type": "control_response",
              "response": {"subtype": "success", "request_id": request_id, "response": result}})

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    out({"kind": "ready", "agent": "claude", "session": "" if TEMP else sid})

    def pump() -> None:
        # Claude's stream-json events → the overlay's small event set.
        for raw in proc.stdout:
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            kind = ev.get("type")
            if kind == "control_request":
                request_id = str(ev.get("request_id") or "")
                req = ev.get("request") or {}
                if req.get("subtype") != "can_use_tool":
                    send({"type": "control_response", "response": {
                        "subtype": "error", "request_id": request_id, "error": "Not supported by omaSearch."}})
                    continue
                tool_input = req.get("input") if isinstance(req.get("input"), dict) else {}
                pending[request_id] = tool_input
                if allow_all["on"]:
                    answer(request_id, True)
                    continue
                block = {"name": str(req.get("tool_name") or "Tool"), "input": tool_input}
                out({"kind": "approve", "id": request_id, "name": block["name"], "text": describe_tool(block),
                     "description": " ".join(str(req.get("description") or tool_input.get("description") or "").split())[:200],
                     "input": tool_input_text(block)})
                continue
            if kind == "control_cancel_request":
                request_id = str(ev.get("request_id") or "")
                pending.pop(request_id, None)
                out({"kind": "approve_cancel", "id": request_id})
                continue
            if kind == "stream_event":
                inner = ev.get("event") or {}
                delta = inner.get("delta") or {}
                if inner.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                    out({"kind": "delta", "text": str(delta.get("text") or "")})
            elif kind == "assistant":
                # A finished assistant message: surface each tool call as a note.
                for block in (ev.get("message") or {}).get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        args = block.get("input") if isinstance(block.get("input"), dict) else {}
                        out({"kind": "tool", "id": str(block.get("id") or ""), "text": describe_tool(block),
                             "name": str(block.get("name") or "Tool"),
                             "description": " ".join(str(args.get("description") or "").split())[:200],
                             "input": tool_input_text(block)})
            elif kind == "user":
                # Tool output comes back as a user message; the id pairs it with its call.
                for block in (ev.get("message") or {}).get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        out({"kind": "tool_result", "id": str(block.get("tool_use_id") or ""),
                             "output": tool_output_text(block.get("content")),
                             "error": block.get("is_error") is True})
            elif kind == "result":
                text = tidy_stream(ev.get("result") or "")
                if ev.get("is_error") or ev.get("subtype") != "success":
                    out({"kind": "done", "ok": False, "agent": "claude",
                         "error": text or "Claude did not return an answer."})
                else:
                    out({"kind": "done", "ok": True, "agent": "claude", "summary": text,
                         "session": "" if TEMP else str(ev.get("session_id") or sid)})
        err = (proc.stderr.read() or b"").decode("utf-8", "replace").strip()[-300:]
        if looks_like_auth_error(err):
            err = "Sign in to Claude, then try again."
        out({"kind": "exit", "error": err})
        os._exit(0)

    threading.Thread(target=pump, daemon=True).start()
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        try:
            msg = json.loads(line)
            if not isinstance(msg, dict):
                continue
        except ValueError:
            continue
        if "approve" in msg:
            # The overlay's Allow / Always / Deny for a pending command.
            if msg.get("always") is True and msg.get("allow") is True:
                allow_all["on"] = True
            answer(str(msg.get("approve") or ""), msg.get("allow") is True)
            continue
        prompt = str(msg.get("prompt") or "").strip()
        if not prompt:
            continue
        content = prompt[:MAX_CHAT_BYTES]
        image = read_shot(str(msg.get("image") or "")) if msg.get("image") else None
        if image:
            content = [{"type": "image", "source": {"type": "base64", "media_type": image[1],
                                                    "data": base64.b64encode(image[0]).decode("ascii")}},
                       {"type": "text", "text": content}]
        if not send({"type": "user", "message": {"role": "user", "content": content}}):
            break
    # The overlay went away: let Claude finish the turn it is on, then exit.
    try:
        proc.stdin.close()
        proc.wait(timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        stop()


CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")
MAX_SESSION_BYTES = 32 * 1024 * 1024
MAX_RECENT = 25
# chatPayload() wraps a message with the earlier turns when no session holds them.
WRAP_PREFIX = "This continues an earlier conversation:"
WRAP_MARK = "\n\nReply to the user's new message: "


def claude_project_dir() -> str:
    """Where Claude keeps the sessions omaSearch starts (they all run in $HOME)."""
    return os.path.join(CLAUDE_PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", os.path.expanduser("~")))


def session_events(path: str, max_bytes: int):
    """JSON events of a Claude session file, reading at most max_bytes."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return
    with os.fdopen(fd, "rb") as fh:
        read = 0
        for raw in fh:
            read += len(raw)
            if read > max_bytes:
                break
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if isinstance(ev, dict):
                yield ev


def user_text(content) -> str:
    """What the user typed in a session message ("" for tool results and meta)."""
    if isinstance(content, list):
        content = "\n".join(str(b.get("text") or "") for b in content
                            if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(content, str):
        return ""
    text = content.strip()
    if text.startswith(WRAP_PREFIX) and WRAP_MARK in text:
        text = text.rsplit(WRAP_MARK, 1)[1].strip()
    if text.startswith(PROMPT_INTRO) and "\n\nQuestion: " in text:
        text = text.split("\n\nQuestion: ", 1)[1].strip()
    if text.startswith(("<command-", "<local-command-", "Caveat: ")):
        return ""
    return text


def recent_claude() -> list[dict]:
    """omaSearch's Claude chats, newest first: the print-mode (sdk-cli) sessions in $HOME.

    Terminal sessions there are "cli" and are left out.
    """
    folder = claude_project_dir()
    try:
        names = [n[:-6] for n in os.listdir(folder) if n.endswith(".jsonl") and SESSION_RE.fullmatch(n[:-6])]
    except OSError:
        return []
    files = []
    for sid in names:
        try:
            files.append((os.stat(os.path.join(folder, sid + ".jsonl")).st_mtime, sid))
        except OSError:
            continue
    files.sort(reverse=True)
    out = []
    for mtime, sid in files:
        if len(out) >= MAX_RECENT:
            break
        entry = title = ""
        for ev in session_events(os.path.join(folder, sid + ".jsonl"), 512 * 1024):
            entry = entry or str(ev.get("entrypoint") or "")
            if ev.get("type") == "user" and not ev.get("isMeta") and not ev.get("isSidechain"):
                title = user_text((ev.get("message") or {}).get("content"))
            if entry and title:
                break
        if entry == "sdk-cli" and title:
            out.append({"session": sid, "title": " ".join(title.split())[:120], "updated": int(mtime * 1000)})
    return out


def load_claude(sid: str) -> dict:
    """Rebuild a Claude chat the way the overlay shows it: your messages, tool
    steps (command + output) and answers, plus the turns sent as context."""
    path = os.path.join(claude_project_dir(), sid + ".jsonl")
    try:
        updated = int(os.stat(path).st_mtime * 1000)
    except OSError:
        return {}
    rows, turns, steps_by_id = [], [], {}
    tool_row = text_row = None
    for ev in session_events(path, MAX_SESSION_BYTES):
        if ev.get("isSidechain") or ev.get("isMeta"):
            continue
        content = (ev.get("message") or {}).get("content")
        if ev.get("type") == "user":
            for block in content if isinstance(content, list) else []:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    step = steps_by_id.get(str(block.get("tool_use_id") or ""))
                    if step is not None:
                        step["output"] = tool_output_text(block.get("content"))[:1500]
                        step["error"] = block.get("is_error") is True
            text = user_text(content)
            if text:
                rows.append({"kind": "you", "text": text[:2000], "count": 1})
                turns.append({"q": text[:2000], "a": "", "error": ""})
                tool_row = text_row = None
        elif ev.get("type") == "assistant" and turns and isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text" and str(block.get("text") or "").strip():
                    text = str(block["text"]).strip()
                    if text_row is None:
                        text_row = {"kind": "text", "text": text, "count": 1}
                        rows.append(text_row)
                    else:
                        text_row["text"] += "\n\n" + text
                    turns[-1]["a"] = text
                    tool_row = None
                elif block.get("type") == "tool_use":
                    args = block.get("input") if isinstance(block.get("input"), dict) else {}
                    step = {"id": str(block.get("id") or ""), "name": str(block.get("name") or "Tool"),
                            "description": " ".join(str(args.get("description") or "").split())[:200],
                            "input": tool_input_text(block)[:1500], "output": "", "error": False, "done": True}
                    steps_by_id[step["id"]] = step
                    if tool_row is None:
                        tool_row = {"kind": "tool", "text": "", "count": 0, "steps": []}
                        rows.append(tool_row)
                    tool_row["steps"].append(step)
                    tool_row["count"] = len(tool_row["steps"])
                    tool_row["text"] = describe_tool(block)
                    text_row = None
    if not turns:
        return {}
    rows, turns = rows[-400:], turns[-200:]
    for row in rows:
        if row["kind"] == "tool":
            row["steps"] = json.dumps(row["steps"][-50:], ensure_ascii=False)
        else:
            row["text"] = tidy_stream(row["text"])
    for turn in turns:
        turn["a"] = tidy_stream(turn["a"])
    return {"id": "c_" + sid, "title": " ".join(turns[0]["q"].split())[:120], "agent": "claude",
            "updated": updated, "sessions": {"claude": sid}, "turns": turns, "rows": rows}


TITLE_PROMPT = """Write a title of 2 to 6 words for this chat. Reply with the title only: no quotes, no trailing period.

User: {q}

Assistant: {a}"""


def make_title() -> str:
    """A short title for a chat from its first question and answer (stdin JSON).

    A quick Haiku call with no tools and no saved session, so it never shows
    up as a chat of its own.
    """
    try:
        data = json.loads((read_stdin_prompt(MAX_PROMPT_BYTES) or b"{}").decode("utf-8", "replace"))
    except ValueError:
        return ""
    q = " ".join(str(data.get("q") or "").split())[:600]
    a = " ".join(str(data.get("a") or "").split())[:900]
    if not q or not is_installed("claude"):
        return ""
    argv = ["claude", "-p", "--model", "haiku", "--output-format", "text", "--no-session-persistence",
            "--permission-mode", "default", "--permission-prompts", "none"]
    try:
        proc = run_bounded(login_argv(argv), max_bytes=4096, timeout=40,
                           stdin_data=TITLE_PROMPT.format(q=q, a=a).encode("utf-8"))
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = strip_ansi((proc.stdout or b"").decode("utf-8", "replace")).strip().splitlines()
    title = lines[0].strip().strip('"\'`*#').rstrip(".") if proc.returncode == 0 and lines else ""
    return " ".join(title.split())[:60]


def looks_like_auth_error(text: str) -> bool:
    """True if CLI output looks like a missing login / API key."""
    lowered = text.lower()
    return any(n in lowered for n in ("login", "auth", "unauthor", "401", "api key", "not logged", "sign in"))


def read_prompt() -> str:
    """Read the overlay question from stdin only."""
    # Follow-ups carry the conversation so far, so allow more than one question.
    raw = read_stdin_prompt(MAX_CHAT_BYTES)
    if not raw:
        return ""
    try:
        return raw.decode("utf-8", "strict").strip()
    except UnicodeDecodeError:
        return ""


def ask_agent(provider: dict, prompt: str, session: str = "") -> None:
    """Call the default agent's CLI and emit a summary or an error."""
    binary = provider.get("binary") or ""
    name = provider["name"]
    agent = provider["id"]
    sid = ""
    if agent in SESSION_AGENTS:
        argv, stdin_data, sid = session_invoke(agent, prompt, selected_model(agent), session)
        invoked = (argv, stdin_data)
    else:
        invoked = invoke_for(agent, prompt, selected_model(agent))
    if not invoked:
        emit(result(
            provider,
            code="open-browser",
            error=f"Overlay answers cannot pass a private prompt to {name} without putting it on the command line. Open the browser to continue.",
        ))
    argv, stdin_data = invoked
    if not binary_on_path(binary):
        emit(result(
            provider,
            code="missing-cli",
            error=f"{name} CLI is not on PATH. Install it with `omarchy default agent {provider['id']}`, then try again.",
        ))
    try:
        proc = run_bounded(
            login_argv(argv),
            max_bytes=MAX_CHILD_BYTES,
            timeout=ASK_TIMEOUT_SEC,
            stdin_data=stdin_data,
        )
    except ValueError:
        emit(result(provider, code="failed", error=f"{name} returned too much output."))
    except OSError:
        emit(result(provider, code="missing-cli", error=f"Could not start {name}."))

    stdout = strip_ansi((proc.stdout or b"").decode("utf-8", "replace")).strip()
    stderr = (proc.stderr or b"").decode("utf-8", "replace").strip()
    event_error = ""
    if agent in ("codex", "opencode"):
        stdout, event_sid, event_error = parse_events(agent, stdout)
        sid = event_sid or sid
    combined = "\n".join(part for part in (stdout, stderr, event_error) if part)

    if proc.returncode != 0 or not stdout:
        if looks_like_auth_error(combined):
            emit(result(provider, code="auth", error=f"Sign in to {name}, then try again."))
        detail = stdout or event_error or stderr or f"{name} exited {proc.returncode}."
        emit(result(provider, code="failed", error=tidy_summary(detail) or f"{name} did not return an answer."))

    summary = tidy_stream(stdout)
    if not summary:
        emit(result(provider, code="failed", error=f"{name} returned an empty answer."))
    keep = not TEMP and SESSION_RE.fullmatch(sid or "")
    emit(result(provider, ok=True, summary=summary, session=sid if keep else ""))


def main(argv: list[str]) -> None:
    """Dispatch `--list`, `--info` or `--ask` for the chosen or default agent."""
    global DETAILED, SAFE, TEMP
    os.environ.setdefault("PYTHONUNBUFFERED", "1")
    DETAILED = "--detailed" in argv
    SAFE = "--safe" in argv
    TEMP = "--temp" in argv
    argv = [a for a in argv if a not in ("--detailed", "--safe", "--temp")]
    if argv[:1] == ["--serve"]:
        sid = argv[2] if len(argv) == 3 and argv[1] == "--session" and SESSION_RE.fullmatch(argv[2]) else ""
        if TEMP:
            sid = ""
        os.chdir(os.path.expanduser("~"))
        serve(sid)
        return
    if argv[:1] == ["--title"]:
        # Run away from $HOME's session folder, just in case.
        os.makedirs(MODELS_CACHE_DIR, mode=0o700, exist_ok=True)
        os.chdir(MODELS_CACHE_DIR)
        emit({"ok": True, "title": make_title()})
    if argv[:1] == ["--recent-claude"]:
        emit({"ok": True, "chats": recent_claude()})
    if len(argv) == 2 and argv[0] == "--load-claude" and SESSION_RE.fullmatch(argv[1]):
        chat = load_claude(argv[1])
        emit({"ok": bool(chat), "chat": chat})
    if argv[:1] == ["--list"]:
        sys.stdout.write(json.dumps({"ok": True, "agents": installed_agents()}) + "\n")
        return
    if len(argv) == 2 and argv[0] == "--models":
        agent = canonical_agent(argv[1])
        if agent not in PROVIDERS:
            emit({"ok": False, "agent": "", "selected": "", "models": []})
        models = [{"id": "", "name": "Default"}] + models_for(agent)[:60]
        emit({"ok": True, "agent": agent, "selected": selected_model(agent), "models": models})
    if len(argv) == 3 and argv[0] == "--select-model":
        agent = canonical_agent(argv[1])
        model = argv[2] if MODEL_RE.fullmatch(argv[2] or "") else ""
        if agent not in PROVIDERS or (argv[2] and not model) or not save_model(agent, model):
            emit({"ok": False})
        emit({"ok": True, "agent": agent, "selected": model})
    if len(argv) == 2 and argv[0] == "--select":
        agent = canonical_agent(argv[1])
        if agent not in PROVIDERS or not save_selected(agent):
            emit(result(provider_for(agent), code="failed", error="Could not select that agent."))
        emit(result(provider_for(agent), ok=True))
    chosen = session = ""
    while len(argv) >= 2 and argv[0] in ("--agent", "--session"):
        if argv[0] == "--agent":
            chosen = canonical_agent(argv[1])
        elif SESSION_RE.fullmatch(argv[1]):
            session = argv[1]
        argv = argv[2:]
    # Sessions are stored per directory; always use $HOME so the terminal finds them.
    os.chdir(os.path.expanduser("~"))
    agent = chosen if chosen in PROVIDERS else (selected_agent() or default_agent())
    if not agent:
        empty = {"id": "", "name": "AI", "web": "", "binary": "", "can_ask": False}
        emit(result(empty, code="no-agent", error="Set a default agent with `omarchy default agent <name>`."))

    provider = provider_for(agent)
    if provider["id"] not in PROVIDERS:
        emit(result(provider, code="no-agent", error="Unknown default agent. Set one with `omarchy default agent <name>`."))

    if not argv or argv[0] in ("--info", "info"):
        emit(result(provider, ok=True, canAsk=bool(provider.get("can_ask"))))

    if argv[0] != "--ask" or len(argv) != 1:
        emit(result(provider, code="usage", error="Usage: ask.py --ask  (prompt on stdin)"), 2)

    prompt = read_prompt()
    if not prompt:
        emit(result(provider, code="empty", error="Type a question first."))

    if not provider.get("can_ask"):
        emit(result(provider, code="open-browser", error=f"No overlay backend for {provider['name']}. Open the browser to continue."))

    ask_agent(provider, prompt, session if provider["id"] in SESSION_AGENTS else "")


if __name__ == "__main__":
    main(sys.argv[1:])
