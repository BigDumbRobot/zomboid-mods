FROM python:3.12-slim
RUN pip install --no-cache-dir pillow tzdata \
 && useradd --uid 1000 --create-home app \
 && mkdir /data && chown app /data
WORKDIR /app
COPY collect.py serve.py server.py alerts.py community.py livefeed.py pzscan.py dashboard.template.html ./
ENV MODSTATS_DATA=/data MODSTATS_WORKSHOP=/workshop MODSTATS_SERVER=/server MODSTATS_HOST=0.0.0.0 MODSTATS_PORT=8642 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER app
EXPOSE 8642
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8642/healthz', timeout=4)"
CMD ["python", "serve.py"]
