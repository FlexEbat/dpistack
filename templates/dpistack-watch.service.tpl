[Unit]
Description=dpistack watchdog
# Until the installer copy exists (step selfinstall) the run is skipped,
# not failed, so the journal stays quiet.
ConditionPathExists=@@LIB_DIR@@/paths.sh
ConditionPathExists=@@CTL_BIN@@

[Service]
Type=oneshot
ExecStart=@@WATCH_BIN@@
# A oneshot service has no start timeout unless one is set. A run that hangs
# (a command that never answers) would then hold the flock, every later run of
# the timer would exit at once, and nothing would be watched or reported. A
# normal run takes a few seconds; a restart of a component it starts can take
# minutes (Suricata loading its rules).
TimeoutStartSec=600
