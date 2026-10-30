"""One-shot additive metadata maintenance; never a web-service startup command."""
import json
from superset.app import create_app


def prepare():
    from superset import db
    from superset.models.core import Database
    from superset.connectors.sqla.models import SqlaTable
    from trade_explorer import prepare_trade_explorer
    database = db.session.query(Database).filter_by(database_name='Asset Avengers analytics').one()
    baseline = db.session.query(SqlaTable).filter_by(database_id=database.id,
        schema='analytics', table_name='named_published_trades').one()
    if not baseline.owners:
        raise RuntimeError('The existing reporting dataset must have an owner')
    try:
        result = prepare_trade_explorer(database, baseline.owners[0])
        db.session.commit()
    except Exception:
        db.session.rollback()
        raise
    print(json.dumps(result))
    return result


if __name__ == '__main__':
    app = create_app()
    with app.app_context():
        prepare()
