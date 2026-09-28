#!/usr/bin/python3 -I
"""Descriptor-bound reads and a deadline-capped child process.

Used by ask.py and open_chat.py. Caps are producer-side (cap + 1) so overflow
is detected instead of silently truncated.
"""

from __future__ import annotations

import os
import select
import signal
import stat
import subprocess
import sys
import time

MAX_CHILD_BYTES = 262144
MAX_AGENT_FILE = 256
MAX_PROMPT_BYTES = 4000


def read_stdin_prompt(max_bytes: int = MAX_PROMPT_BYTES) -> bytes:
    """Read a prompt from stdin until EOF, NUL, or a short idle after data.

    QML Process.write() may not close stdin, so an idle timeout is required.
    Never take the prompt from argv.
    """
    data = b""
    first_wait = 3.0
    idle = 0.4
    got = False
    while len(data) <= max_bytes:
        wait = idle if got else first_wait
        ready, _, _ = select.select([sys.stdin.fileno()], [], [], wait)
        if not ready:
            break
        chunk = os.read(sys.stdin.fileno(), min(4096, max_bytes + 1 - len(data)))
        if not chunk:
            break
        nul = chunk.find(b"\0")
        if nul != -1:
            data += chunk[:nul]
            break
        data += chunk
        got = True
    if len(data) > max_bytes:
        return b""
    return data


def read_nofollow(path: str, max_bytes: int = MAX_AGENT_FILE) -> bytes | None:
    """Open `path` once (O_NOFOLLOW|O_NONBLOCK), fstat, read cap+1, refuse overflow."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        return None
    except OSError:
        raise PermissionError("refusing path") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1:
            raise PermissionError("refusing path")
        if st.st_size > max_bytes:
            raise PermissionError("file too large")
        os.set_blocking(fd, True)
        data = b""
        while len(data) <= max_bytes:
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > max_bytes:
            raise PermissionError("file too large")
        return data
    finally:
        os.close(fd)


def run_bounded(argv: list[str], *, max_bytes: int = MAX_CHILD_BYTES, timeout: float = 20,
                stdin_data: bytes | None = None) -> subprocess.CompletedProcess:
    """Run argv in its own session; cap stdout/stderr; TERM then KILL the group."""
    env = {}
    for key in (
        "HOME",
        "PATH",
        "USER",
        "LANG",
        "LC_ALL",
        "XDG_RUNTIME_DIR",
        "XDG_CONFIG_HOME",
        "WAYLAND_DISPLAY",
        "HYPRLAND_INSTANCE_SIGNATURE",
        "XDG_SESSION_TYPE",
        "XDG_CURRENT_DESKTOP",
        "DISPLAY",
    ):
        if key in os.environ:
            env[key] = os.environ[key]
    proc = subprocess.Popen(
        argv,
        stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        env=env,
    )
    deadline = time.monotonic() + timeout
    out = b""
    err = b""
    if stdin_data is not None and proc.stdin is not None:
        try:
            proc.stdin.write(stdin_data[:max_bytes])
        except OSError:
            pass
        try:
            proc.stdin.close()
        except OSError:
            pass
    streams = [proc.stdout, proc.stderr]
    overflow = False
    try:
        while streams:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([s for s in streams if s], [], [], remaining)
            if not ready:
                break
            for stream in ready:
                chunk = os.read(stream.fileno(), 65536)
                if not chunk:
                    streams.remove(stream)
                    continue
                if stream is proc.stdout:
                    out += chunk
                    if len(out) > max_bytes:
                        overflow = True
                        streams = []
                        break
                else:
                    err += chunk
                    if len(err) > max_bytes:
                        overflow = True
                        streams = []
                        break
        if overflow or (proc.poll() is None and time.monotonic() >= deadline):
            _stop_group(proc.pid)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            _stop_group(proc.pid, kill=True)
            proc.wait(timeout=2)
    finally:
        if proc.poll() is None:
            _stop_group(proc.pid, kill=True)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    if overflow:
        raise ValueError("child output exceeded cap")
    return subprocess.CompletedProcess(argv, proc.returncode if proc.returncode is not None else 1, out, err)


def _stop_group(pid: int, kill: bool = False) -> None:
    """Signal the child's process group, then escalate to KILL if asked."""
    sig = signal.SIGKILL if kill else signal.SIGTERM
    try:
        os.killpg(pid, sig)
    except OSError:
        try:
            os.kill(pid, sig)
        except OSError:
            return
    if not kill:
        time.sleep(0.4)
        try:
            os.killpg(pid, 0)
        except OSError:
            return
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
