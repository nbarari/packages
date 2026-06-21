# travelmate hook scripts

travelmate invokes optional hook scripts at key lifecycle events. Hooks let
operators integrate external tooling (VPN clients, notifications, DNS updates,
etc.) without patching travelmate itself.

## Directory layout

```
/etc/travelmate/hooks.d/
├── pre-connect.d/       # run before travelmate attempts to associate
├── post-connect.d/      # run after travelmate reaches "connected" state
├── pre-disconnect.d/    # run before travelmate tears down the STA interface
├── post-disconnect.d/   # run after the interface is down
├── pre-scan.d/          # run before travelmate scans for uplinks
└── post-scan.d/         # run after the scan result is captured
```

Scripts in each directory are discovered via `find` and executed in
**alphabetical order** (POSIX sort). Name scripts with a numeric prefix to
control ordering, e.g. `10-vpn-start`, `20-notify`.

## Environment variables

Every hook receives the following variables in its environment:

| Variable | Description | Example |
|---|---|---|
| `TRM_STAGE` | `pre` or `post` | `post` |
| `TRM_EVENT` | `connect`, `disconnect`, or `scan` | `connect` |
| `TRM_STATION_ID` | slash-delimited `radio/essid/bssid` | `radio0/MyNet/AA:BB:CC:DD:EE:FF` |
| `TRM_RADIO` | radio device name | `radio0` |
| `TRM_ESSID` | SSID of the uplink (empty during scan events) | `MyNet` |
| `TRM_BSSID` | BSSID of the uplink (`-` if unknown) | `AA:BB:CC:DD:EE:FF` |
| `TRM_RUN_FLAGS` | current feature-flag summary string | `captive: ✔, proactive: ✔, ...` |

During `pre-connect` and `post-scan` events, `TRM_ESSID` and `TRM_BSSID` may
be empty because the target uplink is not yet selected.

## Exit codes

Hooks are **advisory** by default: a non-zero exit code is logged at `info`
level but does not abort the travelmate operation. Each hook runs under a
**10-second timeout**; a hook that hangs is killed and logged as a timeout.

## Writing a hook

```sh
#!/bin/sh
# /etc/travelmate/hooks.d/post-connect.d/10-dyndns
[ "${TRM_EVENT}" = "connect" ] || exit 0
logger -t trm-hook "connected to ${TRM_ESSID}, updating DynDNS"
/usr/sbin/inadyn --once
```

Make the script executable: `chmod +x /etc/travelmate/hooks.d/post-connect.d/10-dyndns`.

## Implementation note

The hook framework is implemented by `f_hook stage event` in
`travelmate-functions.sh` (PR 18). It is called from:

- `f_check`: `f_hook pre connect` / `f_hook post connect` on the STA
  connect/disconnect path.
- `f_scan`: `f_hook pre scan` / `f_hook post scan` around the wifi scan.

See also: [`LOGIN_SCRIPTS.md`](LOGIN_SCRIPTS.md) for the separate
captive-portal login script contract.
