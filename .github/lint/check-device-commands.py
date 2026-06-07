#!/usr/bin/env python3
"""Flag direct command invocations that are absent from the OpenWrt target.

travelmate is a pure-shell, noarch package that runs under busybox `ash` on the
router. Most external tools are resolved through `f_cmd <name>` (a `command -v`
wrapper that fails loudly when a tool is missing), but a command called directly
-- not via f_cmd, not a shell builtin/keyword, not a sourced function -- is only
as portable as the host it was written on. The motivating bug: an LAA-MAC
generator used `od`, which exists on every developer's machine but is NOT a
busybox applet on the device, so it silently produced a constant MAC at runtime.
shellcheck cannot catch this (it is disabled in these files, and would not flag a
missing applet anyway); `busybox ash -n` only checks syntax. This does.

How it works: a small quote/heredoc/case-aware tokenizer extracts every word in
shell *command position*, then reports any that is not

  * a busybox applet or base/dependency command (busybox-applets.txt +
    openwrt-base.txt -- the stock "OpenWrt + travelmate" command surface), nor
  * a shell keyword or builtin, nor
  * a function defined in the file or pulled in by sourcing /lib/functions.sh,
    /lib/functions/network.sh, jshn.sh (uci_*/config_*/json_*/network_*), nor
  * one of travelmate's own f_* functions.

Usage:
  check-device-commands.py [--allow LIST]... FILE...
If no --allow is given, busybox-applets.txt and openwrt-base.txt next to this
script are used. Exit status is non-zero if any offending command is found.
"""
import os
import re
import sys

# Shell keywords / reserved words (command position but not commands).
KEYWORDS = {
    "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "in", "function", "select", "time", "{", "}", "!", "[[", "]]",
}
# POSIX / ash special builtins + common builtins (always available in the shell).
BUILTINS = {
    ".", ":", "source", "alias", "unalias", "bg", "fg", "jobs", "break", "continue",
    "cd", "command", "type", "hash", "eval", "exec", "exit", "export", "getopts",
    "local", "read", "readonly", "return", "set", "shift", "test", "times", "trap",
    "ulimit", "umask", "unset", "wait", "printf", "echo", "pwd", "true", "false",
    "kill", "let",
}
# Function-name prefixes that are defined elsewhere and legitimately called:
#   f_*                          travelmate's own functions (functions.sh), also
#                                called from the sourced *.login scripts
#   uci_/config_/json_/network_  pulled in by sourcing /lib/functions.sh,
#                                /lib/functions/network.sh and jshn.sh
SOURCED_PREFIXES = ("f_", "uci_", "config_", "json_", "network_")
# Specific base shell functions (no common prefix) from the sourced libraries.
SOURCED_FUNCS = {
    "config_get", "config_get_bool", "config_set", "config_list_foreach",
    "append", "list_contains", "default_postinst", "default_prerm",
    "insert_modules", "find_mtd_part", "find_mtd_index", "board_name",
}

WORD_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_./-]*$")
FUNCDEF_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)")


def collect_funcdefs(text):
    """Return the set of `name()` function definitions in the file."""
    defs = set()
    for line in text.splitlines():
        m = FUNCDEF_RE.match(line)
        if m:
            defs.add(m.group(1))
    return defs


def skip_param_expansion(text, i):
    """Given text[i:i+2] == '${', return the index just past the matching '}'.
    Treats the whole ${...} as opaque so neither a default like ${foo:-"-"} nor
    a pattern like ${raw#*\\{} (escaped brace) desyncs the surrounding state.
    Honours backslash escapes and single/double-quoted regions when matching."""
    n = len(text)
    depth = 0
    j = i + 1            # at '{'
    while j < n:
        ch = text[j]
        if ch == "\\":
            j += 2
            continue
        if ch == "'":
            j += 1
            while j < n and text[j] != "'":
                j += 1
            j += 1
            continue
        if ch == '"':
            j += 1
            while j < n and text[j] != '"':
                if text[j] == "\\":
                    j += 1
                j += 1
            j += 1
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return n


_WORD_STOP = " \t\n;&|()<>{}'\"`#$"


def skip_case_pattern(text, i):
    """From the start of a case pattern, return the index just past the ')'
    that ends it. Honours quotes; pattern alternatives (a|b) end at the ')'."""
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "'":
            i += 1
            while i < n and text[i] != "'":
                i += 1
            i += 1
            continue
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if ch == ")":
            return i + 1
        i += 1
    return n


def tokenize_commands(text):
    """Yield (lineno, word) for every word in shell *command position*.

    Tracks single/double quotes, ${...} parameter expansions, $((...))
    arithmetic, $(...) / (...) nesting (via a context stack, so "$(cmd ...)"
    is parsed in its own unquoted context), heredoc bodies (skipped as data)
    and case patterns (which are not commands).
    """
    out = []
    i, n = 0, len(text)
    line = 1
    in_sq = in_dq = False
    expect_cmd = True          # start of input is a command position
    stack = []                 # (kind, saved_in_sq, saved_in_dq); kind: sub/group/arith
    pending_heredocs = []      # [(delimiter, strip_leading_tabs), ...] FIFO
    case_stack = []            # per-nested-case state: "await_in" | "body"
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            if pending_heredocs and not in_sq and not in_dq:
                for delim, strip_tabs in pending_heredocs:
                    while i < n:
                        nl = text.find("\n", i)
                        end = n if nl == -1 else nl
                        body = text[i:end]
                        i = n if nl == -1 else nl + 1
                        line += 1
                        if (body.lstrip("\t") if strip_tabs else body) == delim:
                            break
                pending_heredocs = []
            if not in_sq and not in_dq:
                expect_cmd = True
            continue
        # --- single quotes: everything literal until the next ' ---
        if in_sq:
            if c == "'":
                in_sq = False
            i += 1
            continue
        # --- backslash escape (outside single quotes) ---
        if c == "\\":
            i += 2
            continue
        # --- arithmetic context: skip until matching )) ---
        if stack and stack[-1][0] == "arith":
            if c == ")" and i + 1 < n and text[i + 1] == ")":
                _, in_sq, in_dq = stack.pop()
                i += 2
                continue
            i += 1
            continue
        # --- $(...) command substitution opens a fresh context (even in dq) ---
        if c == "$" and i + 1 < n and text[i + 1] == "(":
            if i + 2 < n and text[i + 2] == "(":
                stack.append(("arith", in_sq, in_dq))
                i += 3
                continue
            stack.append(("sub", in_sq, in_dq))
            in_sq = in_dq = False
            expect_cmd = True
            i += 2
            continue
        # --- ${...} parameter expansion: opaque region ---
        if c == "$" and i + 1 < n and text[i + 1] == "{":
            i = skip_param_expansion(text, i)
            expect_cmd = False     # an expansion fills the command slot
            continue
        # --- inside double quotes: literal except the cases handled above ---
        if in_dq:
            if c == '"':
                in_dq = False
            i += 1
            continue
        # --- normal (unquoted) state ---
        if c == "$":               # $var fills the command slot
            expect_cmd = False
            i += 1
            continue
        if c == "'":
            in_sq = True
            expect_cmd = False     # a quoted word fills the command slot
            i += 1
            continue
        if c == '"':
            in_dq = True
            expect_cmd = False
            i += 1
            continue
        # --- heredoc: skip the body so its data lines aren't parsed as shell ---
        if c == "<" and i + 1 < n and text[i + 1] == "<":
            if i + 2 < n and text[i + 2] == "<":   # <<< here-string, not a heredoc
                i += 3
                continue
            j = i + 2
            strip_tabs = False
            if j < n and text[j] == "-":
                strip_tabs = True
                j += 1
            while j < n and text[j] in " \t":
                j += 1
            if j < n and text[j] in "'\"":         # quoted delimiter
                q = text[j]
                j += 1
                start = j
                while j < n and text[j] != q:
                    j += 1
                delim = text[start:j]
                j += 1
            else:                                  # bare delimiter
                start = j
                while j < n and text[j] not in _WORD_STOP:
                    j += 1
                delim = text[start:j]
            if delim:
                pending_heredocs.append((delim, strip_tabs))
            i = j
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            while i < n and text[i] != "\n":   # comment to end of line
                i += 1
            continue
        if c == "(":           # subshell / grouping
            stack.append(("group", in_sq, in_dq))
            expect_cmd = True
            i += 1
            continue
        if c == ")":           # close subshell or command substitution
            if stack:
                _, in_sq, in_dq = stack.pop()
            expect_cmd = False
            i += 1
            continue
        if c == ";" and i + 1 < n and text[i + 1] == ";":   # ;; ends a case body
            if case_stack and case_stack[-1] == "body":
                i += 2
                while i < n and text[i] in " \t\n":
                    if text[i] == "\n":
                        line += 1
                    i += 1
                if i < n and text[i:i + 4] != "esac":
                    i = skip_case_pattern(text, i)   # next pattern -> body
                expect_cmd = True
                continue
            i += 2
            expect_cmd = True
            continue
        if c in "|&;`":        # command-position-introducing operators
            expect_cmd = True
            i += 1
            continue
        if c in " \t":
            i += 1
            continue
        if c in "<>":          # redirections: not a command intro
            i += 1
            continue
        if c == "{":           # brace group
            expect_cmd = True
            i += 1
            continue
        if c == "}":
            i += 1
            continue
        # a real (non-operator) character
        if expect_cmd:
            j = i
            while j < n and text[j] not in _WORD_STOP:
                j += 1
            if j == i:         # operator char; never stall
                i += 1
                continue
            word = text[i:j]
            # --- case-statement bookkeeping: patterns are not commands ---
            if word == "case":
                case_stack.append("await_in")
                expect_cmd = False
                i = j
                continue
            if word == "esac" and case_stack:
                case_stack.pop()
                expect_cmd = False
                i = j
                continue
            if word == "in" and case_stack and case_stack[-1] == "await_in":
                i = _enter_case_body(text, j, case_stack)
                line += text.count("\n", j, i)
                expect_cmd = True
                continue
            out.append((line, word))
            expect_cmd = False
            i = j
            continue
        # mid-command token: skip to next whitespace/operator
        j = i
        while j < n and text[j] not in _WORD_STOP:
            j += 1
        if j == i:
            i += 1
            continue
        # the `in` of `case WORD in` arrives here (WORD cleared expect_cmd)
        if text[i:j] == "in" and case_stack and case_stack[-1] == "await_in":
            new_i = _enter_case_body(text, j, case_stack)
            line += text.count("\n", j, new_i)
            i = new_i
            expect_cmd = True
            continue
        i = j
    return out


def _enter_case_body(text, j, case_stack):
    """At the `in` of a case: skip whitespace and the first pattern, set body."""
    n = len(text)
    case_stack[-1] = "body"
    k = j
    while k < n and text[k] in " \t\n":
        k += 1
    if k < n and text[k:k + 4] != "esac":
        k = skip_case_pattern(text, k)
    return k


def load_allowlist(paths):
    allow = set()
    for p in paths:
        with open(p) as fh:
            for ln in fh:
                ln = ln.split("#", 1)[0].strip()
                if ln:
                    allow.add(ln)
    return allow


def main(argv):
    allow_files, files = [], []
    k = 0
    while k < len(argv):
        if argv[k] == "--allow":
            allow_files.append(argv[k + 1])
            k += 2
        else:
            files.append(argv[k])
            k += 1
    if not allow_files:
        here = os.path.dirname(os.path.abspath(__file__))
        allow_files = [os.path.join(here, "busybox-applets.txt"),
                       os.path.join(here, "openwrt-base.txt")]
    allowlist = load_allowlist(allow_files)

    rc = 0
    for path in files:
        with open(path) as fh:
            text = fh.read()
        funcdefs = collect_funcdefs(text)
        for lineno, word in tokenize_commands(text):
            if word in KEYWORDS or word in BUILTINS:
                continue
            if "=" in word:                    # assignment, e.g. foo=bar
                continue
            if not WORD_RE.match(word):         # variables, redirs, numbers, globs
                continue
            if word in funcdefs or word in SOURCED_FUNCS:
                continue
            if word.startswith(SOURCED_PREFIXES):
                continue
            if word in allowlist:
                continue
            print(f"{path}:{lineno}: '{word}' is not a busybox applet, base/dep "
                  f"command, or known function -- it may be absent on the device. "
                  f"Resolve it via f_cmd or add it to .github/lint/openwrt-base.txt "
                  f"if it is genuinely present on the target.")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
