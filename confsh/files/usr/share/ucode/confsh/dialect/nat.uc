// SPDX-License-Identifier: MIT
// EdgeOS `service nat rule N …` → firewall sections named nat_<N>:
//   type destination → redirect (DNAT)
//   type source      → nat (SNAT)
//   type masquerade  → nat (MASQUERADE; ACCEPT when `exclude`)
// Until `type` is set a rule lives in a 'confsh_nat' section, which fw4
// ignores, so commands can arrive in any order (show … commands lists `type`
// last). Every change rewrites the section from a type-neutral record.
'use strict';

const FW = 'firewall';
const NEUTRAL = 'confsh_nat';

const ADDR_PORT = {
	children: {
		'address': { type: 'ipv4match' },
		'port': { type: 'port' }
	}
};

const GRAMMAR = {
	children: {
		'rule': {
			tag: 'number',
			children: {
				'description': { type: 'text' },
				'destination': ADDR_PORT,
				'disable': { flag: true },
				'exclude': { flag: true },
				'inbound-interface': { type: 'name' },
				'inside-address': { children: { 'address': { type: 'ipv4' }, 'port': { type: 'port' } } },
				'log': { values: [ 'enable', 'disable' ] },
				'outbound-interface': { type: 'name' },
				'outside-address': { children: { 'address': { type: 'ipv4' }, 'port': { type: 'port' } } },
				'protocol': { values: [ 'all', 'tcp', 'udp', 'tcp_udp', 'icmp' ] },
				'source': ADDR_PORT,
				'type': { values: [ 'source', 'destination', 'masquerade' ] }
			}
		}
	}
};

/* Record field for a path below `rule N`: 'protocol', 'source address', … */
function field(steps, leaf) {
	return (length(steps) > 2) ? `${steps[2].key} ${leaf}` : leaf;
}

/* Record field ↔ option name in the neutral section. */
function neutral_opt(f) {
	return replace(f, /[ -]/g, '_');
}

const FIELDS = [
	'description', 'destination address', 'destination port', 'disable', 'exclude',
	'inbound-interface', 'inside-address address', 'inside-address port', 'log',
	'outbound-interface', 'outside-address address', 'outside-address port',
	'protocol', 'source address', 'source port', 'type'
];

const FLAGS = [ 'disable', 'exclude' ];

function is_flag(v) {
	return type(v) == 'bool' && v;
}

/* fw4 option for each field, per fw4 section type. */
const REDIRECT_MAP = {
	'description': 'name', 'protocol': 'proto',
	'source address': 'src_ip', 'source port': 'src_port',
	'destination address': 'src_dip', 'destination port': 'src_dport',
	'inside-address address': 'dest_ip', 'inside-address port': 'dest_port'
};

const NAT_MAP = {
	'description': 'name', 'protocol': 'proto',
	'source address': 'src_ip', 'source port': 'src_port',
	'destination address': 'dest_ip', 'destination port': 'dest_port',
	'outside-address address': 'snat_ip', 'outside-address port': 'snat_port'
};

const MANAGED = {
	redirect: [ 'name', 'proto', 'src_ip', 'src_port', 'src_dip', 'src_dport', 'dest_ip', 'dest_port',
	            'src', 'dest', 'target', 'enabled', 'log' ],
	nat: [ 'name', 'proto', 'src_ip', 'src_port', 'dest_ip', 'dest_port', 'snat_ip', 'snat_port',
	       'src', 'device', 'target', 'enabled', 'log' ]
};

function str(v) {
	return (type(v) == 'array') ? join(' ', v) : v;
}

function proto_in(v) {
	return (v == 'tcp_udp') ? 'tcpudp' : v;
}

function proto_out(v) {
	v = str(v);

	return (v == 'tcpudp') ? 'tcp_udp' : v;
}

function rule_sections(ctx) {
	return filter(ctx.sections(FW), s => match(s.id, /^nat_[0-9]+$/) &&
		(s.type == NEUTRAL || s.type == 'redirect' || s.type == 'nat'));
}

/* { type, rec, extra, fwtype } for rule n, or null when it does not exist. */
function read_rule(ctx, n) {
	let id = `nat_${n}`;
	let s = filter(ctx.sections(FW), x => x.id == id)[0];

	if (!s)
		return null;

	let o = s.opts;
	let rec = {};
	let extra = {};

	if (s.type == NEUTRAL) {
		for (let f in FIELDS)
			if (o[neutral_opt(f)] != null)
				rec[f] = (index(FLAGS, f) >= 0) ? true : o[neutral_opt(f)];

		return { type: rec.type, rec, extra, fwtype: NEUTRAL };
	}

	if (s.type != 'redirect' && s.type != 'nat')
		ctx.fail(`firewall section '${id}' exists but is a '${s.type}', not a NAT rule`);

	let map = (s.type == 'redirect') ? REDIRECT_MAP : NAT_MAP;

	for (let f in keys(map))
		if (o[map[f]] != null)
			rec[f] = str(o[map[f]]);

	if (rec.protocol != null)
		rec.protocol = proto_out(rec.protocol);

	if (o.enabled == '0')
		rec.disable = true;

	if (o.log != null && o.log != '0')
		rec.log = 'enable';

	if (s.type == 'redirect') {
		rec.type = 'destination';

		if (o.src != null)
			rec['inbound-interface'] = str(o.src);
	}
	else {
		let target = lc(o.target ?? 'masquerade');

		rec.type = (target == 'snat') ? 'source' : 'masquerade';

		if (target == 'accept')
			rec.exclude = true;

		if (o.device != null || o.src != null)
			rec['outbound-interface'] = o.device ?? str(o.src);
	}

	for (let k in keys(o))
		if (index(MANAGED[s.type], k) < 0)
			extra[k] = o[k];

	return { type: rec.type, rec, extra, fwtype: s.type };
}

/* Zone holding network interface `net`, or null. */
function zone_of_network(ctx, net) {
	for (let z in ctx.sections(FW))
		if (z.type == 'zone' && index(type(z.opts.network) == 'array' ? z.opts.network : [ z.opts.network ], net) >= 0)
			return z.opts.name;

	return null;
}

function ip2int(ip) {
	let p = split(ip, '.');

	return ((int(p[0]) * 256 + int(p[1])) * 256 + int(p[2])) * 256 + int(p[3]);
}

function prefix_of(mask) {
	let n = ip2int(mask);
	let bits = 0;

	while (n > 0) {
		bits += n % 2;
		n = int(n / 2);
	}

	return bits;
}

function same_net(a, b, bits) {
	let size = 1;

	for (let i = 0; i < 32 - bits; i++)
		size *= 2;

	return int(ip2int(a) / size) == int(ip2int(b) / size);
}

/* Zone of the static interface whose subnet contains ip (the DNAT target). */
function zone_for_ip(ctx, ip) {
	for (let s in ctx.sections('network')) {
		if (s.type != 'interface' || s.opts.proto != 'static')
			continue;

		for (let a in (type(s.opts.ipaddr) == 'array') ? s.opts.ipaddr : [ s.opts.ipaddr ]) {
			let m = match(a ?? '', /^([0-9.]+)(\/([0-9]+))?$/);

			if (!m)
				continue;

			let bits = m[3] ? int(m[3]) : (s.opts.netmask ? prefix_of(s.opts.netmask) : 32);

			if (same_net(m[1], ip, bits))
				return zone_of_network(ctx, s.label);
		}
	}

	return null;
}

/*
 * outbound-interface: a zone or logical interface selects the zone; anything
 * else is matched as a device (fw4 nat `device`), as EdgeOS does with eth0.
 */
function outbound(ctx, v) {
	for (let z in ctx.sections(FW))
		if (z.type == 'zone' && z.opts.name == v)
			return { src: v };

	for (let s in ctx.sections('network'))
		if (s.type == 'interface' && s.label == v)
			return { src: ctx.zone_for(v) };

	return { device: v };
}

function need(rec, f, why) {
	return (rec[f] == null) ? why : null;
}

function write_rule(ctx, n, r) {
	let cur = ctx.cur;
	let id = `nat_${n}`;
	let rec = r.rec;
	let t = rec.type;

	if (cur.get(FW, id) != null)
		cur.delete(FW, id);

	ctx.touch(FW);

	if (t == null) {
		cur.set(FW, id, NEUTRAL);

		for (let f in FIELDS)
			if (rec[f] != null)
				cur.set(FW, id, neutral_opt(f), is_flag(rec[f]) ? '1' : rec[f]);

		return;
	}

	let bad = (f, only) => {
		if (rec[f] != null)
			ctx.fail(`service nat rule ${n}: '${f}' is only valid for ${only} rules`);
	};

	let map, fwtype;

	if (t == 'destination') {
		bad('outbound-interface', 'source and masquerade');
		bad('outside-address address', 'source');
		bad('outside-address port', 'source');

		if (rec.exclude)
			ctx.fail(`service nat rule ${n}: 'exclude' is only valid for source and masquerade rules`);

		fwtype = 'redirect';
		map = REDIRECT_MAP;
		cur.set(FW, id, fwtype);
		cur.set(FW, id, 'target', 'DNAT');

		if (rec['inbound-interface'] != null)
			cur.set(FW, id, 'src', ctx.zone_for(rec['inbound-interface']));

		let dz = rec['inside-address address'] ? zone_for_ip(ctx, rec['inside-address address']) : null;

		if (dz)
			cur.set(FW, id, 'dest', dz);
	}
	else {
		bad('inbound-interface', 'destination');
		bad('inside-address address', 'destination');
		bad('inside-address port', 'destination');

		if (t == 'masquerade') {
			bad('outside-address address', 'source');
			bad('outside-address port', 'source');
		}

		if (rec.exclude && (rec['outside-address address'] != null || rec['outside-address port'] != null))
			ctx.fail(`service nat rule ${n}: 'exclude' rules cannot have an outside-address`);

		fwtype = 'nat';
		map = NAT_MAP;
		cur.set(FW, id, fwtype);
		cur.set(FW, id, 'target', rec.exclude ? 'ACCEPT' : ((t == 'source') ? 'SNAT' : 'MASQUERADE'));

		if (rec['outbound-interface'] != null) {
			let o = outbound(ctx, rec['outbound-interface']);

			for (let k in keys(o))
				cur.set(FW, id, k, o[k]);
		}
	}

	for (let f in keys(map))
		if (rec[f] != null)
			cur.set(FW, id, map[f], (f == 'protocol') ? proto_in(rec[f]) : rec[f]);

	if (rec.disable)
		cur.set(FW, id, 'enabled', '0');

	if (rec.log == 'enable')
		cur.set(FW, id, 'log', '1');

	if (r.fwtype == fwtype)
		for (let k in keys(r.extra))
			cur.set(FW, id, k, r.extra[k]);
}

function set(ctx, p) {
	let n = p.steps[1].tag;
	let r = read_rule(ctx, n) ?? { rec: {}, extra: {}, fwtype: null };

	if (p.leaf) {
		let f = field(p.steps, p.leaf);

		r.rec[f] = p.leaf_node.flag ? true : p.value;
	}

	write_rule(ctx, n, r);
}

function del(ctx, p) {
	let s = p.steps;

	if (length(s) == 1) {
		for (let r in rule_sections(ctx))
			ctx.cur.delete(FW, r.id);

		ctx.touch(FW);
		return;
	}

	let n = s[1].tag;
	let r = read_rule(ctx, n);

	if (!r)
		ctx.fail(`Nothing to delete: service nat rule ${n} does not exist`);

	if (length(s) == 2 && !p.leaf) {
		ctx.cur.delete(FW, `nat_${n}`);
		ctx.touch(FW);
		return;
	}

	let gone = [];

	if (p.leaf)
		push(gone, field(s, p.leaf));
	else
		push(gone, `${s[2].key} address`, `${s[2].key} port`);

	gone = filter(gone, f => r.rec[f] != null);

	if (!length(gone))
		ctx.fail(`Nothing to delete: ${p.leaf ?? s[2].key} is not set`);

	if (p.leaf && p.value != null && r.rec[gone[0]] != p.value)
		ctx.fail(`Nothing to delete: ${p.leaf} is '${r.rec[gone[0]]}', not '${p.value}'`);

	for (let f in gone)
		delete r.rec[f];

	write_rule(ctx, n, r);
}

function rule_node(n, rec) {
	let kids = [];

	function pair(key) {
		let c = [];

		for (let sub in [ 'address', 'port' ])
			if (rec[`${key} ${sub}`] != null)
				push(c, { name: sub, value: rec[`${key} ${sub}`] });

		if (length(c))
			push(kids, { name: key, children: c });
	}

	function leaf(key) {
		if (is_flag(rec[key]))
			push(kids, { name: key });
		else if (rec[key] != null)
			push(kids, { name: key, value: rec[key] });
	}

	leaf('description');
	pair('destination');
	leaf('disable');
	leaf('exclude');
	leaf('inbound-interface');
	pair('inside-address');
	leaf('log');
	leaf('outbound-interface');
	pair('outside-address');
	leaf('protocol');
	pair('source');
	leaf('type');

	return { name: `rule ${n}`, children: kids };
}

function render(ctx) {
	let rules = sort(rule_sections(ctx), (a, b) => int(substr(a.id, 4)) - int(substr(b.id, 4)));
	let nodes = map(rules, s => rule_node(substr(s.id, 4), read_rule(ctx, substr(s.id, 4)).rec));

	return length(nodes) ? [ { name: 'service', children: [ { name: 'nat', children: nodes } ] } ] : [];
}

/* Commit-time checks, mirroring EdgeOS's commit errors. */
function check(ctx) {
	let errors = [];

	for (let s in rule_sections(ctx)) {
		let n = substr(s.id, 4);
		let rec = read_rule(ctx, n).rec;
		let t = rec.type;
		let problems = [];

		if (t == null) {
			push(problems, 'type must be set (source, destination or masquerade)');
		}
		else if (t == 'destination') {
			push(problems,
				need(rec, 'inbound-interface', 'inbound-interface is required'),
				need(rec, 'inside-address address', 'inside-address address is required'));
		}
		else {
			push(problems, need(rec, 'outbound-interface', 'outbound-interface is required'));

			if (t == 'source' && !rec.exclude)
				push(problems, need(rec, 'outside-address address', 'outside-address address is required'));
		}

		let ports = filter([ 'source port', 'destination port', 'inside-address port', 'outside-address port' ],
			f => rec[f] != null);

		if (length(ports) && index([ 'tcp', 'udp', 'tcp_udp' ], rec.protocol ?? ((t == 'destination') ? 'tcp_udp' : 'all')) < 0)
			push(problems, `protocol must be tcp, udp or tcp_udp when '${ports[0]}' is set`);

		for (let pr in problems)
			if (pr)
				push(errors, `service nat rule ${n}: ${pr}`);
	}

	return errors;
}

function tags(ctx, steps, key) {
	return map(rule_sections(ctx), s => substr(s.id, 4));
}

function suggest(ctx, steps, leaf) {
	if (leaf != 'inbound-interface' && leaf != 'outbound-interface')
		return [];

	let out = [];

	for (let z in ctx.sections(FW))
		if (z.type == 'zone' && z.opts.name)
			push(out, z.opts.name);

	for (let s in ctx.sections('network'))
		if (s.type == 'interface' && s.label != 'loopback') {
			push(out, s.label);

			if (s.opts.device && index(s.opts.device, '@') != 0)
				push(out, s.opts.device);
		}

	return out;
}

return {
	mounts: { 'service nat': GRAMMAR },
	set, del, render, check, tags, suggest
};
