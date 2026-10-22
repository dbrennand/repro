# ansible-test: Docker initialization fails when `pkill sleep` runs before `env` starts `sleep`

## Summary

`ansible-test` has a startup synchronization race when provisioning its Docker controller. It starts the controller with `env sleep 60 ; exec /sbin/init`, remounts the controller's cgroup filesystem read-write from a privileged helper, and immediately runs `pkill sleep`. The controller can still be executing `env` at that point. Because the process has not yet become `sleep`, the one-shot `pkill sleep` returns 1 and provisioning aborts.

We reproduced the original failure on GitHub-hosted Ubuntu 24.04 and 26.04 runners using the actual `ansible-test` provisioning path. Failure-only instrumentation subsequently confirmed `original_pkill_rc=1` while the controller child was still `env sleep 60`. The cgroup filesystem was already read-write before any diagnostic remount.

**Confirmed issue location:** the readiness assumption in `ansible-test`'s container wakeup sequence.

**Unresolved environmental trigger:** newer runner images correlate with the failure, but the reason they delay `env` becoming `sleep` has not been isolated. No specific kernel commit, systemd change, or Docker regression has been established as the cause.

## Issue type and component

- Issue type: Bug Report.
- Primary component: `test/lib/ansible_test/_internal/host_profiles.py`.
- Relevant methods: `DockerProfile.provision()`, `get_docker_init_config()`, `build_init_command()`, and `wake_command`.
- Supporting code: `test/lib/ansible_test/_internal/docker_util.py` and `containers.py`.
- Investigation date: 2026-10-20.

## Environment and versions

| Item                    | Observed value                                                            |
| ----------------------- | ------------------------------------------------------------------------- |
| Ansible                 | `ansible-core 2.23.0.dev0`, devel                                         |
| Reproduction revision   | `f7319e09448e13fa2bc407a1afcd8990f47040fb`                                |
| Host Python             | 3.14.8 in the original failing job; reproduction requests Python 3.14     |
| Controller Python       | `/usr/bin/python3.14`                                                     |
| Controller image        | `quay.io/ansible/default-test-container:v2.23-2`                          |
| Controller image digest | `sha256:ce277ef31e34524b686ff542bc1428e72698670f1b3b305e0b79367000ee7f2f` |
| Utility image           | `quay.io/ansible/ansible-test-utility-container:3.6.0`                    |
| Utility image digest    | `sha256:35be34242c3029a3cf95edaffa71433d35fb00b6fd2ec6870ecc4a297153a247` |
| Cgroup mode             | v2; controller uses `--cgroupns private`                                  |
| Controller privilege    | `privileged=False`, default seccomp                                       |
| Initialization helper   | `--pid host --privileged`                                                 |

The original community.dns job installed `https://github.com/ansible/ansible/archive/devel.tar.gz`. Its exact source SHA was not recorded. The reproduction pins the last devel commit found before that job started; this is not proof that the original tarball contained exactly that revision. The relevant provisioning code and image versions match the observed failure.

| Runner image                   | Kernel              | Docker | Observations                                                                                      |
| ------------------------------ | ------------------- | ------ | ------------------------------------------------------------------------------------------------- |
| Ubuntu 24.04, `20261012.334.1` | `6.17.0-1022-azure` | 28.0.4 | Passed inspected original and reproduction jobs                                                   |
| Ubuntu 24.04, `20261018.339.1` | `7.0.0-1017-azure`  | 28.0.4 | Original failure and actual ansible-test reproductions; verbose standalone diagnostic also passed |
| Ubuntu 26.04, `20261012.163.1` | `7.0.0-1017-azure`  | 29.4.2 | Passed inspected reproduction jobs                                                                |
| Ubuntu 26.04, `20261018.168.1` | `7.0.0-1017-azure`  | 29.4.2 | Actual ansible-test failures; verbose standalone diagnostic also passed                           |

The original linked job ran Ubuntu **24.04.5**, not Ubuntu 26.04. Both operating-system versions are affected in the reproduction. Runner labels do not pin a particular weekly image build; a single matrix run can receive both old and new image versions.

Full `ansible --version` and `ansible-config dump --only-changed -t all` output were not collected. The reproduction uses a minimal generated collection without a custom `ansible.cfg`; the workflow records the pinned revision, runner image, kernel, Docker configuration, and systemd version.

## Original failure

[Original community.dns job](https://github.com/ansible-collections/community.dns/actions/runs/39370637693/job/118457555348).

Invocation:

```sh
ansible-test integration --color yes -v --docker default --python 3.14 --display-traceback error --coverage
```

Failure:

```text
ERROR: Host DockerConfig(python=NativePythonConfig(version='3.14', path='/usr/bin/python3.14'), powershell=PowerShellConfig(version='7.6', path='/usr/local/bin/pwsh7.6'), name='default', image='quay.io/ansible/default-test-container:v2.23-2', memory=None, privileged=False, seccomp='default', cgroup=CGroupVersion.V1_V2, audit=AuditMode.REQUIRED) job failed:
Command "docker run --pid host --privileged --name ansible-test-init-controller-14CkppxL --rm quay.io/ansible/ansible-test-utility-container:3.6.0 nsenter -t 3144 -m -p sh -c 'mount -o remount,rw /sys/fs/cgroup/ && pkill sleep'" returned exit status 1.
FATAL: Host job(s) failed. See previous error(s) for details.
```

There was no accompanying mount or nsenter diagnostic. This compound command initially made it unclear which operation failed.

## Expected behavior

Controller provisioning should wait for the startup synchronization process to be ready, successfully wake it after preparing cgroups, and allow the test target to run. Scheduling or executable-startup delays should not cause an immediate host-job failure while the controller is still starting normally.

## Confirmed evidence

### The original operation fails without pre-failure diagnostics

In [actual ansible-test run 39487216737](https://github.com/dbrennand/repro/actions/runs/39487216737), instrumentation was confined to the provisioning exception handler. The original helper command was unchanged.

Both [Ubuntu 24.04 replica 2](https://github.com/dbrennand/repro/actions/runs/39487216737/job/118850639430) and [Ubuntu 26.04 replica 1](https://github.com/dbrennand/repro/actions/runs/39487216737/job/118850639726) failed on trial 1. Trials 2 and 3 passed on both runners.

After failure, but before the diagnostic remount, the mount table showed:

```text
cgroup /sys/fs/cgroup cgroup2 rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot 0 0
```

The Ubuntu 26.04 entry additionally included `memory_hugetlb_accounting`.

Docker's first process snapshot showed the child still executing `env`:

```text
PID     PPID    STAT    COMMAND    COMMAND
2985    2890    D+      env        env sleep 60
```

Later inspection found `sleep` and returned:

```text
post_failure_pgrep_rc=0
diagnostic_remount_rc=0
diagnostic_signal_zero_rc=0
```

`D` is uninterruptible sleep. It supports the observation that startup was blocked, but does not identify the blocking operation; no kernel stack or wait-channel trace was captured at that instant.

### Direct identification of the failing subcommand

[Confirmation job: Ubuntu 26.04, original wakeup, replica 1](https://github.com/dbrennand/repro/actions/runs/39487948210/job/118853189166).

To distinguish the subcommands directly, the helper payload was changed to:

```sh
mount -o remount,rw /sys/fs/cgroup/ && (
    pkill sleep
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo original_pkill_rc=$rc
        ps -ef
    fi
    exit "$rc"
)
```

The process listing and output occur only after `pkill` fails. This introduces a shell wrapper, but no readiness wait or process inspection before `pkill`. The original command had already reproduced independently in the prior run.

Captured output:

```text
original_pkill_rc=1
root           9       1  0 19:58 pts/0    00:00:00 env sleep 60
```

Because this branch is reached through `&&`, the preceding mount returned success. `pkill sleep` returned 1 while the child was still named `env`. The argument `sleep` in `env sleep 60` does not make its process name match `pkill sleep`.

The exact point at which `env` becomes `sleep` matters; Docker reporting the container as started is not a readiness guarantee for that child process.

## Source-code explanation

Source links below are pinned to the tested Ansible revision:

1. [`get_docker_init_config()`](https://github.com/ansible/ansible/blob/f7319e09448e13fa2bc407a1afcd8990f47040fb/test/lib/ansible_test/_internal/host_profiles.py#L995) selects `mount -o remount,rw /sys/fs/cgroup/` for Docker/cgroup v2 and marks the command as privileged.
2. [`build_init_command()`](https://github.com/ansible/ansible/blob/f7319e09448e13fa2bc407a1afcd8990f47040fb/test/lib/ansible_test/_internal/host_profiles.py#L1048) starts the controller using `env sleep 60 ; exec /sbin/init`. The explicit `env` avoids a shell-builtin sleep.
3. [`provision()`](https://github.com/ansible/ansible/blob/f7319e09448e13fa2bc407a1afcd8990f47040fb/test/lib/ansible_test/_internal/host_profiles.py#L724) appends the wake command and executes the privileged helper through `nsenter -m -p`.
4. [`wake_command`](https://github.com/ansible/ansible/blob/f7319e09448e13fa2bc407a1afcd8990f47040fb/test/lib/ansible_test/_internal/host_profiles.py#L1081) returns `['pkill', 'sleep']`. There is no readiness handshake or retry in this sequence.
5. A nonzero helper result becomes `SubprocessError`, and provisioning fails.

The 60-second sleep is a maximum startup delay, not a guarantee that the sleep executable has started. The observed failure happens within approximately one second of controller creation, well before that timeout.

## Reproduction steps

### GitHub Actions reproduction

Repository: [dbrennand/repro](https://github.com/dbrennand/repro/tree/ansible-test-kernel-repro).

Branch: `ansible-test-kernel-repro`.

Investigation snapshot: `fa3617e`.

Relevant files:

- [Actual ansible-test workflow](https://github.com/dbrennand/repro/blob/fa3617e/.github/workflows/actual-ansible-test.yml).
- [Instrumentation script](https://github.com/dbrennand/repro/blob/fa3617e/scripts/instrument-ansible.py).
- [Post-failure diagnostics](https://github.com/dbrennand/repro/blob/fa3617e/scripts/diagnose-host.sh).
- [Standalone helper experiment](https://github.com/dbrennand/repro/blob/fa3617e/scripts/ansible-cgroup-repro.sh).

Run the actual ansible-test workflow on the branch. It has a push trigger for its own files and scripts, and declares `workflow_dispatch`. GitHub may require a workflow to exist on the default branch before manual dispatch is available; the investigation runs were triggered by pushes to this branch.

The workflow:

1. Uses Ubuntu 24.04 and 26.04, two replicas per OS, and separate original/retry modes.
2. Installs Python 3.14 and the pinned Ansible revision.
3. Creates a minimal `repro.cgroup` collection with a shell integration target that prints `CONTROLLER_INITIALIZED`.
4. Runs three actual `ansible-test integration` trials per job.
5. Captures runner details, per-trial logs, results, and kernel logs as artifacts, including when the job fails.

The first trial runs without explicitly pre-pulling the Ansible images. Later trials reuse cached images. Failures observed in these experiments occurred on the first trial. This is consistent with a startup/cache-related timing effect but is not a controlled proof that caching is the cause.

Artifacts are retained for 14 days under names such as `actual-ansible-ubuntu-26.04-original-1-1`. Download them promptly if attaching evidence to an upstream issue.

### Minimal uninstrumented invocation on a disposable Linux runner

Use a fresh runner with Docker access and Python 3.14. Start in an empty scratch directory:

```sh
python3.14 -m venv .venv
. .venv/bin/activate
python -m pip install \
  https://github.com/ansible/ansible/archive/f7319e09448e13fa2bc407a1afcd8990f47040fb.tar.gz

mkdir -p fixture/ansible_collections/repro/cgroup/tests/integration/targets/smoke
cd fixture/ansible_collections/repro/cgroup

cat > galaxy.yml <<'YAML'
namespace: repro
name: cgroup
version: 1.0.0
readme: README.md
authors: [repro]
YAML
printf '# Initialization repro\n' > README.md
cat > tests/integration/targets/smoke/runme.sh <<'SH'
#!/usr/bin/env bash
set -eu
printf 'CONTROLLER_INITIALIZED\n'
SH
chmod +x tests/integration/targets/smoke/runme.sh

ansible-test integration smoke --color no -v --docker default \
  --python 3.14 --display-traceback error --coverage
```

The minimal target removes collection-specific DNS dependencies while exercising the actual controller provisioning path. It is not the full community.dns test suite. It can emit a warning about inferred target context; that warning did not prevent successful initialization trials.

The failure is timing-sensitive. A successful attempt does not establish that the environment is unaffected. Record `ImageVersion`, `uname -a`, and Docker versions for every fresh runner; repeated attempts within one job are not equivalent to fresh-runner trials.

## Experiment history

| Experiment                                                                                                     | Result and interpretation                                                                                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Original community.dns run](https://github.com/ansible-collections/community.dns/actions/runs/39370637693)    | Inspected devel/Python 3.14 and 3.15 failures used Ubuntu 24.04 image `20261018.339.1`; inspected Python 3.12 and 3.13 successes used `20261012.334.1`. Docker and Ansible container versions matched.                                   |
| [Standalone verbose diagnostic](https://github.com/dbrennand/repro/actions/runs/39486053262)                   | Passed both OS jobs, including affected image versions. Mount, lookup, and wake all returned 0. Process inspection visibly caught `env` becoming `sleep`; diagnostic overhead could hide the race. This version used a 300-second sleep. |
| [Standalone original/retry comparison](https://github.com/dbrennand/repro/actions/runs/39486356696)            | 20 trials passed; no retries needed. Ubuntu 24.04 landed on the older image. The script used the 60-second sleep and removed intervening diagnostics before the original wakeup.                                                         |
| [First actual ansible-test workflow](https://github.com/dbrennand/repro/actions/runs/39486936583)              | Invalid experiment: all jobs stopped before the repro because the instrumentation matcher found two handlers. Fixed by restricting the patch to the provisioning section. Not evidence of the product bug.                               |
| [Actual ansible-test, exception-only diagnostics](https://github.com/dbrennand/repro/actions/runs/39487216737) | Original command reproduced on Ubuntu 24.04 and 26.04, first trial only in the failing jobs. Mount already read-write; child still `env` immediately after failure.                                                                      |
| [Actual ansible-test original/retry comparison](https://github.com/dbrennand/repro/actions/runs/39487570316)   | Original mode failed on newer images on both OS versions. All 12 retry trials passed, but every retry job landed on an older image and reported zero retries. This does not validate the fix against the failing condition.              |
| [Direct pkill-status confirmation](https://github.com/dbrennand/repro/actions/runs/39487948210)                | Captured `original_pkill_rc=1` and `env sleep 60` on Ubuntu 26.04 image `20261018.168.1`. All retry jobs again landed on older images and needed zero retries.                                                                           |

## Areas investigated and conclusions

### Cgroup remount and privilege configuration

The helper already runs privileged. `privileged=False` in the reported `DockerConfig` refers to the controller, not the helper. The failure is not evidence that the helper lacks privilege.

The direct status experiment reached the branch after `mount ... &&`, proving mount success in that failure. Earlier failures also had an already-writable cgroup mount before diagnostic remounting. No host-wide cgroup change or disabling of security controls was necessary to reproduce or diagnose the problem.

### Kernel upgrade

The [Ubuntu 24.04 image release notes](https://github.com/actions/runner-images/releases/tag/ubuntu24%2F20261018.339) show a kernel change from `6.17.0-1022-azure` to `7.0.0-1017-azure`. This initially made the kernel a strong suspect.

However, Ubuntu 26.04 jobs passed on image `20261012.163.1` and failed on `20261018.168.1`, both using kernel `7.0.0-1017-azure`. Kernel version alone is therefore insufficient to explain the behavior.

Source areas inspected:

- `mntns_install()` in [Linux 6.17](https://github.com/torvalds/linux/blob/v6.17/fs/namespace.c) and [7.0](https://github.com/torvalds/linux/blob/v7.0/fs/namespace.c): the namespace-entry body has unchanged behavior relevant to root/cwd updates.
- [Procfs `pidns=` mount option, `fe49652e36bb`](https://github.com/torvalds/linux/commit/fe49652e36bb): adds explicit namespace selection while preserving the default; the repro does not request this option.
- [Procfs access locking, `6650527444da`](https://github.com/torvalds/linux/commit/6650527444da): adds `exec_update_lock` protection, including around `/proc/PID/stat`. The inspected patch does not introduce a process-name visibility policy explaining this failure.
- [Azure kernel package changelog](https://changelogs.ubuntu.com/changelogs/pool/main/l/linux-azure-7.0/linux-azure-7.0_7.0.0-1017.17~24.04.1/changelog): reviewed namespace, procfs, cgroup, and AppArmor-related changes and backports. No causal patch identified.

This investigation was not a kernel bisect or an exhaustive audit of all Ubuntu patches and configuration differences.

### Host systemd

The Ubuntu 24.04 image changed host systemd from `255.4-1ubuntu8.17` to `.18`. The [Ubuntu package changelog](https://changelogs.ubuntu.com/changelogs/pool/main/s/systemd/systemd_255.4-1ubuntu8.18/changelog) lists only the addition of the KSK-2024 DNSSEC trust anchor to systemd-resolved for `.18`. No cgroup or process-management change was identified in that delta.

Host systemd and controller systemd are distinct. The controller's `/sbin/init` has not started at the point of the observed race.

### Docker, runtime, and security policy

Docker remained 28.0.4 across the inspected Ubuntu 24.04 image versions. Reproduction also occurred with Docker 29.4.2 on Ubuntu 26.04. A Docker version change is not required to expose the failure.

Kernel logs were collected. No security-policy denial was established as causal. The verbose Ubuntu 26.04 run contained earlier AppArmor denials associated with `systemd-detect-virt`, but that run passed initialization; these were not evidence of a failed cgroup remount or signal denial.

The actual implementation of commands after namespace entry should not be inferred solely from the utility image's Alpine base. The early BusyBox exit-status investigation was a hypothesis aid, not the final proof. The definitive evidence is the captured `pkill` exit code and contemporaneous process listing.

### Expired sleep, image downloads, and Python

The original utility image was downloaded before the controller was started. Initialization failed within roughly one second, not after the 60-second sleep. The timeout-expiry explanation is excluded for that job.

The failure occurs during host/container initialization, before collection tests execute. Original failures on Python 3.14 and 3.15 do not establish a Python-version bug; runner image versions differed between inspected successful and failed jobs.

## Proposed fix direction and validation limits

Replace the one-shot wakeup assumption with a bounded readiness handshake or retry. A candidate tested in the reproduction is:

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

The remount failure still propagates. The retry is bounded to roughly five seconds plus command execution time, well within the controller's 60-second sleep. This is experimental diagnostic code, not a proposed final upstream implementation.

**Validation limitation:** all actual ansible-test retry jobs observed so far ran on older image builds and reported `wakeup_retries=0`. Therefore the candidate has not yet demonstrated recovery from an observed first-attempt miss on an affected fresh runner. Do not report it as a validated fix.

A production fix should distinguish transient readiness from persistent permission or startup failures, remain bounded, preserve genuine remount errors, and provide useful diagnostics when readiness never occurs. Consider other consumers of `wake_command` before broadening a change beyond the confirmed Docker/cgroup v2 path. No new dependency is required by the experimental retry.

## Remaining work

- Validate a bounded wakeup/handshake on an affected fresh runner, with evidence that an initial miss is recovered.
- Add a deterministic delayed-start case to test the synchronization behavior without relying solely on runner timing.
- If identifying the runner-side trigger is necessary, capture the blocked process's wait channel/kernel stack and runtime/storage details immediately after failure. The current `D` state alone does not identify an I/O or kernel defect.
- Compare old/new Ubuntu 26.04 runner builds and provisioner versions, where the kernel version is unchanged.
- Record complete Ansible version/configuration output for issue-form submission and check current devel and supported stable versions separately. The confirmed scope here is the pinned devel revision, not all Ansible releases.

## Attribution and publication status

Investigation and report prepared with assistance from OpenAI Codex, based on the GPT-6 model. The reproduction workflows were committed and pushed to `dbrennand/repro`; no upstream Ansible code change or GitHub issue was submitted as part of this report.
