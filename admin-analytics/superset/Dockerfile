# Bootstrap uses this pinned version's model API. Metadata migrations/dashboard
# setup run in superset-init; the web service reads the resulting configuration.
FROM apache/superset:6.0.0
USER root
# Apply available vendor OS fixes without changing the pinned Superset version.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get purge -y libc6-dev libecpg-dev libldap-dev libldap2-dev \
        libpq-dev libsasl2-dev libssl-dev linux-libc-dev \
    && rm -rf /var/lib/apt/lists/*
RUN /usr/local/bin/python -m pip install --no-cache-dir --upgrade uv==0.13.4
COPY security-requirements.txt /app/security-requirements.txt
RUN uv pip install --python /app/.venv/bin/python -r /app/security-requirements.txt \
    && uv pip check --python /app/.venv/bin/python
# Install into Superset's own virtual environment, not the system interpreter.
RUN uv pip install --python /app/.venv/bin/python psycopg2-binary==2.9.10
COPY endgame_sso.py /app/pythonpath/endgame_sso.py
COPY superset_config.py /app/pythonpath/superset_config.py
COPY bootstrap.py /app/bootstrap.py
COPY dashboard_config.py /app/dashboard_config.py
COPY init.sh /app/init-analytics.sh
USER superset
