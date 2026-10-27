// SPDX-License-Identifier: MIT
'use strict';

import { fail, as_list, q_curly, q_shell } from 'confsh.util';

/*
 * A config is an ordered list of sections:
 *   { id, type, anon, label, opts: { name: string | array } }
 * Anonymous sections are labelled @N, N being the section's index among
 * all sections of its type (the @type[N] index used by `uci show`).
 */
export function load(cur, cfg) {
	let all = cur.get_all(cfg);

	if (!all)
		return null;

	let secs = [];

	for (let id in all)
		push(secs, all[id]);

	sort(secs, (a, b) => a['.index'] - b['.index']);

	let count = {};
	let out = [];

	for (let s in secs) {
		let t = s['.type'];
		let n = count[t] ?? 0;
		let opts = {};

		count[t] = n + 1;

		for (let k in sort(keys(s)))
			if (substr(k, 0, 1) != '.')
				opts[k] = s[k];

		push(out, {
			id: s['.name'],
			type: t,
			anon: s['.anonymous'],
			index: n,
			label: s['.anonymous'] ? `@${n}` : s['.name'],
			opts
		});
	}

	return out;
};

/* @N matches the N-th section of the type, named or not (like uci's @type[N]). */
export function matches(s, stype, label) {
	let m = match(label, /^@([0-9]+)$/);

	return s.type == stype && (m ? s.index == int(m[1]) : s.label == label);
};

export function find(secs, stype, label) {
	for (let s in secs ?? [])
		if (matches(s, stype, label))
			return s;

	return null;
};

export function find_id(secs, id) {
	for (let s in secs ?? [])
		if (s.id == id)
			return s;

	return null;
};

export function is_index(label) {
	return match(label, /^@[0-9]+$/) != null;
};

/* Resolve a section label; null means "named section that does not exist". */
export function lookup(secs, cfg, stype, label) {
	if (is_index(label)) {
		let s = find(secs, stype, label);

		if (!s)
			fail(`Configuration path: [${cfg} ${stype} ${label}] is not valid`);

		return s;
	}

	let s = find_id(secs, label);

	if (s && s.type != stype)
		fail(`Section '${label}' in ${cfg} has type '${s.type}', not '${stype}'`);

	return s;
};

/* Pair committed (old) and working (cur) sections; state is '', '+' or '-'. */
function merge_secs(old, cur) {
	let out = [];

	for (let s in cur ?? []) {
		let o = find_id(old, s.id);

		push(out, { sec: s, old: o, state: o ? '' : '+' });
	}

	for (let o in old ?? [])
		if (!find_id(cur, o.id))
			push(out, { sec: o, old: o, state: '-' });

	return out;
}

function union_keys(a, b) {
	let seen = {};
	let out = [];

	for (let k in [ ...keys(a), ...keys(b) ]) {
		if (!seen[k]) {
			seen[k] = true;
			push(out, k);
		}
	}

	return sort(out);
}

/* [marker, option, value] for every value of a section, by option name. */
function opt_lines(m) {
	let lines = [];

	if (m.state != '') {
		for (let k in sort(keys(m.sec.opts)))
			for (let v in as_list(m.sec.opts[k]))
				push(lines, [ m.state, k, v ]);

		return lines;
	}

	for (let k in union_keys(m.sec.opts, m.old.opts)) {
		let nv = m.sec.opts[k];
		let ov = m.old.opts[k];

		if (type(nv) == 'string' && type(ov) == 'string') {
			push(lines, [ (nv == ov) ? '' : '>', k, nv ]);
			continue;
		}

		let nl = as_list(nv);
		let ol = as_list(ov);

		for (let v in nl)
			push(lines, [ (index(ol, v) >= 0) ? '' : '+', k, v ]);

		for (let v in ol)
			if (index(nl, v) < 0)
				push(lines, [ '-', k, v ]);
	}

	return lines;
}

function pad(depth) {
	let s = '';

	for (let i = 0; i < depth; i++)
		s += '    ';

	return s;
}

/*
 * EdgeOS-style `show`. ctx.get(cfg) returns { old, cur } section lists;
 * with markers, lines are prefixed '+' (added), '-' (removed), '>' (changed)
 * or ' '.
 */
export function show(ctx, words, markers) {
	let out = [];

	function emit(m, depth, text) {
		push(out, (markers ? ((m == '') ? ' ' : m) : '') + pad(depth) + text);
	}

	function emit_section(m, depth, head) {
		emit(m.state, depth, `${head} {`);

		for (let l in opt_lines(m))
			emit(l[0], depth + 1, `${l[1]} ${q_curly(l[2])}`);

		emit(m.state, depth, '}');
	}

	function emit_config(cfg, depth, stype) {
		let pair = ctx.get(cfg);

		for (let m in merge_secs(pair.old, pair.cur)) {
			if (stype != null && m.sec.type != stype)
				continue;

			emit_section(m, depth, (stype != null) ? m.sec.label : `${m.sec.type} ${m.sec.label}`);
		}
	}

	function config_exists(cfg) {
		let pair = ctx.get(cfg);

		if (pair.old == null && pair.cur == null)
			fail(`Configuration path: [${cfg}] is not valid`);
	}

	let n = length(words);

	if (n > 4)
		fail(`Configuration path: [${join(' ', words)}] is not valid`);

	if (n == 0) {
		for (let cfg in ctx.configs) {
			let pair = ctx.get(cfg);

			if (!length(pair.old ?? []) && !length(pair.cur ?? []))
				continue;

			emit('', 0, `${cfg} {`);
			emit_config(cfg, 1, null);
			emit('', 0, '}');
		}
	}
	else if (n <= 2) {
		config_exists(words[0]);
		emit_config(words[0], 0, words[1]);
	}
	else {
		config_exists(words[0]);

		let pair = ctx.get(words[0]);

		for (let m in merge_secs(pair.old, pair.cur)) {
			if (!matches(m.sec, words[1], words[2]))
				continue;

			for (let l in opt_lines(m))
				if (n == 3 || l[1] == words[3])
					emit(l[0], 0, `${l[1]} ${q_curly(l[2])}`);
		}
	}

	if (!length(out))
		print('Configuration under specified path is empty\n');

	for (let line in out)
		print(line, '\n');
};

/* EdgeOS-style `compare`: [edit ...] headers followed by -/+ lines. */
export function compare(ctx, cfgs) {
	let out = [];

	for (let cfg in cfgs) {
		let pair = ctx.get(cfg);

		for (let m in merge_secs(pair.old, pair.cur)) {
			if (m.state != '') {
				push(out, `[edit ${cfg} ${m.sec.type}]`);
				push(out, `${m.state}${m.sec.label} {`);

				for (let l in opt_lines(m))
					push(out, `${m.state}    ${l[1]} ${q_curly(l[2])}`);

				push(out, `${m.state}}`);
				continue;
			}

			let lines = filter(opt_lines(m), l => l[0] != '');

			if (!length(lines))
				continue;

			push(out, `[edit ${cfg} ${m.sec.type} ${m.sec.label}]`);

			for (let l in lines) {
				if (l[0] == '>') {
					push(out, `-${l[1]} ${q_curly(m.old.opts[l[1]])}`);
					push(out, `+${l[1]} ${q_curly(l[2])}`);
				}
				else {
					push(out, `${l[0]}${l[1]} ${q_curly(l[2])}`);
				}
			}
		}
	}

	return out;
};

/* `show configuration commands`: one `set` line per value. */
export function commands(ctx, words) {
	let out = [];
	let cfgs = length(words) ? [ words[0] ] : ctx.configs;

	for (let cfg in cfgs) {
		for (let s in ctx.get(cfg).cur ?? []) {
			if (words[1] != null && s.type != words[1])
				continue;

			if (words[2] != null && !matches(s, words[1], words[2]))
				continue;

			let prefix = `set ${cfg} ${s.type} ${s.label}`;

			if (!length(keys(s.opts)))
				push(out, prefix);

			for (let k in sort(keys(s.opts)))
				for (let v in as_list(s.opts[k]))
					push(out, `${prefix} ${k} ${q_shell(v)}`);
		}
	}

	return out;
};
