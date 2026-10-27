// SPDX-License-Identifier: MIT
// EdgeOS `vpn ipsec ...` (site-to-site PSK) -> OpenWrt /etc/config/ipsec
// (swanctl-based strongswan). EdgeOS has reusable ike-group/esp-group objects;
// OpenWrt has crypto_proposal sections referenced by name from `remote` (IKE)
// and `tunnel` (ESP). Mapping:
//   ike-group G  -> crypto_proposal 'ike_G'
//   esp-group G  -> crypto_proposal 'esp_G'
//   site-to-site peer A -> remote 'peer_A' (gateway A, psk)
//   peer A tunnel N      -> tunnel 'peer_A_tN', referenced from remote.tunnel
// v1 scope: proposal 1 only per group; key-exchange / per-group lifetime are
// not yet exposed (keyexchange stays at the OpenWrt default, ikev2).
'use strict';

import * as fs from 'fs';
import { as_list } from 'confsh.util';

const CFG = 'ipsec';

// strongswan ships /etc/config/ipsec; without it libuci cannot stage changes.
function need_cfg(ctx) {
	if (!fs.stat('/etc/config/ipsec'))
		ctx.fail('/etc/config/ipsec not found — install the strongswan package first');
}

// EdgeOS dh-group number <-> strongswan dh_group token.
const DH = {
	'1': 'modp768', '2': 'modp1024', '5': 'modp1536', '14': 'modp2048',
	'15': 'modp3072', '16': 'modp4096', '17': 'modp6144', '18': 'modp8192',
	'19': 'ecp256', '20': 'ecp384', '21': 'ecp521'
};
function dh_to_uci(n) { return DH[n] ?? `modp${n}`; }
function dh_from_uci(v) {
	for (let k in DH) if (DH[k] == v) return k;
	return v;
}

const ENC = [ '3des', 'aes128', 'aes192', 'aes256', 'aes128gcm128', 'aes256gcm128' ];
const HASH = [ 'sha1', 'sha256', 'sha384', 'sha512' ];

const PROPOSAL = {
	tag: 'number',
	children: {
		'encryption': { values: ENC },
		'hash': { values: HASH },
		'dh-group': { type: 'number' }
	}
};

const GRAMMAR = {
	children: {
		'ike-group': { tag: 'name', children: { 'proposal': PROPOSAL } },
		'esp-group': { tag: 'name', children: { 'proposal': PROPOSAL } },
		'site-to-site': {
			children: {
				'peer': {
					tag: 'host',
					children: {
						'authentication': {
							children: {
								'mode': { values: [ 'pre-shared-secret' ] },
								'pre-shared-secret': { type: 'text' }
							}
						},
						'ike-group': { type: 'name' },
						'local-address': { type: 'host' },
						'tunnel': {
							tag: 'number',
							children: {
								'local': { children: { 'prefix': { type: 'cidr' } } },
								'remote': { children: { 'prefix': { type: 'cidr' } } },
								'esp-group': { type: 'name' }
							}
						}
					}
				}
			}
		}
	}
};

function san(s) { return replace(s, /[^A-Za-z0-9]/g, '_'); }
function cp_id(kind, g) { return `${kind}_${san(g)}`; }          // ike_<g> / esp_<g>
function remote_id(a) { return `peer_${san(a)}`; }
function tunnel_id(a, n) { return `peer_${san(a)}_t${n}`; }

function list_add(ctx, id, opt, val) {
	let old = ctx.cur.get(CFG, id, opt);
	let items = as_list(old);
	if (index(items, val) < 0) {
		if (type(old) == 'array')
			ctx.cur.list_append(CFG, id, opt, val);
		else
			ctx.cur.set(CFG, id, opt, [ ...items, val ]);
	}
}

function list_del(ctx, id, opt, val, label) {
	let old = ctx.cur.get(CFG, id, opt);
	if (val == null) {
		if (old == null) ctx.fail(`Nothing to delete: ${label} is not set`);
		ctx.cur.delete(CFG, id, opt);
		return;
	}
	let items = as_list(old);
	if (index(items, val) < 0) ctx.fail(`Nothing to delete: ${label} does not contain '${val}'`);
	if (length(items) == 1) ctx.cur.delete(CFG, id, opt);
	else ctx.cur.list_remove(CFG, id, opt, val);
}

// crypto_proposal section (ike_* / esp_*), created on demand.
function proposal_id(ctx, kind, g, create) {
	let id = cp_id(kind, g);
	let t = ctx.cur.get(CFG, id);
	if (t != null && t != 'crypto_proposal')
		ctx.fail(`ipsec section '${id}' exists but is a '${t}'`);
	if (t == null) {
		if (!create) ctx.fail(`Nothing to delete: ${kind == 'ike_' ? 'ike' : 'esp'}-group ${g} does not exist`);
		ctx.cur.set(CFG, id, 'crypto_proposal');
	}
	return id;
}

function remote_sec(ctx, a, create) {
	let id = remote_id(a);
	let t = ctx.cur.get(CFG, id);
	if (t != null && t != 'remote')
		ctx.fail(`ipsec section '${id}' exists but is a '${t}'`);
	if (t == null) {
		if (!create) ctx.fail(`Nothing to delete: peer ${a} does not exist`);
		ctx.cur.set(CFG, id, 'remote');
		ctx.cur.set(CFG, id, 'enabled', '1');
		ctx.cur.set(CFG, id, 'gateway', a);
		ctx.cur.set(CFG, id, 'authentication_method', 'psk');
	}
	return id;
}

function tunnel_sec(ctx, a, n, create) {
	let id = tunnel_id(a, n);
	let t = ctx.cur.get(CFG, id);
	if (t != null && t != 'tunnel')
		ctx.fail(`ipsec section '${id}' exists but is a '${t}'`);
	if (t == null) {
		if (!create) ctx.fail(`Nothing to delete: peer ${a} tunnel ${n} does not exist`);
		ctx.cur.set(CFG, id, 'tunnel');
		list_add(ctx, remote_id(a), 'tunnel', id);   // reference from the remote
	}
	return id;
}

function set_group(ctx, p, kind) {
	let s = p.steps;
	let g = s[1].tag;
	let id = proposal_id(ctx, kind, g, true);

	if (length(s) >= 3 && s[2].key == 'proposal') {
		if (s[2].tag != '1')
			ctx.fail('Only proposal 1 is supported per group in this version');
		if (p.leaf == 'encryption') ctx.cur.set(CFG, id, 'encryption_algorithm', p.value);
		else if (p.leaf == 'hash') ctx.cur.set(CFG, id, 'hash_algorithm', p.value);
		else if (p.leaf == 'dh-group') ctx.cur.set(CFG, id, 'dh_group', dh_to_uci(p.value));
	}
	ctx.touch(CFG);
}

function set_peer(ctx, p) {
	let s = p.steps;            // s[1]=site-to-site, s[2]=peer
	let a = s[2].tag;
	let rid = remote_sec(ctx, a, true);

	// peer-level leaves (no sub-container in steps)
	if (p.leaf == 'ike-group') {
		list_add(ctx, rid, 'crypto_proposal', cp_id('ike', p.value));
	}
	else if (p.leaf == 'local-address') {
		ctx.cur.set(CFG, rid, 'local_ip', p.value);
	}
	else {
		let sub = s[3]?.key;
		if (sub == 'authentication') {
			// 'mode pre-shared-secret' needs no UCI (authentication_method is psk)
			if (p.leaf == 'pre-shared-secret') ctx.cur.set(CFG, rid, 'pre_shared_key', p.value);
		}
		else if (sub == 'tunnel') {
			let tid = tunnel_sec(ctx, a, s[3].tag, true);
			if (p.leaf == 'esp-group') list_add(ctx, tid, 'crypto_proposal', cp_id('esp', p.value));
			else {
				let leg = s[4]?.key;
				if (leg == 'local' && p.leaf == 'prefix') list_add(ctx, tid, 'local_subnet', p.value);
				else if (leg == 'remote' && p.leaf == 'prefix') list_add(ctx, tid, 'remote_subnet', p.value);
			}
		}
	}
	ctx.touch(CFG);
}

function set(ctx, p) {
	need_cfg(ctx);
	let kind = p.steps[1]?.key;
	if (kind == 'ike-group') set_group(ctx, p, 'ike');
	else if (kind == 'esp-group') set_group(ctx, p, 'esp');
	else if (kind == 'site-to-site') set_peer(ctx, p);
	else ctx.touch(CFG);
}

function del(ctx, p) {
	need_cfg(ctx);
	let s = p.steps;
	let kind = s[1]?.key;
	let cur = ctx.cur;

	if (kind == 'ike-group' || kind == 'esp-group') {
		let pfx = (kind == 'ike-group') ? 'ike' : 'esp';
		let id = proposal_id(ctx, pfx, s[1].tag, false);
		if (!p.leaf && length(s) == 2) cur.delete(CFG, id);
		else if (length(s) >= 3 && s[2].key == 'proposal') {
			let opt = (p.leaf == 'encryption') ? 'encryption_algorithm' :
				(p.leaf == 'hash') ? 'hash_algorithm' :
				(p.leaf == 'dh-group') ? 'dh_group' : null;
			if (!p.leaf) cur.delete(CFG, id);            // delete proposal -> whole section
			else { if (cur.get(CFG, id, opt) == null) ctx.fail(`Nothing to delete: ${p.leaf} is not set`); cur.delete(CFG, id, opt); }
		}
		ctx.touch(CFG);
		return;
	}

	if (kind == 'site-to-site') {
		let a = s[2]?.tag;
		if (a == null) ctx.fail('Specify a peer to delete');
		let rid = remote_sec(ctx, a, false);

		if (p.leaf == 'ike-group') {
			list_del(ctx, rid, 'crypto_proposal', p.value ? cp_id('ike', p.value) : null, 'ike-group');
		}
		else if (p.leaf == 'local-address') {
			if (cur.get(CFG, rid, 'local_ip') == null) ctx.fail('Nothing to delete: local-address is not set');
			cur.delete(CFG, rid, 'local_ip');
		}
		else {
			let sub = s[3]?.key;
			if (!sub) {                                  // delete whole peer + its tunnels
				for (let t in as_list(cur.get(CFG, rid, 'tunnel'))) cur.delete(CFG, t);
				cur.delete(CFG, rid);
			}
			else if (sub == 'authentication') {
				if (cur.get(CFG, rid, 'pre_shared_key') == null) ctx.fail('Nothing to delete: pre-shared-secret is not set');
				cur.delete(CFG, rid, 'pre_shared_key');
			}
			else if (sub == 'tunnel') {
				let tid = tunnel_sec(ctx, a, s[3].tag, false);
				if (p.leaf == 'esp-group') list_del(ctx, tid, 'crypto_proposal', p.value ? cp_id('esp', p.value) : null, 'esp-group');
				else {
					let leg = s[4]?.key;
					if (!leg) { list_del(ctx, rid, 'tunnel', tid, 'tunnel'); cur.delete(CFG, tid); }
					else if (leg == 'local') list_del(ctx, tid, 'local_subnet', p.value, 'local prefix');
					else if (leg == 'remote') list_del(ctx, tid, 'remote_subnet', p.value, 'remote prefix');
				}
			}
		}
		ctx.touch(CFG);
		return;
	}

	ctx.fail(`Nothing to delete: [${join(' ', map(s, x => x.tag ? `${x.key} ${x.tag}` : x.key))}]`);
}

function group_node(o) {
	let pk = [];
	if (o.encryption_algorithm != null) push(pk, { name: 'encryption', value: o.encryption_algorithm });
	if (o.hash_algorithm != null) push(pk, { name: 'hash', value: o.hash_algorithm });
	if (o.dh_group != null) push(pk, { name: 'dh-group', value: dh_from_uci(o.dh_group) });
	return [ { name: 'proposal 1', children: pk } ];
}

function render(ctx) {
	let secs = ctx.sections(CFG);
	let kids = [];

	// ike-group / esp-group from crypto_proposal ike_* / esp_*
	for (let s in secs) {
		if (s.type != 'crypto_proposal') continue;
		let m = match(s.label, /^(ike|esp)_(.+)$/);
		if (!m) continue;
		push(kids, { name: `${m[1]}-group ${m[2]}`, children: group_node(s.opts) });
	}

	// site-to-site peers from remote peer_*
	let peers = [];
	for (let s in secs) {
		if (s.type != 'remote') continue;
		let o = s.opts;
		let pk = [];
		let auth = [];
		push(auth, { name: 'mode', value: 'pre-shared-secret' });
		if (o.pre_shared_key != null) push(auth, { name: 'pre-shared-secret', value: o.pre_shared_key, secret: true });
		push(pk, { name: 'authentication', children: auth });
		for (let cp in as_list(o.crypto_proposal)) {
			let mm = match(cp, /^ike_(.+)$/);
			if (mm) push(pk, { name: 'ike-group', value: mm[1] });
		}
		if (o.local_ip != null) push(pk, { name: 'local-address', value: o.local_ip });
		for (let t in as_list(o.tunnel)) {
			let tsec = filter(secs, x => x.type == 'tunnel' && x.label == t)[0];
			if (!tsec) continue;
			let nm = match(t, /_t([0-9]+)$/);
			let tn = nm ? nm[1] : t;
			let tk = [];
			for (let v in as_list(tsec.opts.local_subnet)) push(tk, { name: 'local', children: [ { name: 'prefix', value: v } ] });
			for (let v in as_list(tsec.opts.remote_subnet)) push(tk, { name: 'remote', children: [ { name: 'prefix', value: v } ] });
			for (let cp in as_list(tsec.opts.crypto_proposal)) {
				let mm = match(cp, /^esp_(.+)$/);
				if (mm) push(tk, { name: 'esp-group', value: mm[1] });
			}
			push(pk, { name: `tunnel ${tn}`, children: tk });
		}
		push(peers, { name: `peer ${o.gateway ?? s.label}`, children: pk });
	}
	if (length(peers)) push(kids, { name: 'site-to-site', children: peers });

	return length(kids) ? [ { name: 'vpn', children: [ { name: 'ipsec', children: kids } ] } ] : [];
}

function tags(ctx, steps, key) {
	let secs = ctx.sections(CFG);
	if (key == 'ike-group')
		return map(filter(secs, s => s.type == 'crypto_proposal' && match(s.label, /^ike_/)), s => substr(s.label, 4));
	if (key == 'esp-group')
		return map(filter(secs, s => s.type == 'crypto_proposal' && match(s.label, /^esp_/)), s => substr(s.label, 4));
	if (key == 'peer')
		return map(filter(secs, s => s.type == 'remote' && s.opts.gateway), s => s.opts.gateway);
	return [];
}

return {
	mounts: { 'vpn ipsec': GRAMMAR },
	set, del, render, tags
};
