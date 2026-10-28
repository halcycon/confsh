// SPDX-License-Identifier: MIT
'use strict';

/*
 * EdgeOS-style paths ("dialects"). Modules in DIR declare grammar subtrees
 * mounted at path prefixes (e.g. 'port-forward', 'interfaces wireguard') and
 * translate parsed commands into UCI. The framework does parsing, value
 * validation, completion, and EdgeOS-style rendering with change markers.
 * See docs/DIALECTS.md for the module API.
 */

import * as fs from 'fs';
import { fail, as_list, q_curly, q_shell, CONFDIR } from 'confsh.util';
import * as tree from 'confsh.tree';

const DIR = getenv('CONFSH_DIALECT_DIR') ?? '/usr/share/ucode/confsh/dialect';

const TYPES = {
	number:  [ /^[0-9]+$/, 'a number' ],
	port:    [ /^[0-9]{1,5}(-[0-9]{1,5})?$/, 'a port or range (80, 8000-8010)' ],
	ipv4:    [ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/, 'an IPv4 address' ],
	ipv4net: [ /^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$/, 'an IPv4 prefix (10.0.0.0/24)' ],
	ipv4match: [ /^!?([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$/, 'an IPv4 address or prefix, optionally negated (!10.0.0.0/8)' ],
	cidr:    [ /^[0-9A-Fa-f:.]+\/[0-9]{1,3}$/, 'an IPv4/IPv6 prefix' ],
	host:    [ /^[A-Za-z0-9.:_-]+$/, 'a hostname or address' ],
	name:    [ /^[A-Za-z0-9_.-]+$/, 'a name (letters, digits, _ . -)' ],
	key:     [ /^[A-Za-z0-9+\/]{42,43}=$/, 'a base64 WireGuard key' ],
	text:    [ /^.*$/, 'text' ]
};

let root;

function mount(mod, path, node) {
	let words = split(path, ' ');
	let n = root;

	for (let i = 0; i < length(words) - 1; i++) {
		n.children[words[i]] ??= { children: {} };
		n = n.children[words[i]];
	}

	node.owner = mod;
	n.children[words[length(words) - 1]] = node;
}

function grammar() {
	if (root)
		return root;

	root = { children: {} };

	for (let f in sort(fs.lsdir(DIR) ?? [])) {
		let m = match(f, /^([A-Za-z0-9_]+)\.uc$/);

		if (!m)
			continue;

		try {
			let mod = require(`confsh.dialect.${m[1]}`);

			for (let path in keys(mod?.mounts ?? {}))
				mount(mod, path, mod.mounts[path]);
		}
		catch (e) {
			warn(`confsh: ignoring dialect module ${f}: ${e.message}\n`);
		}
	}

	return root;
}

/* Distinct modules mounted at or below a grammar node. */
function owners(node) {
	if (node.owner)
		return [ node.owner ];

	let out = [];

	for (let k in keys(node.children ?? {}))
		for (let o in owners(node.children[k]))
			if (index(out, o) < 0)
				push(out, o);

	return out;
}

function check_value(type_or_values, v, what) {
	if (type(type_or_values) == 'array') {
		if (index(type_or_values, v) < 0)
			fail(`Invalid value '${v}' for ${what}: expected one of ${join(', ', type_or_values)}`);

		return;
	}

	let t = TYPES[type_or_values ?? 'text'];

	if (!t || !match(v, t[0]))
		fail(`Invalid value '${v}' for ${what}: expected ${t?.[1] ?? type_or_values}`);
}

/* Firewall zone for a zone name, logical interface or device name. */
function zone_for(cur, name) {
	let fw = tree.load(cur, 'firewall') ?? [];
	let zones = filter(fw, s => s.type == 'zone');

	for (let z in zones)
		if (z.opts.name == name)
			return name;

	let nets = map(filter(tree.load(cur, 'network') ?? [],
		s => s.type == 'interface' && (s.label == name || s.opts.device == name)), s => s.label);

	for (let z in zones)
		for (let n in as_list(z.opts.network))
			if (index(nets, n) >= 0)
				return z.opts.name;

	fail(`Cannot map '${name}' to a firewall zone; use a zone name (${join(', ', map(zones, z => z.opts.name))}), ` +
	     'a network interface or its device');
}

function make_ctx(cur) {
	let touched = {};

	return {
		cur,
		fail,
		touch: (cfg) => { touched[cfg] = true; },
		touched: () => keys(touched),
		sections: (cfg) => tree.load(cur, cfg) ?? [],
		zone_for: (name) => zone_for(cur, name)
	};
}

export function roots() {
	return keys(grammar().children);
};

/* True when the path belongs to a dialect rather than a UCI config. */
export function claims(words) {
	return length(words) > 0 &&
		fs.stat(`${CONFDIR}/${words[0]}`)?.type != 'file' &&
		grammar().children[words[0]] != null;
};

/*
 * Parses a full path. Result: { owner, steps: [{ key, tag? }], node,
 * leaf, leaf_node, value }. steps start at the module's mount word.
 */
function parse(words, allow_value) {
	let node = grammar();
	let owner = null;
	let steps = [];
	let res = { owner: null, steps, node, leaf: null, leaf_node: null, value: null };

	for (let i = 0; i < length(words); i++) {
		let w = words[i];
		let child = node.children?.[w];

		if (!child)
			fail(`Configuration path: [${join(' ', slice(words, 0, i + 1))}] is not valid`);

		if (child.owner) {
			owner = child.owner;
			steps = [];
			res.steps = steps;
		}

		if (child.tag) {
			if (i + 1 >= length(words))
				fail(`Configuration path: [${join(' ', words)}] requires a ${child.tag} after '${w}'`);

			check_value(child.tag, words[++i], w);
			push(steps, { key: w, tag: words[i] });
		}
		else if (child.children) {
			push(steps, { key: w });
		}
		else {
			res.leaf = w;
			res.leaf_node = child;

			if (i + 1 < length(words)) {
				res.value = words[++i];

				if (allow_value)
					check_value(child.values ?? child.type, res.value, w);
			}

			if (i + 1 < length(words))
				fail('Too many arguments: quote values that contain spaces');
		}

		node = child;
	}

	res.owner = owner;
	res.node = node;

	if (!owner)
		fail(`Incomplete path: [${join(' ', words)}]`);

	return res;
}

function run(cur, fn) {
	let ctx = make_ctx(cur);

	fn(ctx);

	for (let cfg in ctx.touched())
		if (!cur.save(cfg))
			fail(`Failed to stage change: ${cur.error()}`);
}

export function set(cur, words) {
	let p = parse(words, true);

	if (p.leaf && p.value == null && !p.leaf_node.flag)
		fail(`Value required for '${p.leaf}'`);

	run(cur, ctx => p.owner.set(ctx, p));
};

export function del(cur, words) {
	let p = parse(words, false);

	run(cur, ctx => p.owner.del(ctx, p));
};

function check_all(cur) {
	let ctx = make_ctx(cur);
	let errors = [];

	for (let mod in owners(grammar()))
		if (mod.check)
			for (let e in mod.check(ctx) ?? [])
				push(errors, e);

	return errors;
}

/*
 * Commit-time validation via each module's check(ctx). Problems already in
 * the committed config are reported separately so they don't block
 * unrelated commits: { errors: [new…], existing: [old…] }.
 */
export function check(working_cur, committed_cur) {
	let before = check_all(committed_cur);
	let after = check_all(working_cur);

	return {
		errors: filter(after, e => index(before, e) < 0),
		existing: filter(after, e => index(before, e) >= 0)
	};
};

/* `edit` into a container; tag nodes are created like `set` would. */
export function edit(cur, words) {
	let p = parse(words, false);

	if (p.leaf)
		fail(`Cannot edit '${p.leaf}': it is a value, use set/delete`);

	run(cur, ctx => p.owner.set(ctx, p));
};

/* ---- rendering ------------------------------------------------------- */

/* Full EdgeOS-style tree: modules return top-level nodes, merged by name. */
function render(cur) {
	let ctx = make_ctx(cur);
	let out = [];

	function merge(list, nodes) {
		for (let n in nodes) {
			let prev = n.children ? filter(list, x => x.name == n.name && x.children)[0] : null;

			if (prev)
				merge(prev.children, n.children);
			else
				push(list, n);
		}
	}

	for (let mod in owners(grammar()))
		merge(out, mod.render(ctx));

	return out;
}

function pad(depth) {
	let s = '';

	for (let i = 0; i < depth; i++)
		s += '    ';

	return s;
}

function value_text(n) {
	if (n.value == null)
		return '';

	return ' ' + q_curly(n.secret && getenv('CONFSH_SHOW_SECRETS') != '1' ? '********' : n.value);
}

function uniq_names(list) {
	let out = [];

	for (let n in list)
		if (index(out, n.name) < 0)
			push(out, n.name);

	return out;
}

/* Names in new order, with removed ones kept at their old position. */
function names(newl, oldl) {
	let nn = uniq_names(newl);
	let on = uniq_names(oldl);
	let out = [];
	let oi = 0;

	for (let n in nn) {
		let pos = index(on, n);

		while (pos >= 0 && oi < pos) {
			if (index(nn, on[oi]) < 0)
				push(out, on[oi]);

			oi++;
		}

		if (pos >= oi)
			oi = pos + 1;

		push(out, n);
	}

	while (oi < length(on)) {
		if (index(nn, on[oi]) < 0)
			push(out, on[oi]);

		oi++;
	}

	return out;
}

function diff(oldl, newl, depth, markers, out) {
	function emit(m, d, text) {
		push(out, (markers ? ((m == '') ? ' ' : m) : '') + pad(d) + text);
	}

	function all(n, m, d) {
		if (n.children) {
			emit(m, d, `${n.name} {`);

			for (let c in n.children)
				all(c, m, d + 1);

			emit(m, d, '}');
		}
		else {
			emit(m, d, n.name + value_text(n));
		}
	}

	for (let name in names(newl, oldl)) {
		let os = filter(oldl, n => n.name == name);
		let ns = filter(newl, n => n.name == name);
		let o = os[0], n = ns[0];

		if ((n ?? o).children) {
			if (n && !o)
				all(n, '+', depth);
			else if (o && !n)
				all(o, '-', depth);
			else {
				emit('', depth, `${name} {`);
				diff(o.children, n.children, depth + 1, markers, out);
				emit('', depth, '}');
			}

			continue;
		}

		if (length(os) == 1 && length(ns) == 1 && o.value != n.value) {
			emit('>', depth, name + value_text(n));
			continue;
		}

		let ov = map(os, x => x.value);
		let nv = map(ns, x => x.value);

		for (let x in ns)
			emit((index(ov, x.value) >= 0) ? '' : '+', depth, name + value_text(x));

		for (let x in os)
			if (index(nv, x.value) < 0)
				emit('-', depth, name + value_text(x));
	}
}

/* Display segments for a path: tag nodes are "key tag". */
function segments(words) {
	let node = grammar();
	let segs = [];

	for (let i = 0; i < length(words); i++) {
		let child = node.children?.[words[i]];

		if (!child)
			fail(`Configuration path: [${join(' ', slice(words, 0, i + 1))}] is not valid`);

		if (child.tag && i + 1 < length(words))
			push(segs, `${words[i]} ${words[++i]}`);
		else
			push(segs, words[i]);

		node = child;
	}

	return segs;
}

/*
 * Nodes at a path: the children of the container it names, or, when it
 * names a value, the matching value nodes. Returns [ nodes, parent_segs ].
 */
function descend(nodes, segs) {
	let list = nodes;

	for (let i = 0; i < length(segs); i++) {
		let hit = filter(list ?? [], n => n.name == segs[i]);

		if (i == length(segs) - 1 && length(hit) && !hit[0].children)
			return [ hit, slice(segs, 0, i) ];

		list = hit[0]?.children;
	}

	return [ list ?? [], segs ];
}

/* EdgeOS-style `show`; old_cur/new_cur may be the same cursor (no markers). */
export function show(old_cur, new_cur, words, markers) {
	let segs = segments(words);
	let out = [];

	diff(descend(render(old_cur), segs)[0], descend(render(new_cur), segs)[0], 0, markers, out);

	if (!length(out))
		print('Configuration under specified path is empty\n');

	for (let line in out)
		print(line, '\n');
};

export function commands(cur, words) {
	let out = [];

	function walk(n, prefix) {
		let path = `${prefix} ${n.name}`;

		if (n.children) {
			if (!length(n.children))
				push(out, `set${path}`);

			for (let c in n.children)
				walk(c, path);
		}
		else {
			let v = (n.value == null) ? '' :
				' ' + q_shell(n.secret && getenv('CONFSH_SHOW_SECRETS') != '1' ? '********' : n.value);

			push(out, `set${path}${v}`);
		}
	}

	let r = descend(render(cur), segments(words));

	for (let n in r[0])
		walk(n, length(r[1]) ? ` ${join(' ', r[1])}` : '');

	return out;
};

/* ---- completion ------------------------------------------------------ */

function uniq(list) {
	let out = [];

	for (let v in list ?? [])
		if (index(out, v) < 0)
			push(out, v);

	return out;
}

function complete_raw(words, cur) {
	let node = grammar();
	let owner = null;
	let steps = [];
	let ctx = make_ctx(cur);

	for (let i = 0; i < length(words); i++) {
		let w = words[i];
		let child = node.children?.[w];

		if (!child)
			return [];

		if (child.owner) {
			owner = child.owner;
			steps = [];
		}

		if (child.tag) {
			if (i + 1 == length(words))
				return owner?.tags ? owner.tags(ctx, steps, w) : [];

			push(steps, { key: w, tag: words[++i] });
		}
		else if (child.children) {
			push(steps, { key: w });
		}
		else {
			if (i + 1 < length(words))
				return [];

			return child.values ?? (owner?.suggest ? owner.suggest(ctx, steps, w) : []);
		}

		node = child;
	}

	return sort(keys(node.children ?? {}));
}

export function complete(words, cur_word, cur) {
	return uniq(complete_raw(words, cur));
};
