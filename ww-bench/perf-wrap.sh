#!/bin/sh
# Run $PERF_BIN under perf stat, counting user-space instructions and cycles
# into $PERF_OUT (appended: a benchmark may run its program more than once).
# Used by timing.py in place of a benchmark's binary, so that only the
# program is counted, not runstdtest's own work.  stdin, stdout, stderr and
# the exit status are the program's.
exec perf stat -x, --append -o "$PERF_OUT" -e instructions:u,cycles:u -- "$PERF_BIN" "$@"
