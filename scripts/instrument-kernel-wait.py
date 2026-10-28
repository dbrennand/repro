"""Leave the original wake command intact; diagnose only its exception path."""
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
                subprocess.run(['bash', os.environ['ANSIBLE_REPRO_DIAGNOSTIC'], self.container_name],
                               timeout=20, check=False)
            except Exception as diagnostic_error:
                print(f'Failure diagnostics: {diagnostic_error}', flush=True)
            display.info(f'Checking container "{self.container_name}" logs...')'''
prefix, separator, suffix = text.partition('    def get_init_config(self)')
assert separator and prefix.count(needle) == 1, 'Provisioning handler changed'
source.write_text(prefix.replace(needle, replacement) + separator + suffix)
print('Original provisioning command preserved; exception-only diagnostics installed')
