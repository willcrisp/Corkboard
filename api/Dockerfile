# The sync API image (docs/design.md §8). Build from the repo root, because it
# installs the shared merge core too:
#   docker build -f api/Dockerfile -t corkboard-api .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 CORK_DB=/data/corkboard.db
WORKDIR /app

COPY shared/python /src/shared/python
COPY api /src/api
RUN pip install --no-cache-dir /src/shared/python /src/api \
    && useradd --system --uid 10001 --home /app corkboard \
    && mkdir -p /data && chown corkboard /data

USER corkboard
VOLUME ["/data"]
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/v1/health')"
CMD ["python", "-m", "corkboard_api.app"]
