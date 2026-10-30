"""Create the local deployment dashboards once, then register their embedded IDs for the API.

Uses the pinned Superset 6.0 model API. Managed client labels are upgraded; layouts stay intact so
teammates can edit them in Superset without a container restart undoing their work.
"""
import json
import os
import uuid
import psycopg2
from sqlalchemy.engine import URL
from superset.app import create_app
from superset import db, security_manager as sm
from dashboard_config import native_filter_id, prepared_chart_params, upgrade_native_filters, ensure_order_details


def layout(chart_ids, title):
    positions={
        'DASHBOARD_VERSION_KEY':'v2',
        'ROOT_ID':{'id':'ROOT_ID','type':'ROOT','children':['GRID_ID']},
        'GRID_ID':{'id':'GRID_ID','type':'GRID','children':[],'parents':['ROOT_ID']},
        'HEADER_ID':{'id':'HEADER_ID','type':'HEADER','meta':{'text':title}},
    }
    for index,chart_id in enumerate(chart_ids):
        row_id=f'ROW-{index}'
        chart_key=f'CHART-{chart_id}'
        positions['GRID_ID']['children'].append(row_id)
        positions[row_id]={'id':row_id,'type':'ROW','children':[chart_key],
                          'parents':['ROOT_ID','GRID_ID'],'meta':{'background':'BACKGROUND_TRANSPARENT'}}
        positions[chart_key]={'id':chart_key,'type':'CHART','children':[],
            'parents':['ROOT_ID','GRID_ID',row_id],'meta':{'chartId':chart_id,'width':12,'height':50}}
    return positions


def setup():
    # Model encryption fields require an initialized Flask application.
    from superset.models.core import Database
    from superset.models.dashboard import Dashboard
    from superset.models.slice import Slice
    from superset.models.embedded_dashboard import EmbeddedDashboard
    from superset.connectors.sqla.models import SqlaTable, SqlMetric
    admin=sm.find_user(username=os.environ['SUPERSET_ADMIN_USER'])
    if admin is None:
        admin=sm.add_user(os.environ['SUPERSET_ADMIN_USER'],'Dashboard','Author',
            'dashboard-author@example.invalid',sm.find_role('Admin'),os.environ['SUPERSET_ADMIN_PASSWORD'])
    issuer=sm.add_role('GuestTokenIssuer')
    permission=sm.find_permission_view_menu('can_grant_guest_token','SecurityRestApi')
    if permission is None:
        raise RuntimeError('Run superset init before bootstrap')
    sm.add_permission_role(issuer,permission)
    sm.add_permission_role(issuer,sm.find_permission_view_menu('can_read','SecurityRestApi'))
    if sm.find_user(username=os.environ['SUPERSET_SERVICE_USER']) is None:
        sm.add_user(os.environ['SUPERSET_SERVICE_USER'],'Internal','API','internal-api@example.invalid',
                    issuer,os.environ['SUPERSET_SERVICE_PASSWORD'])
    guest=sm.add_role('EmbeddedAnalyst')
    # Start with normal dashboard-reader actions, excluding SQL Lab and broad
    # database/data-source access. Guest tokens further restrict dashboard IDs.
    gamma=sm.find_role('Gamma')
    guest.permissions=[p for p in gamma.permissions if p.permission and p.view_menu
        and p.permission.name not in ('all_database_access','all_datasource_access','database_access','datasource_access','schema_access')
        and 'sqllab' not in p.view_menu.name.lower()]
    database=db.session.query(Database).filter_by(database_name='Asset Avengers analytics').one_or_none()
    if database is None:
        database=Database(database_name='Asset Avengers analytics')
        database.expose_in_sqllab=False
        database.allow_dml=False
        db.session.add(database)
    # Refresh saved connections when migrating local reporting data to RDS.
    database.set_sqlalchemy_uri(URL.create('postgresql+psycopg2',
        username=os.environ['SUPERSET_REPORTING_USER'],password=os.environ['SUPERSET_REPORTING_PASSWORD'],
        host=os.getenv('ADMIN_DB_HOST', 'reporting-db'),port=int(os.getenv('ADMIN_DB_PORT', '5432')),database=os.environ['ADMIN_DB_NAME']).render_as_string(hide_password=False))
    db.session.flush()
    # A separate author account can SELECT/JOIN reporting data and save its own
    # datasets/charts. Database writes are denied both here and by PostgreSQL grants.
    database.expose_in_sqllab=True
    database.allow_dml=False
    database.allow_ctas=False
    database.allow_cvas=False
    database.allow_file_upload=False
    author_role=sm.add_role('ReportingSqlAuthor')
    database_permission=sm.add_permission_view_menu('database_access',database.perm)
    sm.add_permission_role(author_role,database_permission)
    # Retire the former shared demo author; individual auth UUIDs own SSO work.
    legacy=sm.find_user(username='friday-author')
    if legacy and sm.find_role('Admin') not in legacy.roles:
        legacy.active=False
    dataset=db.session.query(SqlaTable).filter_by(database_id=database.id,schema='analytics',table_name='named_published_trades').one_or_none()
    if dataset is None:
        dataset=db.session.query(SqlaTable).filter_by(database_id=database.id,schema='analytics',table_name='published_trades').one_or_none()
    if dataset is None:
        dataset=SqlaTable(database=database,schema='analytics',table_name='published_trades',owners=[admin])
        db.session.add(dataset)
        db.session.flush()
        dataset.fetch_metadata()
        dataset.metrics=[SqlMetric(metric_name='trade_count',expression='COUNT(*)'),
                         SqlMetric(metric_name='traded_notional',expression='SUM(cash_amount)'),
                         SqlMetric(metric_name='active_clients',expression='COUNT(DISTINCT client_id)')]
        db.session.flush()
    # Reuse the existing dataset ID so authored charts and native filter scopes survive.
    dataset.table_name='named_published_trades'
    dataset.fetch_metadata()
    sm.add_permission_role(guest,sm.add_permission_view_menu('datasource_access',dataset.get_perm()))
    db.session.commit()
    dashboards=[]
    prepared_description=('Published report fills only. Gross traded notional is SUM(cash_amount) in USD, '
                          'not revenue or profit. Report dates follow the published New York report windows.')
    definitions=[('business-overview','Business overview',['report_date']),
                 ('instrument-activity','Instrument activity',['symbol','security_type','order_side']),
                 ('client-activity','Client activity',['client_name','client_id'])]
    for key,title,groups in definitions:
        dashboard=db.session.query(Dashboard).filter_by(slug='asset-'+key).one_or_none()
        if dashboard is None:
            # A prepared summary table and a notional bar chart share one approved
            # dataset, so all dashboard filters apply consistently to both.
            charts=[]
            for viz,suffix in [('table','Summary'),('echarts_timeseries_bar','Traded notional')]:
                params={'datasource':f'{dataset.id}__table','viz_type':viz,'time_range':'No filter',
                        'granularity_sqla':'report_date','row_limit':1000,'adhoc_filters':[]}
                if viz=='table':
                    params.update(query_mode='aggregate',groupby=groups,metrics=['trade_count','traded_notional'],order_desc=True)
                else:
                    params.update(x_axis=groups[0],metrics=['traded_notional'],groupby=[],
                                  orientation='vertical',show_legend=False,rich_tooltip=True)
                params=prepared_chart_params(params,key,viz)
                chart=Slice(slice_name=f'{title}: {suffix}',viz_type=viz,datasource_id=dataset.id,
                            datasource_type='table',params=json.dumps(params),owners=[admin])
                db.session.add(chart);db.session.flush();charts.append(chart)
            filters=[]
            for column,label in [('symbol','Instrument'),('security_type','Asset type'),('order_side','Side'),('client_id','Client')]:
                filters.append({'id':native_filter_id(column),'name':label,'type':'NATIVE_FILTER','filterType':'filter_select',
                    'targets':[{'datasetId':dataset.id,'column':{'name':column}}],
                    'defaultDataMask':{'extraFormData':{},'filterState':{},'ownState':{}},
                    'cascadeParentIds':[],'scope':{'rootPath':['ROOT_ID'],'excluded':[]},
                    'controlValues':{'multiSelect':True,'searchAllOptions':True,'inverseSelection':False}})
            filters.append({'id':native_filter_id('date'),'name':'Report dates','type':'NATIVE_FILTER','filterType':'filter_time','targets':[{}],
                'defaultDataMask':{'extraFormData':{'time_range':'No filter'},'filterState':{'value':'No filter'}},
                'cascadeParentIds':[],'scope':{'rootPath':['ROOT_ID'],'excluded':[]},'controlValues':{}})
            dashboard=Dashboard(slug='asset-'+key,dashboard_title=title,published=True,owners=[admin],
                slices=charts,position_json=json.dumps(layout([c.id for c in charts],title)),
                json_metadata=json.dumps({'native_filter_configuration':filters}),
                description=prepared_description)
            db.session.add(dashboard);db.session.flush()
        if dashboard.description=='Same-day simulated trades, midnight to 7 PM America/New_York. Exact recorded cash amounts.':
            dashboard.description=prepared_description
        # Existing metadata survives restarts: repair our prepared charts in place,
        # including Business overview, rather than only fixing new installations.
        # Leave independent analyst-authored charts and all dashboard layouts intact.
        for chart in dashboard.slices:
            if (chart.slice_name not in (title+': Summary',title+': Traded notional')
                    or chart.datasource_id != dataset.id
                    or chart.viz_type not in ('table','echarts_timeseries_bar')):
                continue
            params=json.loads(chart.params or '{}')
            repaired=prepared_chart_params(params,key,chart.viz_type)
            if repaired != params:
                chart.params=json.dumps(repaired)
                chart.query_context=None  # Rebuild queries from repaired form data.
        ensure_order_details(dashboard, dataset.id, db.session, Slice, admin)
        metadata=upgrade_native_filters(json.loads(dashboard.json_metadata or '{}'))
        for item in metadata.get('native_filter_configuration',[]):
            if item.get('id')==native_filter_id('date') and item.get('name')=='Dates':
                item['name']='Report dates'
            if item.get('id')==native_filter_id('security_type') and item.get('name')=='Class':
                item['name']='Asset type'
            for target in item.get('targets',[]):
                if target.get('column',{}).get('name')=='client_id':
                    target['column']['name']='client_label'
                    item['name']='Client name / ID'
                    item['defaultDataMask']={'extraFormData':{},'filterState':{},'ownState':{}}
        # Add current portfolio classification once, preserving teammate-authored filters.
        filters=metadata.setdefault('native_filter_configuration',[])
        existing={item['id'] for item in filters}
        for column,label in [('year','Order year'), ('month','Order month (1–12)'), ('month_name','Order month name'),
                             ('current_portfolio_class','Current portfolio class'),
                             ('current_portfolio_size_band','Current portfolio size'),
                             ('current_valuation_status','Valuation quality'),
                             ('account_type','Investment account type'),
                             ('account_label','Investment account')]:
            if native_filter_id(column) not in existing:
                filters.append({'id':native_filter_id(column),'name':label,'type':'NATIVE_FILTER','filterType':'filter_select',
                    'targets':[{'datasetId':dataset.id,'column':{'name':column}}],
                    'defaultDataMask':{'extraFormData':{},'filterState':{},'ownState':{}},
                    'cascadeParentIds':[],'scope':{'rootPath':['ROOT_ID'],'excluded':[]},
                    'controlValues':{'multiSelect':True,'searchAllOptions':True,'inverseSelection':False}})
        dashboard.json_metadata=json.dumps(metadata)
        embedded=db.session.query(EmbeddedDashboard).filter_by(dashboard_id=dashboard.id).one_or_none()
        if embedded is None:
            embedded=EmbeddedDashboard(uuid=uuid.uuid4(),dashboard_id=dashboard.id,
                allow_domain_list=os.environ['SUPERSET_EMBED_ORIGINS'])
            db.session.add(embedded)
        # Origin configuration can change when adding the separate test UI.
        # Update the allowlist on rerun while preserving authored chart layouts.
        embedded.allow_domain_list=os.environ['SUPERSET_EMBED_ORIGINS']
        dashboards.append((key,title,str(embedded.uuid)))
    from trade_explorer import prepare_trade_explorer
    prepare_trade_explorer(database, admin)
    db.session.commit()
    # Only this initialization job has registry-write credentials. Running Superset
    # itself receives a reporting login restricted to SELECT on approved views.
    with psycopg2.connect(host=os.getenv('ADMIN_DB_HOST', 'reporting-db'),port=int(os.getenv('ADMIN_DB_PORT', '5432')),dbname=os.environ['ADMIN_DB_NAME'],
        user=os.environ['ADMIN_DB_SUPERUSER'],password=os.environ['ADMIN_DB_SUPERUSER_PASSWORD']) as connection:
        with connection.cursor() as cur:
            cur.executemany('''INSERT INTO integration.dashboard_registry VALUES (%s,%s,%s)
                ON CONFLICT(dashboard_key) DO UPDATE SET title=EXCLUDED.title,embedded_id=EXCLUDED.embedded_id''',dashboards)
    print('Three dashboards configured and registered for the internal API')


if __name__=='__main__':
    app=create_app()
    with app.app_context():
        setup()
