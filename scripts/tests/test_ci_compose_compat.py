"""Exercise the legacy-compatible staff verifier without starting application stacks."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('staff_verifier', ROOT / 'scripts/verify-admin-stack.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ComposeCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.command = ['docker', 'compose', '-p', 'verify-test']
        self.services = ['reporting-db', 'kafka-init', 'consumer']
        self.states = {
            'reporting-db': {'Status': 'running', 'Health': {'Status': 'healthy'}},
            'kafka-init': {'Status': 'exited', 'ExitCode': 0},
            'consumer': {'Status': 'running'},
        }

    def output(self, command, **kwargs):
        if command[-2:] == ['config', '--services']:
            return '\n'.join(self.services)
        if 'ps' in command:
            return command[-1] + '-id'
        service = command[-1].removesuffix('-id')
        return json.dumps([{'Config': {'Labels': {'com.docker.compose.project': 'verify-test'}},
                            'State': self.states[service]}])

    def test_port_removal_preserves_application_and_database_config(self):
        original = (ROOT / 'deployment/admin-analytics/admin-analyst-stack.compose.yml').read_text()
        portable = verifier.portable_test_base(original)
        self.assertNotIn('ports:', portable)
        self.assertIn('postgres:18.6-trixie', portable)
        self.assertIn('../../DB/admin_analytics_db.schema.sql', portable)
        self.assertIn('service_completed_successfully', portable)
        self.assertEqual(original, (ROOT / 'deployment/admin-analytics/admin-analyst-stack.compose.yml').read_text())

    def test_unexpected_multiline_ports_are_rejected(self):
        with self.assertRaises(ValueError):
            verifier.portable_test_base('services:\n  api:\n    ports:\n      - "8085:8085"\n')

    @patch.object(verifier.time, 'sleep')
    @patch.object(verifier.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0))
    def test_healthy_containers_and_successful_init_need_no_fixed_delay(self, run, sleep):
        with patch.object(verifier.subprocess, 'check_output', side_effect=self.output) as output:
            verifier.wait_for_stack(self.command, 'verify-test')
        self.assertIn(self.command + ['ps', '-a', '-q', 'kafka-init'], [call.args[0] for call in output.call_args_list])
        sleep.assert_not_called()
        probe = run.call_args.args[0]
        self.assertIn('http://superset:8088/health', probe[-1])
        self.assertIn('http://internal-backend:8085/v3/api-docs', probe[-1])

    def test_failed_initializer_is_not_treated_as_healthy(self):
        self.states['kafka-init']['ExitCode'] = 1
        with patch.object(verifier.subprocess, 'check_output', side_effect=self.output):
            with self.assertRaisesRegex(RuntimeError, 'Initialization failed'):
                verifier.wait_for_stack(self.command, 'verify-test')

    def test_stopped_worker_fails(self):
        self.states['consumer']['Status'] = 'exited'
        with patch.object(verifier.subprocess, 'check_output', side_effect=self.output):
            with self.assertRaisesRegex(RuntimeError, 'stopped'):
                verifier.wait_for_stack(self.command, 'verify-test')

    @patch.object(verifier.time, 'monotonic', side_effect=[0, 2])
    def test_unhealthy_container_times_out(self, clock):
        self.states['reporting-db']['Health']['Status'] = 'starting'
        with patch.object(verifier.subprocess, 'check_output', side_effect=self.output):
            with self.assertRaises(TimeoutError):
                verifier.wait_for_stack(self.command, 'verify-test', timeout=1)

    @patch.object(verifier.time, 'monotonic', side_effect=[0, 2])
    @patch.object(verifier.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1))
    def test_http_readiness_failure_times_out(self, run, clock):
        with patch.object(verifier.subprocess, 'check_output', side_effect=self.output):
            with self.assertRaisesRegex(TimeoutError, 'HTTP'):
                verifier.wait_for_stack(self.command, 'verify-test', timeout=1)

    def test_normal_staff_commands_keep_existing_project_identity(self):
        for name in ('start-project.sh', 'stop-project.sh', 'load-demo-data.sh'):
            self.assertIn('docker compose -p asset-avengers-internal --env-file .env',
                          (ROOT / 'scripts' / name).read_text())
        override = (ROOT / 'deployment/admin-analytics/admin-analyst-tests.override.yml').read_text()
        self.assertNotIn('!reset', override)


if __name__ == '__main__':
    unittest.main()
