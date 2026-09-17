FROM python:3.12-slim-bookworm
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-dev
COPY apple_fm_audit /app/apple_fm_audit
COPY static /app/static
ENV PYTHONPATH=/app
ENV AFM_LISTEN_HOST=0.0.0.0
ENV AFM_LISTEN_PORT=1977
ENV AFM_UPSTREAM=host.docker.internal:1976
ENV AFM_DB=/data/audit.sqlite
EXPOSE 1977
VOLUME ["/data"]
CMD ["uv", "run", "--no-dev", "python", "-m", "apple_fm_audit"]
