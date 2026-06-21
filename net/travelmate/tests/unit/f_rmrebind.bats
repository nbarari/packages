#!/usr/bin/env bats
# Unit tests for f_rmrebind — tracked captive-portal rebind cleanup (finding 1.4).
#
# Calibration (finding 1.4): the fork adds f_rmrebind to track and remove only
# the rebind_domain entries that travelmate itself added (recorded in
# trm_rebindfile). On upstream there was no domain-tracking teardown — entries
# accumulated. These tests verify the fork's targeted cleanup contract.
#
# Note: the dnsmasq path (uci_remove_list per domain + reload) requires
# /etc/init.d/dnsmasq and /etc/config/dhcp, which are absent on CI runners.
# That path is exercised end-to-end by the Tier-2 captive integration scenarios.

load test_helper

setup() {
	mocks_reset
	load_functions
}

@test "no-op when rebindfile is missing or empty" {
	rm -f "${trm_rebindfile}"

	call f_rmrebind
	assert_success
	assert_equal "${#UCI_CHANGES[@]}" "0"
}

@test "rebindfile is removed even when dnsmasq is absent" {
	printf 'captive.example.com\n' >"${trm_rebindfile}"

	call f_rmrebind
	assert_success
	[ ! -f "${trm_rebindfile}" ]
}
