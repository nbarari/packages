# shellcheck shell=bash
# Misc device-command and logging overrides.
#
# _install_lib_overrides() is called by load_functions() AFTER the library is
# sourced, so these win over the real definitions. f_log/f_wifi/sleep are
# replaced; tests that need finer control (e.g. f_getval) redefine them locally
# after calling load_functions.

cmd_reset() {
	TRM_LOG=()
	TRM_WIFI_CALLS=0
}

_install_lib_overrides() {
	# capture log lines instead of writing to logd; never terminate the process
	f_log() { TRM_LOG+=("$*"); }
	f_log_fatal() { TRM_LOG+=("FATAL $*"); return 1; }

	# count reload requests without touching radios
	f_wifi() { TRM_WIFI_CALLS=$((TRM_WIFI_CALLS + 1)); }

	# no real delays in unit tests
	sleep() { :; }
}

# Convenience: was a substring logged?
assert_logged() { # substring
	local line
	for line in "${TRM_LOG[@]}"; do
		case "${line}" in
		*"$1"*) return 0 ;;
		esac
	done
	batslib_print_kv_single 8 "wanted-substring" "$1" "logged-lines" "${TRM_LOG[*]}" |
		batslib_decorate "log line containing substring not found" | fail
}

# Convenience: was a uci change recorded matching a substring?
assert_uci_change() { # substring
	local line
	for line in "${UCI_CHANGES[@]}"; do
		case "${line}" in
		*"$1"*) return 0 ;;
		esac
	done
	batslib_print_kv_single 8 "wanted-substring" "$1" "uci-changes" "${UCI_CHANGES[*]}" |
		batslib_decorate "uci change containing substring not found" | fail
}
