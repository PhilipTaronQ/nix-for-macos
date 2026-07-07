# nix-install — the macOS installer

The Swift installer engine for the macOS standalone Nix package. Design:
`DESIGN.md` §11 (design-docs branch); this package is the third sibling to
`packaging/installer/` (the classic shell bootstrap) and
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
  machinery), plus the default plan in §11.2 order.
- **`Actions/`** — one file per §11.2 action. Currently: `SyntheticConf`
  (the `/etc/synthetic.conf` firmlink line, trailing newline and all).
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
