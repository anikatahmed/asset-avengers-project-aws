# Runtime Superset settings: metadata is separate from trading/reporting facts.
# Guest tokens allow the approved staff iframe; database/service credentials stay
# server-side. bootstrap.py creates the matching roles, dataset and dashboard IDs.

"""Local local deployment embedding configuration; all secrets come from the environment."""
import os
from sqlalchemy.engine import URL

SECRET_KEY = os.environ['SUPERSET_SECRET_KEY']
SQLALCHEMY_DATABASE_URI = URL.create('postgresql+psycopg2',
    username=os.environ['SUPERSET_METADATA_USER'], password=os.environ['SUPERSET_METADATA_PASSWORD'],
    host=os.getenv('SUPERSET_METADATA_HOST', 'reporting-db'), port=int(os.getenv('SUPERSET_METADATA_PORT', '5432')), database=os.environ['SUPERSET_METADATA_DB']).render_as_string(hide_password=False)
FEATURE_FLAGS = {'EMBEDDED_SUPERSET': True}
GUEST_TOKEN_JWT_SECRET = os.environ['SUPERSET_GUEST_TOKEN_SECRET']
GUEST_TOKEN_JWT_AUDIENCE = 'asset-avengers-internal'
GUEST_TOKEN_JWT_EXP_SECONDS = 300
GUEST_ROLE_NAME = 'EmbeddedAnalyst'
ENABLE_PROXY_FIX = True
# Local HTTP is intentional for the local deployment. Use HTTPS/secure cookies when hosting it.
SESSION_COOKIE_SECURE = False
WTF_CSRF_ENABLED = True
TALISMAN_ENABLED = True
TALISMAN_CONFIG = {
    'force_https': False,
    'session_cookie_secure': False,
    'frame_options': None,
    'content_security_policy': {
        'default-src': ["'self'"],
        'script-src': ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
        'style-src': ["'self'", "'unsafe-inline'"],
        'img-src': ["'self'", 'data:', 'blob:'],
        'worker-src': ["'self'", 'blob:'],
        'connect-src': ["'self'"],
        'frame-ancestors': os.environ.get('SUPERSET_EMBED_ORIGINS','http://localhost:8086,http://localhost:5174,http://localhost:8084,http://localhost:4200').split(','),
    },
}
# Short caching permits a newly published 7 PM batch to appear promptly.
DATA_CACHE_CONFIG = {'CACHE_TYPE': 'SimpleCache', 'CACHE_DEFAULT_TIMEOUT': 30}

# Register the one-use SSO handoff and validate its live auth-session lease.
from endgame_sso import configure_sso
FLASK_APP_MUTATOR = configure_sso
