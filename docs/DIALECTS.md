# Writing an EdgeOS-path ("dialect") module

> SPDX-License-Identifier: MIT

A dialect module adds EdgeOS-style paths such as `port-forward rule 1 …`
or `interfaces wireguard wg0 peer … …` on top of UCI. The framework
(`confsh/dialect.uc`) does the parsing, value validation, tab
completion, `show` rendering with change markers, and
`show configuration [commands]`. A module only declares a grammar and
translates parsed commands into UCI.

The reference module is
[`dialect/port_forward.uc`](../confsh/files/usr/share/ucode/confsh/dialect/port_forward.uc),
with its test in
[`tests/t-dialect-portforward.sh`](../tests/t-dialect-portforward.sh).

## Where modules live

`/usr/share/ucode/confsh/dialect/<name>.uc`, where `<name>` is letters,
digits and `_`. Every file there is loaded. Another package can ship a
module without confsh depending on it, the same as op commands.

A module is a ucode **script**, not an ES module. It may `import`
helpers, and it must end with `return { … }`. `export` statements don't
work, because modules are loaded with `require()`.

## Mounts

```js
return {
	mounts: { 'interfaces wireguard': GRAMMAR },
	set, del, render,
	tags, suggest          // optional
};
```

A mount is the path prefix the module owns. Parent words (`interfaces`)
are shared containers, so several modules can live under `interfaces`.
Prefix ownership agreed so far:

| Mount | Owner |
|-------|-------|
| `port-forward` | confsh |
| `service nat` | confsh (planned) |
| `interfaces ethernet` (vif) | confsh (planned) |
| `interfaces wireguard`, `interfaces openvpn`, `interfaces tunnel`, `vpn ipsec` | @packerlschupfer ([#2](https://github.com/halcycon/confsh/issues/2)) |

UCI config names win: a dialect root word that matches a file in
`/etc/config` is never routed to the dialect.

## Grammar

Nodes are plain objects:

| Node | Shape | Example |
|------|-------|---------|
| Container | `{ children: { word: node, … } }` | `forward-to { address …; port … }` |
| Tag | `{ tag: '<type>', children: { … } }` | `rule 1`, `wireguard wg0`, `peer <key>` |
| Value | `{ type: '<type>' }` or `{ values: [ … ] }` | `original-port 443`, `protocol tcp` |
| Flag (no value) | `{ flag: true }` | `disable` |

A mount node may itself be a tag node. `'interfaces wireguard': { tag:
'name', children: { … } }` gives `interfaces wireguard wg0 …`.

Built-in value types: `number`, `port` (also ranges), `ipv4`,
`ipv4net`, `cidr`, `host`, `name`, `key` (base64 WireGuard key) and
`text`. Values are validated before your module is called, and errors
are reported as `Invalid value 'x' for <word>: expected …`.

## Callbacks

All callbacks receive a `ctx`:

| Field | Use |
|-------|-----|
| `ctx.cur` | UCI cursor. In `set`/`del` it is the session's working cursor; in `render` it may be the committed one |
| `ctx.touch(cfg)` | Mark a config as changed; the framework saves it to the session after your callback |
| `ctx.fail(msg)` | Abort with an error (nothing is saved) |
| `ctx.sections(cfg)` | Sections as `{ id, type, label, index, anon, opts }` (`label` is the confsh path name, `@N` for anonymous) |
| `ctx.zone_for(name)` | Firewall zone for a zone name, logical interface or device (`eth0`) |

`set` and `del` also receive the parsed path `p`:

```text
set port-forward rule 1 forward-to port 8443
p.steps = [ { key: 'port-forward' }, { key: 'rule', tag: '1' }, { key: 'forward-to' } ]
p.leaf  = 'port'          p.value = '8443'
```

`p.steps` starts at your mount word. `p.leaf` is null when the path
ends at a container or tag, as in `set port-forward rule 5` (create)
or `delete port-forward rule 5` (remove). `edit` into a tag node calls
`set` with no leaf, so creating on `set` without a leaf makes `edit`
work too. For `delete … <leaf> <value>`, `p.value` holds the value to
remove (for multi-value nodes).

- **`set(ctx, p)`**: apply to UCI. Create sections on demand, and give
  them stable names (`pf_1`, `peer_<…>`), never anonymous ones.
- **`del(ctx, p)`**: remove. Call `ctx.fail('Nothing to delete: …')` if
  the target does not exist.
- **`render(ctx)`**: return the module's EdgeOS view as top-level
  nodes, built from UCI each time:

  ```js
  [ { name: 'interfaces', children: [
        { name: 'wireguard wg0', children: [
            { name: 'address', value: '10.0.0.1/24' },
            { name: 'private-key', value: key, secret: true },
            { name: 'peer XYZ=', children: [ { name: 'allowed-ips', value: '10.0.0.2/32' } ] } ] } ] } ]
  ```

  Containers with the same name from different modules are merged, so
  each module returns only its own subtree. A multi-value node is
  several entries with the same `name`. `secret: true` masks the value
  unless `CONFSH_SHOW_SECRETS=1`. Return children in the order EdgeOS
  shows them (usually alphabetical); the framework keeps that order and
  diffs against the committed render to produce `+`/`-`/`>` markers.
- **`tags(ctx, steps, key)`** *(optional)*: completion candidates for
  a tag value, e.g. existing rule numbers or peer keys.
- **`suggest(ctx, steps, leaf)`** *(optional)*: completion candidates
  for a value without a fixed `values` list (e.g. zone names).

## State

Keep all state in UCI. Prefer the target package's own config. Settings
with no natural home (EdgeOS globals like `port-forward wan-interface`)
go in a named section of `/etc/config/confsh` (`port_forward`). Never
write files directly. Everything goes through `ctx.cur` so that
`compare`, `discard`, `commit-confirm` and `rollback` keep working.

## Tests and docs

- A `tests/t-dialect-<name>.sh` covering set, edit levels, show (both
  modes), `show configuration commands`, completion, validation errors
  and deletes. Copy `t-dialect-portforward.sh`.
- Stub any live-state commands your op commands call in `tests/stubs/`.
- Add EdgeOS rows to the cheat sheet in `docs/COMMANDS.md`.
