#!/usr/bin/env bash
# Compare the original ansible-test wakeup with a bounded readiness retry.
set -euo pipefail
utility=quay.io/ansible/ansible-test-utility-container:3.6.0
controller=quay.io/ansible/default-test-container:v2.23-2
uname -a
docker version
docker pull "$utility"
docker pull "$controller"
container_id=
cleanup() {
  if [ -n "$container_id" ]; then docker rm -f "$container_id" >/dev/null; fi
}
trap cleanup EXIT
failures=0
for mode in original retry; do
  for attempt in 1 2 3 4 5; do
    echo "=== mode=$mode attempt=$attempt ==="
    container_id=$(docker run -dt --cgroupns private --tmpfs /tmp:exec \
      --tmpfs /run:exec --tmpfs /run/lock \
      --volume /var/run/docker.sock:/var/run/docker.sock --ulimit nofile=10240 \
      "$controller" sh -c 'env sleep 60; exec /sbin/init')
    controller_pid=$(docker inspect --format '{{.State.Pid}}' "$container_id")
    if [ "$mode" = original ]; then
      payload='mount -o remount,rw /sys/fs/cgroup/ && pkill sleep'
    else
      payload='mount -o remount,rw /sys/fs/cgroup/ || exit $?;
        attempt=0
        until pkill sleep; do
          attempt=$((attempt + 1))
          if [ "$attempt" -ge 50 ]; then
            echo "wakeup_retry_exhausted=$attempt"; exit 1
          fi
          sleep 0.1
        done
        echo "wakeup_retries=$attempt"'
    fi
    # No process listing, tracing, or extra commands before the wakeup.
    set +e
    docker run --rm --pid host --privileged "$utility" \
      nsenter -t "$controller_pid" -m -p sh -c "$payload"
    helper_rc=$?
    set -e
    echo "RESULT mode=$mode attempt=$attempt helper_rc=$helper_rc"
    if [ "$helper_rc" -ne 0 ]; then
      failures=$((failures + 1))
      # Only inspect after the original command has returned.
      docker top "$container_id" -eo pid,ppid,comm,args || true
      docker run --rm --pid host --privileged "$utility" \
        nsenter -t "$controller_pid" -m -p sh -c '
          mount -o remount,rw /sys/fs/cgroup/
          echo "diagnostic_mount_rc=$?"
          ps -ef
          pgrep sleep
          echo "diagnostic_pgrep_rc=$?"
          for proc_dir in /proc/[0-9]*; do
            echo "$proc_dir"
            cat "$proc_dir/comm" "$proc_dir/stat"
          done
        ' || true
    fi
    docker logs "$container_id" || true
    cleanup
    container_id=
  done
done
echo "failed_trials=$failures"
[ "$failures" -eq 0 ]
