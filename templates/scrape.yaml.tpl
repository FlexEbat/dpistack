# Managed by dpistack: install and reconfigure overwrite this file.
# One job: GET /metrics of the dpistack panel. The bearer token is read
# from a file, it is not written here. The same file serves Prometheus and
# VictoriaMetrics (-promscrape.config).
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: dpistack
    metrics_path: /metrics
    scheme: http
    authorization:
      type: Bearer
      credentials_file: @@TOKEN_FILE@@
    static_configs:
      - targets: ['@@TARGET@@']
