"""CI lifecycle guard tests. Docker is mocked; no real containers are changed."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/ci-compose.sh'


class CiComposeGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        folder = Path(self.temp.name)
        self.project = 'endgame-ci-' + secrets.token_hex(8)
        self.receipt = ROOT / '.ci' / (self.project + '.initialized')
        self.log = folder / 'calls.jsonl'
        fixture = folder / 'test.env'
        fixture.write_text('TEST_ONLY=1\n')
        docker = folder / 'docker'
        docker.write_text('''#!/usr/bin/env python3
import json,os,sys
with open(os.environ['CI_MOCK_LOG'],'a') as log: log.write(json.dumps(sys.argv[1:])+'\\n')
if 'config' in sys.argv and os.environ.get('CI_MOCK_CONFIG_FAIL')=='1': sys.exit(7)
''')
        docker.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(folder) + os.pathsep + os.environ['PATH'],
                    'CI_PROJECT_NAME': self.project, 'CI_ENV_FILE': str(fixture), 'CI_MOCK_LOG': str(self.log)}

    def tearDown(self):
        self.receipt.unlink(missing_ok=True)
        self.temp.cleanup()

    def run_helper(self, *args):
        return subprocess.run(['bash', str(HELPER), *args], env=self.env, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_missing_or_development_name_never_calls_docker(self):
        for value in ['', 'asset-avengers-project', 'endgame-ci-', '../../unsafe', 'endgame-ci-1234;echo bad']:
            self.env['CI_PROJECT_NAME'] = value
            self.assertNotEqual(self.run_helper('cleanup').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_cleanup_before_initialization_never_calls_docker(self):
        self.assertNotEqual(self.run_helper('cleanup').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_failed_configuration_does_not_arm_cleanup(self):
        self.env['CI_MOCK_CONFIG_FAIL'] = '1'
        self.assertNotEqual(self.run_helper('init').returncode, 0)
        self.assertFalse(self.receipt.exists())
        before = self.calls()
        self.assertNotEqual(self.run_helper('cleanup').returncode, 0)
        self.assertEqual(self.calls(), before)

    def test_all_operations_use_exact_ci_project_and_file(self):
        self.assertEqual(self.run_helper('init').returncode, 0)
        self.assertEqual(self.run_helper('up', '-d', 'postgres').returncode, 0)
        self.assertEqual(self.run_helper('cleanup').returncode, 0)
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        for call in calls:
            self.assertEqual(call[:7], ['compose', '--env-file', self.env['CI_ENV_FILE'], '-p', self.project,
                                       '-f', str(ROOT / 'deployment/ci/ci.compose.yml')])
        self.assertEqual(calls[-1][7:], ['down', '--volumes', '--remove-orphans'])
        self.assertFalse(self.receipt.exists())
        self.assertNotEqual(self.run_helper('cleanup').returncode, 0)
        self.assertEqual(len(self.calls()), 3)

    def test_mismatched_receipt_and_unapproved_actions_are_refused(self):
        self.assertEqual(self.run_helper('init').returncode, 0)
        self.assertNotEqual(self.run_helper('down', '--volumes').returncode, 0)
        self.receipt.write_text('different-project\n')
        self.assertNotEqual(self.run_helper('cleanup').returncode, 0)
        self.assertEqual(len(self.calls()), 1)

    def test_generated_project_is_accepted_by_init(self):
        generated = self.run_helper('new-project')
        self.assertEqual(generated.returncode, 0)
        self.env['CI_PROJECT_NAME'] = generated.stdout.strip()
        receipt = ROOT / '.ci' / (self.env['CI_PROJECT_NAME'] + '.initialized')
        self.addCleanup(receipt.unlink, missing_ok=True)
        self.assertEqual(self.run_helper('init').returncode, 0)
        self.assertTrue(receipt.exists())
        self.assertEqual(self.run_helper('cleanup').returncode, 0)

    def test_jenkins_does_not_shadow_mutable_runtime_state(self):
        pipeline = (ROOT / 'Jenkinsfile').read_text()
        before_stages = pipeline.split('    stages {', 1)[0]
        for name in ('CI_PROJECT_NAME', 'CI_ENV_INITIALIZED', 'STAFF_ENV_STARTED', 'CI_SETTINGS_GENERATED'):
            self.assertNotIn(name + ' =', before_stages)
            self.assertIn('env.' + name + ' =', pipeline)
        self.assertIn('env.CI_PROJECT_NAME ==~ /endgame-ci-[a-f0-9]{16}/', pipeline)

    def test_project_names_are_unique_and_resource_free(self):
        first = self.run_helper('new-project')
        second = self.run_helper('new-project')
        self.assertRegex(first.stdout.strip(), r'^endgame-ci-[a-f0-9]{16}$')
        self.assertNotEqual(first.stdout, second.stdout)
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
