[Unit]
Description=dpistack watchdog
# Until the installer copy exists (step selfinstall) the run is skipped,
# not failed, so the journal stays quiet.
ConditionPathExists=@@LIB_DIR@@/paths.sh
ConditionPathExists=@@CTL_BIN@@

[Service]
Type=oneshot
ExecStart=@@WATCH_BIN@@
