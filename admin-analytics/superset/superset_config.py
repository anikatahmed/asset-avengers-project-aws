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
# Keep optional server-side screenshot/image-processing jobs disabled while
# upstream Pillow fixes remain outside the supported Superset dependency range.
FEATURE_FLAGS = {
    'EMBEDDED_SUPERSET': True,
    'THUMBNAILS': False,
    'ALERT_REPORTS': False,
    'PLAYWRIGHT_REPORTS_AND_THUMBNAILS': False,
}
PREVENT_UNSAFE_DB_CONNECTIONS = True
GUEST_TOKEN_JWT_SECRET = os.environ['SUPERSET_GUEST_TOKEN_SECRET']
GUEST_TOKEN_JWT_AUDIENCE = 'asset-avengers-internal'
GUEST_TOKEN_JWT_EXP_SECONDS = 300
GUEST_ROLE_NAME = 'EmbeddedAnalyst'
ENABLE_PROXY_FIX = True
# Local HTTP stays supported; hosted deployments enable secure cookies behind HTTPS.
SESSION_COOKIE_SECURE = os.environ.get('SUPERSET_COOKIE_SECURE', 'false').lower() == 'true'
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'
WTF_CSRF_ENABLED = True
TALISMAN_ENABLED = True
TALISMAN_CONFIG = {
    'force_https': False,
    'session_cookie_secure': SESSION_COOKIE_SECURE,
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
