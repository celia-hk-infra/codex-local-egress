import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'install_dev_tunnel.sh'


class InstallerTests(unittest.TestCase):
    def run_install(self, arch='aarch64', system='Linux', fail_download=False, bad_binary=False):
        tmp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(tmp.cleanup)
        home = Path(tmp.name)
        tools = home / 'tools'
        tools.mkdir()
        def tool(name, content):
            path = tools / name
            path.write_text('#!/bin/bash\n' + content)
            path.chmod(0o755)
        tool('uname', f'if [[ "$1" == -s ]]; then echo {system}; else echo {arch}; fi\n')
        tool('curl', '''printf '%s\\n' "$@" > "$HOME/curl-args"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output="$2"; shift; fi
  shift
done
if [[ "${FAIL_DOWNLOAD:-}" == 1 ]]; then exit 22; fi
if [[ "${BAD_BINARY:-}" == 1 ]]; then
  printf '#!/bin/bash\\nexit 1\\n' > "$output"
else
  printf '#!/bin/bash\\nprintf "test devtunnel version\\\\n"\\n' > "$output"
fi
''')
        env = dict(os.environ, HOME=str(home), PATH=str(tools)+':/usr/bin:/bin',
                   FAIL_DOWNLOAD=str(int(fail_download)), BAD_BINARY=str(int(bad_binary)))
        if fail_download or bad_binary:
            (home / '.local/bin').mkdir(parents=True)
            (home / '.local/bin/devtunnel').write_text('previous install')
        result = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)
        return home, result

    def test_install_arm64(self):
        home, result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = home / '.local/bin/devtunnel'
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertIn('https://aka.ms/TunnelsCliDownload/linux-arm64', (home/'curl-args').read_text())
        self.assertIn('test devtunnel version', result.stdout)

    def test_install_x64(self):
        home, result = self.run_install(arch='x86_64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('linux-x64', (home/'curl-args').read_text())

    def test_unsupported_architecture(self):
        home, result = self.run_install(arch='riscv64')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((home/'curl-args').exists())

    def test_unsupported_os(self):
        home, result = self.run_install(system='Darwin')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((home/'curl-args').exists())

    def test_failed_download_keeps_existing_binary(self):
        home, result = self.run_install(fail_download=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((home/'.local/bin/devtunnel').read_text(), 'previous install')
        self.assertEqual(list((home/'.local/bin').glob('.devtunnel-download.*')), [])

    def test_unusable_binary_keeps_existing_binary(self):
        home, result = self.run_install(bad_binary=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((home/'.local/bin/devtunnel').read_text(), 'previous install')
        self.assertEqual(list((home/'.local/bin').glob('.devtunnel-download.*')), [])

    def test_scripts_find_user_local_install(self):
        home, result = self.run_install()
        env = dict(os.environ, HOME=str(home), PATH='/usr/bin:/bin')
        command = 'require() { command -v "$1" >/dev/null; }; DIR="$1"; source "$DIR/devtunnel-auth.sh"; require devtunnel; devtunnel --version'
        result = subprocess.run(['bash', '-c', command, 'test', str(ROOT)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help(self):
        result = subprocess.run(['bash', str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Linux', result.stdout)


if __name__ == '__main__':
    unittest.main()
