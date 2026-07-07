# nix-install — the macOS installer

The Swift installer engine for the macOS standalone Nix package — the
third sibling to `packaging/installer/` (the classic shell bootstrap) and
`packaging/rust-installer/`.

## Shape

- **`Ledger.swift`** — the install ledger (`/var/db/nix/install-ledger.json`):
  a flat, ordered list of actions with per-entry state. Install runs
  forward, fail-fast, persisting after every transition; uninstall replays
  in reverse, best-effort. The file carries a format magic
  (`org.nixos.nix.install-ledger`) and the parser refuses anything without
  it — this installer never replays state it did not write. An `flock`
  beside the ledger serializes install/uninstall/repair.
- **`Action.swift`** — the fixed action set as a Codable enum (no plugin
  machinery), plus the default plan in execution order.
- **`Actions/`** — one file per action, the complete 15-action set:
  from `SyntheticConf` (the `/etc/synthetic.conf` firmlink line) through
  volume creation/mount, build users, `/etc/nix`, shell init, the
  nix-daemon LaunchDaemon, and the self-heal daemon.
- **`pkg/`** — `build-pkg.sh` + `Distribution.xml` assemble the flat
  `.pkg`: the `/opt/nix` payload plus `nix-install` as postinstall.
- Every system path resolves through `Context.root`, so the entire engine —
  uninstall included — runs against a scratch directory in tests, and will
  run for real in CI once the package installs and uninstalls between runs.

## Use

```
swift test                          # the engine, against scratch roots
sudo nix-install install           # apply the plan (root, real /)
sudo nix-install uninstall         # reverse-replay the ledger
nix-install plan                   # show plan/ledger state, change nothing
nix-install install --root /tmp/x  # exercise against a scratch tree
```
