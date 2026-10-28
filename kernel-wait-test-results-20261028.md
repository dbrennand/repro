# ansible-test kernel-wait experiments — 2026-10-28

## Result

Actual ansible-test provisioning fails while the controller child is still named `env` and blocked on a file-backed page fault. Failure-time `/proc` snapshots and independent scheduler-event stack traces show `folio_wait_bit_common` through `filemap_fault`. Other captured waits include buffered reads through OverlayFS and ext4.

Executing `env sleep 0` once in the controller image before testing prevented the observed first-attempt failures in a small matched comparison. A bounded wake retry also recovered an actual initial `pkill` miss on both fresh runners tested. These experiments establish more than the previous report's observation of state D, but do not identify a specific kernel regression or patch.

## Runs and results

All 10 fresh runners reported image `20261026.354.1` and kernel `7.0.0-1017-azure`, with `/proc/version_signature` reporting `Ubuntu 7.0.0-1017.17~24.04.1-azure 7.0.14`. Each runner ran three actual `ansible-test integration smoke` trials. Ansible revision: `f7319e09448e13fa2bc407a1afcd8990f47040fb`. Controller: `quay.io/ansible/default-test-container:v2.23-2`; utility: `quay.io/ansible/ansible-test-utility-container:3.6.0`.

| Experiment | Fresh runners | First trial | All three trials |
| --- | ---: | --- | --- |
| Original command, no scheduler tracing | 2 | Both failed | 3 failed, 3 passed |
| Original command, scheduler tracing | 2 | Both failed | 2 failed, 4 passed |
| Images pre-pulled, controller not prewarmed, 5-second settling interval | 2 | Both failed | 3 failed, 3 passed |
| Images pre-pulled, controller prewarmed, 5-second settling interval | 2 | Both passed | 6 passed |
| Bounded retry, no controller prewarming | 2 | Both recovered an initial miss | 6 passed |

Run links and exact experiment source:

1. [Original controls and scheduler tracing](https://github.com/dbrennand/repro/actions/runs/40757118976), [source commit 251b6c6](https://github.com/dbrennand/repro/commit/251b6c6019d9dbd91b1a3cd990fe97ab7b5cc566).
2. [Prewarming comparison](https://github.com/dbrennand/repro/actions/runs/40757567526), [source commit 60ebcc0](https://github.com/dbrennand/repro/commit/60ebcc0208e602198129f1f4cf9b9845fd349923).
3. [Bounded retry recovery](https://github.com/dbrennand/repro/actions/runs/40757924679), [source commit c0cb9f5](https://github.com/dbrennand/repro/commit/c0cb9f5c039afedabf0a9ac390cf7809705649a8).

The aggregate workflow failure status in runs 1 and 2 is expected: the workflow preserves test failures while still running subsequent trials and uploading artifacts. No upstream Ansible issue comment or PR was posted.

## Captured wait

From [scheduler replica 1](https://github.com/dbrennand/repro/actions/runs/40757118976/job/123058895519), trial 1, controller child host PID 2974:

```text
--- comm ---
env
--- stack ---
[<0>] folio_wait_bit_common+0x13d/0x360
[<0>] filemap_fault+0x52a/0xce0
[<0>] __do_fault+0x3f/0x1a0
[<0>] do_read_fault+0x126/0x240
[<0>] do_fault+0x16e/0x2b0
[<0>] handle_pte_fault+0xa5/0x1f0
[<0>] __handle_mm_fault+0x56a/0x760
[<0>] handle_mm_fault+0x13d/0x3b0
[<0>] do_user_addr_fault+0x1d2/0x8c0
[<0>] exc_page_fault+0x81/0x1c0
[<0>] asm_exc_page_fault+0x27/0x30
--- wchan ---
folio_wait_bit_common
--- syscall ---
-1 0x7ffe8dc7dc70 0x7fd162cf9e60
State: D (disk sleep)
```

The original compound helper command exited 1. The failure diagnostics execute only in the provisioning exception handler. No wakeup retry or pre-failure process inspection was added in runs 1 and 2.

All five provisioning failures in run 1 captured `env` in D with this filemap-fault stack, including the untraced controls. The shell parent was waiting for its child. This directly identifies the sampled blocking path; it does not identify the owner of the folio lock or prove a disk or filesystem defect.

The traced jobs used an isolated ftrace instance with a `sched_switch` stacktrace trigger for `env` and `pkill`, plus `sched_process_exec`. This does not use BPF syscall-enter tracepoints. The two traced first trials recorded 28 and 29 D-state switches for `env`. The inspected first-trial trace buffers reported no overruns or dropped events.

One captured blocking path during executable loading included:

```text
schedule
io_schedule
folio_wait_bit_common
filemap_fault
...
asm_exc_page_fault
rep_stos_alternative
load_elf_binary
exec_binprm
bprm_execve
...
__x64_sys_execve
```

Another showed buffered file reads:

```text
folio_wait_bit_common
filemap_update_page
filemap_get_pages
filemap_read
generic_file_read_iter
ext4_file_read_iter
...
backing_file_read_iter
ovl_read_iter
vfs_read
ksys_read
```

Use the `prev_comm`/`next_comm` fields to interpret scheduler events. The formatted trace's leading task label can reflect a later name for a reused command-line cache entry; some lines are labelled `sleep` while their recorded `prev_comm` is `env`.

The prewarming-control snapshot additionally mapped the executable to `/usr/lib/cargo/bin/coreutils/env`. Its sampled instruction pointer was within that executable's executable mapping. The fault address was not captured, so this does not establish which code or data page caused that individual fault.

## Prewarming intervention

Both arms explicitly pulled the same two images. The prewarmed arm then ran:

```sh
docker run --rm --entrypoint /usr/bin/env \
  quay.io/ansible/default-test-container:v2.23-2 sleep 0
```

The control arm ran `/bin/true` in the utility image instead. Both arms had five seconds total between the start of that preconditioning command and proceeding, as recorded in their logs. Both then used the same original ansible-test provisioning command and scheduler tracing.

Untouched controllers failed on both first trials; prewarmed controllers passed all six trials. In inspected replica-1 first-trial traces, the untouched arm recorded 44 D-state switches for `env`, versus one in the prewarmed arm. In that prewarmed trace, the controller child's `env` and `sleep` successful-exec events were approximately 4.145 ms apart.

This supports a cold file-loading/startup delay exposing Ansible's readiness race. Executing a container warms multiple caches and changes other startup state, so it is not an isolated page-cache-only intervention. The sample is small and does not establish a general failure probability.

## Retry recovery

The last experiment kept the cgroup remount and changed only the following wakeup operation to the earlier report's bounded candidate:

```sh
mount -o remount,rw /sys/fs/cgroup/ && (
    i=0
    until pkill sleep; do
        i=$((i+1))
        [ "$i" -lt 50 ] || exit 1
        sleep 0.1
    done
    echo wakeup_retries=$i
)
```

Both fresh runners reported `wakeup_retries=1` on trial 1 and completed the smoke target. Trials 2 and 3 reported zero retries and passed. Unlike the previous investigation, these are observed initial misses recovered on the affected kernel, not merely successes on an older image. This remains an experimental mitigation, not a reviewed production patch.

## Assessment of proposed kernel causes

* **Procfs/exec_update_lock:** not the sampled wait. The `env` stacks identify filemap waits; the scheduler traces do not show an `exec_update_lock` wait for these events. This weakens the direct explanation, without excluding every indirect timing interaction.
* **BPF syscall-enter bug, runner-images #15003:** no causal evidence. The captured waits occur in page faults and ordinary buffered reads. No kernel patch was reverted, and tracing/monitoring was not disabled, so this is not a definitive exclusion test.
* **EEVDF starvation:** not established. The observed task is blocked on file pages, not simply runnable and starved. An indirectly delayed worker is still possible; these tests did not measure that dependency.
* **JBD2/ext4 stall:** not established. Ext4 appears in the read path, but there is no captured JBD2 checkpoint/shrinker stack proving the particular changelog fixes are involved.

## Limits and next discriminating test

No runner was rebooted into 6.17 or 1018, no kernel was rebuilt, and no candidate commit was reverted. Docker was 28.0.4; the inspected runners used overlay2 on ext4. Runtime and image metadata are retained in each artifact. The image version in the job's initial banner differed from its live `ImageVersion`; this report uses the latter and the actual `uname`/version-signature output.

The next step for kernel attribution is the same fresh-start workload on otherwise matched VMs booted with the working and affected kernels, followed by patch isolation. A more detailed trace should identify the faulted file/page and the operation holding its folio lock or completing its I/O. A successful 1018 run alone would not identify which of that release's changes mattered.

Artifacts are retained by GitHub for 14 days. The decisive stack excerpts and result counts are preserved here. Investigation and test implementation prepared with assistance from OpenAI Codex.
