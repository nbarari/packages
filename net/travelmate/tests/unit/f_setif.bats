#!/usr/bin/env bats
# Unit tests for f_setif — apply uplink-enabled state to 'wifi-iface' (sta) sections.
#
# Regression coverage (not finding-tied): f_setif's sta enable/disable decision
# matrix is upstream logic the fork relies on. The uplink-config lookup it drives
# (f_getcfg/f_getval) is stubbed here — that indexed-section iteration depends on
# uci_get's absent-key exit status, which the Tier-1 mock deliberately does not
# model (see the kickoff ADR); it belongs to Tier-2. Stubbing f_getval mirrors
# how f_mac's tests stub it.
#
# Mutates trm_activesta / trm_stalist / UCI state, so invoke via call().

load test_helper

setup() {
	mocks_reset
	load_functions
	trm_radiolist="radio0" # f_setif early-returns for radios outside this list
	trm_ifstatus="false"
	trm_activesta=""
	trm_stalist=""

	# Stub the uplink-config resolution f_setif calls; STA_ENABLED drives the
	# "enabled" flag f_getval would read from the matched uplink section.
	STA_ENABLED="0"
	f_getcfg() { :; }
	f_getval() { printf '%s' "${STA_ENABLED}"; }
}

# Declare a wifi-iface section. Usage: mk_iface <section> <mode> [disabled] [radio]
mk_iface() {
	uci_fixture_set "wireless.$1.device" "${4:-radio0}"
	uci_fixture_set "wireless.$1.mode" "${2}"
	uci_fixture_set "wireless.$1.ssid" "TestNet"
	uci_fixture_set "wireless.$1.bssid" ""
	[ -n "$3" ] && uci_fixture_set "wireless.$1.disabled" "$3"
}

@test "returns early when the section's radio is not in the active radiolist" {
	mk_iface sta0 sta 0 radio9

	call f_setif sta0 0
	assert_success
	assert_equal "${#UCI_CHANGES[@]}" "0"
	assert_equal "${trm_stalist}" ""
}

@test "disables an sta whose uplink is off (enabled=0)" {
	STA_ENABLED="0"
	mk_iface sta0 sta 0

	call f_setif sta0 0
	assert_success
	assert_uci_change "set wireless.sta0.disabled=1"
}

@test "disables an enabled sta when not in proactive-connected state" {
	STA_ENABLED="1"
	trm_ifstatus="false"
	mk_iface sta0 sta 0

	call f_setif sta0 0
	assert_success
	assert_uci_change "set wireless.sta0.disabled=1"
}

@test "keeps the first active sta in proactive-connected mode" {
	STA_ENABLED="1"
	trm_ifstatus="true"
	mk_iface sta0 sta 0

	call f_setif sta0 1
	assert_success
	assert_equal "${trm_activesta}" "sta0"
	assert_equal "${#UCI_CHANGES[@]}" "0"
}

@test "disables additional active stations beyond the first" {
	STA_ENABLED="1"
	trm_ifstatus="true"
	trm_activesta="sta_first"
	mk_iface sta0 sta 0

	call f_setif sta0 1
	assert_success
	assert_uci_change "set wireless.sta0.disabled=1"
	assert_equal "${trm_activesta}" "sta_first"
}

@test "tracks every enabled sta in trm_stalist" {
	STA_ENABLED="1"
	mk_iface sta0 sta 0

	call f_setif sta0 0
	assert_success
	assert_equal "${trm_stalist}" "sta0-radio0"
}

@test "ignores non-sta (ap) sections" {
	STA_ENABLED="1"
	mk_iface ap0 ap 0

	call f_setif ap0 0
	assert_success
	assert_equal "${#UCI_CHANGES[@]}" "0"
	assert_equal "${trm_stalist}" ""
}
