#!/usr/bin/env bats
# Unit tests for f_addsta — auto-add of open uplinks.
#
# Calibration (finding 1.5): the auto-add quota is derived live from the existing
# 'opensta' uplink sections via config_load/config_cb, replacing the persistent
# 'trm_autoaddcnt' counter. These tests drive that derived-count control flow.
# They exercise fork behaviour that has no upstream equivalent (upstream gates on
# a stored counter, not a section scan), so they pass on the fork and could not
# pass against the upstream counter logic.

load test_helper

setup() {
	mocks_reset
	load_functions
	trm_ssidfilter=""
	trm_maxautoadd="5"
	trm_iface="trm_wwan"
	trm_stdvpnservice=""
	trm_stdvpniface=""
}

@test "adds a new open uplink when under quota and no duplicate exists" {
	call f_addsta radio0 CoffeeShop
	assert_success
	assert_output "trm_uplink2-radio0"
	assert_equal "${TRM_WIFI_CALLS}" "1"
	assert_uci_change "commit travelmate"
	assert_uci_change "commit wireless"
	[ -f "${trm_refreshfile}" ]
}

@test "refuses a new uplink at quota (count derived from opensta sections)" {
	trm_maxautoadd="2"
	uci_fixture_section travelmate uplink u1
	uci_fixture_set travelmate.u1.opensta 1
	uci_fixture_section travelmate uplink u2
	uci_fixture_set travelmate.u2.opensta 1

	call f_addsta radio0 NewNet
	assert_success
	assert_output ""
	assert_equal "${TRM_WIFI_CALLS}" "0"
}

@test "counts only opensta sections toward the quota" {
	trm_maxautoadd="2"
	uci_fixture_section travelmate uplink u1
	uci_fixture_set travelmate.u1.opensta 1
	# a manually-added uplink without opensta must NOT count against the quota
	uci_fixture_section travelmate uplink u2

	call f_addsta radio0 NewNet
	assert_success
	assert_output "trm_uplink2-radio0"
}

@test "treats trm_maxautoadd=0 as unlimited" {
	trm_maxautoadd="0"
	uci_fixture_section travelmate uplink u1
	uci_fixture_set travelmate.u1.opensta 1
	uci_fixture_section travelmate uplink u2
	uci_fixture_set travelmate.u2.opensta 1
	uci_fixture_section travelmate uplink u3
	uci_fixture_set travelmate.u3.opensta 1

	call f_addsta radio0 NewNet
	assert_success
	refute_output ""
}

@test "skips when an identical wifi-iface uplink already exists" {
	uci_fixture_section wireless wifi-iface sta_known
	uci_fixture_set wireless.sta_known.ssid CoffeeShop
	uci_fixture_set wireless.sta_known.device radio0

	call f_addsta radio0 CoffeeShop
	assert_success
	assert_output ""
	assert_equal "${TRM_WIFI_CALLS}" "0"
}

@test "filters essids matching trm_ssidfilter" {
	trm_ssidfilter="Coffee*"

	call f_addsta radio0 CoffeeShop
	assert_success
	assert_output ""
	assert_logged "filtered out"
}
