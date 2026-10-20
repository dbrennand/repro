#!/usr/bin/env bash
# Run on a disposable Linux CI runner with Docker access.
set -euo pipefail
utility=quay.io/ansible/ansible-test-utility-container:3.6.0
controller=quay.io/ansible/default-test-container:v2.23-2
uname -a
docker version
docker info --format 'cgroup={{.CgroupVersion}} security={{json .SecurityOptions}}'
docker pull "$utility"
docker pull "$controller"
container_id=$(docker run -dt --cgroupns private --tmpfs /tmp:exec \
  --tmpfs /run:exec --tmpfs /run/lock "$controller" \
  sh -c 'env sleep 300; exec /sbin/init')
cleanup() { docker rm -f "$container_id" >/dev/null; }
trap cleanup EXIT
controller_pid=$(docker inspect --format '{{.State.Pid}}' "$container_id")
docker top "$container_id" -eo pid,ppid,comm,args
set +e
docker run --rm --pid host --privileged "$utility" \
  nsenter -t "$controller_pid" -m -p sh -c '
    set -x
    mount -o remount,rw /sys/fs/cgroup/
    mount_rc=$?
    echo "mount_rc=$mount_rc"
    echo "Process view inside nsenter:"
    ps
    for proc_dir in /proc/[0-9]*; do
      echo "$proc_dir"
      cat "$proc_dir/comm" "$proc_dir/stat"
    done
    pgrep sleep
    echo "pgrep_rc=$?"
    if [ "$mount_rc" -ne 0 ]; then exit "$mount_rc"; fi
    pkill sleep
    wake_rc=$?
    echo "pkill_rc=$wake_rc"
    exit "$wake_rc"
  '
helper_rc=$?
echo "helper_rc=$helper_rc"
docker logs "$container_id"
# Audit records can reveal kernel security-policy denials.
sudo journalctl -k --since '-5 minutes' --no-pager | \
  grep -Ei 'apparmor|denied|audit|seccomp' || true
exit "$helper_rc"
