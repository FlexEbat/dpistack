#!/usr/bin/env bash
# suricata-build-check.sh <suricata-X.Y.Z> - builds that Suricata release
# with the installer itself (nDPI step and Suricata step, the same code
# path a user runs) and checks the result: the version, the nDPI plugin in
# the place suricata.yaml expects it, and that the rendered configuration
# loads. It changes the machine, so it is for CI runners and test hosts.
set -euo pipefail

tag="${1:-}"
if [[ ! "$tag" =~ ^suricata-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "usage: $0 suricata-X.Y.Z" >&2
	exit 2
fi
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
as_root=()
[[ "${EUID:-$(id -u)}" -eq 0 ]] || as_root=(sudo -E)

"${as_root[@]}" bash "$repo_dir/install.sh" install -y --no-color --only ndpi,suricata \
	--set "SURICATA_VERSION=$tag" --set TEST_ON_INSTALL=no

want="${tag#suricata-}"
got="$("${as_root[@]}" /usr/local/bin/suricata -V | sed -n 's/^This is Suricata version \([^ ]*\).*/\1/p')"
if [[ "$got" != "$want" ]]; then
	echo "built Suricata $got, wanted $want" >&2
	exit 1
fi
"${as_root[@]}" /usr/local/bin/suricata --build-info | grep -Eq '^ *nDPI: +yes' || {
	echo "the build has no nDPI support" >&2
	exit 1
}
[[ -f /usr/lib/suricata/ndpi.so ]] || {
	echo "the nDPI plugin is not in /usr/lib/suricata" >&2
	exit 1
}
# -S: only an empty rule file, the check is about the binary, the plugin
# and the rendered suricata.yaml, not about a ruleset download.
"${as_root[@]}" /usr/local/bin/suricata -T -c /etc/suricata/suricata.yaml -S /dev/null
echo "ok: $tag builds with nDPI and loads the installer's configuration"
