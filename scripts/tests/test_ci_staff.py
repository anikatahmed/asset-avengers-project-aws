"""Staff CI configuration and isolation checks without real credentials or services."""
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StaffPipelineTests(unittest.TestCase):
    def test_generated_settings_are_private_complete_and_fresh(self):
        pipeline = (ROOT / 'Jenkinsfile').read_text()
        code = re.search(r"python3 - <<'PYENV'\n(.*?)\nPYENV", pipeline, re.S).group(1)
        previous = None
        for _ in range(2):
            with tempfile.TemporaryDirectory() as directory:
                result = subprocess.run(['bash', '-c', 'umask 077; python3 -'], input=code,
                                        text=True, capture_output=True, cwd=directory,
                                        env=dict(os.environ, FAUXNANCE_PRICING_API_KEY='fixture-provider-key'))
                self.assertEqual(result.returncode, 0, result.stderr)
                path = Path(directory) / '.env'
                settings = dict(line.split('=', 1) for line in path.read_text().splitlines())
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(settings['EMAIL_FROM'], 'Asset Avengers <security@assetavengers.top>')
                self.assertNotIn('RESEND_API_KEY', settings)
                self.assertEqual(len(base64.b64decode(settings['MFA_ENCRYPTION_KEY'])), 32)
                self.assertGreaterEqual(len(settings['SUPERSET_SSO_SECRET']), 32)
                self.assertGreaterEqual(len(settings['JWT_SECRET']), 32)
                self.assertNotEqual(settings['DB_PASSWORD'], settings['AUTH_DB_PASSWORD'])
                self.assertNotIn(settings['JWT_SECRET'], result.stdout)
                if previous:
                    self.assertNotEqual(previous, settings['JWT_SECRET'])
                previous = settings['JWT_SECRET']

    def test_cleanup_mode_never_starts_a_stack(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            calls = folder / 'calls'
            compose = folder / 'docker'
            compose.write_text("""#!/usr/bin/env python3
import os,sys
from pathlib import Path
with open(os.environ['CALLS'],'a') as output: output.write(' '.join(sys.argv[1:])+'\\n')
settings=dict(line.split('=',1) for line in Path(sys.argv[sys.argv.index('--env-file')+1]).read_text().splitlines())
Path(os.environ['COPIED_SSO']).write_text(settings['SUPERSET_SSO_SECRET'])
""")
            sso = folder / 'copied-sso'
            fixture = folder / 'auth.env'
            fixture.write_text('SUPERSET_SSO_SECRET=shared-disposable-secret-for-this-test\n')
            compose.chmod(0o755)
            result = subprocess.run(['python3', str(ROOT / 'scripts/verify-admin-stack.py'),
                                     '--project-name', 'endgame-ci-0123456789abcdef-staff',
                                     '--image-tag', 'endgame-ci-0123456789abcdef', '--ci-env-file', str(fixture), '--cleanup'],
                                    env=dict(os.environ, PATH=directory+':'+os.environ['PATH'], CALLS=str(calls), COPIED_SSO=str(sso)),
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(sso.read_text(), 'shared-disposable-secret-for-this-test')
            commands = calls.read_text()
            self.assertIn('down --volumes --remove-orphans', commands)
            self.assertNotIn(' up ', commands)
            self.assertIn('-p endgame-ci-0123456789abcdef-staff', commands)

    def test_cleanup_refuses_development_project(self):
        result = subprocess.run(['python3', str(ROOT / 'scripts/verify-admin-stack.py'),
                                 '--project-name', 'asset-avengers-internal', '--cleanup'],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Expected an isolated', result.stderr)

    def test_all_four_builds_and_integration_are_required_before_sonar(self):
        pipeline = (ROOT / 'Jenkinsfile').read_text()
        for action in ('staff-build', 'staff-integration'):
            self.assertLess(pipeline.index('bash scripts/ci-checks.sh ' + action),
                            pipeline.index("stage('SonarQube Analysis')"))
        self.assertIn('bash scripts/ci-checks.sh staff-cleanup', pipeline)
        self.assertIn("sh 'rm -f .env'", pipeline)
        config = (ROOT / 'deployment/admin-analytics/admin-analyst-ci.compose.yml').read_text()
        self.assertEqual(config.count(':${STAFF_IMAGE_TAG:-local}'), 7)
        self.assertIn("'amr':['pwd','mfa']", (ROOT / 'admin-analytics/pipeline/tests/http-check.py').read_text())


if __name__ == '__main__':
    unittest.main()
