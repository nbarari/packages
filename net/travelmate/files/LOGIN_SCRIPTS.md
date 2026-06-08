# Captive-portal login scripts

Travelmate can run an external shell script to complete a captive-portal
auto-login after it associates with an open uplink. This document describes the
contract such a script must follow, so you can write one for a portal that is
not covered by the scripts shipped in this package.

The shipped scripts — `generic-user-pass.login`, `telekom.login`,
`vodafone.login`, `wifibahn.login` — are working references for everything
below.

## How travelmate invokes a login script

A login script is attached to an uplink through two per-uplink UCI options on the
`travelmate` config (set them in LuCI or with `uci`):

| Option        | Meaning                                                        |
|---------------|----------------------------------------------------------------|
| `script`      | Absolute path to an **executable** login script.               |
| `script_args` | Optional arguments passed to the script (e.g. `user password`).|

When travelmate detects a captive portal on that uplink it runs, in effect:

```sh
"${script}" ${script_args}      # stdout and stderr are discarded
rc=$?
```

Then:

- The script's **exit code is the only channel travelmate observes** — its
  stdout and stderr are sent to `/dev/null`. Report status through `exit`, not
  by printing.
- travelmate logs `captive portal login script ... finished with rc '<rc>'`.
- **On `rc = 0`** travelmate re-runs its connectivity check; if the portal is now
  cleared the uplink goes live. **Any non-zero `rc`** is treated as "login did
  not succeed" — travelmate logs it and does not re-check.

Scripts are conventionally installed in `/etc/travelmate` with a `.login`
extension and must be executable (`chmod +x`).

## Environment available to the script

travelmate does **not** export its `trm_*` variables to the child process. A
login script obtains them by sourcing the functions library and calling
`f_conf`, guarding on the `trm_bver` sentinel so it does not re-source when
travelmate already provides the environment:

```sh
trm_funlib="/usr/lib/travelmate-functions.sh"
if [ -z "${trm_bver}" ]; then
	. "${trm_funlib}"
	f_conf
fi
```

After that block the following are available (resolved from UCI and the system):

| Variable         | Purpose                                                                    |
|------------------|----------------------------------------------------------------------------|
| `trm_lookupcmd`  | DNS resolver (`nslookup`); use it to confirm the portal host resolves.     |
| `trm_fetch`      | HTTP client (`curl`); the variable the shipped scripts call.               |
| `trm_fetchcmd`   | Same `curl` path (`trm_fetch` is an alias of it).                          |
| `trm_fetchparm`  | Standard `curl` options, including `--interface <uplink>`, retries, timeout.|
| `trm_useragent`  | User-Agent string travelmate uses for portal requests.                     |
| `trm_captiveurl` | Captive-detection URL travelmate probes.                                   |
| `trm_awkcmd`     | `awk` path (for scripts that parse portal HTML).                            |
| `trm_jsoncmd`    | `jsonfilter` path (for scripts that parse JSON portal APIs).               |
| `trm_sortcmd`    | `sort` path.                                                                |
| `trm_bver`       | Travelmate backend version; also the "already sourced" sentinel above.     |

`trm_domain` is **not** provided — each script sets its own portal host (see the
shipped scripts), typically right before a `trm_lookupcmd` precondition check.

Credentials are passed positionally via `script_args`; the shipped scripts read
`user="${1}"` and `password="${2}"`.

## Exit-code conventions

`0` and non-zero are the firm contract; the staged non-zero codes below are the
convention the shipped scripts follow, useful for diagnosing failures from the
log:

| Code  | Meaning                                                                  |
|-------|--------------------------------------------------------------------------|
| `0`   | Login succeeded — travelmate re-checks connectivity and brings the uplink up. |
| `1`   | Precondition/DNS failure (e.g. `trm_lookupcmd` failed, or a required redirect could not be obtained). |
| `2`   | Could not obtain a security token / session needed for the login.        |
| `255` | The login request was sent but the portal did not confirm success.       |

A script may use additional non-zero codes for finer-grained failures
(`vodafone.login`, for example, uses `3` when no eligible login profile is
offered). travelmate treats every non-zero code the same way — only `0` triggers
the connectivity re-check.

## Skeleton template

```sh
#!/bin/sh
# captive portal auto-login script for <portal name>

# set (s)hellcheck exceptions
# shellcheck disable=all

export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

# pull in the travelmate environment (trm_fetch, trm_useragent, ...)
#
trm_funlib="/usr/lib/travelmate-functions.sh"
if [ -z "${trm_bver}" ]; then
	. "${trm_funlib}"
	f_conf
fi

# credentials are passed via the uplink's 'script_args' UCI option
#
user="${1}"
password="${2}"

# 1) precondition: make sure the portal host resolves
#
trm_domain="portal.example.com"
if ! "${trm_lookupcmd}" "${trm_domain}" >/dev/null 2>&1; then
	exit 1
fi

# 2) perform the portal-specific login request(s) with curl
#
raw_html="$("${trm_fetch}" ${trm_fetchparm} --user-agent "${trm_useragent}" \
	--data "username=${user}&password=${password}" "http://${trm_domain}")"

# 3) report success (0) or failure (non-zero) via the exit code only
#
[ -z "${raw_html}" ] && exit 0 || exit 255
```

See `generic-user-pass.login` for the minimal real example, and the
`telekom`/`vodafone`/`wifibahn` scripts for portals that need token/redirect
handling.
