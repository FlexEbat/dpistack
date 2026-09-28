# dpistack-rendered ntopng.conf. ntopng's config file is one
# command-line flag per line (confirmed against ntopng's own
# README/-h output), not YAML.
@@NTOPNG_INTERFACES@@
-w=@@NTOPNG_BIND@@
-G=@@NTOPNG_PIDFILE@@
--redis=127.0.0.1:6379
