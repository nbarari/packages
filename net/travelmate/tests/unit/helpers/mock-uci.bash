# shellcheck shell=bash
# In-memory UCI shadow + config_load/config_cb driver for unit tests.
#
# bash-3.2 safe: no associative arrays. The shadow is a flat list of "key=value"
# entries (linear scan); test fixtures are tiny so this is plenty fast.
#
# Faithfulness note: the real /lib/config/uci.sh uci_get concatenates its
# positional args into a single dotted lookup (`uci -q get pkg.section.option`),
# which is why travelmate can call it both as `uci_get pkg section option` and as
# `uci_get "pkg.section.option"`. _uci_key reproduces that concatenation so both
# call forms resolve identically here.

uci_reset() {
	UCI_STORE=()    # "key=value" entries
	UCI_SECTIONS=() # "pkg|type|name" entries, in declaration order
	UCI_CHANGES=()  # recorded mutations, for assertions
	UCI_ADD_SEQ=0
	UCI_FORCE_CHANGES="${UCI_FORCE_CHANGES:-1}"
}

# --- shadow primitives ------------------------------------------------------
_uci_store_set() { # key value
	local i
	for i in "${!UCI_STORE[@]}"; do
		case "${UCI_STORE[$i]}" in
		"$1="*)
			UCI_STORE[$i]="$1=$2"
			return 0
			;;
		esac
	done
	UCI_STORE+=("$1=$2")
}

_uci_store_get() { # key -> prints value, returns 1 if absent
	local kv
	for kv in "${UCI_STORE[@]}"; do
		case "${kv}" in
		"$1="*)
			printf '%s' "${kv#*=}"
			return 0
			;;
		esac
	done
	return 1
}

_uci_store_del() { # key
	local kv new=()
	for kv in "${UCI_STORE[@]}"; do
		case "${kv}" in
		"$1="*) ;;
		*) new+=("${kv}") ;;
		esac
	done
	UCI_STORE=("${new[@]}")
}

_uci_key() { # build dotted key from up to 3 args
	local k="$1"
	[ -n "$2" ] && k="${k}.$2"
	[ -n "$3" ] && k="${k}.$3"
	printf '%s' "${k}"
}

# --- fixtures (used by tests) ----------------------------------------------
# Declare a config section so config_load will visit it.
uci_fixture_section() { # pkg type name
	UCI_SECTIONS+=("$1|$2|$3")
	_uci_store_set "$1.$3" "$2" # `uci get pkg.section` returns the section type
}

# Set an option value.
uci_fixture_set() { # dotted-key value
	_uci_store_set "$1" "$2"
}

# --- library-facing helpers (mocks of /lib/config/uci.sh) ------------------
uci_get() { # pkg [section] [option] [default]
	local key
	key="$(_uci_key "$1" "$2" "$3")"
	_uci_store_get "${key}" || printf '%s' "${4:-}"
}

uci_set() { # pkg section option value
	_uci_store_set "$1.$2.$3" "$4"
	UCI_CHANGES+=("set $1.$2.$3=$4")
}

uci_remove() { # pkg section [option]
	_uci_store_del "$(_uci_key "$1" "$2" "$3")"
	UCI_CHANGES+=("remove $(_uci_key "$1" "$2" "$3")")
}

uci_commit() { UCI_CHANGES+=("commit $1"); }
uci_add_list() { UCI_CHANGES+=("add_list $1.$2.$3=$4"); }
uci_remove_list() { UCI_CHANGES+=("remove_list $1.$2.$3=$4"); }

# config_load <pkg>: invoke the currently-defined config_cb for each section of
# <pkg>, in declaration order — mirroring /lib/functions.sh behaviour closely
# enough to drive travelmate's count/dedup callbacks.
config_load() {
	local entry pkg="$1" p t n
	for entry in "${UCI_SECTIONS[@]}"; do
		IFS='|' read -r p t n <<<"${entry}"
		# real config_load ignores the callback's exit status; swallow it so a
		# section that doesn't match the cb's predicate doesn't fail the loader
		if [ "${p}" = "${pkg}" ]; then
			config_cb "${t}" "${n}" || true
		fi
	done
	return 0
}
config_cb() { :; } # default no-op; the library redefines it per pass

# `uci` command stub: handles the batch/add/changes/get/set forms travelmate uses.
uci() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		-q | -S) shift ;;
		-c) shift 2 ;;
		*) break ;;
		esac
	done
	case "$1" in
	batch)
		cat >/dev/null # consume the heredoc
		UCI_CHANGES+=("batch")
		;;
	add)
		UCI_ADD_SEQ=$((UCI_ADD_SEQ + 1))
		local id="cfg${UCI_ADD_SEQ}"
		UCI_SECTIONS+=("$2|$3|${id}")
		_uci_store_set "$2.${id}" "$3"
		UCI_CHANGES+=("add $2 $3 -> ${id}")
		printf '%s' "${id}"
		;;
	changes)
		# non-empty output => the caller takes its uci_commit branch
		[ "${UCI_FORCE_CHANGES}" = "1" ] && printf 'changed'
		;;
	get)
		shift
		uci_get "$@"
		;;
	set)
		shift
		UCI_CHANGES+=("set $1")
		;;
	*) : ;;
	esac
}
