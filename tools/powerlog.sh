#!/bin/sh
# Read-only logger: whole-system power vs. Thunderbolt display link, display state and CPU load.
# Usage: tools/powerlog.sh [seconds-between-samples] [max-samples] > build/powerlog.csv
interval=${1:-30}; count=${2:-360}
cd "$(dirname "$0")/.."
echo "time,pstr_w,pdtr_w,tb0_link,tb0_status,display,cpu_user,cpu_sys"
i=0
while [ $i -lt "$count" ]; do
    pstr=$(./fanctl dump PSTR | awk '{printf "%.1f", $NF}')
    pdtr=$(./fanctl dump PDTR | awk '{printf "%.1f", $NF}')
    tb=$(system_profiler SPThunderboltDataType 2>/dev/null | awk '/Bus 0:/{g=1} g && /Status:/ && !s{s=$2" "$3} g && /Link Status/{print $NF","s; exit}')
    disp=$(pmset -g log 2>/dev/null | grep -E "Display is turned (on|off)" | tail -1 | awk '{print $NF}')
    cpu=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/{gsub("%",""); print $3","$5}')
    echo "$(date '+%F %T'),$pstr,$pdtr,$tb,$disp,$cpu"
    i=$((i + 1))
    sleep "$interval"
done
