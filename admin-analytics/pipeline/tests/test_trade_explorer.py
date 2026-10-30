"""Superset-independent contracts for the reusable trade workspace."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('trade_explorer',
    Path(__file__).resolve().parents[2] / 'superset/trade_explorer.py')
explorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(explorer)


class TradeExplorerTest(unittest.TestCase):
    def test_dataset_joins_permitted_names_and_current_valuation_without_email(self):
        sql = explorer.DATASET_SQL
        self.assertIn('FROM analytics.named_published_trades p', sql)
        self.assertIn('LEFT JOIN reporting.client_directory', sql)
        self.assertIn('LEFT JOIN reporting.client_portfolios', sql)
        self.assertIn('d.first_name AS client_first_name', sql)
        self.assertNotIn('email', sql.lower())
        self.assertNotIn('auth.', sql.lower())
        self.assertNotIn('SELECT *', sql)
        self.assertIn("'filled'::text AS trade_status", sql)

    def test_native_filters_search_values_and_use_dataset_scopes(self):
        filters = explorer.explorer_filters(42)
        self.assertEqual(len({item['id'] for item in filters}), len(filters))
        for item in filters:
            self.assertTrue(item['id'].startswith('NATIVE_FILTER-'))
            if item['filterType'] == 'filter_select':
                self.assertEqual(item['targets'][0]['datasetId'], 42)
                self.assertTrue(item['controlValues']['searchAllOptions'])
                self.assertFalse(item['controlValues']['creatable'])
                self.assertEqual(item['defaultDataMask']['extraFormData'], {})
        first_name = next(item for item in filters if item['name'] == 'First name')
        self.assertEqual(first_name['targets'][0]['column']['name'], 'client_first_name')
        self.assertEqual(explorer.explorer_filters(43)[0]['targets'][0]['datasetId'], 43)

    def test_details_are_fill_level_and_default_filters_do_not_hide_history(self):
        charts = dict(explorer.explorer_chart_params(7))
        params = charts['Published trades']
        self.assertEqual(params['datasource'], '7__table')
        self.assertEqual(params['query_mode'], 'raw')
        self.assertEqual(params['time_range'], 'No filter')
        for column in ['client_first_name','client_last_name','symbol','fill_id','cash_amount']:
            self.assertIn(column, params['all_columns'])
        self.assertEqual(charts['Traded amount by ticker']['metrics'], ['traded_notional'])

    def test_metrics_are_trade_totals_not_portfolio_values_summed_per_fill(self):
        self.assertEqual(explorer.METRICS['traded_notional'][1], 'SUM(cash_amount)')
        self.assertEqual(explorer.METRICS['active_clients'][1], 'COUNT(DISTINCT client_id)')
        self.assertFalse(any('current_' in value[1] for value in explorer.METRICS.values()))

    def test_chart_parameters_are_fresh_and_layout_references_real_chart_ids(self):
        first = explorer.explorer_chart_params(7)
        first[0][1]['adhoc_filters'].append({'custom': 'test'})
        self.assertEqual(explorer.explorer_chart_params(7)[0][1]['adhoc_filters'], [])
        layout = explorer.explorer_layout([12, 13])
        self.assertEqual(layout['CHART-12']['meta']['chartId'], 12)
        self.assertEqual(layout['CHART-13']['parents'][-1], 'ROW-trade-explorer-1')


if __name__ == '__main__':
    unittest.main()
