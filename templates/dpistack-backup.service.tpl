[Unit]
Description=dpistack scheduled backup of the configuration
# Skipped, not failed, until the installer copy exists.
ConditionPathExists=@@LIB_DIR@@/paths.sh
ConditionPathExists=@@CTL_BIN@@

[Service]
Type=oneshot
ExecStart=@@CTL_BIN@@ backup run
TimeoutStartSec=300
