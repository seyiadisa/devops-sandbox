FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    API_PORT=8000 \
    VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH"

RUN apt-get update \
    && apt-get install --no-install-recommends -y bash ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install --no-install-recommends -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/* \
    && python -m venv "$VIRTUAL_ENV" \
    && groupadd --system --gid 10001 appgroup \
    && useradd --system --uid 10001 --gid appgroup --create-home --home-dir /home/appuser appuser \
    && mkdir -p /app /app/platform /app/envs /app/logs /app/nginx \
    && chown -R appuser:appgroup /app /home/appuser

WORKDIR /app

COPY platform/requirements.txt /tmp/requirements.txt
RUN pip install --upgrade pip \
    && pip install -r /tmp/requirements.txt

COPY --chown=appuser:appgroup platform /app/platform

USER appuser

EXPOSE 8000

WORKDIR /app/platform

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${API_PORT}"]
