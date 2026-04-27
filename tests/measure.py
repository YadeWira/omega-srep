#!/usr/bin/env python3
"""Run a command, print 'max_rss_kib elapsed_secs' to stdout.

Substitute for /usr/bin/time -v on hosts where the GNU time package
isn't installed. Uses getrusage(RUSAGE_CHILDREN) which on Linux
returns ru_maxrss in KiB. Wall-clock comes from time.monotonic.

The wrapped command's stdout/stderr is silenced so this can be
embedded in `read RSS ELAPSED <<< "$(...)"` without contamination.
"""

import resource
import subprocess
import sys
import time


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: measure.py <cmd> [args...]", file=sys.stderr)
        return 2

    t0 = time.monotonic()
    rc = subprocess.call(
        argv[1:],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    elapsed = time.monotonic() - t0
    rusage_after = resource.getrusage(resource.RUSAGE_CHILDREN)

    if rc != 0:
        print(f"# wrapped command exited rc={rc}", file=sys.stderr)
        return rc

    print(f"{rusage_after.ru_maxrss} {elapsed:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
