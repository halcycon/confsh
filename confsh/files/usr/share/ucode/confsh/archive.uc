// SPDX-License-Identifier: MIT
'use strict';

import * as fs from 'fs';
import {
	fail, user, fmt_time, private_dir, read_json, write_json, reload,
	BACKEND, RUNDIR
} from 'confsh.util';

let uci = require('uci');

/* Kept on flash so a pending commit-confirm survives a power cycle. */
const STATE = getenv('CONFSH_STATEDIR') ?? '/etc/confsh';
const MARK = `${STATE}/confirm.json`;
const PRE = `${STATE}/confirm-pre.tar.gz`;

function positive(v, dflt) {
	let n = int(v ?? dflt);

	return (type(n) == 'int' && n >= 1) ? n : dflt;
}

export function settings() {
	let c = uci.cursor(null, `${RUNDIR}/empty`);

	return {
		max: positive(c.get('confsh', 'archive', 'max'), 20),
		path: c.get('confsh', 'archive', 'path') ?? `${STATE}/archive`,
		confirm_minutes: positive(c.get('confsh', 'confirm', 'minutes'), 10)
	};
};

function index_path(st) {
	return `${st.path}/index.json`;
}

export function list() {
	return read_json(index_path(settings()), []);
};

function snapshot(file) {
	if (system([ 'tar', '-czf', file, '-C', '/etc', 'config' ]) != 0)
		return false;

	fs.chmod(file, 0o600);

	return true;
}

/* Restores the files contained in an archive; other configs are untouched. */
function restore(file) {
	if (system([ 'tar', '-xzf', file, '-C', '/etc', 'config' ]) != 0)
		fail(`Failed to restore configuration from ${file}`);
}

export function add(comment, via) {
	let st = settings();
	let idx = list();
	let t = time();
	let name = `config.${t}.tar.gz`;

	private_dir(st.path);

	for (let n = 1; fs.stat(`${st.path}/${name}`); n++)
		name = `config.${t}-${n}.tar.gz`;

	if (!snapshot(`${st.path}/${name}`))
		fail('Failed to archive configuration');

	unshift(idx, { file: name, time: t, user: user(), via, comment });

	while (length(idx) > st.max)
		fs.unlink(`${st.path}/${pop(idx).file}`);

	write_json(index_path(st), idx);
};

/* The first commit also records the state it started from. */
export function ensure_baseline() {
	if (!length(list()))
		add('configuration before first confsh commit', 'baseline');
};

export function print_list() {
	let idx = list();

	if (!length(idx)) {
		print('No commits archived yet\n');
		return;
	}

	for (let i = 0; i < length(idx); i++) {
		let e = idx[i];

		printf('%-3d %s by %s via %s\n', i, fmt_time(e.time), e.user, e.via);

		if (e.comment)
			printf('    %s\n', e.comment);
	}
};

export function check_revision(rev) {
	let idx = list();
	let n = int(rev);

	if (type(n) != 'int' || n < 1 || n >= length(idx))
		fail(length(idx) > 1
			? `Invalid revision '${rev}': choose 1-${length(idx) - 1} (see 'show system commit')`
			: 'No earlier revision to roll back to');

	return idx[n];
};

export function rollback(rev) {
	let e = check_revision(rev);

	restore(`${settings().path}/${e.file}`);
	reload();
	add(`rollback to revision ${rev} (${fmt_time(e.time)})`, 'rollback');
};

export function confirm_pending() {
	return read_json(MARK);
};

export function confirm_prepare() {
	private_dir(STATE);

	if (!snapshot(PRE))
		fail('Failed to snapshot configuration for commit-confirm');
};

export function confirm_arm(minutes) {
	let spm = positive(getenv('CONFSH_CONFIRM_SECONDS_PER_MINUTE'), 60);
	let token = trim(fs.readfile('/proc/sys/kernel/random/uuid') ?? `${time()}`);

	write_json(MARK, {
		token,
		minutes,
		deadline: time() + minutes * spm,
		user: user()
	});

	system(`setsid ${BACKEND} confirm-timeout ${token} </dev/null >/dev/null 2>&1 &`);
};

export function confirm() {
	if (!confirm_pending())
		fail('No commit-confirm is pending');

	fs.unlink(MARK);
	fs.unlink(PRE);
};

function revert(reason, do_reload) {
	restore(PRE);
	fs.unlink(MARK);
	fs.unlink(PRE);

	if (do_reload)
		reload();

	system([ 'logger', '-t', 'confsh', reason ]);
	add(reason, 'confirm-revert');
}

/* Detached timer started by commit-confirm; exits quietly once confirmed. */
export function confirm_timeout(token) {
	while (true) {
		let m = confirm_pending();

		if (m?.token != token)
			return;

		if (time() >= m.deadline)
			break;

		sleep(1000);
	}

	revert('commit-confirm not confirmed in time: configuration reverted', true);
};

/* Called from /etc/init.d/confsh before network/firewall start. */
export function confirm_boot() {
	if (confirm_pending())
		revert('commit-confirm not confirmed before reboot: configuration reverted', false);
};
