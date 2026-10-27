// SPDX-License-Identifier: MIT
'use strict';

import * as fs from 'fs';
import { startswith, as_list, schema, type_hints, is_secret, CONFDIR } from 'confsh.util';
import * as tree from 'confsh.tree';

export const OPDIR = getenv('CONFSH_OPDIR') ?? '/usr/libexec/confsh/op';

function visible(name) {
	return substr(name, 0, 1) != '.';
}

function finish(cand, cur) {
	let seen = {};
	let out = [];

	for (let c in cand) {
		if (c != null && !seen[c] && startswith(c, cur)) {
			seen[c] = true;
			push(out, c);
		}
	}

	return sort(out);
}

/* Candidates for the next word of a config path (words = level + typed). */
export function config_path(cmd, words, cur, working) {
	let d = length(words);
	let cand = [];

	if (d == 0)
		return finish(filter(fs.lsdir(CONFDIR) ?? [], visible), cur);

	let cfg = words[0];
	let secs = tree.load(working, cfg) ?? [];
	let sch = schema()[cfg] ?? {};

	if (d == 1) {
		for (let s in secs)
			push(cand, s.type);

		if (cmd == 'set' || cmd == 'edit')
			for (let t in keys(sch))
				if (index(t, '*') < 0)
					push(cand, t);
	}
	else if (d == 2) {
		for (let s in secs)
			if (s.type == words[1])
				push(cand, s.label);
	}
	else if (cmd != 'edit') {
		let sec = tree.find(secs, words[1], words[2]);
		let opts = sec?.opts ?? {};
		let tsch = type_hints(cfg, words[1]) ?? {};

		if (d == 3) {
			for (let k in keys(opts))
				push(cand, k);

			if (cmd == 'set')
				for (let k in keys(tsch))
					push(cand, k);
		}
		else if (d == 4) {
			let h = tsch[words[3]];

			if (cmd == 'set') {
				for (let v in h?.values ?? [])
					push(cand, v);

				if (h?.type == 'bool')
					push(cand, '0', '1');
			}
			else if (cmd == 'delete' && !is_secret(cfg, words[1], words[3])) {
				for (let v in as_list(opts[words[3]]))
					push(cand, v);
			}
		}
	}

	return finish(cand, cur);
};

/* Candidates for the next word of an op-mode command. */
export function op_path(words, cur) {
	let node = OPDIR;

	for (let w in words) {
		if (!visible(w) || index(w, '/') >= 0)
			return [];

		node = `${node}/${w}`;

		if (fs.stat(node)?.type != 'directory')
			return [];
	}

	return finish(filter(fs.lsdir(node) ?? [], visible), cur);
};
