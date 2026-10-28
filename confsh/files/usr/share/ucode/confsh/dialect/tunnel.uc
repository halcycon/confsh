// SPDX-License-Identifier: MIT
// EdgeOS `interfaces tunnel tunN ...` -> OpenWrt network tunnel interface.
//   encapsulation gre|gre-bridge|ipip -> proto gre|gretap|ipip
//   local-ip  -> ipaddr (tunnel endpoint)   remote-ip -> peeraddr
//   mtu/ttl   -> mtu/ttl
//   address   -> a companion `config interface '<name>_net'` (proto static,
//                device '@<name>') carrying the tunnel's own L3 address, which
//                is how OpenWrt assigns an address to a tunnel device.
// v1 scope: gre / gre-bridge (gretap) / ipip.
'use strict';

const CFG = 'network';

const ENCAP = { 'gre': 'gre', 'gre-bridge': 'gretap', 'ipip': 'ipip' };
const PROTOS = [ 'gre', 'gretap', 'ipip' ];
function encap_from(proto) { for (let k in ENCAP) if (ENCAP[k] == proto) return k; return proto; }

const POW = [ 1, 2, 4, 8, 16, 32, 64, 128, 256 ];
function pfx2mask(p) {
	p = int(p);
	let parts = [];
	for (let i = 0; i < 4; i++) {
		let n = (p >= 8) ? 8 : ((p < 0) ? 0 : p);
		push(parts, (256 - POW[8 - n]) % 256);
		p -= 8;
	}
	return join('.', parts);
}
function mask2pfx(m) {
	let bits = 0;
	for (let o in split(m, '.')) {
		let n = int(o);
		while (n) { bits += (n & 1); n = n >> 1; }
	}
	return bits;
}

const GRAMMAR = {
	tag: 'name',
	children: {
		'encapsulation': { values: keys(ENCAP) },
		'local-ip': { type: 'ipv4' },
		'remote-ip': { type: 'ipv4' },
		'address': { type: 'ipv4net' },
		'mtu': { type: 'number' },
		'ttl': { type: 'number' }
	}
};

function tun_id(ctx, name, create) {
	let t = ctx.cur.get(CFG, name);
	if (t != null && t != 'interface')
		ctx.fail(`network section '${name}' exists but is a '${t}'`);
	if (t == 'interface') {
		let proto = ctx.cur.get(CFG, name, 'proto');
		if (proto != null && index(PROTOS, proto) < 0)
			ctx.fail(`interface '${name}' exists with proto '${proto}', not a tunnel`);
	}
	if (t == null) {
		if (!create) ctx.fail(`Nothing to delete: interfaces tunnel ${name} does not exist`);
		ctx.cur.set(CFG, name, 'interface');
		ctx.cur.set(CFG, name, 'proto', 'gre');   // default; encapsulation overrides
	}
	return name;
}

function net_id(name) { return `${name}_net`; }

function set_address(ctx, name, cidr) {
	let nid = net_id(name);
	let parts = split(cidr, '/');
	ctx.cur.set(CFG, nid, 'interface');
	ctx.cur.set(CFG, nid, 'proto', 'static');
	ctx.cur.set(CFG, nid, 'device', `@${name}`);
	ctx.cur.set(CFG, nid, 'ipaddr', parts[0]);
	ctx.cur.set(CFG, nid, 'netmask', pfx2mask(parts[1] ?? '32'));
}

function set(ctx, p) {
	let name = p.steps[0].tag;
	let id = tun_id(ctx, name, true);
	let cur = ctx.cur;

	switch (p.leaf) {
	case 'encapsulation': cur.set(CFG, id, 'proto', ENCAP[p.value]); break;
	case 'local-ip':      cur.set(CFG, id, 'ipaddr', p.value); break;
	case 'remote-ip':     cur.set(CFG, id, 'peeraddr', p.value); break;
	case 'mtu':           cur.set(CFG, id, 'mtu', p.value); break;
	case 'ttl':           cur.set(CFG, id, 'ttl', p.value); break;
	case 'address':       set_address(ctx, name, p.value); break;
	}
	ctx.touch(CFG);
}

function del(ctx, p) {
	let name = p.steps[0].tag;
	let id = tun_id(ctx, name, false);
	let cur = ctx.cur;

	if (!p.leaf) {
		cur.delete(CFG, net_id(name));
		cur.delete(CFG, id);
		ctx.touch(CFG);
		return;
	}

	if (p.leaf == 'address') {
		if (cur.get(CFG, net_id(name)) == null) ctx.fail('Nothing to delete: address is not set');
		cur.delete(CFG, net_id(name));
	}
	else if (p.leaf == 'encapsulation') {
		cur.set(CFG, id, 'proto', 'gre');   // never leave the interface with no protocol
	}
	else {
		let opt = (p.leaf == 'local-ip') ? 'ipaddr' : (p.leaf == 'remote-ip') ? 'peeraddr' : p.leaf;
		if (cur.get(CFG, id, opt) == null) ctx.fail(`Nothing to delete: ${p.leaf} is not set`);
		cur.delete(CFG, id, opt);
	}
	ctx.touch(CFG);
}

function render(ctx) {
	let secs = ctx.sections(CFG);
	let out = [];
	for (let s in secs) {
		if (s.type != 'interface' || index(PROTOS, s.opts.proto) < 0) continue;
		let o = s.opts;
		let k = [];
		push(k, { name: 'encapsulation', value: encap_from(o.proto) });
		if (o.ipaddr != null) push(k, { name: 'local-ip', value: o.ipaddr });
		if (o.peeraddr != null) push(k, { name: 'remote-ip', value: o.peeraddr });
		let net = filter(secs, x => x.type == 'interface' && x.label == net_id(s.label))[0];
		if (net && net.opts.ipaddr != null)
			push(k, { name: 'address', value: `${net.opts.ipaddr}/${net.opts.netmask ? mask2pfx(net.opts.netmask) : '32'}` });
		if (o.mtu != null) push(k, { name: 'mtu', value: o.mtu });
		if (o.ttl != null) push(k, { name: 'ttl', value: o.ttl });
		push(out, { name: `tunnel ${s.label}`, children: k });
	}
	return length(out) ? [ { name: 'interfaces', children: out } ] : [];
}

function tags(ctx, steps, key) {
	if (key == 'tunnel')
		return map(filter(ctx.sections(CFG), s => s.type == 'interface' && index(PROTOS, s.opts.proto) >= 0), s => s.label);
	return [];
}

return {
	mounts: { 'interfaces tunnel': GRAMMAR },
	set, del, render, tags
};
