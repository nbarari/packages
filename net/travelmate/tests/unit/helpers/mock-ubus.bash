# shellcheck shell=bash
# Stubs for ubus / jsonfilter-backed device queries.
#
# Tests point trm_ubuscmd / trm_jsoncmd at these (or at a per-test function) so
# the function under test never touches a real ubus socket. We deliberately stop
# at the *extracted value* boundary: reproducing jsonfilter's JSONPath engine
# would be re-implementing it, which Tier-1 does not attempt (see the kickoff
# ADR — jshn/jsonfilter fidelity is Tier-2's job).

ubus_reset() {
	UBUS_REPLY=""  # raw bytes ubus_stub echoes
	JSON_REPLY=""  # value json_stub echoes (the post-filter result)
}

# Stand-in for `${trm_ubuscmd}` — ignores all args, echoes the canned reply.
ubus_stub() { printf '%s' "${UBUS_REPLY}"; }

# Stand-in for `${trm_jsoncmd}` — drains stdin, echoes the canned extracted value.
json_stub() {
	cat >/dev/null 2>&1
	printf '%s' "${JSON_REPLY}"
}
