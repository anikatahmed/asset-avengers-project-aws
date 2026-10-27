"""Render deployment configs without Docker daemon access or real credentials."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('docker'), 'Docker Compose CLI required')
class AwsRuntimeTests(unittest.TestCase):
    def test_external_databases_and_static_frontends(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'runtime.env'
            fixture.write_text('\n'.join(
                line if line.split('=', 1)[1] else line + 'test-placeholder'
                for line in (ROOT / '.env.example').read_text().splitlines()
                if line and not line.startswith('#') and '=' in line
            ) + '\n')
            # Ignore developer overrides so this check always verifies the fixture.
            env = {k: v for k, v in os.environ.items()
                   if k not in {line.split('=', 1)[0] for line in fixture.read_text().splitlines()}}
            configs = []
            for name in ['docker-compose.yml',
                         'deployment/admin-analytics/admin-analyst-stack.compose.yml']:
                result = subprocess.run(['docker', 'compose', '--env-file', str(fixture),
                                         '-f', str(ROOT / name), 'config', '--format', 'json'],
                                        env=env, capture_output=True, text=True, check=True)
                configs.append(json.loads(result.stdout))
            client, staff = configs
            self.assertEqual(set(client['services']), {'backend', 'auth-server'})
            self.assertEqual(set(staff['services']), {'kafka', 'kafka-init', 'publisher',
                             'consumer', 'reporting-job', 'internal-backend', 'superset-init', 'superset'})
            for config in configs:
                for service in config['services'].values():
                    self.assertFalse(service.get('image', '').startswith('postgres:'))
                    self.assertNotIn('reporting-db', service.get('depends_on', {}))
            auth = client['services']['auth-server']['environment']
            self.assertEqual(auth['AUTH_DB_HOST'], 'YOUR-RDS-ENDPOINT')
            self.assertEqual(str(auth['AUTH_DB_PORT']), '5432')
            self.assertEqual(str(auth['AUTH_DB_SSL']).lower(), 'true')
            self.assertIn('YOUR-RDS-ENDPOINT', client['services']['backend']['environment']['DB_URL'])
            for name in ['consumer', 'reporting-job']:
                self.assertEqual(staff['services'][name]['environment']['REPORTING_DB_HOST'], 'YOUR-RDS-ENDPOINT')
            self.assertEqual(staff['services']['publisher']['environment']['SOURCE_DB_HOST'], 'YOUR-RDS-ENDPOINT')
            self.assertIn('YOUR-RDS-ENDPOINT', staff['services']['internal-backend']['environment']['ADMIN_DB_URL'])
            for name in ['superset', 'superset-init']:
                self.assertEqual(staff['services'][name]['environment']['SUPERSET_METADATA_HOST'], 'YOUR-RDS-ENDPOINT')
                self.assertEqual(staff['services'][name]['environment']['ADMIN_DB_HOST'], 'YOUR-RDS-ENDPOINT')


class RdsFixtureSafetyTests(unittest.TestCase):
    def test_demo_loader_refuses_to_write_to_shared_databases(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/load-demo-data.sh')],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('disabled for RDS', result.stderr)


if __name__ == '__main__':
    unittest.main()
