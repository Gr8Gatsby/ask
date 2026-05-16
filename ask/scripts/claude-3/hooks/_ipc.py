"""Shared IPC helper for claude-3 hooks.

Hooks talk to the daemon over a unix socket. Under load the daemon's accept
loop can get queued (lots of pre_tool_use events firing rapidly), and the
hook's connect/sendall can time out before the daemon services it. The
result: hook events silently dropped, which manifests as missing entries on
iPhone (e.g. the Stop hook never updating `last_message`).

This helper wraps the connect-send-close cycle in a small retry loop so
transient daemon backpressure no longer drops events. Failures are still
silent (hooks must not break Claude Code), but each delivery gets up to
three tries with short backoff.
"""
import json
import os
import socket
import time

SOCKET_PATH = os.environ.get(
    'ASK_SOCKET_PATH',
    os.path.expanduser('~/.ask/sockets/claude-3.sock'),
)

# Retry parameters tuned to typical hook bursts (~100 events in a few seconds
# observed in the wild). Three attempts with 100ms / 250ms backoffs covers
# the accept-queue-saturation window without making hook teardown slow.
_MAX_ATTEMPTS = 3
_BACKOFFS = (0.1, 0.25)
_PER_ATTEMPT_TIMEOUT = 3.0


def send_to_daemon(payload: dict, *, max_attempts: int = _MAX_ATTEMPTS,
                   timeout: float = _PER_ATTEMPT_TIMEOUT) -> bool:
    """Send a JSON message to the claude-3 daemon. Returns True on success.

    Retries on ConnectionRefusedError, ConnectionResetError, BrokenPipeError,
    and socket timeout. Other exceptions are swallowed (hooks must never
    break Claude Code).

    Args:
      payload: dict to JSON-encode and send.
      max_attempts: total tries (default 3). Pass 1 for user-blocking hooks
        like permission_request where we must not delay the terminal prompt.
      timeout: per-attempt socket timeout in seconds (default 3.0). Use a
        smaller value for latency-sensitive hooks.
    """
    blob = json.dumps(payload).encode()
    for attempt in range(max_attempts):
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            try:
                sock.connect(SOCKET_PATH)
                sock.sendall(blob)
            finally:
                sock.close()
            return True
        except (ConnectionRefusedError, ConnectionResetError, BrokenPipeError,
                FileNotFoundError, socket.timeout, TimeoutError):
            # FileNotFoundError covers the daemon-socket-not-yet-bound case
            # (e.g. AskMac restarting); the daemon recreates the socket
            # within a few hundred ms, so a retry usually wins.
            if attempt + 1 < max_attempts:
                time.sleep(_BACKOFFS[min(attempt, len(_BACKOFFS) - 1)])
                continue
            return False
        except Exception:
            return False
    return False
