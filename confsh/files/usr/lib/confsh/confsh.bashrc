# SPDX-License-Identifier: GPL-2.0-only
# shellcheck shell=bash
#
# confsh: EdgeOS/Vyatta-style configuration shell for OpenWrt UCI.
# Sourced by /usr/bin/confsh. Config-mode commands are shell functions
# that only exist between `configure` and `exit`, because `set` shadows
# the bash builtin.

CONFSH_BACKEND=${CONFSH_BACKEND:-/usr/libexec/confsh/backend}
export CONFSH_BACKEND

_confsh_cfg_cmds=(set delete edit up top compare discard commit commit-confirm
	confirm rollback save run exit)

_confsh_be() {
	"$CONFSH_BACKEND" "$@"
}

_confsh_prompt() {
	if [ -n "${CONFSH_SESSION:-}" ]; then
		PS1="[edit${CONFSH_EDIT:+ $CONFSH_EDIT}]\n\\u@\\h# "
	else
		PS1='\u@\h:\w$ '
	fi
}

# Operational mode `show`; replaced by the config-tree `show` in config mode.
_confsh_op_show() {
	_confsh_be op show "$@"
}

show() {
	_confsh_op_show "$@"
}

_confsh_cfg_on() {
	set() { _confsh_be set "$@"; }
	delete() { _confsh_be delete "$@"; }
	show() { _confsh_be show "$@"; }
	compare() { _confsh_be compare "$@"; }
	discard() { _confsh_be discard "$@"; }
	commit() { _confsh_be commit "$@"; }
	commit-confirm() { _confsh_be commit-confirm "$@"; }
	confirm() { _confsh_be confirm "$@"; }
	save() { _confsh_be save "$@"; }

	edit() {
		local l
		l=$(_confsh_be edit "$@") || return
		CONFSH_EDIT=$l
		_confsh_prompt
	}

	up() {
		if [[ $CONFSH_EDIT == *' '* ]]; then
			CONFSH_EDIT=${CONFSH_EDIT% *}
		else
			CONFSH_EDIT=
		fi
		_confsh_prompt
	}

	top() {
		CONFSH_EDIT=
		_confsh_prompt
	}

	run() {
		case ${1:-} in
		'') echo "Usage: run <operational command>" >&2; return 1 ;;
		show) shift; _confsh_op_show "$@" ;;
		*) command "$@" ;;
		esac
	}

	rollback() {
		local a
		if [ $# -ne 1 ]; then
			echo "Usage: rollback <revision>" >&2
			return 1
		fi
		_confsh_be rollback-check "$1" || return
		a=y
		if [ -t 0 ]; then
			read -r -p "Proceed with rollback to revision $1? [y/N] " a
		fi
		case $a in
		[yY]*) _confsh_be rollback "$1" ;;
		*) echo "Rollback aborted"; return 1 ;;
		esac
	}

	exit() {
		if [ "${1:-}" = discard ]; then
			_confsh_be discard >/dev/null
		elif _confsh_be pending; then
			echo "Cannot exit: configuration modified." >&2
			echo "Use 'exit discard' to discard the changes and exit." >&2
			return 1
		fi
		_confsh_cfg_off
	}
}

_confsh_cfg_off() {
	_confsh_be session-end
	unset -f "${_confsh_cfg_cmds[@]}"
	unset CONFSH_SESSION CONFSH_EDIT
	show() { _confsh_op_show "$@"; }
	_confsh_prompt
}

configure() {
	local s
	if [ -n "${CONFSH_SESSION:-}" ]; then
		echo "Already in configuration mode" >&2
		return 1
	fi
	s=$(_confsh_be session-new "$$") || return
	export CONFSH_SESSION=$s CONFSH_EDIT=
	_confsh_cfg_on
	_confsh_prompt
}

_confsh_complete() {
	local ctx=$1
	local -a words=("${COMP_WORDS[@]:1:COMP_CWORD-1}")

	case $ctx in
	show) [ -n "${CONFSH_SESSION:-}" ] || ctx=op-show ;;
	esac

	mapfile -t COMPREPLY < <(_confsh_be complete "$ctx" "${words[@]}" "${COMP_WORDS[COMP_CWORD]}" 2>/dev/null)
}

trap '[ -n "${CONFSH_SESSION:-}" ] && _confsh_be session-end' EXIT

if [[ $- == *i* ]]; then
	# `!` in values (passwords, descriptions) must not trigger history expansion.
	set +H
	complete -F _confsh_complete set delete edit show run rollback
	_confsh_prompt
	echo "confsh: 'configure' enters configuration mode; 'show <Tab>' lists status commands."
fi
