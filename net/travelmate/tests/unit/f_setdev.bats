#!/usr/bin/env bats
# Unit tests for f_setdev — build the active radio list from 'wifi-device' sections.
#
# Regression coverage (not finding-tied): f_setdev's filter/dedup/enable control
# flow is upstream logic the fork relies on, so these lock in behaviour rather
# than prove a fork change (cf. f_trim/f_normbssid plumbing-proof precedent).
# It mutates the trm_radiolist global, so invoke via call() (current shell), not
# `run` (which would lose the mutation in a subshell).

load test_helper

setup() {
	mocks_reset
	load_functions
	trm_radio=""     # operator radio filter (empty = all)
	trm_radiolist="" # accumulated active radios
	trm_revradio="0" # prepend instead of append when 1
}

@test "empty filter: appends a new radio to the list" {
	call f_setdev radio0
	assert_success
	assert_equal "${trm_radiolist}" "radio0"
}

@test "empty filter: enables a radio it adds that is administratively disabled" {
	uci_fixture_set wireless.radio0.disabled 1

	call f_setdev radio0
	assert_success
	assert_equal "${trm_radiolist}" "radio0"
	assert_uci_change "set wireless.radio0.disabled=0"
}

@test "empty filter: does not re-add a radio already in the list" {
	trm_radiolist="radio0"
	# even if it looks disabled, an already-tracked radio is skipped wholesale
	uci_fixture_set wireless.radio0.disabled 1

	call f_setdev radio0
	assert_success
	assert_equal "${trm_radiolist}" "radio0"
	assert_equal "${#UCI_CHANGES[@]}" "0"
}

@test "filter set: adds only radios named in trm_radio" {
	trm_radio="radio1"

	call f_setdev radio0
	assert_success
	assert_equal "${trm_radiolist}" ""

	call f_setdev radio1
	assert_success
	assert_equal "${trm_radiolist}" "radio1"
}

@test "revradio=1 prepends the radio to the list" {
	trm_revradio="1"
	trm_radiolist="radio0"

	call f_setdev radio1
	assert_success
	assert_equal "${trm_radiolist}" "radio1 radio0"
}

@test "does not touch an already-enabled radio" {
	uci_fixture_set wireless.radio0.disabled 0

	call f_setdev radio0
	assert_success
	assert_equal "${trm_radiolist}" "radio0"
	assert_equal "${#UCI_CHANGES[@]}" "0"
}
