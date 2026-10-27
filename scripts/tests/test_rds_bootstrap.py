"""RDS bootstrap configuration and opt-in disposable PostgreSQL integration checks."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / 'deployment/rds/create-databases.sql'


def settings():
    return dict(SOURCE_DB_HOST='test.example.rds.amazonaws.com', RDS_ADMIN_USER='postgres',
                RDS_ADMIN_PASSWORD='fixture-admin-password', POSTGRES_DB='Endgame_Trading',
                DB_USERNAME='trading-app', DB_PASSWORD="fixture'quoted$password",
                AUTH_DB_NAME='auth', AUTH_DB_USER='auth', AUTH_DB_PASSWORD='fixture-auth',
                ADMIN_DB_NAME='admin_analytics', ADMIN_DB_SUPERUSER='reporting_owner',
                ADMIN_DB_SUPERUSER_PASSWORD='fixture-owner', ADMIN_DB_USERNAME='endgame_admin',
                ADMIN_DB_PASSWORD='fixture-api', ETL_DB_USERNAME='analytics_worker',
                ETL_DB_PASSWORD='fixture-etl', SUPERSET_REPORTING_USER='superset_reader',
                SUPERSET_REPORTING_PASSWORD='fixture-reader', SUPERSET_METADATA_DB='superset_metadata',
                SUPERSET_METADATA_USER='superset_metadata', SUPERSET_METADATA_PASSWORD='fixture-metadata')


class BootstrapConfigTests(unittest.TestCase):
    def test_compose_passes_credentials_without_executing_dotenv(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture = Path(folder) / '.env'
            fixture.write_text("UNRELATED='$(do-not-execute)'\n")
            result = subprocess.run(['docker', 'compose', '--env-file', str(fixture),
                                     '-f', str(ROOT / 'deployment/rds/bootstrap.compose.yml'),
                                     'config', '--format', 'json'],
                                    env={**os.environ, **settings()}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads(result.stdout)['services']['bootstrap']
            self.assertEqual(config['environment']['PGHOST'], settings()['SOURCE_DB_HOST'])
            # Compose escapes dollar signs when serializing reusable configuration.
            self.assertEqual(config['environment']['DB_PASSWORD'].replace('$$', '$'), settings()['DB_PASSWORD'])
            self.assertNotIn('UNRELATED', config['environment'])
            self.assertIn('exec psql', config['entrypoint'][-1])

    def test_help_needs_no_database_connection(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/create-rds-databases.sh'), '--help'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('Does not load schemas', result.stdout)


@unittest.skipUnless(os.getenv('RDS_BOOTSTRAP_DOCKER_TEST') == '1', 'Opt-in local Docker test')
class BootstrapDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.name = 'rds-bootstrap-test-' + secrets.token_hex(6)
        subprocess.run(['docker', 'run', '-d', '--name', self.name,
                        '--tmpfs', '/var/lib/postgresql', '-e', 'POSTGRES_PASSWORD=fixture-only',
                        'postgres:18.6-trixie'], check=True, capture_output=True)
        self.addCleanup(subprocess.run, ['docker', 'rm', '-f', self.name], capture_output=True)
        for _ in range(60):
            result = subprocess.run(['docker', 'exec', self.name, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'],
                                    capture_output=True)
            if result.returncode == 0:
                break
            time.sleep(0.5)
        else:
            self.fail('Disposable PostgreSQL did not become ready')

    def psql(self, sql):
        return subprocess.run(['docker', 'exec', '-i', self.name, 'psql', '-X', '-q', '-At',
                               '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-d', 'postgres'],
                              input=sql, capture_output=True, text=True, check=True).stdout

    def bootstrap(self, overrides=None):
        args = ['docker', 'exec', '-i']
        for key, value in {**settings(), **(overrides or {})}.items():
            args += ['-e', key + '=' + value]
        return subprocess.run(args + [self.name, 'psql', '-X', '-q', '-U', 'postgres',
                                       '-v', 'ON_ERROR_STOP=1', '-d', 'postgres'],
                              input=SQL.read_text(), capture_output=True, text=True)

    def test_create_and_rerun_preserves_data_and_passwords(self):
        result = self.bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        for secret in [settings()['DB_PASSWORD'], settings()['AUTH_DB_PASSWORD']]:
            self.assertNotIn(secret, result.stdout + result.stderr)
        owners = self.psql("SELECT datname || ':' || pg_get_userbyid(datdba) FROM pg_database WHERE datname IN ('Endgame_Trading','auth','admin_analytics','superset_metadata') ORDER BY datname;")
        self.assertEqual(owners.splitlines(), ['Endgame_Trading:trading-app', 'admin_analytics:reporting_owner',
                                             'auth:auth', 'superset_metadata:superset_metadata'])
        before = self.psql("SELECT rolpassword FROM pg_authid WHERE rolname='trading-app';")
        self.psql('CREATE TABLE preserved_data (value int); INSERT INTO preserved_data VALUES (42);')
        result = self.bootstrap({'DB_PASSWORD': 'different-fixture'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, self.psql("SELECT rolpassword FROM pg_authid WHERE rolname='trading-app';"))
        self.assertEqual(self.psql('SELECT value FROM preserved_data;').strip(), '42')
        self.assertEqual(self.psql("SELECT pg_has_role('endgame_admin','analytics_admin','MEMBER');").strip(), 't')

    def test_owner_conflict_fails_before_creating_service_roles(self):
        self.psql('CREATE DATABASE auth;')
        result = self.bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('different owner', result.stderr)
        self.assertEqual(self.psql("SELECT count(*) FROM pg_roles WHERE rolname='trading-app';").strip(), '0')

    def test_duplicate_service_logins_fail_before_mutation(self):
        result = self.bootstrap({'AUTH_DB_USER': 'trading-app'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('distinct service logins', result.stderr)
        self.assertEqual(self.psql("SELECT count(*) FROM pg_roles WHERE rolname='trading-app';").strip(), '0')


if __name__ == '__main__':
    unittest.main()
