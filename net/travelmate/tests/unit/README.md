# travelmate Tier-1 unit tests

Fast, hermetic [bats](https://github.com/bats-core/bats-core) unit tests for the
travelmate shell library (`../../files/travelmate-functions.sh`). They run on any
host with `git` and `bash` — no OpenWrt SDK, no device, no network — because the
device userland (`ubus`, `uci`, `jshn`, `wifi`) is replaced by shell-function
mocks defined in `helpers/`.

This is **Tier-1** of the Track 5 test harness. Scope, the mock strategy, and
what is deliberately *deferred to Tier-2 (QEMU + `mac80211_hwsim`)* — notably the
jshn-heavy `f_scan`/`f_genstatus` — are recorded in the nbarari/travelmate docs
repo at `docs/decisions/2026-06-19-track5-tier1-bats-harness.md`.

## Layout

```text
tests/unit/
├── bats-core/ bats-support/ bats-assert/   # git submodules (the runner + asserts)
├── test_helper.bash                        # load_functions(): sandbox-safe source + call()
├── helpers/
│   ├── mock-uci.bash                       # in-memory UCI shadow + config_load/config_cb
│   ├── mock-ubus.bash                      # ubus / jsonfilter value stubs
│   └── mock-cmd.bash                       # f_log/f_wifi/sleep overrides + assert helpers
└── *.bats                                  # one file per function under test
```

## Running

```sh
# from the repo root, after `git submodule update --init --recursive`
./net/travelmate/tests/unit/bats-core/bin/bats net/travelmate/tests/unit

# or, with a system bats (>= 1.5):
bats net/travelmate/tests/unit
```

CI runs the first form on every PR touching `net/travelmate/**`
(`.github/workflows/ci-unit.yml`).

## Adding a test

1. Create `f_<name>.bats`, `load test_helper`, and in `setup()` call
   `mocks_reset` then `load_functions`.
2. Invoke the function with `call f_<name> <args>` (current-shell capture, so
   mock side-effect state survives) — **not** bats `run` or `$(...)`, which fork
   a subshell and lose `UCI_CHANGES`/`TRM_WIFI_CALLS`. Use `run` only for pure
   functions whose result is stdout (e.g. `f_trim`).
3. For finding-tied tests, note the calibration intent in the file header (must
   exercise fork behaviour, i.e. fail against upstream).
