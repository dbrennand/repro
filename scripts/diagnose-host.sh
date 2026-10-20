#!/usr/bin/env bash
set -u
container_name=$1
echo '=== Failure-only diagnostics: original helper has already failed ==='
date --iso-8601=ns
docker inspect "$container_name"
docker top "$container_name" -eo pid,ppid,stat,comm,args
controller_pid=$(docker inspect --format '{{.State.Pid}}' "$container_name")
sudo cat "/proc/$controller_pid/task/$controller_pid/children"
docker run --rm --pid host --privileged quay.io/ansible/ansible-test-utility-container:3.6.0 \
  nsenter -t "$controller_pid" -m -p sh -c '
    echo "=== Mount state before diagnostic remount ==="
    cat /proc/mounts
    ps -ef
    for proc_dir in /proc/[0-9]*; do
      echo "$proc_dir"
      cat "$proc_dir/comm" "$proc_dir/stat"
    done
    pgrep sleep
    echo "post_failure_pgrep_rc=$?"
    mount -o remount,rw /sys/fs/cgroup/
    echo "diagnostic_remount_rc=$?"
    pkill -0 sleep
    echo "diagnostic_signal_zero_rc=$?"
  '
sudo journalctl -k --since '-3 minutes' --no-pager
