#!/bin/bash
# Runs the prototype under gdb and saves a backtrace if it crashes.
out="$HOME/.config/tala-prototype/crash.txt"
here="$(cd "$(dirname "$0")/.." && pwd)"
cat > "$out.cmds" <<GDB
set pagination off
set confirm off
set print thread-events off
handle SIGPIPE SIGPROF SIGUSR1 SIGUSR2 SIG32 SIG33 SIG34 SIG35 nostop noprint pass
run
echo === STOPPED ===\n
bt 40
thread apply all bt 12
GDB
exec gdb -q -batch -x "$out.cmds" --args "$here/build/linux/x64/release/bundle/tala" "$@" > "$out" 2>&1
