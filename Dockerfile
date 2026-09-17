FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY apple_fm_audit /app/apple_fm_audit
COPY static /app/static
ENV AFM_LISTEN_HOST=0.0.0.0
ENV AFM_LISTEN_PORT=1977
ENV AFM_UPSTREAM=host.docker.internal:1976
ENV AFM_DB=/data/audit.sqlite
EXPOSE 1977
VOLUME ["/data"]
CMD ["python3", "-m", "apple_fm_audit"]
