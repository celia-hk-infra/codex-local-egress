import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'install_dev_tunnel.sh'


class InstallerTests(unittest.TestCase):
    def clean_env(self, home):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('CONDA_') and key not in (
                   'LD_LIBRARY_PATH', 'ICU_LIB_DIR', 'DOTNET_SYSTEM_GLOBALIZATION_INVARIANT')}
        env.update(HOME=str(home), PATH=str(home / 'tools') + ':/usr/bin:/bin')
        return env

    def run_install(self, arch='aarch64', system='Linux', fail_download=False,
                    bad_binary=False, needs_icu=False, setup=None):
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
        tool('conda', 'exit 1\n')
        tool('curl', '''printf '%s\\n' "$@" > "$HOME/curl-args"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output="$2"; shift; fi
  shift
done
if [[ "${FAIL_DOWNLOAD:-}" == 1 ]]; then exit 22; fi
if [[ "${BAD_BINARY:-}" == 1 ]]; then
  printf '#!/bin/bash\\nexit 1\\n' > "$output"
else
  cat > "$output" <<'BINARY'
#!/bin/bash
if [[ -f "$HOME/needs-icu" ]]; then
  printf '%s\\n' "${LD_LIBRARY_PATH:-}" >> "$HOME/probe-paths"
  expected="$(cat "$HOME/working-icu")"
  if [[ ":${LD_LIBRARY_PATH:-}:" != *":$expected:"* ]]; then
    echo "Couldn't find a valid ICU package installed on the system" >&2
    exit 1
  fi
fi
if [[ "$1" == --version ]]; then
  echo 'test devtunnel version'
else
  printf '<%s>\\n' "$@"
  printf 'LD_LIBRARY_PATH=%s\\n' "${LD_LIBRARY_PATH:-}"
fi
BINARY
fi
''')
        env = self.clean_env(home)
        env.update(FAIL_DOWNLOAD=str(int(fail_download)), BAD_BINARY=str(int(bad_binary)))
        if needs_icu:
            (home / 'needs-icu').touch()
            (home / 'working-icu').write_text('/nonexistent-icu-library')
        if fail_download or bad_binary:
            (home / '.local/bin').mkdir(parents=True)
            (home / '.local/bin/devtunnel').write_text('previous install')
        if setup:
            setup(home, tool, env)
        result = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)
        return home, result

    def libraries(self, home, prefix, working=True, missing=None):
        lib = home / prefix / 'lib'
        lib.mkdir(parents=True, exist_ok=True)
        for name in ('libicuuc', 'libicui18n', 'libicudata'):
            if name != missing:
                (lib / (name + '.so.73')).touch()
        if working:
            (home / 'working-icu').write_text(str(lib.resolve()))
        return lib

    def assert_wrapper_works(self, home):
        result = subprocess.run([str(home / '.local/bin/devtunnel'), '--version'],
                                env=self.clean_env(home), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('test devtunnel version', result.stdout)
        self.assertTrue((home / '.local/bin/devtunnel.bin').is_file())
        self.assertEqual(list((home / '.local/bin').glob('.devtunnel-download.*')), [])

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

    def test_conda_base_and_fresh_shell(self):
        def setup(home, tool, env):
            self.libraries(home, 'custom conda')
            tool('conda', '[[ "$2" == --base ]] && echo "$HOME/custom conda"\n')
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)

    def test_environment_outside_conda_base(self):
        def setup(home, tool, env):
            self.libraries(home, 'external environment')
            tool('conda', '''if [[ "$2" == --base ]]; then
  echo "$HOME/base"
else
  echo '# conda environments:'
  echo "external env    *  $HOME/external environment"
fi
''')
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)

    def test_active_conda_environment(self):
        def setup(home, tool, env):
            lib = self.libraries(home, 'active')
            env['CONDA_PREFIX'] = str(lib.parent)
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)

    def test_conda_not_on_path(self):
        def setup(home, tool, env):
            (home / 'tools/conda').unlink()
            self.libraries(home, 'miniconda3/envs/worker')
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)

    def test_conda_environment_registry(self):
        def setup(home, tool, env):
            lib = self.libraries(home, 'registered env')
            (home / '.conda').mkdir()
            (home / '.conda/environments.txt').write_text(str(lib.parent))
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)

    def test_skip_incomplete_and_incompatible_libraries(self):
        def setup(home, tool, env):
            self.libraries(home, 'miniconda3', working=False, missing='libicudata')
            self.libraries(home, 'miniconda3/envs/a-bad', working=False)
            self.libraries(home, 'miniconda3/envs/b-good')
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        probes = (home / 'probe-paths').read_text().splitlines()
        self.assertNotIn(str(home / 'miniconda3/lib'), probes)
        self.assertIn(str(home / 'miniconda3/envs/a-bad/lib'), probes)
        self.assert_wrapper_works(home)

    def test_explicit_library_path_is_safely_quoted_and_preserves_arguments(self):
        def setup(home, tool, env):
            lib = self.libraries(home, "ICU 'quoted' $(touch injected) $literal")
            env['ICU_LIB_DIR'] = str(lib)
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)
        env = self.clean_env(home)
        env['LD_LIBRARY_PATH'] = '/existing/libraries'
        result = subprocess.run([str(home / '.local/bin/devtunnel'), 'arg with spaces', '*', '$literal'],
                                cwd=home, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<arg with spaces>\n<*>\n<$literal>', result.stdout)
        self.assertIn(':/existing/libraries', result.stdout)
        self.assertFalse((home / 'injected').exists())

    def test_shell_library_path_is_saved_for_future_shells(self):
        def setup(home, tool, env):
            env['LD_LIBRARY_PATH'] = str(self.libraries(home, 'custom libraries'))
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)

    def test_rerun_updates_wrapper_and_keeps_old_install_on_failure(self):
        def setup(home, tool, env):
            self.libraries(home, 'miniconda3')
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.libraries(home, 'miniconda3/envs/new-environment')
        result = subprocess.run(['bash', str(SCRIPT)], env=self.clean_env(home),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_wrapper_works(home)
        wrapper = home / '.local/bin/devtunnel'
        binary = home / '.local/bin/devtunnel.bin'
        previous = (wrapper.read_bytes(), binary.read_bytes())
        for failure in ('download', 'binary', 'icu'):
            with self.subTest(failure=failure):
                env = self.clean_env(home)
                if failure == 'download':
                    env['FAIL_DOWNLOAD'] = '1'
                elif failure == 'binary':
                    env['BAD_BINARY'] = '1'
                else:
                    (home / 'working-icu').write_text('/no-compatible-icu')
                result = subprocess.run(['bash', str(SCRIPT)], env=env,
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((wrapper.read_bytes(), binary.read_bytes()), previous)
                self.assertEqual(list(wrapper.parent.glob('.devtunnel-download.*')), [])

    def test_missing_icu_gives_manual_override(self):
        home, result = self.run_install(needs_icu=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ICU_LIB_DIR=', result.stderr)
        self.assertFalse((home / '.local/bin/devtunnel').exists())

    def test_scripts_find_icu_wrapper(self):
        def setup(home, tool, env):
            self.libraries(home, 'miniconda3')
        home, result = self.run_install(needs_icu=True, setup=setup)
        self.assertEqual(result.returncode, 0, result.stderr)
        env = self.clean_env(home)
        env['PATH'] = '/usr/bin:/bin'
        command = 'require() { command -v "$1" >/dev/null; }; DIR="$1"; source "$DIR/devtunnel-auth.sh"; require devtunnel; devtunnel --version'
        result = subprocess.run(['bash', '-c', command, 'test', str(ROOT)], env=env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help(self):
        result = subprocess.run(['bash', str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Linux', result.stdout)


if __name__ == '__main__':
    unittest.main()
