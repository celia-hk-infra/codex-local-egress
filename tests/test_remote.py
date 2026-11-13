import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        for name in ('remote.sh', 'devtunnel-auth.sh'):
            shutil.copy2(ROOT / name, self.work / name)
        (self.work / 'connection.env').write_text(
            "PROXY_PORT=51842\nPROXY_AUTH=test:abcdef\nTUNNEL_ID=example\n")
        tools = self.work / 'tools'
        tools.mkdir()
        # Mock only network preflight; execute the requested commands normally.
        for name, body in {
            'python3': 'exit "${PROBE_STATUS:-0}"',
            'curl': 'printf 203.0.113.1; exit "${CURL_STATUS:-0}"',
        }.items():
            path = tools / name
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o700)
        self.env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'])

    def run_remote(self, *args, umask=0o022, **env):
        return subprocess.run(
            ['bash', str(self.work / 'remote.sh'), *args],
            env=dict(self.env, **env), cwd=self.work,
            capture_output=True, text=True, umask=umask)

    def test_command_stdout_is_clean(self):
        result = self.run_remote('bash', '-c', 'printf \'{"ok":true}\\n\'')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '{"ok":true}\n')
        self.assertIn('203.0.113.1', result.stderr)

    def test_test_mode_keeps_ip_on_stdout(self):
        result = self.run_remote('test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('203.0.113.1', result.stdout)

    def test_failed_preflight_prevents_execution(self):
        for env, expected in (({'PROBE_STATUS': '1'}, 1), ({'CURL_STATUS': '22'}, 22)):
            with self.subTest(env=env):
                result = self.run_remote('bash', '-c', 'echo executed', **env)
                self.assertEqual(result.returncode, expected)
                self.assertNotIn('executed', result.stdout)


if __name__ == '__main__':
    unittest.main()
