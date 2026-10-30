#!/usr/bin/env python3
"""Run Superset Trade Explorer integration checks in isolated local containers."""
import argparse
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', default='asset-analytics-superset:local',
                        help='Existing Superset 6 image; build admin-analytics/superset first')
    args = parser.parse_args()
    subprocess.run(['docker','image','inspect',args.image],check=True,stdout=subprocess.DEVNULL)
    name = 'aa-trade-explorer-test-' + secrets.token_hex(6)
    runner = name + '-runner'
    work = Path(tempfile.mkdtemp(prefix=name+'-'))
    os.chmod(work,0o700)
    env = {'SUPERSET_SECRET_KEY':secrets.token_hex(32),
           'SUPERSET_CONFIG_PATH':'/tests/config.py','FLASK_APP':'superset',
           'TRADE_EXPLORER_TEST_ONLY':'1','EXPLORER_TEST_PASSWORD':secrets.token_urlsafe(24),
           'SUPERSET_LOAD_EXAMPLES':'no','PYTHONPATH':'/workspace'}
    envfile = work/'test.env'
    envfile.write_text(''.join(k+'='+v+'\n' for k,v in env.items()))
    os.chmod(envfile,0o600)
    (work/'config.py').write_text("""import os
SECRET_KEY=os.environ['SUPERSET_SECRET_KEY']
SQLALCHEMY_DATABASE_URI='postgresql+psycopg2://postgres@127.0.0.1/aa_explorer_test_metadata'
WTF_CSRF_ENABLED=True
TALISMAN_ENABLED=False
PREVENT_UNSAFE_DB_CONNECTIONS=False
DATA_CACHE_CONFIG={'CACHE_TYPE':'SimpleCache','CACHE_DEFAULT_TIMEOUT':30}
""")
    started = False
    try:
        subprocess.run(['docker','run','-d','--rm','--name',name,'--network','none',
                        '--label','project=asset-avengers-test',
                        '-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:18.6-trixie'],
                       check=True,stdout=subprocess.DEVNULL)
        started = True
        for attempt in range(60):
            if subprocess.run(['docker','exec',name,'pg_isready','-U','postgres'],
                              stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError('Disposable PostgreSQL did not become ready')
        for database in ['aa_explorer_test_metadata','aa_explorer_test_reporting']:
            subprocess.run(['docker','exec',name,'createdb','-U','postgres',database],check=True)
        command = ('/app/.venv/bin/superset db upgrade > /tests/migrate.log 2>&1 && '
                   '/app/.venv/bin/superset init > /tests/init.log 2>&1 && '
                   '/app/.venv/bin/python /workspace/tests/test_trade_explorer_integration.py '
                   '> /tests/integration.log 2>&1')
        subprocess.run(['docker','run','--rm','--name',runner,'--network','container:'+name,
                        '--env-file',str(envfile),
                        '-v',str(ROOT/'admin-analytics/superset')+':/workspace:ro',
                        '-v',str(work)+':/tests','--entrypoint','bash',args.image,'-c',command],
                       check=True,timeout=600)
        print('Trade Explorer Superset integration checks passed. Reports: '+str(work))
    finally:
        # Only containers created by this invocation; no pruning, AWS calls or .env reads.
        subprocess.run(['docker','stop',runner],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if started:
            subprocess.run(['docker','stop',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        envfile.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
