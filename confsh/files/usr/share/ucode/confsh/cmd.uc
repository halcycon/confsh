// SPDX-License-Identifier: GPL-2.0-only
'use strict';

import * as fs from 'fs';
import {
	fail, startswith, as_list, hint, valid_name, valid_type, config_stamps,
	uci_cli_pending, mkdir_p, rm_rf, read_json, write_json, reload, user,
	CONFDIR, RUNDIR
} from 'confsh.util';
import * as tree from 'confsh.tree';
import * as archive from 'confsh.archive';
import * as complete from 'confsh.complete';

let uci = require('uci');

const SESSIONS = `${RUNDIR}/sessions`;

/* ---- sessions -------------------------------------------------------- */

function session(required) {
	let s = getenv('CONFSH_SESSION');

	if (s && startswith(s, `${SESSIONS}/`) && fs.stat(`${s}/delta`)?.type == 'directory')
		return s;

	if (required)
		fail("Not in configuration mode (type 'configure' first)");

	return null;
}

function level() {
	let l = trim(getenv('CONFSH_EDIT') ?? '');

	return (l == '') ? [] : split(l, / +/);
}

function working(s) {
	return uci.cursor(null, `${s}/delta`);
}

function committed() {
	mkdir_p(`${RUNDIR}/empty`);

	return uci.cursor(null, `${RUNDIR}/empty`);
}

function config_names() {
	return sort(filter(fs.lsdir(CONFDIR) ?? [],
		n => substr(n, 0, 1) != '.' && fs.stat(`${CONFDIR}/${n}`)?.type == 'file'));
}

function view(old_cur, new_cur) {
	let cache = {};

	return {
		configs: config_names(),
		get: function(cfg) {
			if (!cache[cfg])
				cache[cfg] = {
					old: tree.load(old_cur, cfg),
					cur: tree.load(new_cur, cfg)
				};

			return cache[cfg];
		}
	};
}

/* cursor.changes() would also include /tmp/.uci, so read the session's own deltas. */
function changed_configs(s) {
	let dir = `${s}/delta`;

	return sort(filter(fs.lsdir(dir) ?? [], n => (fs.stat(`${dir}/${n}`)?.size ?? 0) > 0));
}

function cmd_session_new(args) {
	let pid = args[0] ?? '';

	if (!match(pid, /^[0-9]+$/))
		fail('usage: session-new <pid>');

	mkdir_p(SESSIONS);

	for (let d in fs.lsdir(SESSIONS) ?? [])
		if (!fs.stat(`/proc/${d}`))
			rm_rf(`${SESSIONS}/${d}`);

	let dir = `${SESSIONS}/${pid}`;

	rm_rf(dir);
	mkdir_p(`${dir}/delta`);
	write_json(`${dir}/meta.json`, { created: time(), user: user(), stamps: config_stamps() });

	let cli = uci_cli_pending();

	if (length(cli))
		warn(`Warning: uncommitted 'uci' changes exist for ${join(', ', cli)} ('uci changes').\n` +
		     "They show up here and would be committed along with your changes to the same config.\n");

	print(dir, '\n');

	return 0;
}

function cmd_session_end() {
	let s = session(false);

	if (s)
		rm_rf(s);

	return 0;
}

/* ---- path handling --------------------------------------------------- */

function check_config(cfg) {
	if (!valid_name(cfg) || fs.stat(`${CONFDIR}/${cfg}`)?.type != 'file')
		fail(`Configuration path: [${cfg}] is not valid`);
}

function check_path(w) {
	check_config(w[0]);

	if (length(w) > 1 && !valid_type(w[1]))
		fail(`Invalid section type '${w[1]}'`);

	if (length(w) > 2 && !tree.is_index(w[2]) && !valid_name(w[2]))
		fail(`Invalid section name '${w[2]}' (use letters, digits and _)`);

	if (length(w) > 3 && !valid_name(w[3]))
		fail(`Invalid option name '${w[3]}'`);
}

/* Section for w[0..2], creating a named section when allowed. */
function section_for(cur, w, create) {
	let secs = tree.load(cur, w[0]) ?? [];
	let sec = tree.lookup(secs, w[0], w[1], w[2]);

	if (sec)
		return sec.id;

	if (!create)
		fail(`Configuration path: [${join(' ', w)}] is not valid`);

	cur.set(w[0], w[2], w[1]);

	return w[2];
}

/* ---- configuration mode ---------------------------------------------- */

function cmd_set(args) {
	let s = session(true);
	let w = [ ...level(), ...args ];
	let n = length(w);

	if (n < 3)
		fail('Incomplete path: set <config> <section-type> <section> [<option> <value>]');

	if (n > 5)
		fail('Too many arguments: quote values that contain spaces');

	check_path(w);

	let cur = working(s);
	let id = section_for(cur, w, true);

	if (n >= 4) {
		let cfg = w[0], opt = w[3];
		let h = hint(cfg, w[1], opt);
		let val = w[4];

		if (val == null) {
			if (h?.type != 'bool')
				fail(`Value required for option '${opt}'`);

			val = '1';
		}

		if (h?.strict && h?.values && index(h.values, val) < 0)
			fail(`Invalid value '${val}' for '${opt}': expected one of ${join(', ', h.values)}`);

		let old = cur.get(cfg, id, opt);

		if (type(old) == 'array' || h?.list) {
			let items = as_list(old);

			if (index(items, val) < 0) {
				if (type(old) == 'array')
					cur.list_append(cfg, id, opt, val);
				else
					cur.set(cfg, id, opt, [ ...items, val ]);
			}
		}
		else {
			cur.set(cfg, id, opt, val);
		}
	}

	if (!cur.save(w[0]))
		fail(`Failed to stage change: ${cur.error()}`);

	return 0;
}

function cmd_delete(args) {
	let s = session(true);
	let w = [ ...level(), ...args ];
	let n = length(w);

	if (n == 0)
		fail('Incomplete path: delete <config> <section-type> [<section> [<option> [<value>]]]');

	if (n == 1)
		fail(`Refusing to delete all of '${w[0]}'; delete section types or sections instead`);

	if (n > 5)
		fail('Too many arguments: quote values that contain spaces');

	check_path(w);

	let cfg = w[0];
	let cur = working(s);
	let secs = tree.load(cur, cfg) ?? [];

	if (n == 2) {
		let ids = map(filter(secs, x => x.type == w[1]), x => x.id);

		if (!length(ids))
			fail(`Nothing to delete: no '${w[1]}' sections in ${cfg}`);

		for (let id in ids)
			cur.delete(cfg, id);
	}
	else {
		let sec = tree.lookup(secs, cfg, w[1], w[2]);

		if (!sec)
			fail(`Nothing to delete: [${join(' ', slice(w, 0, 3))}] does not exist`);

		if (n == 3) {
			cur.delete(cfg, sec.id);
		}
		else {
			let opt = w[3];
			let old = sec.opts[opt];

			if (old == null)
				fail(`Nothing to delete: option '${opt}' is not set`);

			if (n == 4) {
				cur.delete(cfg, sec.id, opt);
			}
			else {
				let items = as_list(old);

				if (index(items, w[4]) < 0)
					fail(`Nothing to delete: '${opt}' does not contain '${w[4]}'`);

				if (length(items) == 1)
					cur.delete(cfg, sec.id, opt);
				else
					cur.list_remove(cfg, sec.id, opt, w[4]);
			}
		}
	}

	if (!cur.save(cfg))
		fail(`Failed to stage change: ${cur.error()}`);

	return 0;
}

function cmd_edit(args) {
	let s = session(true);
	let w = [ ...level(), ...args ];

	if (length(w) > 3)
		fail('Cannot edit below section level; use set/delete for options');

	if (length(w) > 0)
		check_path(w);

	if (length(w) == 3) {
		let cur = working(s);
		let id = section_for(cur, w, !tree.is_index(w[2]));

		if (id == w[2] && !cur.save(w[0]))
			fail(`Failed to stage change: ${cur.error()}`);
	}

	print(join(' ', w), '\n');

	return 0;
}

function cmd_show(args) {
	let s = session(true);

	tree.show(view(committed(), working(s)), [ ...level(), ...args ], true);

	return 0;
}

function cmd_compare() {
	let s = session(true);
	let out = tree.compare(view(committed(), working(s)), changed_configs(s));

	if (!length(out))
		print('No changes between working and active configurations\n');

	for (let line in out)
		print(line, '\n');

	return 0;
}

function cmd_pending() {
	return length(changed_configs(session(true))) ? 0 : 1;
}

function cmd_discard() {
	let s = session(true);

	if (!length(changed_configs(s))) {
		print('No changes have been discarded\n');
		return 0;
	}

	rm_rf(`${s}/delta`);
	mkdir_p(`${s}/delta`);
	print('Changes have been discarded\n');

	return 0;
}

function parse_commit_args(args, with_minutes) {
	let o = { force: false, comment: null, minutes: null };

	for (let i = 0; i < length(args); i++) {
		let a = args[i];

		if (a == 'force') {
			o.force = true;
		}
		else if (a == 'comment') {
			o.comment = join(' ', slice(args, i + 1));

			if (o.comment == '')
				fail('comment: text required');

			break;
		}
		else if (with_minutes && o.minutes == null && match(a, /^[0-9]+$/)) {
			o.minutes = int(a);
		}
		else {
			fail(`Unexpected argument '${a}'`);
		}
	}

	return o;
}

function do_commit(s, o, via) {
	let cfgs = changed_configs(s);
	let meta = read_json(`${s}/meta.json`, {});
	let now = config_stamps();

	if (!o.force) {
		let stale = filter(cfgs, c => meta.stamps?.[c] != null && meta.stamps[c] != now[c]);

		if (length(stale))
			fail(`Commit refused: ${join(', ', stale)} changed outside this session since 'configure'.\n` +
			     "Use 'discard' and re-apply, or 'commit force' to apply your changes on top.");

		let cli = filter(uci_cli_pending(), c => index(cfgs, c) >= 0);

		if (length(cli))
			fail(`Commit refused: uncommitted 'uci' changes for ${join(', ', cli)} would be committed too.\n` +
			     `Run 'uci commit' or 'uci revert' for ${join(', ', cli)} first, or 'commit force' to include them.`);
	}

	archive.ensure_baseline();

	let cur = working(s);

	for (let c in cfgs) {
		cur.load(c);

		if (!cur.commit(c))
			fail(`Commit failed for ${c}: ${cur.error()}`);
	}

	reload();
	archive.add(o.comment, via);

	meta.stamps = config_stamps();
	write_json(`${s}/meta.json`, meta);
}

function refuse_if_confirm_pending() {
	if (archive.confirm_pending())
		fail("A commit-confirm is pending: type 'confirm' to keep it before committing again");
}

function cmd_commit(args) {
	let s = session(true);
	let o = parse_commit_args(args, false);

	refuse_if_confirm_pending();

	if (!length(changed_configs(s))) {
		print('No configuration changes to commit\n');
		return 0;
	}

	do_commit(s, o, 'cli');

	return 0;
}

function cmd_commit_confirm(args) {
	let s = session(true);
	let o = parse_commit_args(args, true);
	let minutes = o.minutes ?? archive.settings().confirm_minutes;

	if (minutes < 1 || minutes > 1440)
		fail('commit-confirm: minutes must be between 1 and 1440');

	refuse_if_confirm_pending();

	if (!length(changed_configs(s))) {
		print('No configuration changes to commit\n');
		return 0;
	}

	archive.confirm_prepare();
	do_commit(s, o, 'commit-confirm');
	archive.confirm_arm(minutes);

	printf("commit-confirm: changes will be reverted in %d minute%s unless you type 'confirm'\n",
		minutes, (minutes == 1) ? '' : 's');

	return 0;
}

function cmd_confirm() {
	archive.confirm();
	print('Commit confirmed\n');

	return 0;
}

function cmd_rollback_check(args) {
	let s = session(true);

	if (length(changed_configs(s)))
		fail("Uncommitted changes exist: 'commit' or 'discard' them before rolling back");

	refuse_if_confirm_pending();
	archive.check_revision(args[0]);

	return 0;
}

function cmd_rollback(args) {
	cmd_rollback_check(args);
	archive.rollback(args[0]);

	let s = session(true);
	let meta = read_json(`${s}/meta.json`, {});

	meta.stamps = config_stamps();
	write_json(`${s}/meta.json`, meta);

	return 0;
}

function cmd_save(args) {
	if (length(args))
		fail('save <file> is not supported yet');

	print("UCI 'commit' already saves to flash; nothing else to save\n");

	return 0;
}

/* ---- operational mode ------------------------------------------------ */

function cmd_show_config(args) {
	let c = committed();
	let v = view(c, c);

	if (args[0] == 'commands') {
		for (let line in tree.commands(v, slice(args, 1)))
			print(line, '\n');
	}
	else {
		tree.show(v, args, false);
	}

	return 0;
}

function op_entries(node) {
	return sort(filter(fs.lsdir(node) ?? [], n => substr(n, 0, 1) != '.'));
}

/* Walks the op tree: `show ip route x` runs op/show/ip/route with args [x]. */
function cmd_op(args) {
	let node = complete.OPDIR;
	let i = 0;

	while (i < length(args)) {
		let w = args[i];

		if (substr(w, 0, 1) == '.' || index(w, '/') >= 0)
			break;

		let st = fs.stat(`${node}/${w}`);

		if (!st)
			break;

		node = `${node}/${w}`;
		i++;

		if (st.type != 'directory')
			break;
	}

	if (fs.stat(node)?.type == 'directory') {
		if (fs.access(`${node}/.run`, 'x')) {
			node = `${node}/.run`;
		}
		else {
			if (i < length(args))
				fail(`Invalid command: ${join(' ', slice(args, 0, i + 1))}`);

			print('Possible completions:\n');

			for (let e in op_entries(node))
				printf('  %s\n', e);

			return 1;
		}
	}

	return system([ node, ...slice(args, i) ]);
}

function cmd_complete(args) {
	let ctx = args[0];
	let words = slice(args, 1, -1);
	let cur = args[length(args) - 1] ?? '';
	let cand = [];

	if (ctx == 'op-show')
		cand = complete.op_path([ 'show', ...words ], cur);
	else if (ctx == 'run')
		cand = complete.op_path(words, cur);
	else if (ctx == 'rollback') {
		for (let i = 1; i < length(archive.list()); i++)
			push(cand, `${i}`);
	}
	else if (index([ 'set', 'delete', 'edit', 'show' ], ctx) >= 0) {
		let s = session(false);

		if (s)
			cand = complete.config_path(ctx, [ ...level(), ...words ], cur, working(s));
	}

	for (let c in cand)
		if (startswith(c, cur))
			print(c, '\n');

	return 0;
}

/* ---- dispatch -------------------------------------------------------- */

const COMMANDS = {
	'session-new': cmd_session_new,
	'session-end': cmd_session_end,
	'set': cmd_set,
	'delete': cmd_delete,
	'edit': cmd_edit,
	'show': cmd_show,
	'compare': cmd_compare,
	'pending': cmd_pending,
	'discard': cmd_discard,
	'commit': cmd_commit,
	'commit-confirm': cmd_commit_confirm,
	'confirm': cmd_confirm,
	'rollback-check': cmd_rollback_check,
	'rollback': cmd_rollback,
	'save': cmd_save,
	'show-config': cmd_show_config,
	'show-commits': () => { archive.print_list(); return 0; },
	'op': cmd_op,
	'complete': cmd_complete,
	'confirm-timeout': (args) => { archive.confirm_timeout(args[0]); return 0; },
	'confirm-boot': () => { archive.confirm_boot(); return 0; }
};

export function main(argv) {
	let fn = COMMANDS[argv[0]];

	if (!fn)
		fail(`confsh backend: unknown command '${argv[0] ?? ''}'`);

	return fn(slice(argv, 1)) ?? 0;
};
