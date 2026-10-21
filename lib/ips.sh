#!/usr/bin/env bash
# IPS mode (slice 29): the DPISTACK chain and its jumps. Shared by
# dpistack-ctl (mode, fw) and the installer (uninstall).
#
# The installer never flushes, deletes or reorders a chain that is not its
# own. What it does add to the standard chains is one rule each, the jump
# "-j DPISTACK" at position 1 (IPS_NFQ_CHAINS says which chains); the
# chain DPISTACK holds one NFQUEUE rule with --queue-bypass, so a stopped
# Suricata lets traffic through instead of cutting the network.

IPS_CHAIN="DPISTACK"
IPS_QUEUE_NUM=0
IPS_ALL_CHAINS=(INPUT OUTPUT FORWARD)

# ips_tools - the iptables front ends that exist (v4 and v6 if there).
ips_tools() {
	command -v iptables >/dev/null 2>&1 && echo iptables
	command -v ip6tables >/dev/null 2>&1 && echo ip6tables
	return 0
}

# ips_backend - which firewall front end carries the queue rules: iptables
# where it exists (also iptables-nft), nft on a system that has only nft
# (a minimal Rocky/Alma, say). Prints nothing when there is neither.
# nft keeps its own table "inet dpistack" (v4 and v6 in one), so the rules of
# the host stay untouched there too.
ips_backend() {
	if command -v iptables >/dev/null 2>&1; then
		echo iptables
	elif command -v nft >/dev/null 2>&1; then
		echo nft
	fi
	return 0
}

IPS_NFT_TABLE="dpistack"

# ips_nft_hook <chain> - the nft hook of an iptables chain name.
ips_nft_hook() {
	case "$1" in
	INPUT) echo input ;;
	OUTPUT) echo output ;;
	FORWARD) echo forward ;;
	esac
}

# ips_nft_ruleset <chains> - the table as one nft script. "add" and "delete"
# first make the rebuild atomic and repeatable whether or not it existed.
ips_nft_ruleset() {
	local chain hook
	echo "add table inet $IPS_NFT_TABLE"
	echo "delete table inet $IPS_NFT_TABLE"
	echo "table inet $IPS_NFT_TABLE {"
	for chain in $(ips_nfq_chains "$1"); do
		hook=$(ips_nft_hook "$chain")
		[[ -n "$hook" ]] || continue
		echo "	chain $hook {"
		echo "		type filter hook $hook priority -10; policy accept;"
		echo "		queue num $IPS_QUEUE_NUM bypass"
		echo "	}"
	done
	echo "}"
}

# ips_nfq_chains - the chains that get the jump, from IPS_NFQ_CHAINS.
ips_nfq_chains() {
	local list="${1:-INPUT,OUTPUT,FORWARD}" c
	local IFS=,
	for c in $list; do
		[[ -n "$c" ]] && echo "$c"
	done
	return 0
}

# ips_fw_apply <chains> - create and fill DPISTACK, put the jumps in.
# Repeatable: the chain is rebuilt, a jump is added only if missing.
ips_fw_apply() {
	local chains="$1" tool chain
	if [[ "$(ips_backend)" == "nft" ]]; then
		ips_nft_ruleset "$chains" | nft -f - || return 1
		return 0
	fi
	# iptables carries the rules: a table left by an earlier nft run must go,
	# or every packet would be queued twice.
	ips_nft_remove
	for tool in $(ips_tools); do
		"$tool" -w -N "$IPS_CHAIN" 2>/dev/null || true
		"$tool" -w -F "$IPS_CHAIN" || return 1
		"$tool" -w -A "$IPS_CHAIN" -j NFQUEUE --queue-num "$IPS_QUEUE_NUM" --queue-bypass || return 1
		for chain in $(ips_nfq_chains "$chains"); do
			"$tool" -w -C "$chain" -j "$IPS_CHAIN" 2>/dev/null ||
				"$tool" -w -I "$chain" 1 -j "$IPS_CHAIN" || return 1
		done
	done
	return 0
}

# ips_fw_present - DPISTACK exists in iptables.
ips_fw_present() {
	local tool
	ips_nft_present && return 0
	for tool in $(ips_tools); do
		"$tool" -w -n -L "$IPS_CHAIN" >/dev/null 2>&1 && return 0
	done
	return 1
}

# ips_fw_remove - take out every jump to DPISTACK (whatever the current
# IPS_NFQ_CHAINS says) and then the chain itself. Nothing else is touched.
ips_fw_remove() {
	local tool chain
	ips_nft_remove
	for tool in $(ips_tools); do
		for chain in "${IPS_ALL_CHAINS[@]}"; do
			while "$tool" -w -C "$chain" -j "$IPS_CHAIN" 2>/dev/null; do
				"$tool" -w -D "$chain" -j "$IPS_CHAIN" || break
			done
		done
		if "$tool" -w -n -L "$IPS_CHAIN" >/dev/null 2>&1; then
			"$tool" -w -F "$IPS_CHAIN"
			"$tool" -w -X "$IPS_CHAIN"
		fi
	done
	return 0
}

# ips_nft_present - the table "inet dpistack" exists.
ips_nft_present() {
	command -v nft >/dev/null 2>&1 && nft list table inet "$IPS_NFT_TABLE" >/dev/null 2>&1
}

# ips_nft_remove - delete our own table, and only that.
ips_nft_remove() {
	if ips_nft_present; then
		nft delete table inet "$IPS_NFT_TABLE" || return 1
	fi
	return 0
}
