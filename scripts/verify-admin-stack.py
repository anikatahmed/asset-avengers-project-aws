#!/usr/bin/env python3
"""Start a disposable staff stack, run end-to-end assertions, then remove only it.

Requires four prebuilt staff images (:local by default, or --image-tag for CI).
Build internal-backend directly
from its folder; it does not require the client backend (see the setup guide).
The test-runtime.Dockerfile remains an optional shortcut for a locally tested jar.
"""
import os
import argparse
import json
import secrets
import subprocess
import tempfile
import re
import time
import signal
import base64
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
project='asset-internal-verify-'+secrets.token_hex(4)
values={key:secrets.token_hex(24) for key in ['DB_PASSWORD','JWT_SECRET','ADMIN_DB_SUPERUSER_PASSWORD',
    'ADMIN_DB_PASSWORD','ETL_DB_PASSWORD','SUPERSET_SECRET_KEY','SUPERSET_GUEST_TOKEN_SECRET',
    'SUPERSET_METADATA_PASSWORD','SUPERSET_REPORTING_PASSWORD','SUPERSET_ADMIN_PASSWORD','SUPERSET_SERVICE_PASSWORD','SUPERSET_SSO_SECRET']}
values.update(DB_USERNAME='audit_test',POSTGRES_DB='audit_test',TRADING_NETWORK=project+'-trading',
    ADMIN_DB_NAME='admin_analytics',ADMIN_DB_SUPERUSER='postgres',ADMIN_DB_USERNAME='endgame_admin',
    ETL_DB_USERNAME='analytics_worker',SUPERSET_METADATA_USER='superset_metadata',SUPERSET_METADATA_DB='superset_metadata',
    SUPERSET_REPORTING_USER='superset_reader',SUPERSET_ADMIN_USER='dashboard-author',SUPERSET_SERVICE_USER='internal-api',
    SUPERSET_EMBED_ORIGINS='http://localhost:8086,http://localhost:5174,http://localhost:8084,http://localhost:4200')

def portable_test_base(text):
    """Remove only inline host ports from a temporary base, not the real stack.

    Legacy Compose merges port lists and cannot clear them with YAML reset tags.
    Fail on a new multiline layout rather than accidentally publishing live ports.
    """
    result = []
    for line in text.splitlines():
        if re.match(r"^\s+ports:", line):
            if not re.fullmatch(r"\s+ports:\s*\[.*\]\s*", line):
                raise ValueError('Expected inline port declarations in staff Compose')
            continue
        result.append(line)
    return '\n'.join(result) + '\n'


def wait_for_stack(command, project_name, timeout=300):
    """Poll healthy services and successful one-shot jobs without Compose --wait."""
    services = subprocess.check_output(command + ['config', '--services'], text=True).split()
    if not services:
        raise RuntimeError('No staff test services configured')
    deadline = time.monotonic() + timeout
    previous = None
    while True:
        pending = []
        for service in services:
            cid = subprocess.check_output(command + ['ps', '-a', '-q', service], text=True).strip()
            if not cid:
                raise RuntimeError('Missing test service: ' + service)
            data = json.loads(subprocess.check_output(['docker', 'inspect', cid], text=True))[0]
            labels = data['Config']['Labels']
            if labels.get('com.docker.compose.project') != project_name:
                raise RuntimeError('Container does not belong to this verification project')
            state = data['State']
            if service in ('kafka-init', 'superset-init'):
                if state['Status'] == 'exited' and state['ExitCode'] == 0:
                    continue
                if state['Status'] in ('exited', 'dead'):
                    raise RuntimeError('Initialization failed: ' + service)
                pending.append(service)
            elif state['Status'] != 'running':
                raise RuntimeError('Test service stopped: ' + service)
            elif state.get('Health', {}).get('Status', 'healthy') != 'healthy':
                pending.append(service)
        if not pending:
            # Running containers without Docker healthchecks still need HTTP readiness.
            cid = subprocess.check_output(command + ['ps', '-q', 'consumer'], text=True).strip()
            probe = "from urllib.request import urlopen; " + "; ".join(
                "urlopen('" + url + "', timeout=3).close()" for url in (
                    'http://internal-backend:8085/v3/api-docs',
                    'http://internal-frontend/health', 'http://superset:8088/health'))
            response = subprocess.run(['docker', 'exec', cid, 'python', '-c', probe],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            if response.returncode == 0:
                print('Staff verification stack is ready', flush=True)
                return
            pending.append('staff HTTP endpoints')
        message = ', '.join(pending)
        if message != previous:
            print('Waiting for: ' + message, flush=True)
            previous = message
        if time.monotonic() >= deadline:
            raise TimeoutError('Staff readiness timed out: ' + message)
        time.sleep(2)


def run_auth_browser(command, project_name, settings):
    """Run real browser auth in a disposable, version-matched Playwright container."""
    auth_id = subprocess.check_output(command + ['ps', '-q', 'auth-server'], text=True).strip()
    environment = dict(os.environ, TEST_LOGIN_PASSWORD=secrets.token_urlsafe(24),
                       TEST_ADMIN_EMAIL='admin-' + secrets.token_hex(6) + '@example.invalid',
                       TEST_ANALYST_EMAIL='analyst-' + secrets.token_hex(6) + '@example.invalid')
    # Only account provisioning uses SQL. Password verification and MFA enrollment
    # then use the real browser UI and unmodified auth endpoints.
    provision = """
const pg = require('pg'), bcrypt = require('bcrypt'), { randomUUID } = require('crypto');
(async () => {
  const e=process.env;
  const pool=new pg.Pool({host:e.AUTH_DB_HOST,port:Number(e.AUTH_DB_PORT),database:e.AUTH_DB_NAME,user:e.AUTH_DB_USER,password:e.AUTH_DB_PASSWORD});
  try {
    const hash=await bcrypt.hash(e.TEST_LOGIN_PASSWORD,10);
    for(const [email,role,name] of [[e.TEST_ADMIN_EMAIL,'ADMIN','Admin'],[e.TEST_ANALYST_EMAIL,'ANALYST','Analyst']]) {
      await pool.query('INSERT INTO users(id,email,password_hash,roles,first_name,last_name,mfa_required) VALUES($1,$2,$3,$4,$5,$6,true)',[randomUUID(),email,hash,[role],'Browser',name]);
    }
  } finally { await pool.end(); }
})().catch(()=>process.exit(1));
"""
    forwarded = ['--env', 'TEST_LOGIN_PASSWORD', '--env', 'TEST_ADMIN_EMAIL', '--env', 'TEST_ANALYST_EMAIL']
    subprocess.run(['docker', 'exec', *forwarded, auth_id, 'node', '--input-type=commonjs', '-e', provision], env=environment, check=True)
    lock = json.loads((ROOT / 'internal-frontend/package-lock.json').read_text())
    version = lock['packages']['node_modules/@playwright/test']['version']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Expected a pinned Playwright release')
    results = ROOT / 'internal-frontend/test-results/browser'
    results.mkdir(parents=True, exist_ok=True)
    name = project_name + '-browser'
    install_and_test = """
set -euo pipefail
mkdir -p /tmp/staff/tests
cp /workspace/internal-frontend/package.json /workspace/internal-frontend/package-lock.json /tmp/staff/
cp /workspace/internal-frontend/playwright.ci.config.ts /tmp/staff/
cp /workspace/internal-frontend/tests/auth-journey.e2e.ts /tmp/staff/tests/
cd /tmp/staff
npm ci --ignore-scripts --cache /tmp/npm-cache
npx playwright test --config playwright.ci.config.ts
"""
    print('Running real password/MFA/Superset browser authentication in Playwright', flush=True)
    try:
        subprocess.run(['docker', 'run', '--rm', '--init', '--name', name,
                        '--label', 'com.docker.compose.project=' + project_name,
                        '--label', 'com.docker.compose.service=browser-auth-test',
                        '--network', project_name + '_internal', '--shm-size', '1g',
                        '--user', f'{os.getuid()}:{os.getgid()}', '-e', 'HOME=/tmp', *forwarded,
                        '-v', str(ROOT) + ':/workspace:ro', '-v', str(results) + ':/results',
                        'mcr.microsoft.com/playwright:v' + version + '-noble',
                        'bash', '-c', install_and_test], env=environment, check=True, timeout=600)
    finally:
        # Playwright may create an unmasked accessibility snapshot on failure.
        for snapshot in results.rglob('error-context.md'):
            snapshot.unlink()
        # --rm handles normal exit. This exact name handles a timeout/interruption.
        present = subprocess.run(['docker', 'container', 'inspect', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if present.returncode == 0:
            subprocess.run(['docker', 'rm', '-f', name], check=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--browser',action='store_true',help='Run real login/MFA/SSO in a temporary Playwright container')
    parser.add_argument('--auth-image', help='Existing built auth image for the isolated browser stack')
    parser.add_argument('--image-tag', default='local', help='Use images built for this CI project; local is the developer default')
    parser.add_argument('--project-name', default=project, help='Explicit isolated project, enabling Jenkins to retry teardown')
    parser.add_argument('--ci-env-file', type=Path, help="Share this disposable CI auth stack's SSO secret")
    parser.add_argument('--log-file', type=Path, help='Save stack diagnostics at a Jenkins artifact path')
    parser.add_argument('--cleanup', action='store_true', help='Remove only the explicitly named isolated stack')
    args=parser.parse_args()
    if not re.fullmatch(r'(?:asset-internal-verify-[a-f0-9]{8}|endgame-ci-[a-f0-9]{16}-staff)', args.project_name):
        parser.error('Expected an isolated verification project name')
    if not re.fullmatch(r'(?:local|endgame-ci-[a-f0-9]{16})', args.image_tag):
        parser.error('Expected local or a CI-specific image tag')
    if args.browser and not args.auth_image:
        parser.error('--browser requires --auth-image')
    project=args.project_name
    values['TRADING_NETWORK']=project+'-trading'
    values['STAFF_IMAGE_TAG']=args.image_tag
    if args.ci_env_file:
        settings=dict(line.split('=', 1) for line in args.ci_env_file.read_text().splitlines() if '=' in line)
        values['SUPERSET_SSO_SECRET']=settings['SUPERSET_SSO_SECRET']
    if args.browser:
        values.update(TEST_AUTH_IMAGE=args.auth_image, TEST_AUTH_DB_PASSWORD=secrets.token_hex(24),
                      TEST_MFA_ENCRYPTION_KEY=base64.b64encode(secrets.token_bytes(32)).decode(),
                      SUPERSET_PUBLIC_URL='http://superset:8088')
        values['SUPERSET_EMBED_ORIGINS'] += ',http://internal-frontend'
    # SIGTERM from a Jenkins timeout must also reach the existing finally teardown.
    def terminate(*_):
        raise SystemExit(143)
    signal.signal(signal.SIGTERM, terminate)
    with tempfile.TemporaryDirectory(prefix='asset-internal-') as directory, tempfile.NamedTemporaryFile(mode='w',prefix='asset-internal-',suffix='.env') as env_file:
        env_file.write(''.join(key+'='+value+'\n' for key,value in values.items()));env_file.flush()
        base=ROOT/'deployment/admin-analytics/admin-analyst-ci.compose.yml'
        portable=Path(directory)/'staff-test-base.compose.yml'
        portable.write_text(portable_test_base(base.read_text()))
        # Preserve relative build/SQL paths despite placing the generated file in /tmp.
        command=['docker', 'compose','-p',project,'--project-directory',str(base.parent),
                 '--env-file',env_file.name,'-f',str(portable),
                 '-f',str(ROOT/'deployment/admin-analytics/admin-analyst-tests.override.yml')]
        if args.browser:
            command += ['-f', str(ROOT/'deployment/admin-analytics/admin-analyst-browser.override.yml')]
        subprocess.run(command+['config'],stdout=subprocess.DEVNULL,check=True)
        if args.cleanup:
            if args.log_file and not args.log_file.exists():
                with args.log_file.open('w') as log:
                    subprocess.run(command+['logs','--no-color','--tail','100'], stdout=log, stderr=subprocess.STDOUT)
            subprocess.run(command+['down','--volumes','--remove-orphans'],check=True)
            raise SystemExit(0)
        try:
            subprocess.run(command+['up','-d','--no-build'],check=True,timeout=600)
            wait_for_stack(command, project)
            # The test script runs on the internal network, accessing real HTTP and
            # Kafka services. Its inputs are ephemeral credentials, never live .env.
            cid=subprocess.check_output(command+['ps','-q','consumer'],text=True).strip()
            container_env=os.environ.copy()
            container_env['TEST_JWT_SECRET']=values['JWT_SECRET']
            container_env['TEST_DB_PASSWORD']=values['ADMIN_DB_SUPERUSER_PASSWORD']
            container_env['TEST_SOURCE_PASSWORD']=values['DB_PASSWORD']
            source_cid=subprocess.check_output(command+['ps','-q','source-db'],text=True).strip()
            # Seed a source order through SQL; existing Java tests separately verify
            # actual order execution against the same schema.
            seed=(ROOT/'admin-analytics/pipeline/tests/stack-seed.sql').read_text()
            subprocess.run(['docker','exec','-i',source_cid,'psql','-v','ON_ERROR_STOP=1','-U','audit_test','-d','audit_test'],input=seed,text=True,check=True)
            subprocess.run(['docker','exec','-i',cid,'python','-c',
                "import os,sys; exec(sys.stdin.read())"],input=(ROOT/'admin-analytics/pipeline/tests/stack-check.py').read_text(),
                text=True,check=True,env=container_env)
            # HTTP assertions need credentials inside the process environment.
            subprocess.run(['docker','exec','-i','--env','TEST_JWT_SECRET','--env','TEST_DB_PASSWORD',cid,'python','-'],
                input=(ROOT/'admin-analytics/pipeline/tests/http-check.py').read_text(),text=True,check=True,env=container_env)
            if args.browser:
                # Kafka/report ingestion has already been verified. Release its resources
                # before launching Chromium; browser auth needs only the served results.
                print('Stopping completed ingestion workers before browser authentication', flush=True)
                subprocess.run(command+['stop','publisher','consumer','reporting-job','kafka','source-db'],check=True)
                run_auth_browser(command, project, values)
            print('Passed: Kafka ingestion, dashboard initialization, staff API authorization and Superset guest tokens')
        except Exception:
            # Application logs omit credential values; retain them in a local log
            # for diagnosing initialization failures without dumping env/config.
            path=args.log_file or Path(tempfile.gettempdir())/(project+'.log')
            with path.open('w') as log:
                subprocess.run(command+['logs','--no-color','--tail','100'],stdout=log,stderr=subprocess.STDOUT)
            print('Verification logs: '+str(path))
            raise
        finally:
            subprocess.run(command+['down','--volumes','--remove-orphans'],check=True)
