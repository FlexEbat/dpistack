# dpistack-rendered ntopng.conf. ntopng's config file is one
# command-line flag per line (confirmed against ntopng's own
# README/-h output), not YAML.
%%DPISTACK_NTOPNG_INTERFACES%%
-w=%%DPISTACK_NTOPNG_BIND%%
-G=%%DPISTACK_NTOPNG_PIDFILE%%
--redis=127.0.0.1:6379
