// SPDX-License-Identifier: MIT
// EdgeOS `interfaces wireguard wgN …` → UCI network wireguard interface + peers.
//
// WireGuard was never part of the official EdgeOS CLI (it was the community
// wireguard-vyatta add-on), so there is no canonical grammar to mirror; this
// follows the add-on's de-facto paths but keeps OpenWrt-native semantics where
// they diverge. Notably route-allowed-ips is per-peer (as in OpenWrt), not
// interface-wide. See https://github.com/halcycon/confsh/issues/1.
'use strict';

import { as_list } from 'confsh.util';

const IFACE_OPTS = {
	'private-key': 'private_key',
	'listen-port': 'listen_port',
	'mtu': 'mtu',
	'fwmark': 'fwmark'
};

const PEER_OPTS = {
	'persistent-keepalive': 'persistent_keepalive',
	'preshared-key': 'preshared_key',
	'description': 'description'
};

const GRAMMAR = {
	tag: 'name',
	children: {
		'address': { type: 'cidr' },
		'fwmark': { type: 'text' },
		'listen-port': { type: 'port' },
		'mtu': { type: 'number' },
		'private-key': { type: 'key' },
		'peer': {
			tag: 'key',
			children: {
				'allowed-ips': { type: 'cidr' },
				'description': { type: 'text' },
				'disable': { flag: true },
				'endpoint': { type: 'host' },
				'persistent-keepalive': { type: 'number' },
				'preshared-key': { type: 'key' },
				'route-allowed-ips': { values: [ 'true', 'false' ] }
			}
		}
	}
};

function peer_type(ifname) {
	return `wireguard_${ifname}`;
}

// Ensure the wireguard interface section exists; create on demand.
function iface_id(ctx, name, create) {
	let t = ctx.cur.get('network', name);

	if (t != null && t != 'interface')
		ctx.fail(`network section '${name}' exists but is a '${t}', not an interface`);

	if (t == null) {
		if (!create)
			ctx.fail(`Nothing to delete: interfaces wireguard ${name} does not exist`);

		ctx.cur.set('network', name, 'interface');
		ctx.cur.set('network', name, 'proto', 'wireguard');
	}

	return name;
}

// Peers are identified by public key; created as a stable named section.
function find_peer(ctx, ifname, key) {
	let pt = peer_type(ifname);

	for (let s in ctx.sections('network'))
		if (s.type == pt && s.opts.public_key == key)
			return s.id;

	return null;
}

function peer_id(ctx, ifname, key, create) {
	let id = find_peer(ctx, ifname, key);

	if (id != null)
		return id;

	if (!create)
		ctx.fail(`Nothing to delete: peer ${key} does not exist`);

	id = `peer_${replace(key, /[^A-Za-z0-9]/g, '')}`;
	ctx.cur.set('network', id, peer_type(ifname));
	ctx.cur.set('network', id, 'public_key', key);

	return id;
}

// host:port -> [ host, port ]; port is null when absent. Splits on last ':'.
function split_endpoint(v) {
	let at = -1;

	for (let i = 0; i < length(v); i++)
		if (substr(v, i, 1) == ':')
			at = i;

	if (at < 0)
		return [ v, null ];

	return [ substr(v, 0, at), substr(v, at + 1) ];
}

function list_add(ctx, id, opt, val) {
	let old = ctx.cur.get('network', id, opt);
	let items = as_list(old);

	if (index(items, val) < 0) {
		if (type(old) == 'array')
			ctx.cur.list_append('network', id, opt, val);
		else
			ctx.cur.set('network', id, opt, [ ...items, val ]);
	}
}

function list_del(ctx, id, opt, val, label) {
	let old = ctx.cur.get('network', id, opt);

	if (val == null) {
		if (old == null)
			ctx.fail(`Nothing to delete: ${label} is not set`);

		ctx.cur.delete('network', id, opt);
		return;
	}

	let items = as_list(old);

	if (index(items, val) < 0)
		ctx.fail(`Nothing to delete: ${label} does not contain '${val}'`);

	if (length(items) == 1)
		ctx.cur.delete('network', id, opt);
	else
		ctx.cur.list_remove('network', id, opt, val);
}

function set(ctx, p) {
	let s = p.steps;
	let ifname = s[0].tag;
	let iid = iface_id(ctx, ifname, true);

	if (length(s) == 1) {
		if (p.leaf) {
			if (p.leaf == 'address')
				list_add(ctx, iid, 'addresses', p.value);
			else
				ctx.cur.set('network', iid, IFACE_OPTS[p.leaf], p.value);
		}

		ctx.touch('network');
		return;
	}

	let pid = peer_id(ctx, ifname, s[1].tag, true);

	if (p.leaf) {
		if (p.leaf == 'allowed-ips') {
			list_add(ctx, pid, 'allowed_ips', p.value);
		}
		else if (p.leaf == 'endpoint') {
			let hp = split_endpoint(p.value);

			ctx.cur.set('network', pid, 'endpoint_host', hp[0]);

			if (hp[1] != null)
				ctx.cur.set('network', pid, 'endpoint_port', hp[1]);
			else
				ctx.cur.delete('network', pid, 'endpoint_port');
		}
		else if (p.leaf == 'route-allowed-ips') {
			ctx.cur.set('network', pid, 'route_allowed_ips', (p.value == 'true') ? '1' : '0');
		}
		else if (p.leaf == 'disable') {
			ctx.cur.set('network', pid, 'disabled', '1');
		}
		else {
			ctx.cur.set('network', pid, PEER_OPTS[p.leaf], p.value);
		}
	}

	ctx.touch('network');
}

function del(ctx, p) {
	let s = p.steps;
	let ifname = s[0].tag;
	let cur = ctx.cur;

	if (length(s) == 1) {
		let iid = iface_id(ctx, ifname, false);

		if (!p.leaf) {
			for (let sec in ctx.sections('network'))
				if (sec.type == peer_type(ifname))
					cur.delete('network', sec.id);

			cur.delete('network', iid);
			ctx.touch('network');
			return;
		}

		if (p.leaf == 'address') {
			list_del(ctx, iid, 'addresses', p.value, 'address');
		}
		else {
			let opt = IFACE_OPTS[p.leaf];

			if (cur.get('network', iid, opt) == null)
				ctx.fail(`Nothing to delete: ${p.leaf} is not set`);

			cur.delete('network', iid, opt);
		}

		ctx.touch('network');
		return;
	}

	let pid = peer_id(ctx, ifname, s[1].tag, false);

	if (!p.leaf) {
		cur.delete('network', pid);
	}
	else if (p.leaf == 'allowed-ips') {
		list_del(ctx, pid, 'allowed_ips', p.value, 'allowed-ips');
	}
	else if (p.leaf == 'endpoint') {
		if (cur.get('network', pid, 'endpoint_host') == null)
			ctx.fail('Nothing to delete: endpoint is not set');

		cur.delete('network', pid, 'endpoint_host');
		cur.delete('network', pid, 'endpoint_port');
	}
	else if (p.leaf == 'route-allowed-ips') {
		if (cur.get('network', pid, 'route_allowed_ips') == null)
			ctx.fail('Nothing to delete: route-allowed-ips is not set');

		cur.delete('network', pid, 'route_allowed_ips');
	}
	else if (p.leaf == 'disable') {
		if (cur.get('network', pid, 'disabled') == null)
			ctx.fail('Nothing to delete: disable is not set');

		cur.delete('network', pid, 'disabled');
	}
	else {
		let opt = PEER_OPTS[p.leaf];

		if (cur.get('network', pid, opt) == null)
			ctx.fail(`Nothing to delete: ${p.leaf} is not set`);

		cur.delete('network', pid, opt);
	}

	ctx.touch('network');
}

function peer_node(po) {
	let pk = [];

	for (let a in as_list(po.allowed_ips))
		push(pk, { name: 'allowed-ips', value: a });

	if (po.description != null)
		push(pk, { name: 'description', value: po.description });

	if (po.disabled == '1')
		push(pk, { name: 'disable' });

	if (po.endpoint_host != null)
		push(pk, { name: 'endpoint',
			value: po.endpoint_host + ((po.endpoint_port != null) ? `:${po.endpoint_port}` : '') });

	if (po.persistent_keepalive != null)
		push(pk, { name: 'persistent-keepalive', value: po.persistent_keepalive });

	if (po.preshared_key != null)
		push(pk, { name: 'preshared-key', value: po.preshared_key, secret: true });

	if (po.route_allowed_ips != null)
		push(pk, { name: 'route-allowed-ips', value: (po.route_allowed_ips == '1') ? 'true' : 'false' });

	return pk;
}

function render(ctx) {
	let secs = ctx.sections('network');
	let ifaces = filter(secs, s => s.type == 'interface' && s.opts.proto == 'wireguard');
	let out = [];

	for (let w in sort(ifaces, (a, b) => (a.label < b.label) ? -1 : 1)) {
		let o = w.opts;
		let kids = [];

		for (let a in as_list(o.addresses))
			push(kids, { name: 'address', value: a });

		if (o.fwmark != null)
			push(kids, { name: 'fwmark', value: o.fwmark });

		if (o.listen_port != null)
			push(kids, { name: 'listen-port', value: o.listen_port });

		if (o.mtu != null)
			push(kids, { name: 'mtu', value: o.mtu });

		let pt = peer_type(w.label);
		let peers = sort(filter(secs, s => s.type == pt),
			(a, b) => ((a.opts.public_key ?? '') < (b.opts.public_key ?? '')) ? -1 : 1);

		for (let pr in peers)
			push(kids, { name: `peer ${pr.opts.public_key}`, children: peer_node(pr.opts) });

		if (o.private_key != null)
			push(kids, { name: 'private-key', value: o.private_key, secret: true });

		push(out, { name: `wireguard ${w.label}`, children: kids });
	}

	return length(out) ? [ { name: 'interfaces', children: out } ] : [];
}

function tags(ctx, steps, key) {
	if (key == 'wireguard')
		return map(filter(ctx.sections('network'),
			s => s.type == 'interface' && s.opts.proto == 'wireguard'), s => s.label);

	if (key == 'peer' && length(steps) >= 1 && steps[0].tag) {
		let pt = peer_type(steps[0].tag);

		return map(filter(ctx.sections('network'),
			s => s.type == pt && s.opts.public_key != null), s => s.opts.public_key);
	}

	return [];
}

return {
	mounts: { 'interfaces wireguard': GRAMMAR },
	set, del, render, tags
};
