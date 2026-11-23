#!/usr/bin/env bats
# Task 59: the capture can be tuned. Threads, ring and block size, tpacket,
# the memcaps of flow, stream and reassembly, and CPU pinning are keys, and
# the defaults render what the template always had.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
}

teardown() { rm -rf "$DPISTACK_ROOT"; }

# render <settings> <what> - runs a renderer with some CONF lines set
render() {
	bash -c '
		SCRIPT_DIR="'"$REPO_DIR"'"
		for f in paths common schema config render; do source "'"$REPO_DIR"'/lib/$f.sh"; done
		config_reset; config_load_defaults
		'"$1"'
		source "'"$REPO_DIR"'/lib/step_suricata.sh"
		'"$2"'
	'
}

@test "the defaults render no tuning line in the af-packet block and the old memcaps in the yaml" {
	run render 'CONF[IFACES]=eth1' 'suricata_render_af_packet_block'
	[ "$status" -eq 0 ]
	[[ "$output" != *"threads:"* ]]
	[[ "$output" != *"ring-size"* ]]
	[[ "$output" != *"block-size"* ]]
	[[ "$output" != *"tpacket"* ]]
	run render 'CONF[IFACES]=eth1' 'suricata_render_yaml'
	[ "$status" -eq 0 ]
	grep -qx '  memcap: 128mb' <<<"$output"
	grep -qx '  memcap: 64mb' <<<"$output"
	grep -qx '    memcap: 256mb' <<<"$output"
	grep -qx '  set-cpu-affinity: no' <<<"$output"
	grep -qx '        cpu: \[ "all" \]' <<<"$output"
}

@test "threads, ring size, tpacket-v3 and block size go into every interface block" {
	run render 'CONF[IFACES]=eth1,eth2; CONF[CAPTURE_THREADS]=4; CONF[CAPTURE_RING_SIZE]=8192; CONF[CAPTURE_TPACKET]=v3; CONF[CAPTURE_BLOCK_SIZE]=1048576' 'suricata_render_af_packet_block'
	[ "$(grep -c '    threads: 4' <<<"$output")" -eq 2 ]
	[ "$(grep -c '    ring-size: 8192' <<<"$output")" -eq 2 ]
	[ "$(grep -c '    tpacket-v3: yes' <<<"$output")" -eq 2 ]
	[ "$(grep -c '    block-size: 1048576' <<<"$output")" -eq 2 ]
}

@test "tpacket v2 switches v3 off and leaves out the block size, which only v3 has" {
	run render 'CONF[IFACES]=eth1; CONF[CAPTURE_TPACKET]=v2; CONF[CAPTURE_BLOCK_SIZE]=1048576' 'suricata_render_af_packet_block'
	[[ "$output" == *"tpacket-v3: no"* ]]
	[[ "$output" != *"block-size"* ]]
}

@test "IPS over af-packet always asks for tpacket v2: copy mode has no v3" {
	run render 'CONF[IFACES]=eth1,eth2; CONF[SURICATA_MODE]=ips; CONF[IPS_METHOD]=afpacket' 'suricata_render_af_packet_block'
	[ "$(grep -c 'tpacket-v3: no' <<<"$output")" -eq 2 ]
	[[ "$output" == *"copy-mode: ips"* ]]
}

@test "the memcaps are rendered where the template has them" {
	run render 'CONF[FLOW_MEMCAP]=512mb; CONF[STREAM_MEMCAP]=1gb; CONF[STREAM_REASSEMBLY_MEMCAP]=2gb' 'suricata_render_yaml'
	grep -qx '  memcap: 512mb' <<<"$output"
	grep -qx '  memcap: 1gb' <<<"$output"
	grep -qx '    memcap: 2gb' <<<"$output"
	[[ "$output" != *"@@"* ]]
}

@test "CAPTURE_CPUS turns the pinning on and gives the workers those CPUs only" {
	run render 'CONF[CAPTURE_CPUS]="2-5,8"' 'suricata_render_yaml'
	grep -qx '  set-cpu-affinity: yes' <<<"$output"
	grep -qx '        cpu: \[ "2-5", "8" \]' <<<"$output"
	[[ "$output" != *'[ "all" ]'* ]]
}

@test "the schema takes good values and refuses bad ones, with exit 5 from the config verb" {
	local good bad
	for good in 'CAPTURE_THREADS=auto' 'CAPTURE_THREADS=8' 'CAPTURE_RING_SIZE=0' 'CAPTURE_RING_SIZE=65536' 'CAPTURE_BLOCK_SIZE=0' 'CAPTURE_BLOCK_SIZE=1048576' 'FLOW_MEMCAP=1gb' 'STREAM_MEMCAP=512mb' 'CAPTURE_CPUS=0,2-3' 'CAPTURE_TPACKET=v3'; do
		run bash -c "source '$REPO_DIR/lib/schema.sh'; schema_validate_entry ${good%%=*} '${good#*=}'"
		[ "$status" -eq 0 ] || {
			echo "$good: $output"
			false
		}
	done
	for bad in 'CAPTURE_THREADS=0' 'CAPTURE_THREADS=many' 'CAPTURE_RING_SIZE=-1' 'CAPTURE_BLOCK_SIZE=1000' 'CAPTURE_BLOCK_SIZE=4096' 'FLOW_MEMCAP=128' 'FLOW_MEMCAP=128MB' 'STREAM_MEMCAP=0mb' 'CAPTURE_CPUS=a' 'CAPTURE_CPUS=1-' 'CAPTURE_TPACKET=v1'; do
		run bash -c "source '$REPO_DIR/lib/schema.sh'; schema_validate_entry ${bad%%=*} '${bad#*=}'"
		[ "$status" -ne 0 ] || {
			echo "$bad was accepted"
			false
		}
	done
}

@test "the config check refuses tpacket v3 with IPS over af-packet, and a backwards CPU range" {
	run bash -c "source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/schema.sh'; source '$REPO_DIR/lib/config.sh'
		config_reset; config_load_defaults
		CONF[SURICATA_MODE]=ips; CONF[IPS_METHOD]=afpacket; CONF[CAPTURE_TPACKET]=v3; CONF[CAPTURE_CPUS]=5-2
		config_validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"CAPTURE_TPACKET=v3 does not work with IPS over af-packet"* ]]
	[[ "$output" == *"the range 5-2 runs backwards"* ]]
}

@test "an empty CAPTURE_CPUS explains itself in the prompts" {
	run bash -c "source '$REPO_DIR/lib/schema.sh'; schema_empty_meaning CAPTURE_CPUS"
	[[ "$output" == *"no pinning"* ]]
}

# ---- NIC_OFFLOADS_OFF: a drop-in of suricata.service

install_base() {
	MOCK_IP_EXISTING_IFACES="enp2s0,eth1"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE MOCK_CALLS_LOG
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@" >/dev/null 2>&1
}

@test "NIC_OFFLOADS_OFF=yes writes one ExecStartPre per capture interface, with the minus that makes it harmless" {
	run render 'CONF[IFACES]=eth1,eth2; CONF[NIC_OFFLOADS_OFF]=yes' 'suricata_render_nic_dropin'
	[ "$status" -eq 0 ]
	[[ "$output" == *"[Service]"* ]]
	grep -Eq '^ExecStartPre=-[^ ]*ethtool -K eth1 gro off lro off gso off tso off$' <<<"$output"
	grep -Eq '^ExecStartPre=-[^ ]*ethtool -K eth2 gro off lro off gso off tso off$' <<<"$output"
}

@test "install with NIC_OFFLOADS_OFF=yes writes the drop-in, the key set to no takes it away again" {
	local nic="$DPISTACK_ROOT/etc/systemd/system/suricata.service.d/dpistack-nic.conf"
	install_base --set NIC_OFFLOADS_OFF=yes
	[ -f "$nic" ]
	grep -q 'ethtool -K enp2s0 gro off lro off gso off tso off' "$nic"
	install_base --set NIC_OFFLOADS_OFF=no
	[ ! -e "$nic" ]
}

@test "uninstall removes the drop-in" {
	local nic="$DPISTACK_ROOT/etc/systemd/system/suricata.service.d/dpistack-nic.conf"
	install_base --set NIC_OFFLOADS_OFF=yes
	[ -f "$nic" ]
	run bash "$REPO_DIR/install.sh" uninstall -y
	[ ! -e "$nic" ]
}

@test "the config check refuses NIC_OFFLOADS_OFF=yes with a container" {
	run bash -c "source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/schema.sh'; source '$REPO_DIR/lib/config.sh'
		config_reset; config_load_defaults
		CONF[NIC_OFFLOADS_OFF]=yes; CONF[SURICATA_RUNTIME]=docker
		config_validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"NIC_OFFLOADS_OFF=yes needs SURICATA_RUNTIME=native"* ]]
}
