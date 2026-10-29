# Preserve the existing broker version and storage format; apply vendor OS fixes.
FROM apache/kafka:4.1.2@sha256:5cc2a2fd93fa2687b44015eee04fb2c3edd9e526bd64bf8bec5ff1e268772e0e
USER root
RUN apk upgrade --no-cache
USER appuser
