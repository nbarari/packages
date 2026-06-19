#!/usr/bin/env bats
# Unit tests for f_mac — station MAC selection (config / random-LAA / driver).
#
# Calibration (finding 1.3): the random path forces a locally-administered,
# unicast MAC (second nibble of the first octet in {2,6,A,E}); the clear path
# removes the override and falls back to the driver MAC via ubus. The LAA-nibble
# invariant holds for ANY random input, so the assertion is deterministic.

load test_helper

setup() {
	mocks_reset
	load_functions
	trm_randomize="0"
	trm_ubuscmd="ubus_stub"
	trm_jsoncmd="json_stub"
}

@test "set: uses the macaddr from the uplink config when present" {
	f_getval() { printf '%s' "AA:BB:CC:DD:EE:FF"; }

	call f_mac set sta0
	assert_success
	assert_output "AA:BB:CC:DD:EE:FF"
	assert_uci_change "set wireless.sta0.macaddr=AA:BB:CC:DD:EE:FF"
}

@test "set: generates a locally-administered random MAC when randomize=1" {
	trm_randomize="1"
	f_getval() { printf ''; }

	call f_mac set sta0
	assert_success
	assert_output --regexp '^[0-9A-F]{2}(:[0-9A-F]{2}){5}$'

	# LAA + unicast: second nibble of the first octet must be 2, 6, A or E
	local nibble="${output:1:1}"
	[[ "${nibble}" == [26AE] ]] || fail "expected LAA nibble (2/6/A/E), got first octet ${output:0:2}"

	assert_uci_change "set wireless.sta0.macaddr=${output}"
}

@test "set: clears the override and falls back to the driver MAC via ubus" {
	trm_randomize="0"
	f_getval() { printf ''; }
	UBUS_REPLY='{"radio0":{"interfaces":[]}}'
	JSON_REPLY="11:22:33:44:55:66"

	call f_mac set sta0
	assert_success
	assert_output "11:22:33:44:55:66"
	assert_uci_change "remove wireless.sta0.macaddr"
}

@test "get: returns the configured macaddr" {
	uci_fixture_set wireless.sta0.macaddr "DE:AD:BE:EF:00:01"

	call f_mac get sta0
	assert_success
	assert_output "DE:AD:BE:EF:00:01"
}

@test "get: falls back to the driver MAC via ubus when none configured" {
	JSON_REPLY="99:88:77:66:55:44"

	call f_mac get sta0
	assert_success
	assert_output "99:88:77:66:55:44"
}
