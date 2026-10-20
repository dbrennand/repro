"""Add diagnostics exclusively to DockerProfile.provision's exception path."""
from pathlib import Path
import ansible_test

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
assert text.count(needle) == 1, 'Expected exception handler changed; refusing to patch'
source.write_text(text.replace(needle, replacement))
print(f'Instrumented failure handler: {source}')
