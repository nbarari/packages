# travelmate runtime.json schema

`travelmate-service.sh` (via `f_genstatus`) writes a status snapshot to
`/var/run/travelmate/travelmate.runtime.json` on every state change. The
LuCI app (`overview.js`, `stations.js`) and CLI users read this file.

## File location

```
/var/run/travelmate/travelmate.runtime.json
```

Lives on tmpfs — cleared on reboot. Written atomically (temp file + `mv`).

## Shape

All fields are under a top-level `data` object:

```json
{
  "data": {
    "travelmate_status": "connected, net ok/98",
    "frontend_ver":      "2.4.6-r1",
    "backend_ver":       "2.4.6-r2",
    "station_id":        "radio0/MyNet/AA:BB:CC:DD:EE:FF",
    "station": {
      "radio": "radio0",
      "essid": "MyNet",
      "bssid": "AA:BB:CC:DD:EE:FF"
    },
    "station_mac":        "22:FE:49:89:92:DF",
    "station_interfaces": "trm_wwan, -",
    "station_subnet":     "10.10.0.0 (lan: 10.10.14.0)",
    "run_flags":   "captive: ✔, proactive: ✔, netcheck: ✘, autoadd: ✘, randomize: ✔, eviltwin: ✘",
    "ext_hooks":   "ntp: ✔, vpn: ✘, mail: ✘",
    "last_run":    "2026.06.18-23:17:50",
    "system":      "GL.iNet GL-MT3000, mediatek/filogic, OpenWrt 25.12.2 (r32802)"
  }
}
```

## Field reference

| Field | Type | Source | Notes |
|---|---|---|---|
| `travelmate_status` | string | `f_genstatus` | Human-readable compound: `"connected, net ok/98"`, `"processing"`, `"program error"`. The prefix before `,` is the state; suffix is `net ok/<quality>` or `net cp/<quality>` (captive) or `net nok/<quality>`. |
| `frontend_ver` | string | `trm_fver` | LuCI app version (`PKG_VERSION-PKG_RELEASE`). |
| `backend_ver` | string | `trm_bver` | Shell package version. |
| `station_id` | string | `f_genstatus` | Slash-delimited `radio/essid/bssid`. Used as an internal data bus by `f_check`/`f_main` to re-parse station identity. `-` for any unknown component. |
| `station` | object | `f_genstatus` (fork) | Structured station identity: `{radio, essid, bssid}`. Added additively in the fork (finding L4, packages#19). LuCI prefers this over splitting `station_id`; older frontends fall back to `station_id`. |
| `station_mac` | string | `f_genstatus` | Effective MAC of the STA interface (randomized or hardware). `-` if unknown. |
| `station_interfaces` | string | `f_genstatus` | Comma-separated `trm_wwan_iface, vpn_iface`. `-` for inactive. |
| `station_subnet` | string | `f_genstatus` | WAN subnet / LAN subnet pair via `f_subnet`. |
| `run_flags` | string | `f_genstatus` | Feature flag summary — `key: ✔/✘` pairs for captive, proactive, netcheck, autoadd, randomize, eviltwin. Free-form; parse by splitting on `, `. |
| `ext_hooks` | string | `f_genstatus` | External hook status — `key: ✔/✘` pairs for ntp, vpn, mail. |
| `last_run` | string | `f_genstatus` | Timestamp of last `f_genstatus` call: `YYYY.MM.DD-HH:MM:SS`. |
| `system` | string | `trm_sysver` | Flat system description (board, target, OpenWrt version). Not an object. |

## Stability

Fields without "(fork)" in the Source column are present in upstream travelmate
2.4.6 and later. The `station` object is fork-only and must not be relied on in
code that targets the upstream package.

`station_id` is the stable cross-version key; `station` is the preferred
consumer API in fork-aware code.

## Consumers

- `luci-app-travelmate` `overview.js` — reads `travelmate_status`, `run_flags`,
  `ext_hooks`, `last_run`, `system`.
- `luci-app-travelmate` `stations.js` — reads `station` (fork) / `station_id`
  (fallback), `station_mac`, `station_interfaces`, `station_subnet`.
- Hook scripts via `TRM_*` environment variables — see [`HOOKS.md`](HOOKS.md).
- CLI: `cat /var/run/travelmate/travelmate.runtime.json | jsonfilter -e '@.data.travelmate_status'`

## travelmate.lock

A second file, `/var/run/travelmate/travelmate.lock`, is created by the service
on startup and removed on clean shutdown. Its presence indicates the daemon is
running; its absence (with travelmate enabled) indicates a crash. LuCI uses this
to distinguish "stopped" from "crashed" in the status view.
