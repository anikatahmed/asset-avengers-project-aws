#!/usr/bin/env python3
"""Verify real PDF API responses in a disposable reporting DB; no live data writes."""
import argparse
import xml.etree.ElementTree as ET
import base64
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('db_verifier', ROOT/'scripts/verify-db-schemas.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--classes',action='store_true',help='Use the last Maven test runtime instead of a packaged jar')
    args=parser.parse_args()
    container = 'endgame_postgres'
    configuration = json.loads(subprocess.check_output(['docker','inspect','--format','{{json .Config.Env}}',container],text=True))
    configuration = dict(item.split('=',1) for item in configuration if '=' in item)
    jar = ROOT/'internal-backend/target/internal-backend-0.0.1-SNAPSHOT.jar'
    launch=['-jar',str(jar)]
    if args.classes:
        report=ROOT/'internal-backend/target/surefire-reports/TEST-com.avengers.internal.InternalSecurityTest.xml'
        properties=ET.parse(report).getroot().find('properties')
        classpath=next(p.attrib['value'] for p in properties if p.attrib['name']=='java.class.path')
        classpath=os.pathsep.join(entry for entry in classpath.split(os.pathsep) if not entry.endswith('/test-classes'))
        launch=['-cp',classpath,'com.avengers.internal.InternalApplication']
    elif not jar.exists(): raise SystemExit('Build internal-backend with mvn package first, or run tests and use --classes.')
    database = 'asset_pdf_verify_'+uuid.uuid4().hex[:12]
    secret = secrets.token_hex(32)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
    verifier.psql(container,'postgres','CREATE DATABASE "'+database+'";')
    process = None
    logpath = Path(tempfile.gettempdir())/(database+'.log')
    try:
        verifier.psql(container,database,(ROOT/'DB/admin_analytics_db.schema.sql').read_text())
        verifier.psql(container,database,"""
            INSERT INTO integration.report_batches(batch_id,report_date,period_start,cutoff_at,status,completed_at)
            VALUES ('00000000-0000-0000-0000-000000000001','2026-10-01','2026-10-01T04:00:00Z','2026-10-01T23:00:00Z','published',now());
            INSERT INTO integration.published_reports VALUES ('2026-10-01','00000000-0000-0000-0000-000000000001');
            INSERT INTO admin_audit_log(actor_id,action,target_order_id,metadata,occurred_at)
            VALUES ('00000000-0000-0000-0000-000000000009','view_trade','00000000-0000-0000-0000-000000000002',
                '{"note":"Recorded audit metadata"}','2026-10-01T12:00:00Z');
            """)
        env=os.environ.copy()
        env.update(ADMIN_DB_URL=f'jdbc:postgresql://127.0.0.1:5432/{database}?options=-c%20role%3Danalytics_admin',
                   ADMIN_DB_USERNAME=configuration['POSTGRES_USER'],ADMIN_DB_PASSWORD=configuration['POSTGRES_PASSWORD'],
                   JWT_SECRET=secret,JWT_ISSUER='endgame-auth',STAFF_JWT_AUDIENCE='endgame-staff',SERVER_PORT=str(port))
        java=Path('/Library/Java/JavaVirtualMachines/openjdk-25.jdk/Contents/Home/bin/java')
        with logpath.open('w') as log:
            process=subprocess.Popen([str(java) if java.exists() else 'java']+launch,env=env,stdout=log,stderr=subprocess.STDOUT)
            def token(role):
                enc=lambda value:base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b'=')
                body=b'.'.join([enc({'alg':'HS256','typ':'JWT'}),enc({'sub':'00000000-0000-0000-0000-000000000009',
                    'email':'staff@example.invalid','roles':[role],'iss':'endgame-auth',
                    'aud':['endgame-api','endgame-auth','endgame-staff'],'amr':['pwd','mfa'],
                    'iat':int(time.time()),'exp':int(time.time())+300})])
                return (body+b'.'+base64.urlsafe_b64encode(hmac.new(secret.encode(),body,hashlib.sha256).digest()).rstrip(b'=')).decode()
            def request(path,role):
                try:
                    with urlopen(Request(f'http://127.0.0.1:{port}'+path,headers={'Authorization':'Bearer '+token(role)}),timeout=10) as response:
                        return response.status,response.headers,response.read()
                except HTTPError as error:return error.code,error.headers,error.read()
            for attempt in range(60):
                try:
                    if request('/api/v1/analytics/status','ANALYST')[0]==200:break
                except (URLError,TimeoutError):pass
                if process.poll() is not None:raise RuntimeError('Staff API startup failed; see '+str(logpath))
                time.sleep(1)
            else:raise RuntimeError('Staff API did not become ready; see '+str(logpath))
            for path,role in [('/api/v1/analytics/reports/2026-10-01/pdf','ANALYST'),
                              ('/api/v1/analytics/reports/2026-10-01/pdf','ADMIN'),
                              ('/api/v1/admin/audit-log/pdf?from=2026-10-01&to=2026-10-01','ADMIN')]:
                status,headers,body=request(path,role)
                assert status==200,(path,status)
                assert headers['Content-Type']=='application/pdf'
                assert headers['Cache-Control']=='no-store'
                assert 'attachment' in headers['Content-Disposition'] and body.startswith(b'%PDF-')
            assert request('/api/v1/analytics/reports/2026-10-02/pdf','ANALYST')[0]==404
            assert request('/api/v1/analytics/reports/2026-10-01/pdf','CLIENT')[0]==403
            assert request('/api/v1/admin/audit-log/pdf?from=2026-10-01&to=2026-10-01','ANALYST')[0]==403
            print('Passed: real PostgreSQL published-report/audit PDFs, metadata, download headers and JWT role checks.')
    finally:
        if process:
            process.terminate()
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        verifier.psql(container,'postgres','DROP DATABASE "'+database+'" WITH (FORCE);')
