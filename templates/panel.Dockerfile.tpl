# Managed by dpistack: the image of the panel. The base image supplies nsenter
# (busybox), which is how the panel reaches dpistack on the host.
FROM @@PANEL_BASE_IMAGE@@
COPY dpistack-panel /usr/local/bin/dpistack-panel
ENTRYPOINT ["/usr/local/bin/dpistack-panel"]
