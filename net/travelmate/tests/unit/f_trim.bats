#!/usr/bin/env bats
# Unit tests for f_trim — pure whitespace trim helper (no device deps).
# Doubles as the harness plumbing smoke test.

load test_helper

setup() {
	mocks_reset
	load_functions
}

@test "f_trim strips leading and trailing spaces" {
	run f_trim "   hello world   "
	assert_success
	assert_output "hello world"
}

@test "f_trim preserves inner whitespace" {
	run f_trim "  a  b  "
	assert_output "a  b"
}

@test "f_trim is identity on already-trimmed input" {
	run f_trim "tidy"
	assert_output "tidy"
}

@test "f_trim collapses whitespace-only input to empty" {
	run f_trim "     "
	assert_output ""
}

@test "f_trim strips leading and trailing tabs" {
	run f_trim "$(printf '\t\tval\t')"
	assert_output "val"
}
