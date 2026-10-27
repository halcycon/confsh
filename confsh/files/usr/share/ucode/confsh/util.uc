// SPDX-License-Identifier: MIT
'use strict';

import * as fs from 'fs';

export const CONFDIR = '/etc/config';
export const BACKEND = getenv('CONFSH_BACKEND') ?? '/usr/libexec/confsh/backend';
export const RUNDIR = getenv('CONFSH_RUNDIR') ?? '/var/run/confsh';

export function fail(msg) {
	warn(`${msg}\n`);
	exit(1);
};

export function startswith(s, p) {
	return substr(s, 0, length(p)) == p;
};

export function as_list(v) {
	if (v == null)
		return [];

	return (type(v) == 'array') ? v : [ v ];
};

/* Value as shown in the curly-brace config tree (EdgeOS style). */
export function q_curly(v) {
	if (v == '' || match(v, /[[:space:]"'{};#\\]/))
		return '"' + replace(replace(v, /\\/g, '\\\\'), /"/g, '\\"') + '"';

	return v;
};

/* Value as shown in `set ...` command listings. */
export function q_shell(v) {
	return "'" + replace(v, /'/g, "'\\''") + "'";
};

export function fmt_time(t) {
	let l = localtime(t);

	return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
		l.year, l.mon, l.mday, l.hour, l.min, l.sec);
};

export function user() {
	return getenv('USER') ?? getenv('LOGNAME') ?? 'root';
};

export function mkdir_p(path) {
	let cur = '';

	for (let part in split(path, '/')) {
		if (part == '')
			continue;

		cur += '/' + part;

		if (!fs.stat(cur))
			fs.mkdir(cur);
	}
};

export function rm_rf(path) {
	return system([ 'rm', '-rf', path ]) == 0;
};

export function read_json(path, dflt) {
	let data = fs.readfile(path);

	if (data == null)
		return dflt;

	try {
		return json(data);
	}
	catch (e) {
		return dflt;
	}
};

export function write_json(path, data) {
	let tmp = `${path}.tmp`;

	fs.writefile(tmp, sprintf('%.J\n', data));
	fs.rename(tmp, path);
};

function merge(dst, src) {
	for (let k in src) {
		if (type(dst[k]) == 'object' && type(src[k]) == 'object')
			merge(dst[k], src[k]);
		else
			dst[k] = src[k];
	}
}

let schema_cache;

/* Deep-merged schema hints from every *.json in the schema directory. */
export function schema() {
	if (schema_cache)
		return schema_cache;

	let dir = getenv('CONFSH_SCHEMA_DIR') ?? '/usr/share/confsh/schema';

	schema_cache = {};

	for (let f in sort(fs.lsdir(dir) ?? [])) {
		if (!match(f, /\.json$/))
			continue;

		let data = read_json(`${dir}/${f}`);

		if (type(data) == 'object')
			merge(schema_cache, data);
		else
			warn(`confsh: ignoring invalid schema file ${dir}/${f}\n`);
	}

	return schema_cache;
};

/* Hints for a section type; keys ending in '*' match by prefix (wireguard_*). */
export function type_hints(cfg, stype) {
	let c = schema()[cfg];

	if (!c || stype == null)
		return null;

	if (c[stype])
		return c[stype];

	for (let k in keys(c)) {
		let n = length(k) - 1;

		if (substr(k, n) == '*' && startswith(stype, substr(k, 0, n)))
			return c[k];
	}

	return null;
};

export function hint(cfg, stype, opt) {
	return type_hints(cfg, stype)?.[opt];
};

export function is_secret(cfg, stype, opt) {
	return hint(cfg, stype, opt)?.secret == true && getenv('CONFSH_SHOW_SECRETS') != '1';
};

/* Value for display: secrets are masked unless CONFSH_SHOW_SECRETS=1. */
export function shown(cfg, stype, opt, v) {
	return is_secret(cfg, stype, opt) ? '********' : v;
};

export function str(v) {
	if (v == null || v == '')
		return '-';

	return (type(v) == 'array') ? join(' ', v) : `${v}`;
};

function rpad(s, n) {
	while (length(s) < n)
		s += ' ';

	return s;
}

export function table(headers, rows) {
	let w = map(headers, h => length(h));

	for (let r in rows)
		for (let i = 0; i < length(r); i++)
			if (length(`${r[i]}`) > w[i])
				w[i] = length(`${r[i]}`);

	for (let r in [ headers, ...rows ]) {
		let cells = [];

		for (let i = 0; i < length(r); i++)
			push(cells, rpad(`${r[i]}`, w[i]));

		print(rtrim(join('  ', cells)), '\n');
	}
};

export function human_bytes(n) {
	let units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	let i = 0;

	n = +n;

	while (n >= 1024 && i < length(units) - 1) {
		n = n / 1024.0;
		i++;
	}

	return (i == 0) ? sprintf('%d B', n) : sprintf('%.2f %s', n, units[i]);
};

export function duration(secs) {
	secs = int(secs);

	let d = int(secs / 86400), h = int(secs / 3600) % 24, m = int(secs / 60) % 60, s = secs % 60;
	let out = [];

	if (d) push(out, `${d}d`);
	if (h) push(out, `${h}h`);
	if (m) push(out, `${m}m`);
	if (s || !length(out)) push(out, `${s}s`);

	return join(' ', out);
};

/* `ubus call` via the CLI (stubbable in tests); null when unavailable. */
export function ubus_call(obj, method, args) {
	let cmd = `ubus call ${obj} ${method}`;

	if (args)
		cmd += ` '${sprintf('%J', args)}'`;

	let p = fs.popen(`${cmd} 2>/dev/null`, 'r');

	if (!p)
		return null;

	let out = p.read('all');

	p.close();

	try {
		return json(out);
	}
	catch (e) {
		return null;
	}
};

export function valid_name(s) {
	return match(s, /^[A-Za-z0-9_]+$/) != null;
};

export function valid_type(s) {
	return match(s, /^[A-Za-z0-9_-]+$/) != null;
};

/* mtime:size of every config file, to detect edits made outside a session. */
export function config_stamps() {
	let stamps = {};

	for (let name in fs.lsdir(CONFDIR) ?? []) {
		let st = fs.stat(`${CONFDIR}/${name}`);

		if (st?.type == 'file')
			stamps[name] = `${st.mtime}:${st.size}`;
	}

	return stamps;
};

/*
 * libuci always overlays the default delta dir (/tmp/.uci, used by the `uci`
 * CLI) on top of any other savedir, and ucode cannot remove it. LuCI is not
 * affected: rpcd stages per session under /var/run/rpcd.
 */
export function uci_cli_pending() {
	let dir = getenv('CONFSH_UCI_SAVEDIR') ?? '/tmp/.uci';

	return sort(filter(fs.lsdir(dir) ?? [], n => (fs.stat(`${dir}/${n}`)?.size ?? 0) > 0));
};

export function reload() {
	let cmd = getenv('CONFSH_RELOAD_CMD') ?? '/sbin/reload_config';
	let rc = system(cmd);

	if (rc != 0)
		warn(`confsh: warning: '${cmd}' exited with status ${rc}\n`);

	return rc == 0;
};
