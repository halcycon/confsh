// SPDX-License-Identifier: MIT
// EdgeOS `interfaces openvpn vtunN ...` (site-to-site, static key) ->
// OpenWrt /etc/config/openvpn `config openvpn 'vtunN'`. The openvpn package
// turns every option into an openvpn directive, so only real directives may be
// stored here (no confsh-private options). v1 scope: site-to-site with a
// pre-shared static key; client/server/TLS modes are not yet exposed.
'use strict';

import * as fs from 'fs';
import { as_list } from 'confsh.util';

const CFG = 'openvpn';

const ENC = { 'aes128': 'AES-128-CBC', 'aes192': 'AES-192-CBC', 'aes256': 'AES-256-CBC', '3des': 'DES-EDE3-CBC' };
const HASH = { 'sha1': 'SHA1', 'sha256': 'SHA256', 'sha384': 'SHA384', 'sha512': 'SHA512', 'md5': 'MD5' };
function rev(map, v) { for (let k in map) if (map[k] == v) return k; return v; }

const GRAMMAR = {
	tag: 'name',
	children: {
		'mode': { values: [ 'site-to-site' ] },
		'device-type': { values: [ 'tun', 'tap' ] },
		'local-address': { type: 'ipv4' },
		'remote-address': { type: 'ipv4' },
		'local-port': { type: 'port' },
		'remote-host': { type: 'host' },
		'remote-port': { type: 'port' },
		'shared-secret-key-file': { type: 'text' },
		'encryption': { values: keys(ENC) },
		'hash': { values: keys(HASH) },
		'disable': { flag: true }
	}
};

function need_cfg(ctx) {
	if (!fs.stat('/etc/config/openvpn'))
		ctx.fail('/etc/config/openvpn not found — install the openvpn package first');
}

function ovpn_id(ctx, name, create) {
	let t = ctx.cur.get(CFG, name);
	if (t != null && t != 'openvpn')
		ctx.fail(`openvpn section '${name}' exists but is a '${t}'`);
	if (t == null) {
		if (!create) ctx.fail(`Nothing to delete: openvpn ${name} does not exist`);
		ctx.cur.set(CFG, name, 'openvpn');
		ctx.cur.set(CFG, name, 'enabled', '1');
		ctx.cur.set(CFG, name, 'dev', 'tun');
		ctx.cur.set(CFG, name, 'proto', 'udp');
	}
	return name;
}

// ifconfig holds "<local> <remote>"; patch one field, keeping the other.
function set_ifconfig(ctx, id, which, val) {
	let cur = as_list(ctx.cur.get(CFG, id, 'ifconfig'));
	let parts = split(cur[0] ?? '', ' ');
	let local = parts[0] ?? '';
	let remote = parts[1] ?? '';
	if (which == 'local') local = val; else remote = val;
	ctx.cur.set(CFG, id, 'ifconfig', trim(`${local} ${remote}`));
}

function set(ctx, p) {
	need_cfg(ctx);
	let id = ovpn_id(ctx, p.steps[0].tag, true);
	let cur = ctx.cur;

	switch (p.leaf) {
	case 'mode':                   break;                               // site-to-site = static-key p2p, no directive
	case 'device-type':            cur.set(CFG, id, 'dev', p.value); break;
	case 'local-address':          set_ifconfig(ctx, id, 'local', p.value); break;
	case 'remote-address':         set_ifconfig(ctx, id, 'remote', p.value); break;
	case 'local-port':             cur.set(CFG, id, 'port', p.value); break;
	case 'remote-host':            cur.set(CFG, id, 'remote', p.value); break;
	case 'remote-port':            cur.set(CFG, id, 'rport', p.value); break;
	case 'shared-secret-key-file': cur.set(CFG, id, 'secret', p.value); break;
	case 'encryption':             cur.set(CFG, id, 'cipher', ENC[p.value]); break;
	case 'hash':                   cur.set(CFG, id, 'auth', HASH[p.value]); break;
	case 'disable':                cur.set(CFG, id, 'enabled', '0'); break;
	}
	ctx.touch(CFG);
}

function del(ctx, p) {
	need_cfg(ctx);
	let id = ovpn_id(ctx, p.steps[0].tag, false);
	let cur = ctx.cur;

	if (!p.leaf) { cur.delete(CFG, id); ctx.touch(CFG); return; }

	let drop = (opt) => { if (cur.get(CFG, id, opt) == null) ctx.fail(`Nothing to delete: ${p.leaf} is not set`); cur.delete(CFG, id, opt); };
	switch (p.leaf) {
	case 'local-address':          set_ifconfig(ctx, id, 'local', ''); break;
	case 'remote-address':         set_ifconfig(ctx, id, 'remote', ''); break;
	case 'local-port':             drop('port'); break;
	case 'remote-host':            drop('remote'); break;
	case 'remote-port':            drop('rport'); break;
	case 'shared-secret-key-file': drop('secret'); break;
	case 'encryption':             drop('cipher'); break;
	case 'hash':                   drop('auth'); break;
	case 'device-type':            cur.set(CFG, id, 'dev', 'tun'); break;
	case 'disable':                cur.set(CFG, id, 'enabled', '1'); break;
	}
	ctx.touch(CFG);
}

function render(ctx) {
	let out = [];
	for (let s in ctx.sections(CFG)) {
		if (s.type != 'openvpn') continue;
		let o = s.opts;
		let k = [];
		// site-to-site when a static key is configured
		push(k, { name: 'mode', value: 'site-to-site' });
		if (o.dev != null && o.dev != 'tun') push(k, { name: 'device-type', value: o.dev });
		let ic = split((type(o.ifconfig) == 'array' ? o.ifconfig[0] : o.ifconfig) ?? '', ' ');
		if (ic[0]) push(k, { name: 'local-address', value: ic[0] });
		if (ic[1]) push(k, { name: 'remote-address', value: ic[1] });
		if (o.port != null) push(k, { name: 'local-port', value: o.port });
		if (o.remote != null) push(k, { name: 'remote-host', value: (type(o.remote) == 'array') ? o.remote[0] : o.remote });
		if (o.rport != null) push(k, { name: 'remote-port', value: o.rport });
		if (o.secret != null) push(k, { name: 'shared-secret-key-file', value: o.secret });
		if (o.cipher != null) push(k, { name: 'encryption', value: rev(ENC, o.cipher) });
		if (o.auth != null) push(k, { name: 'hash', value: rev(HASH, o.auth) });
		if (o.enabled == '0') push(k, { name: 'disable' });
		push(out, { name: `openvpn ${s.label}`, children: k });
	}
	return length(out) ? [ { name: 'interfaces', children: out } ] : [];
}

function tags(ctx, steps, key) {
	if (key == 'openvpn')
		return map(filter(ctx.sections(CFG), s => s.type == 'openvpn'), s => s.label);
	return [];
}

return {
	mounts: { 'interfaces openvpn': GRAMMAR },
	set, del, render, tags
};
