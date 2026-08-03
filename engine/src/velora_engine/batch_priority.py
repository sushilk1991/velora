"""Darwin background scheduling for batch jobs (meetings, idle mining).

Meeting transcription/notes previously ran at default priority and visibly
fought the user's foreground apps the moment a meeting ended. While batch
work runs and no dictation is active, the engine and its cleanup sidecar drop
to Darwin BACKGROUND (efficiency cores, throttled I/O, deprioritized GPU
submission); they return to normal the instant a dictation starts, so live
latency is unaffected.

setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG) is the same mechanism
`taskpolicy -b -p` uses; a process may freely demote and restore itself and
its same-uid children. No-op off macOS.
"""

from __future__ import annotations

import ctypes
import logging
import sys

log = logging.getLogger("velora.priority")

_PRIO_DARWIN_PROCESS = 4  # sys/resource.h (3 is PRIO_DARWIN_THREAD)
_PRIO_DARWIN_BG = 0x1000  # sys/resource.h


def set_background(pid: int, background: bool) -> bool:
    """Move `pid` in/out of Darwin background. Returns True on success.

    Failures (dead pid, non-Darwin, missing libc symbol) are logged at debug
    and swallowed — scheduling policy is an optimization, never a correctness
    dependency.
    """
    if sys.platform != "darwin":
        return False
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        rc = libc.setpriority(
            _PRIO_DARWIN_PROCESS, pid, _PRIO_DARWIN_BG if background else 0)
        if rc != 0:
            log.debug(
                "setpriority(%d, background=%s) failed errno=%d",
                pid, background, ctypes.get_errno())
            return False
        return True
    except Exception:  # noqa: BLE001 — never let policy break a job
        log.debug("setpriority unavailable", exc_info=True)
        return False
