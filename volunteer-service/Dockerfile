
FROM python:3.12-alpine AS builder

WORKDIR /app

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    opentelemetry-bootstrap -a install

FROM python:3.12-alpine AS runtime

RUN addgroup -S -g 1000 app && \
    adduser -S -u 1000 -G app -H app

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY app.py consumer.py ./

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER app

EXPOSE 8083

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8083/health', timeout=2).status == 200 else 1)"

CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8083", "--workers", "2", "app:app"]
