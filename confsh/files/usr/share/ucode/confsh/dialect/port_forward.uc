// SPDX-License-Identifier: MIT
// EdgeOS `port-forward` → fw4 DNAT redirects named pf_<rule>.
// Global settings (wan/lan interface, hairpin) live in /etc/config/confsh.
'use strict';

const SETTINGS = 'port_forward';

const SETTING_OPTS = {
	'auto-firewall': 'auto_firewall',
	'hairpin-nat': 'hairpin_nat',
	'lan-interface': 'lan_interface',
	'wan-interface': 'wan_interface'
};

const RULE_OPTS = { 'description': 'name', 'original-port': 'src_dport', 'protocol': 'proto' };
const FORWARD_OPTS = { 'address': 'dest_ip', 'port': 'dest_port' };

const GRAMMAR = {
	children: {
		'auto-firewall': { values: [ 'enable', 'disable' ] },
		'hairpin-nat': { values: [ 'enable', 'disable' ] },
		'lan-interface': { type: 'name' },
		'wan-interface': { type: 'name' },
		'rule': {
			tag: 'number',
			children: {
				'description': { type: 'text' },
				'original-port': { type: 'port' },
				'protocol': { values: [ 'tcp', 'udp', 'tcp_udp' ] },
				'forward-to': {
					children: {
						'address': { type: 'ipv4' },
						'port': { type: 'port' }
					}
				}
			}
		}
	}
};

function setting(ctx, key) {
	return ctx.cur.get('confsh', SETTINGS, SETTING_OPTS[key]);
}

function rules(ctx) {
	return filter(ctx.sections('firewall'), s => s.type == 'redirect' && match(s.id, /^pf_[0-9]+$/));
}

function apply_settings(ctx, id) {
	let cur = ctx.cur;
	let hairpin = setting(ctx, 'hairpin-nat');

	cur.set('firewall', id, 'src', ctx.zone_for(setting(ctx, 'wan-interface') ?? 'wan'));
	cur.set('firewall', id, 'dest', ctx.zone_for(setting(ctx, 'lan-interface') ?? 'lan'));

	if (hairpin)
		cur.set('firewall', id, 'reflection', (hairpin == 'enable') ? '1' : '0');
	else
		cur.delete('firewall', id, 'reflection');

	ctx.touch('firewall');
}

function rule_id(ctx, n, create) {
	let id = `pf_${n}`;
	let t = ctx.cur.get('firewall', id);

	if (t != null && t != 'redirect')
		ctx.fail(`firewall section '${id}' exists but is a '${t}', not a redirect`);

	if (t == null) {
		if (!create)
			ctx.fail(`Nothing to delete: port-forward rule ${n} does not exist`);

		ctx.cur.set('firewall', id, 'redirect');
		ctx.cur.set('firewall', id, 'target', 'DNAT');
		ctx.cur.set('firewall', id, 'proto', 'tcpudp');
		apply_settings(ctx, id);
	}

	return id;
}

function set(ctx, p) {
	let s = p.steps;

	if (length(s) == 1) {
		if (!p.leaf)
			return;

		if (p.leaf == 'auto-firewall' && p.value == 'disable')
			ctx.fail('auto-firewall disable is not supported: fw4 always accepts traffic to port-forwarded hosts');

		if (p.leaf == 'wan-interface' || p.leaf == 'lan-interface')
			ctx.zone_for(p.value);

		if (ctx.cur.get('confsh', SETTINGS) == null)
			ctx.cur.set('confsh', SETTINGS, 'port_forward');

		ctx.cur.set('confsh', SETTINGS, SETTING_OPTS[p.leaf], p.value);
		ctx.touch('confsh');

		for (let r in rules(ctx))
			apply_settings(ctx, r.id);

		return;
	}

	let id = rule_id(ctx, s[1].tag, true);

	if (p.leaf) {
		let opt = (length(s) == 2) ? RULE_OPTS[p.leaf] : FORWARD_OPTS[p.leaf];
		let v = (p.leaf == 'protocol' && p.value == 'tcp_udp') ? 'tcpudp' : p.value;

		ctx.cur.set('firewall', id, opt, v);
	}

	ctx.touch('firewall');
}

function del(ctx, p) {
	let s = p.steps;
	let cur = ctx.cur;

	if (length(s) == 1) {
		if (!p.leaf) {
			for (let r in rules(ctx))
				cur.delete('firewall', r.id);

			if (cur.get('confsh', SETTINGS) != null)
				cur.delete('confsh', SETTINGS);

			ctx.touch('firewall');
			ctx.touch('confsh');

			return;
		}

		if (setting(ctx, p.leaf) == null)
			ctx.fail(`Nothing to delete: port-forward ${p.leaf} is not set`);

		cur.delete('confsh', SETTINGS, SETTING_OPTS[p.leaf]);
		ctx.touch('confsh');

		for (let r in rules(ctx))
			apply_settings(ctx, r.id);

		return;
	}

	let id = rule_id(ctx, s[1].tag, false);

	if (length(s) == 2 && !p.leaf) {
		cur.delete('firewall', id);
	}
	else if (length(s) == 3 && !p.leaf) {
		cur.delete('firewall', id, 'dest_ip');
		cur.delete('firewall', id, 'dest_port');
	}
	else {
		let opt = (length(s) == 2) ? RULE_OPTS[p.leaf] : FORWARD_OPTS[p.leaf];

		if (cur.get('firewall', id, opt) == null)
			ctx.fail(`Nothing to delete: ${p.leaf} is not set`);

		if (opt == 'proto')
			cur.set('firewall', id, 'proto', 'tcpudp');
		else
			cur.delete('firewall', id, opt);
	}

	ctx.touch('firewall');
}

function render(ctx) {
	let kids = [];

	for (let k in [ 'auto-firewall', 'hairpin-nat', 'lan-interface' ]) {
		let v = setting(ctx, k);

		if (v != null)
			push(kids, { name: k, value: v });
	}

	let rs = sort(rules(ctx), (a, b) => int(substr(a.id, 3)) - int(substr(b.id, 3)));

	for (let r in rs) {
		let o = r.opts;
		let rk = [];
		let fwd = [];

		if (o.name != null)
			push(rk, { name: 'description', value: o.name });

		if (o.dest_ip != null)
			push(fwd, { name: 'address', value: o.dest_ip });

		if (o.dest_port != null)
			push(fwd, { name: 'port', value: o.dest_port });

		if (length(fwd))
			push(rk, { name: 'forward-to', children: fwd });

		if (o.src_dport != null)
			push(rk, { name: 'original-port', value: o.src_dport });

		if (o.proto != null)
			push(rk, { name: 'protocol', value: (o.proto == 'tcpudp') ? 'tcp_udp' : `${o.proto}` });

		push(kids, { name: `rule ${substr(r.id, 3)}`, children: rk });
	}

	let wan = setting(ctx, 'wan-interface');

	if (wan != null)
		push(kids, { name: 'wan-interface', value: wan });

	return length(kids) ? [ { name: 'port-forward', children: kids } ] : [];
}

function tags(ctx, steps, key) {
	return map(rules(ctx), r => substr(r.id, 3));
}

function suggest(ctx, steps, leaf) {
	if (leaf != 'wan-interface' && leaf != 'lan-interface')
		return [];

	let out = [];

	for (let s in ctx.sections('firewall'))
		if (s.type == 'zone' && s.opts.name)
			push(out, s.opts.name);

	return out;
}

return {
	mounts: { 'port-forward': GRAMMAR },
	set, del, render, tags, suggest
};
