"""Add diagnostics exclusively to DockerProfile.provision's exception path."""
from pathlib import Path
import ansible_test
import os

source = Path(ansible_test.__file__).parent / '_internal/host_profiles.py'
text = source.read_text()
needle = '''        except SubprocessError:
            display.info(f'Checking container "{self.container_name}" logs...')'''
replacement = '''        except SubprocessError:
            import subprocess
            import os
            try:
                subprocess.run(
                    ['bash', os.environ['ANSIBLE_REPRO_DIAGNOSTIC'], self.container_name],
                    timeout=30, check=False,
                )
            except Exception as diagnostic_error:
                print(f'Failure diagnostics could not complete: {diagnostic_error}', flush=True)
            display.info(f'Checking container "{self.container_name}" logs...')'''
prefix, separator, suffix = text.partition('    def get_init_config(self)')
assert separator and prefix.count(needle) == 1, 'Expected provisioning handler changed; refusing to patch'
prefix = prefix.replace(needle, replacement)
if os.environ.get('WAKE_MODE') == 'retry':
    wake = "init_command += f' && {shlex.join(self.wake_command)}'"
    bounded = "init_command += ' && (i=0; until pkill sleep; do i=$((i+1)); [ \"$i\" -lt 50 ] || exit 1; sleep 0.1; done; echo wakeup_retries=$i)'"
    assert prefix.count(wake) == 1
    prefix = prefix.replace(wake, bounded)
    call = "                run_utility_container(self.args, f'ansible-test-init-{self.label}', cmd, options)"
    assert prefix.count(call) == 1
    prefix = prefix.replace(call, "                wake_output = " + call.strip() + "\n                display.info(f'Wake diagnostic: {wake_output[0]}')")
    print('Enabled bounded wakeup retry; remount failure still propagates')
source.write_text(prefix + separator + suffix)
print(f'Instrumented failure handler: {source}')
