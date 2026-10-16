#!/bin/sh
# {{MARK}}
# One bar per monitor; run again (WM restart) to reload them.
pkill -u "$USER" -x polybar
while pgrep -u "$USER" -x polybar >/dev/null; do sleep 0.2; done
log=/tmp/$USER/polybar.log
for m in $(polybar --list-monitors | cut -d: -f1); do
    MONITOR=$m polybar main >>"$log" 2>&1 &
done
