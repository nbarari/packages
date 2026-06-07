#!/bin/sh
# Syntax-check each argument with busybox ash -- the exact parser that runs on
# the OpenWrt device. Unlike shellcheck (which is disabled in these files via
# `# shellcheck disable=all`, and is bash-oriented anyway), this is the device's
# own shell: it catches broken syntax that would fail at runtime on the router.
#
# Requires `busybox` on PATH (CI installs it; on a dev box: apt/brew install
# busybox). Falls back to `ash`/`dash` if busybox is unavailable.
set -eu

if command -v busybox >/dev/null 2>&1; then
	SH="busybox ash"
elif command -v ash >/dev/null 2>&1; then
	SH="ash"
elif command -v dash >/dev/null 2>&1; then
	SH="dash"
else
	echo "ash-syntax-check: no busybox/ash/dash found on PATH" >&2
	exit 2
fi

rc=0
for f in "$@"; do
	if ! $SH -n "$f"; then
		echo "ash-syntax-check: syntax error in $f" >&2
		rc=1
	fi
done
exit "$rc"
