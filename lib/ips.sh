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

# ips_tools - the iptables front ends that exist (v4 always, v6 if there).
ips_tools() {
	echo iptables
	command -v ip6tables >/dev/null 2>&1 && echo ip6tables
	return 0
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
	for tool in $(ips_tools); do
		"$tool" -w -n -L "$IPS_CHAIN" >/dev/null 2>&1 && return 0
	done
	return 1
}

# ips_fw_remove - take out every jump to DPISTACK (whatever the current
# IPS_NFQ_CHAINS says) and then the chain itself. Nothing else is touched.
ips_fw_remove() {
	local tool chain
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
