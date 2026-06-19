#!/usr/bin/env bats
# Unit tests for f_normbssid — upper-cases a BSSID into the trm_normbssid global.
# Note: writes a global, so call directly (not via `run`, which forks a subshell).

load test_helper

setup() {
	mocks_reset
	load_functions
}

@test "f_normbssid upper-cases all hex letters" {
	f_normbssid "aa:bb:cc:dd:ee:ff"
	assert_equal "${trm_normbssid}" "AA:BB:CC:DD:EE:FF"
}

@test "f_normbssid folds only a-f and leaves digits/colons intact" {
	f_normbssid "a1:b2:c3:d4:e5:f6"
	assert_equal "${trm_normbssid}" "A1:B2:C3:D4:E5:F6"
}

@test "f_normbssid is identity on an already-upper BSSID" {
	f_normbssid "12:34:56:78:9A:BC"
	assert_equal "${trm_normbssid}" "12:34:56:78:9A:BC"
}

@test "f_normbssid handles an empty BSSID" {
	f_normbssid ""
	assert_equal "${trm_normbssid}" ""
}
