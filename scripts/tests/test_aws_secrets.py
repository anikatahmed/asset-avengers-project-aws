"""Render root .env from a stub Secrets Manager response without AWS access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SECRET = {'JWT_SECRET': "fixture'quoted$secret", 'AUTH_DB_SSL_CA': 'line one\nline two',
          'MFA_ENCRYPTION_KEY': 'k', 'SUPERSET_SSO_SECRET': 's', 'RESEND_API_KEY': 'r'}


def fetch(folder, secret, aws_fails=False):
    (folder / 'scripts').mkdir(exist_ok=True)
    shutil.copy(ROOT / 'scripts/fetch-env-aws.sh', folder / 'scripts')
    (folder / 'bin').mkdir(exist_ok=True)
    aws = folder / 'bin/aws'
    aws.write_text('#!/usr/bin/env bash\n' + ('exit 254\n' if aws_fails else 'cat "$SECRET_FIXTURE"\n'))
    aws.chmod(0o755)
    (folder / 'secret.json').write_text(json.dumps(secret))
    env = {**os.environ, 'PATH': f"{folder / 'bin'}{os.pathsep}{os.environ['PATH']}",
           'SECRET_FIXTURE': str(folder / 'secret.json')}
    return subprocess.run(['bash', str(folder / 'scripts/fetch-env-aws.sh')],
                          env=env, capture_output=True, text=True)


@unittest.skipUnless(shutil.which('jq'), 'jq required')
class FetchEnvTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('docker'), 'Docker Compose CLI required')
    def test_compose_reads_values_literally(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            result = fetch(folder, SECRET)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((folder / '.env').stat().st_mode & 0o777, 0o600)
            (folder / 'compose.yml').write_text('services:\n  app:\n    image: busybox\n    environment:\n'
                                                + ''.join(f'      {key}: ${{{key}}}\n' for key in SECRET))
            config = subprocess.run(['docker', 'compose', 'config', '--format', 'json'], cwd=folder,
                                    capture_output=True, text=True, check=True)
            environment = json.loads(config.stdout)['services']['app']['environment']
            # Compose escapes dollar signs when serializing reusable configuration.
            self.assertEqual({key: value.replace('$$', '$') for key, value in environment.items()}, SECRET)

    def test_failed_fetch_keeps_existing_env(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / '.env').write_text('KEEP=1\n')
            result = fetch(folder, SECRET, aws_fails=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((folder / '.env').read_text(), 'KEEP=1\n')

    def test_backslash_value_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            result = fetch(folder, {**SECRET, 'DB_PASSWORD': 'ends\\'})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('DB_PASSWORD contains a backslash', result.stderr)
            self.assertFalse((folder / '.env').exists())

    def test_missing_feature_keys_warn(self):
        with tempfile.TemporaryDirectory() as directory:
            result = fetch(Path(directory), {'JWT_SECRET': 'x'})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('MFA_ENCRYPTION_KEY is not in the secret', result.stderr)


if __name__ == '__main__':
    unittest.main()
