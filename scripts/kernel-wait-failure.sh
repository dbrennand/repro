#!/usr/bin/env bash
set -u
container=$1
output=${DIAGNOSTIC_DIR:?}
# Freeze the event history first, before docker inspection can miss the wait.
instance=/sys/kernel/tracing/instances/ansible-kernel-wait
if sudo test -d "$instance"; then
  echo 0 | sudo tee "$instance/tracing_on" >/dev/null
fi
{
  date --iso-8601=ns
  controller=$(docker inspect --format '{{.State.Pid}}' "$container")
  echo "controller_host_pid=$controller"
  children=$(sudo cat "/proc/$controller/task/$controller/children")
  for pid in $children "$controller"; do
    echo "host_pid=$pid"
    for field in comm stack wchan syscall status maps; do
      echo "--- $field ---"
      sudo timeout 1s cat "/proc/$pid/$field" || true
    done
  done
  docker top "$container" -eo pid,ppid,stat,comm,args
  docker inspect "$container"
  cat /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory
} 2>&1 | tee "$output/failure.log"
