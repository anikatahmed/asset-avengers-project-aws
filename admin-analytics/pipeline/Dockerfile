# One image supports separate publisher, consumer and scheduler processes;
# Compose selects the CLI command and supplies only that process's DB settings.
ARG PYTHON_IMAGE=python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0
FROM ${PYTHON_IMAGE} AS build
RUN apk add --no-cache build-base librdkafka-dev \
    && python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY requirements.txt .
# Confluent does not publish a musllinux wheel for this pinned version.
# Build its binding against Alpine's maintained librdkafka, not a glibc wheel.
RUN pip install --no-cache-dir --no-binary=confluent-kafka -r requirements.txt

FROM ${PYTHON_IMAGE}
RUN apk upgrade --no-cache \
    && apk add --no-cache librdkafka tzdata ca-certificates \
    && /usr/local/bin/python -m pip uninstall --yes pip \
    && rm -rf /usr/local/lib/python3.12/ensurepip
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
RUN /opt/venv/bin/python -m pip uninstall --yes pip
COPY . .
USER 65534:65534
ENTRYPOINT ["python", "-m", "pipeline"]
