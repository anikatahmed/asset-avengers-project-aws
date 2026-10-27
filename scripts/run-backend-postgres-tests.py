#!/usr/bin/env python3
"""Run backend tests against the actual SQL schema in a disposable PostgreSQL database."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('db_verifier', ROOT/'scripts/verify-db-schemas.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container', default='endgame_postgres')
    parser.add_argument('--port', type=int, default=5432)
    parser.add_argument('--java-home')
    args = parser.parse_args()
    database = 'asset_backend_verify_' + uuid.uuid4().hex[:12]
    inspection = subprocess.run(['docker','inspect','--format','{{json .Config.Env}}',args.container],
                                capture_output=True,text=True,check=True)
    configuration = dict(item.split('=',1) for item in json.loads(inspection.stdout) if '=' in item)
    verifier.psql(args.container,'postgres','CREATE DATABASE "' + database + '";')
    try:
        verifier.psql(args.container,database,(ROOT/'DB/endgame_db.schema.sql').read_text())
        env = os.environ.copy()
        env['ORDER_TEST_JDBC_USER'] = configuration['POSTGRES_USER']
        env['ORDER_TEST_JDBC_PASSWORD'] = configuration['POSTGRES_PASSWORD']
        # Multiple cached Spring test contexts otherwise allocate ten connections each.
        env['SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE'] = '4'
        env['SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE'] = '0'
        env.setdefault('JWT_SECRET','isolated-schema-test-secret-at-least-32-characters')
        if args.java_home:
            env['JAVA_HOME'] = args.java_home
        command = ['mvn','test','-q','-Dorder.test.ddl-auto=validate',
                   '-Dorder.test.jdbc-driver=org.postgresql.Driver',
                   f'-Dorder.test.jdbc-url=jdbc:postgresql://127.0.0.1:{args.port}/{database}']
        path = Path(tempfile.gettempdir()) / (database + '.log')
        with path.open('w') as log:
            result = subprocess.run(command,cwd=ROOT/'backend',env=env,stdout=log,stderr=subprocess.STDOUT)
        print('Backend PostgreSQL test log: ' + str(path))
        print('SQL schema validation and backend tests: ' + ('passed' if result.returncode == 0 else 'failed'))
        raise SystemExit(result.returncode)
    finally:
        verifier.psql(args.container,'postgres','DROP DATABASE "' + database + '" WITH (FORCE);')
