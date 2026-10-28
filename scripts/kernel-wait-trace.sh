#!/usr/bin/env bash
set -euo pipefail
action=$1
output=$2
root=/sys/kernel/tracing
instance=$root/instances/ansible-kernel-wait
if [ "$action" = start ]; then
  if ! mountpoint -q "$root"; then mount -t tracefs tracefs "$root"; fi
  mkdir -p "$instance"
  echo 0 > "$instance/tracing_on"
  echo 8192 > "$instance/buffer_size_kb"
  echo > "$instance/trace"
  echo 'prev_comm == "env" || next_comm == "env" || prev_comm == "pkill" || next_comm == "pkill"' > "$instance/events/sched/sched_switch/filter"
  echo 'stacktrace if prev_comm == "env" || prev_comm == "pkill"' > "$instance/events/sched/sched_switch/trigger"
  echo 1 > "$instance/events/sched/sched_switch/enable"
  echo 1 > "$instance/events/sched/sched_process_exec/enable"
  cat "$instance/events/sched/sched_switch/format" > "$output/sched-switch-format.txt"
  cat "$instance/events/sched/sched_switch/trigger" > "$output/trigger.txt"
  echo 1 > "$instance/tracing_on"
else
  if [ -d "$instance" ]; then
    echo 0 > "$instance/tracing_on"
    cat "$instance/trace" > "$output/scheduler-trace.txt"
    for stats in "$instance"/per_cpu/cpu*/stats; do echo "$stats"; cat "$stats"; done > "$output/trace-buffer-stats.txt"
    echo '!stacktrace' > "$instance/events/sched/sched_switch/trigger"
    echo 0 > "$instance/events/enable"
    rmdir "$instance"
  fi
fi
