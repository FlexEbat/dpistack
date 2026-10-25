# Managed by dpistack: the metrics backend as the default data source.
apiVersion: 1
datasources:
  - name: dpistack
    type: prometheus
    access: proxy
    url: http://@@URL@@
    isDefault: true
