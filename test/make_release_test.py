"""Check release signing setup without accessing real credentials or building Flutter.

Run: python3 -m unittest discover -s test -p make_release_test.py
"""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MakeReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        shutil.copyfile(Path(__file__).resolve().parents[1] / 'Makefile', self.root / 'Makefile')
        flutter = self.root / 'flutter'
        flutter.write_text('''#!/usr/bin/env python3
import json, os, pathlib, stat, sys
path = pathlib.Path(os.environ['TUNNEL_FORGE_ANDROID_KEYSTORE_PATH'])
pathlib.Path('invocation.json').write_text(json.dumps({
    'args': sys.argv[1:], 'path': str(path), 'key': path.read_text(),
    'mode': stat.S_IMODE(path.stat().st_mode),
    'password': os.environ['TUNNEL_FORGE_ANDROID_KEYSTORE_PASSWORD'],
    'alias': os.environ['TUNNEL_FORGE_ANDROID_KEY_ALIAS'],
    'key_password': os.environ['TUNNEL_FORGE_ANDROID_KEY_PASSWORD'],
}))
sys.exit(int(os.environ.get('FAKE_FLUTTER_EXIT', '0')))
''')
        flutter.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('TUNNEL_FORGE_ANDROID_')}
        self.env['PATH'] = str(self.root) + os.pathsep + self.env['PATH']
        self.env['TMPDIR'] = str(self.root)

    def run_make(self, source=None, credentials=True):
        if source is not None:
            content = source + '\n'
            if credentials:
                content += (
                    "TUNNEL_FORGE_ANDROID_KEYSTORE_PASSWORD='test password $ with spaces'\n"
                    'TUNNEL_FORGE_ANDROID_KEY_ALIAS=test-alias\n'
                    "TUNNEL_FORGE_ANDROID_KEY_PASSWORD='test key password'\n"
                )
            (self.root / '.env').write_text(content)
        return subprocess.run(['make', 'build-release'], cwd=self.root, env=self.env,
                              capture_output=True, text=True)

    def test_file_keystore_is_exported_with_absolute_path(self):
        key = self.root / 'test key.jks'
        key.write_text('test keystore')
        result = self.run_make("TUNNEL_FORGE_ANDROID_KEYSTORE_PATH='test key.jks'")
        self.assertEqual(result.returncode, 0, result.stderr)
        invocation = json.loads((self.root / 'invocation.json').read_text())
        self.assertEqual(invocation['args'], ['build', 'apk', '--release', '--split-per-abi'])
        self.assertEqual(invocation['path'], str(key))
        self.assertEqual(invocation['password'], 'test password $ with spaces')
        self.assertEqual(invocation['alias'], 'test-alias')
        self.assertEqual(invocation['key_password'], 'test key password')
        self.assertEqual(key.read_text(), 'test keystore')
        self.assertNotIn('test password', result.stdout + result.stderr)

    def test_base64_keystore_is_private_and_removed_even_on_build_failure(self):
        for exit_code in ('0', '1'):
            with self.subTest(exit_code=exit_code):
                self.env['FAKE_FLUTTER_EXIT'] = exit_code
                encoded = base64.b64encode(b'test keystore').decode()
                result = self.run_make('TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64=' + encoded)
                self.assertEqual(result.returncode == 0, exit_code == '0')
                invocation = json.loads((self.root / 'invocation.json').read_text())
                self.assertEqual(invocation['key'], 'test keystore')
                self.assertEqual(invocation['mode'], 0o600)
                self.assertFalse(Path(invocation['path']).exists())

    def test_missing_or_invalid_signing_configuration_never_builds(self):
        for source, credentials in (
            (None, True), ('', True), ('', False),
            ('TUNNEL_FORGE_ANDROID_KEYSTORE_PATH=missing.jks', True),
            ('TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64=not-base64!', True),
            ('TUNNEL_FORGE_ANDROID_KEYSTORE_PATH=key.jks\n'
             'TUNNEL_FORGE_ANDROID_KEYSTORE_BASE64=dGVzdA==', True),
        ):
            with self.subTest(source=source, credentials=credentials):
                result = self.run_make(source, credentials)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'invocation.json').exists())
                self.assertFalse(list(self.root.glob('tmp.*')))


if __name__ == '__main__':
    unittest.main()
