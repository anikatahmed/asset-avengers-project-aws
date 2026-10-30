"""Explicit opt-in Superset 6 integration checks; disposable localhost DBs only.

Run with the test harness described in docs/admin-analytics/trade-explorer.md.
Never point this file at RDS. It creates fixtures only in aa_explorer_test_reporting.
"""
import json
import os
import unittest
import uuid

if os.environ.get('TRADE_EXPLORER_TEST_ONLY') != '1':
    raise RuntimeError('Disposable local test harness required')

import psycopg2
from sqlalchemy import text
from superset.app import create_app
from trade_explorer import DATASET_SQL, prepare_trade_explorer

app = create_app()


def fixtures():
    with psycopg2.connect(host='127.0.0.1', dbname='aa_explorer_test_reporting', user='postgres') as c:
        with c.cursor() as cur:
            cur.execute('SELECT current_database()')
            assert cur.fetchone()[0] == 'aa_explorer_test_reporting'
            cur.execute('''CREATE SCHEMA analytics; CREATE SCHEMA reporting;
CREATE TABLE reporting.client_directory(client_id uuid PRIMARY KEY,first_name text,last_name text);
CREATE TABLE reporting.client_portfolios(client_id uuid PRIMARY KEY,portfolio_value numeric,
 cash_balance numeric,holdings_value numeric,unpriced_positions bigint,oldest_quote_at timestamptz);
CREATE TABLE analytics.named_published_trades(
 batch_id uuid,fill_id uuid PRIMARY KEY,report_date date,client_id uuid,order_id uuid,
 instrument_id uuid,symbol text,security_type text,order_side text,quantity numeric,
 price numeric,cash_amount numeric,executed_at timestamptz,client_name text,client_label text,
 account_id uuid,account_name text,account_type text,account_label text,placed_at timestamptz,
 order_placed_at text,year int,month int,month_name text,current_portfolio_class text,
 current_portfolio_size_band text,current_valuation_status text);
CREATE ROLE explorer_reader LOGIN;
GRANT CONNECT ON DATABASE aa_explorer_test_reporting TO explorer_reader;
GRANT USAGE ON SCHEMA analytics,reporting TO explorer_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics,reporting TO explorer_reader;''')
            ids = [str(uuid.UUID(int=n)) for n in range(1, 5)]
            for i, (first, last) in enumerate([('Cameron','Adams'),('Cameron','Bennett'),('Camille','Adams')]):
                cur.execute('INSERT INTO reporting.client_directory VALUES (%s,%s,%s)', (ids[i],first,last))
                cur.execute("INSERT INTO reporting.client_portfolios VALUES (%s,10000,5000,5000,0,'2026-10-01T12:00:00Z')", (ids[i],))
            for n, (client, symbol, amount) in enumerate([(0,'AAPL',200),(1,'AAPL',120),(2,'AAPL',270),(0,'MSFT',400),(3,'AAPL',80)], 1):
                cur.execute('''INSERT INTO analytics.named_published_trades
 (fill_id,client_id,symbol,cash_amount,quantity,price,report_date,executed_at,
 account_name,account_type,client_name,client_label,security_type,order_side)
 VALUES (%s,%s,%s,%s,1,%s,'2026-10-01','2026-10-01T12:00:00Z',
 'Brokerage','Individual Brokerage','Client','Client','equity','buy')''',
                            (str(uuid.UUID(int=100+n)),ids[client],symbol,amount,amount))


class TradeExplorerIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures()
        cls.context = app.app_context()
        cls.context.push()
        from superset import db, security_manager as sm
        from superset.models.core import Database
        from superset.models.dashboard import Dashboard
        from superset.models.slice import Slice
        from superset.connectors.sqla.models import SqlaTable
        cls.db, cls.sm, cls.Dashboard, cls.Slice, cls.SqlaTable = db, sm, Dashboard, Slice, SqlaTable
        cls.owner = sm.add_user('explorer-owner','Test','Owner','owner@example.com',sm.find_role('Admin'),os.environ['EXPLORER_TEST_PASSWORD'])
        author_role = sm.add_role('ReportingSqlAuthor')
        cls.author = sm.add_user('explorer-analyst','Test','Analyst','analyst@example.com',
            [sm.find_role('Alpha'),sm.find_role('sql_lab'),author_role],os.environ['EXPLORER_TEST_PASSWORD'])
        cls.database = Database(database_name='Asset Avengers analytics',expose_in_sqllab=True,
                                allow_dml=False,allow_ctas=False,allow_cvas=False)
        cls.database.set_sqlalchemy_uri('postgresql+psycopg2://explorer_reader@127.0.0.1/aa_explorer_test_reporting')
        db.session.add(cls.database);db.session.flush()
        sm.add_permission_role(author_role,sm.add_permission_view_menu('database_access',cls.database.perm))
        original = Dashboard(slug='existing-authored',dashboard_title='Existing authored dashboard',
                             owners=[cls.owner],position_json='{"custom":"keep"}',json_metadata='{"keep":true}')
        db.session.add(original);db.session.flush()
        cls.existing_id = original.id
        db.session.commit()
        # Permission helpers must not commit a partly prepared workspace.
        prepare_trade_explorer(cls.database,cls.owner)
        db.session.rollback()
        assert db.session.query(SqlaTable).count() == 0, 'Dataset escaped rollback'
        assert db.session.query(Dashboard).count() == 1, 'Dashboard escaped rollback'
        assert db.session.query(Slice).count() == 0, 'Charts escaped rollback'
        cls.result = prepare_trade_explorer(cls.database,cls.owner)
        db.session.commit()
        cls.database_id = cls.database.id
        cls.context.pop()
        cls.client = app.test_client()
        login = cls.client.post('/api/v1/security/login',json={
            'username':'explorer-analyst','password':os.environ['EXPLORER_TEST_PASSWORD'],
            'provider':'db','refresh':True})
        assert login.status_code == 200, login.status_code
        cls.headers = {'Authorization':'Bearer '+login.json['access_token']}
        csrf = cls.client.get('/api/v1/security/csrf_token/',headers=cls.headers)
        assert csrf.status_code == 200, csrf.status_code
        cls.headers['X-CSRFToken'] = csrf.json['result']

    @classmethod
    def tearDownClass(cls):
        with app.app_context():
            cls.db.session.remove()

    def test_join_preserves_fill_grain_and_exact_first_name_filter(self):
        with app.app_context():
            database = self.db.session.get(type(self.database), self.database_id)
            with database.get_sqla_engine() as engine:
                with engine.connect() as c:
                    self.assertEqual(c.execute(text('SELECT count(*) FROM ('+DATASET_SQL+') x')).scalar(),5)
                    row = c.execute(text('SELECT count(*),sum(cash_amount) FROM ('+DATASET_SQL+
                        ") x WHERE symbol='AAPL' AND client_first_name='Cameron'")).one()
                    self.assertEqual(tuple(row),(2,320))
                    self.assertEqual(c.execute(text('SELECT count(*) FROM ('+DATASET_SQL+
                        ") x WHERE client_first_name IS NULL")).scalar(),1)
                    self.assertFalse(c.execute(text("SELECT has_table_privilege(current_user,'analytics.named_published_trades','INSERT')")).scalar())

    def query(self,filters):
        payload={'datasource':{'id':self.result['dataset_id'],'type':'table'},'force':True,
                 'queries':[{'columns':[],'metrics':['trade_count','traded_notional'],
                             'filters':filters,'row_limit':100,'time_range':'No filter',
                             'granularity':'report_date','extras':{'having':'','where':''}}],
                 'result_format':'json','result_type':'full'}
        response=self.client.post('/api/v1/chart/data',json=payload,headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertNotIn('errors',response.json)
        return response.json['result'][0]['data'][0]

    def test_nonadmin_chart_api_applies_typed_name_ticker_and_numeric_filters(self):
        filters=[{'col':'client_first_name','op':'==','val':'Cameron'},
                 {'col':'symbol','op':'==','val':'AAPL'}]
        row=self.query(filters)
        self.assertEqual(row['trade_count'],2)
        self.assertEqual(row['traded_notional'],320)
        row=self.query(filters+[{'col':'cash_amount','op':'>=','val':150}])
        self.assertEqual(row['trade_count'],1)
        self.assertEqual(row['traded_notional'],200)

    def test_text_patterns_and_quoted_user_values_are_filters_not_sql(self):
        row=self.query([{'col':'client_first_name','op':'LIKE','val':'Cam%'},
                        {'col':'symbol','op':'==','val':'AAPL'}])
        self.assertEqual(row['trade_count'],3)
        self.assertEqual(row['traded_notional'],590)
        row=self.query([{'col':'client_first_name','op':'==','val':"Cameron' OR 1=1 --"}])
        self.assertEqual(row['trade_count'],0)

    def test_author_can_read_dataset_and_save_a_chart_without_sql(self):
        response=self.client.get('/api/v1/dataset/'+str(self.result['dataset_id']),headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertIn('client_first_name',[x['column_name'] for x in response.json['result']['columns']])
        response=self.client.post('/api/v1/chart/',headers=self.headers,json={
            'slice_name':'Analyst saved without SQL','viz_type':'table',
            'datasource_id':self.result['dataset_id'],'datasource_type':'table',
            'params':json.dumps({'viz_type':'table','query_mode':'aggregate',
                                'groupby':['symbol'],'metrics':['trade_count'],'time_range':'No filter'})})
        self.assertEqual(response.status_code,201)

    def test_rerun_preserves_existing_and_newly_authored_layouts_and_charts(self):
        with app.app_context():
            database = self.db.session.get(type(self.database), self.database_id)
            owner = self.sm.find_user(username='explorer-owner')
            dashboard=self.db.session.get(self.Dashboard,self.result['dashboard_id'])
            original_layout=dashboard.position_json
            metadata=json.loads(dashboard.json_metadata);metadata['analyst_note']='keep'
            dashboard.json_metadata=json.dumps(metadata)
            chart=dashboard.slices[0]
            params=json.loads(chart.params);params['row_limit']=500
            chart.params=json.dumps(params);self.db.session.commit()
            result=prepare_trade_explorer(database,owner);self.db.session.commit()
            self.assertEqual(result['dataset_id'],self.result['dataset_id'])
            self.assertEqual(result['dashboard_id'],self.result['dashboard_id'])
            self.assertEqual(dashboard.position_json,original_layout)
            self.assertEqual(json.loads(dashboard.json_metadata)['analyst_note'],'keep')
            self.assertEqual(json.loads(chart.params)['row_limit'],500)
            self.assertEqual(self.db.session.get(self.Dashboard,self.existing_id).position_json,'{"custom":"keep"}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
