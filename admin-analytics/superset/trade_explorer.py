"""Reusable read-only trade dataset and a separate, filterable Superset workspace.

The joins run against approved reporting views. No schema migration, financial
write, shared connection change or replacement of existing dashboards is needed.
"""
from copy import deepcopy
import json
import uuid

DATASET_NAME = 'asset_avengers_trade_explorer'
DASHBOARD_SLUG = 'asset-trade-explorer'
DATASET_UUID = uuid.uuid5(uuid.NAMESPACE_URL, 'asset-avengers/trade-explorer/dataset/v1')
DASHBOARD_UUID = uuid.uuid5(uuid.NAMESPACE_URL, 'asset-avengers/trade-explorer/dashboard/v1')
DATASET_SQL = '''SELECT
    p.batch_id, p.fill_id, p.report_date, p.client_id, p.order_id,
    p.instrument_id, p.symbol, p.security_type, p.order_side,
    p.quantity, p.price, p.cash_amount, p.executed_at,
    p.client_name, p.client_label,
    d.first_name AS client_first_name, d.last_name AS client_last_name,
    p.account_id, p.account_name, p.account_type, p.account_label,
    p.placed_at, p.order_placed_at, p.year, p.month, p.month_name,
    p.current_portfolio_class, p.current_portfolio_size_band,
    p.current_valuation_status,
    v.portfolio_value AS current_portfolio_value,
    v.cash_balance AS current_cash_balance,
    v.holdings_value AS current_holdings_value,
    v.unpriced_positions AS current_unpriced_positions,
    v.oldest_quote_at AS current_oldest_quote_at,
    'filled'::text AS trade_status
FROM analytics.named_published_trades p
LEFT JOIN reporting.client_directory d ON d.client_id = p.client_id
LEFT JOIN reporting.client_portfolios v ON v.client_id = p.client_id'''

DESCRIPTION = (
    'One row per published trade fill. Filter any included column in Explore; '
    'no SQL joins are required. First/last names and current portfolio fields '
    'describe the current reporting directory/valuation, not historical identity '
    'or portfolio snapshots. USD cash_amount is gross traded notional, not profit. '
    'Only filled trades in published report windows are included; rejected and '
    'unpublished orders are excluded. No email, bank credentials or auth data.'
)
METRICS = {
    'trade_count': ('Trade count', 'COUNT(*)'),
    'traded_notional': ('Traded amount (USD)', 'SUM(cash_amount)'),
    'active_clients': ('Distinct clients', 'COUNT(DISTINCT client_id)'),
    'active_accounts': ('Distinct accounts', 'COUNT(DISTINCT account_id)'),
    'shares_traded': ('Quantity traded (group by instrument)', 'SUM(quantity)'),
}
SELECT_FILTERS = [
    ('client_first_name', 'First name'), ('client_last_name', 'Last name'),
    ('client_label', 'Client name / ID'), ('symbol', 'Ticker'),
    ('security_type', 'Asset type'), ('order_side', 'Buy / sell'),
    ('account_label', 'Investment account'), ('account_type', 'Account type'),
    ('current_portfolio_class', 'Current portfolio class'),
    ('current_valuation_status', 'Valuation quality'),
]
COLUMN_LABELS = {
    'client_first_name': 'Client first name', 'client_last_name': 'Client last name',
    'symbol': 'Ticker', 'security_type': 'Asset type', 'order_side': 'Buy / sell',
    'cash_amount': 'Trade amount (USD)', 'price': 'Execution price (USD)',
    'quantity': 'Filled quantity', 'report_date': 'Published report date',
    'executed_at': 'Execution timestamp (UTC)', 'placed_at': 'Order timestamp (UTC)',
    'trade_status': 'Trade status (published fills only)',
    'current_portfolio_value': 'Current client portfolio value (USD)',
    'current_cash_balance': 'Current client cash balance (USD)',
    'current_holdings_value': 'Current client holdings value (USD)',
    'current_oldest_quote_at': 'Oldest current quote timestamp',
}


def explorer_filters(dataset_id):
    filters = []
    for column, label in SELECT_FILTERS:
        filters.append({
            'id': 'NATIVE_FILTER-trade-explorer-' + column,
            'name': label, 'type': 'NATIVE_FILTER', 'filterType': 'filter_select',
            'targets': [{'datasetId': dataset_id, 'column': {'name': column}}],
            'defaultDataMask': {'extraFormData': {}, 'filterState': {}, 'ownState': {}},
            'cascadeParentIds': [], 'scope': {'rootPath': ['ROOT_ID'], 'excluded': []},
            'controlValues': {'multiSelect': True, 'searchAllOptions': True,
                              'creatable': False, 'inverseSelection': False},
        })
    filters.append({
        'id': 'NATIVE_FILTER-trade-explorer-date', 'name': 'Report dates',
        'type': 'NATIVE_FILTER', 'filterType': 'filter_time', 'targets': [{}],
        'defaultDataMask': {'extraFormData': {'time_range': 'No filter'},
                            'filterState': {'value': 'No filter'}},
        'cascadeParentIds': [], 'scope': {'rootPath': ['ROOT_ID'], 'excluded': []},
        'controlValues': {},
    })
    return filters


def explorer_chart_params(dataset_id):
    base = {'datasource': f'{dataset_id}__table', 'time_range': 'No filter',
            'granularity_sqla': 'report_date', 'adhoc_filters': [], 'row_limit': 1000}
    details = {**deepcopy(base), 'viz_type': 'table', 'query_mode': 'raw',
               'all_columns': ['client_first_name', 'client_last_name', 'client_name',
                               'account_name', 'account_type', 'symbol', 'order_side',
                               'quantity', 'price', 'cash_amount', 'report_date',
                               'order_placed_at', 'order_id', 'fill_id'],
               'order_by_cols': ['["report_date", false]']}
    totals = {**deepcopy(base), 'viz_type': 'echarts_timeseries_bar',
              'x_axis': 'symbol', 'metrics': ['traded_notional'], 'groupby': [],
              'orientation': 'vertical', 'show_legend': False, 'rich_tooltip': True,
              'y_axis_format': '$,.2f', 'y_axis_title': 'Gross traded amount (USD)'}
    return [('Published trades', details), ('Traded amount by ticker', totals)]


def explorer_layout(chart_ids):
    positions = {
        'DASHBOARD_VERSION_KEY': 'v2',
        'ROOT_ID': {'id': 'ROOT_ID', 'type': 'ROOT', 'children': ['GRID_ID']},
        'GRID_ID': {'id': 'GRID_ID', 'type': 'GRID', 'children': [], 'parents': ['ROOT_ID']},
        'HEADER_ID': {'id': 'HEADER_ID', 'type': 'HEADER', 'meta': {'text': 'Trade Explorer'}},
    }
    for i, chart_id in enumerate(chart_ids):
        row = f'ROW-trade-explorer-{i}'
        chart = f'CHART-{chart_id}'
        positions['GRID_ID']['children'].append(row)
        positions[row] = {'id': row, 'type': 'ROW', 'children': [chart],
                          'parents': ['ROOT_ID', 'GRID_ID'],
                          'meta': {'background': 'BACKGROUND_TRANSPARENT'}}
        positions[chart] = {'id': chart, 'type': 'CHART', 'children': [],
                            'parents': ['ROOT_ID', 'GRID_ID', row],
                            'meta': {'chartId': chart_id, 'width': 12, 'height': 60}}
    return positions


def prepare_trade_explorer(database, owner):
    """Apply additively inside the caller's metadata transaction (Superset 6).

    Stable UUIDs prevent duplicate setup and name collisions with authored objects.
    Existing managed layouts/charts/extra metrics are left as authored on rerun.
    No commit: the caller validates and commits or rolls back the whole operation.
    """
    from superset import db, security_manager as sm
    from superset.connectors.sqla.models import SqlaTable, SqlMetric
    from superset.models.dashboard import Dashboard
    from superset.models.slice import Slice

    if database.allow_dml or database.allow_ctas or database.allow_cvas:
        raise RuntimeError('Expected the existing read-only reporting connection')
    role = sm.find_role('ReportingSqlAuthor')
    if role is None or owner is None:
        raise RuntimeError('Existing reporting author role and dataset owner are required')
    dataset = db.session.query(SqlaTable).filter_by(uuid=DATASET_UUID).one_or_none()
    if dataset is None:
        collision = db.session.query(SqlaTable).filter_by(
            database_id=database.id, schema='analytics', table_name=DATASET_NAME).first()
        if collision is not None:
            raise RuntimeError('An unrelated dataset already uses the Trade Explorer name')
        dataset = SqlaTable(database=database, schema='analytics', table_name=DATASET_NAME,
                            uuid=DATASET_UUID, sql=DATASET_SQL, owners=[owner],
                            main_dttm_col='report_date', description=DESCRIPTION)
        db.session.add(dataset)
        db.session.flush()
        dataset.fetch_metadata()
    elif dataset.sql != DATASET_SQL or dataset.database_id != database.id:
        raise RuntimeError('Trade Explorer definition changed; review rather than overwrite it')

    for column in dataset.columns:
        column.filterable = True
        column.groupby = True
        if not column.verbose_name and column.column_name in COLUMN_LABELS:
            column.verbose_name = COLUMN_LABELS[column.column_name]
    existing_metrics = {metric.metric_name: metric for metric in dataset.metrics}
    for name, (label, expression) in METRICS.items():
        if name not in existing_metrics:
            dataset.metrics.append(SqlMetric(metric_name=name, verbose_name=label,
                                              expression=expression))
    db.session.flush()
    # Existing author permissions only; do not expand the embedded guest role.
    # FAB's add_permission_* helpers commit internally. Use the existing models
    # directly so a later guard failure can roll back this entire additive setup.
    permission = db.session.query(sm.permission_model).filter_by(name='datasource_access').one()
    view = db.session.query(sm.viewmenu_model).filter_by(name=dataset.get_perm()).one_or_none()
    if view is None:
        view = sm.viewmenu_model(name=dataset.get_perm())
        db.session.add(view)
        db.session.flush()
    permission_view = sm.find_permission_view_menu('datasource_access', dataset.get_perm())
    if permission_view is None:
        permission_view = sm.permissionview_model(permission=permission, view_menu=view)
        db.session.add(permission_view)
        db.session.flush()
    if permission_view not in role.permissions:
        role.permissions.append(permission_view)

    dashboard = db.session.query(Dashboard).filter_by(uuid=DASHBOARD_UUID).one_or_none()
    if dashboard is None:
        if db.session.query(Dashboard).filter_by(slug=DASHBOARD_SLUG).first():
            raise RuntimeError('An unrelated dashboard already uses the Trade Explorer slug')
        charts = []
        for title, params in explorer_chart_params(dataset.id):
            chart = Slice(slice_name='Trade Explorer: ' + title, viz_type=params['viz_type'],
                          datasource_id=dataset.id, datasource_type='table',
                          params=json.dumps(params), owners=[owner],
                          uuid=uuid.uuid5(DATASET_UUID, title))
            db.session.add(chart)
            db.session.flush()
            charts.append(chart)
        dashboard = Dashboard(uuid=DASHBOARD_UUID, slug=DASHBOARD_SLUG,
                              dashboard_title='Trade Explorer', published=True, owners=[owner],
                              slices=charts, description=DESCRIPTION,
                              position_json=json.dumps(explorer_layout([c.id for c in charts])),
                              json_metadata=json.dumps({'native_filter_configuration': explorer_filters(dataset.id)}))
        db.session.add(dashboard)
    db.session.flush()
    return {'dataset_id': dataset.id, 'dataset_name': DATASET_NAME,
            'dashboard_id': dashboard.id,
            'dashboard_path': f'/superset/dashboard/{DASHBOARD_SLUG}/',
            'columns': len(dataset.columns), 'chart_ids': [chart.id for chart in dashboard.slices]}
