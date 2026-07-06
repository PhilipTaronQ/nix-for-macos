# nix-for-macos — Design & Requirements

Status: **draft for redline**. Captures the locked requirements from the design
discussion. Nothing here is built yet.

## Goal

Produce a macOS Nix that is built **outside of Nix**, using the standard macOS
toolchain, linking **only** against macOS system libraries + frameworks, with
**no dependency on the Nix store** (no "seed store" baked into the binary). Then
package it as a `.pkg`.

Nix is still *installed* during the build — but **demoted** to a source/version
oracle: it fetches the exact dependency sources at the versions the pinned
nixpkgs specifies. The compiler and build environment are stock GitHub Actions
macOS (Apple clang). Third-party dependencies are built from those nixpkgs
sources as **static** libraries (as static as macOS allows — the goal is a `nix`
with no seed store, not a fully-static executable, which is impossible on macOS).

## Milestones

1. Produce the store-free `nix` binary on CI (build pipeline below).
2. Package it as a `.pkg` with the Swift installer.
3. **Provide our own GitHub Action** that installs the produced `.pkg` on a
   runner and builds a real project **to completion** — our own answer to
   `cachix/install-nix-action`, proving the artifact end-to-end.

## Governing principle

> **Maximize fidelity to upstream Nix built from the pinned nixpkgs.** Keep
> defaults on, keep optional libraries, match **versions**. Diverge only when
> physically impossible.

Rationale: minimize "huh, that behavior diverged" bugs between the `.pkg`-delivered
Nix and a normal nixpkgs-built Nix.

The principle auto-answers most dependency-of-dependency questions ("does libgit2
include libssh2? which libarchive formats? openssl 3 vs 1.1? which boost libs?"):
**whatever the pinned nixpkgs ships by default for `aarch64-darwin`.**

### Refinement: match versions, but explore dependency *build options*

The principle pins **versions**, not necessarily every upstream `configure`/build
flag. A dependency's build options may be **sliced to what Nix actually uses**,
with an open mind, as long as Nix's behavior is unaffected. Example: curl is a
huge dependency, but Nix uses a narrow slice of it — LDAP and other gnarly
protocols can be excised with no loss to how Nix uses curl. This is an
exploration per dependency, not a blanket rule.

### Unavoidable divergences (forced by the goal, flagged as seams to watch)

1. **Static vs dynamic linking.** nixpkgs' `nix` links its deps dynamically from
   the store. We forbid the store, so we link the *same libraries, same versions,
   statically*. Behaviorally inert for Nix's dep set in practice, but this is the
   one axis we cannot keep identical.
2. **Toolchain.** Upstream-via-nixpkgs uses nixpkgs' Clang/libc++. We use **Apple
   clang + system libc++**. Accepted because Apple's toolchain has the deepest
   testing, and a recent macOS runner's Clang/libc++ should meet or exceed
   nixpkgs' LLVM. A CI behavior-diff step measures rather than assumes this.

## Locked decisions

| Area | Decision |
|---|---|
| Build runner | `macos-26` (arm64; newest Xcode/SDK) |
| Target arch | **arm64-only** (aarch64-darwin). x86_64-darwin dropped. |
| Deployment target | `MACOSX_DEPLOYMENT_TARGET=14.0` (widest base; bump to 15 when macOS 27 is widely deployed, ~Jan) |
| Compiler / stdlib | Apple clang from Xcode + system `libc++.1.dylib` |
| Allowed dynamic links | Only `libSystem`, `libc++`, and `/System/**/Frameworks/*` (what upstream also gets from the SDK). Everything else static. |
| Demoted Nix | `cachix/install-nix-action` (upstream Nix building/evaluating upstream Nix) |
| Deps: versions | From pinned nixpkgs, evaluated for `aarch64-darwin` |
| Deps: build options | Sliced to Nix's actual usage where safe (open exploration) |
| Deps: unit tests | **Skipped with prejudice** — not useful, unlikely to work on static builds |
| S3 (`aws-crt-cpp`) | **Keep** (`-Ds3-aws-auth=enabled`) — matches upstream surface |
| Docs (`lowdown`) | **Keep** |
| `libcpuid` | **Dropped** — x86-only, unused on Apple Silicon (zero divergence) |
| `libcurl` | **Built from nixpkgs** — meson needs `>= 8.17.0`; every macOS system curl is older. OpenSSL TLS backend. |
| Components shipped | Full default install: `nix` + legacy `nix-*` + `nix-daemon` + man pages |
| Config deviation | `experimental-features = nix-command flakes` on by default (via install conf) |
| `.pkg` signing | **Unsigned for now** (no Developer ID cert yet); notarize later |

## nixpkgs pin (source of truth)

- Locked rev: **`714a5f8c4ead6b31148d829288440ed033ccc041`** (nixos-26.05.3494),
  from `flake.lock` (tarball input, not the moving channel URL).
- **Evaluation must target `aarch64-darwin`.** The dependency *graph* is
  platform-dependent (`buildInputs` differ on darwin), even though most `.src`
  fetches are not. On the arm runner this is native; anywhere else (e.g. a Linux
  host) force it: `import nixpkgs { localSystem = "aarch64-darwin"; }` or
  `--system aarch64-darwin` for pure eval.
- The workflow reads versions/sources from this pin at build time
  (`nix eval`, `nix build nixpkgs#<pkg>.src`) rather than hardcoding, so it can't
  drift from "what upstream would use."

## Dependency bill of materials (RESOLVED from the flake)

Sourced from the **flake itself** — the `buildInputs`+`propagatedBuildInputs`
closure of `packages.aarch64-darwin.nix-everything`, with `packaging/dependencies.nix`
overrides applied by the flake (not hand-replicated). Nix's own components and dep
unit-test frameworks are pruned; `nativeBuildInputs` (build tools) excluded.
Result: **50 third-party libraries** (full machine-readable graph, incl. per-lib
`cache_key`, in `bom/tiers.json`).

Concrete versions (selected): boost **1.89.0**, openssl **3.6.2**, sqlite
**3.51.2**, curl **8.20.0** (≥8.17 ✓), libgit2 **1.9.3** (override bumps to 1.9.4),
libarchive **3.8.7**, boehm-gc **8.2.12** (largeConfig), nlohmann_json **3.12.0**,
toml11 **4.4.0**, libsodium **1.0.22**, zstd **1.5.7**, brotli **1.2.0**, editline
**1.17.1**, lowdown **3.0.1**, libblake3 **1.8.5**.

Tier sizes (leaves → roots): **T0=21, T1=15, T2=6, T3=3, T4=3, T5=1, T6=1**.
`aws-crt-cpp` sits alone at T6 atop the entire AWS chain (13 of the 50 libs are the
AWS/S3 subsystem).

- **Dropped/NA:** libcpuid (x86-only), seccomp (Linux), libjail (FreeBSD)
- **`mimalloc`** is defined in `packaging/dependencies.nix` but **not** in the
  darwin `nix-everything` closure (not linked here) — so it is *not* in the BOM.
  (My earlier hand-eval wrongly added it; the flake corrected this.)
- Build tools (from demoted Nix, never compiled by us): meson, ninja, cmake,
  pkg-config.

> **Correction from the eval:** the AWS CRT tree on darwin **does** pull
> `s2n-tls` (1.7.2) via `aws-c-io`/`http`/`auth` — my earlier "no s2n on macOS"
> was wrong. Keeping S3 costs 13 libs (all `aws-c-*` + `aws-checksums` +
> `s2n-tls`), and it's the whole of tiers 3–6.

### Known wisdom: `packaging/dependencies.nix` is authoritative

Upstream Nix already ships its own dependency overrides — our build **replicates
these** (they define the fidelity baseline):

- **boost:** `enableIcu = false`; only `container, context, coroutine, iostreams,
  url` compiled. Nix uses `boost::regex` with **no ICU** (verified: no `u32regex`
  / `boost::locale` anywhere in `src/`). ⇒ **icu4c never enters the graph** — not a
  slice we invent.
- **libblake3:** `useTBB = !(… || isStatic || libcxx.isLLVM)`. We are static **and**
  Apple LLVM libc++ ⇒ upstream builds blake3 **without TBB** on macOS. ⇒ onetbb,
  hwloc, expat drop **for free, matching upstream** (keeping TBB would be the
  divergence, and hits the libc++ test failures upstream dodges).
- **curl:** `http3Support` on (ngtcp2/nghttp3 stay), + zstd/brotli/zlib; rest at
  nixpkgs defaults. This is the fidelity baseline.
- **boehmgc** largeConfig + mark-stack cflag; **libgit2 → 1.9.4**.

### Remaining slicing exploration (below upstream = deliberate divergence)

Only **curl** is left as a genuine open exploration — everything else is already at
upstream's minimal config. Curl still pulls libssh2, krb5→libedit→ncurses,
c-ares (via nghttp2's apps), libpsl→libidn2→libunistring, and libxslt→gettext
(libxslt/gettext are libpsl's build-time PSL generators — dead code to Nix). Nix
uses curl for plain HTTPS; slicing these is **below** upstream's own curl config,
so it's a deliberate divergence to be validated against the behavior-diff gate.
Read curl carefully (see Open items). Est. removable if fully sliced: ~7–9 libs.

## Runtime executable dependencies (shell-outs)

A dependency the library BOM does **not** capture: programs Nix `exec`s at runtime.
A runtime dep on a macOS-provided binary is the seed-store problem in disguise
(version-locked to the OS, divergent from upstream), so per project principle we
**bundle our own** where feasible. Inventory (from `runProgram`/`exec` call sites):

| Program | Why Nix execs it | macOS-provided | Plan |
|---|---|---|---|
| `git` | **all** git-fetcher network (fetch, ls-remote), flake ops, signature verify | ⚠️ /usr/bin/git | **bundle our own** git (nixpkgs pin, static) — biggest item |
| `ssh` | SSH stores / remote builders, git-lfs over ssh | ⚠️ /usr/bin/ssh | bundle OpenSSH (lower priority; niche paths) |
| `lsof` | GC: find processes holding roots (`_NIX_TEST_NO_LSOF` seam exists) | ⚠️ /usr/sbin/lsof | bundle, or patch GC to `libproc`/`proc_pidinfo` |
| `/bin/sh`, `bash` | pager, `nix develop`/`nix-shell -i`, remote `SHELL` | ⚠️ often Apple | builder shell is a store path (fine); bundle/point a shell for the interactive paths |
| `hg` | mercurial fetcher | ✗ opt-in | **CUT via patch** → sentinel error (see below) |
| own `nix`/`nix-env`, derivation builders, user hooks | channels, upgrade, builds | ✓ | fine (our binary / store paths / user's choice) |

Good news: the macOS **build sandbox is a libSystem API** (`sandbox_init_with_parameters`
in `darwin-derivation-builder.cc`), **not** the `sandbox-exec` binary; and unpacking
is libarchive, **not** a `tar` shell-out.

### Bundled git — DECIDED, recursed BOM

**Strategy:** bundle our own `git` (from the nixpkgs pin, `v2.54.0`), keep Nix
shelling out but to *our* absolute path. No Nix transport rewrite. This resolves
`libssh2` (cut) and removes the Apple-git dependency.

- **Recursion converges.** gitMinimal's closure overwhelmingly *reuses* our BOM
  (curl, openssl, zlib, libiconv). git's unique deps are all cuttable for Nix's
  usage (Makefile knobs): `NO_EXPAT` (push-only), `NO_GETTEXT` (translations are a
  liability when Nix parses git output), `NO_PERL`/`NO_PYTHON`/`NO_TCLTK`, omit
  `USE_LIBPCRE`; hashing via bundled `DC_SHA1` + bundled SHA256 (no
  openssl-for-hash, **no Apple CommonCrypto**). **Net new libraries: ~0.**
- **Shared, sliced curl** serves both Nix and git (git-https = curl remote-https).
  git-ssh uses the **`ssh` binary**, not curl/libgit2 — hence libssh2 is unused.
- **#1 env isolation — RESOLVED: inherit (match upstream).** Two contexts, and
  only one touches our git: `nix-fetchers` is linked by `libexpr`/`libflake` only
  (**not** `libstore`/`nix-daemon`), so native git fetch runs **client-side as the
  user**; the daemon never runs it. (The daemon's only git is a nixpkgs `fetchgit`
  FOD built under `_nixbld` with a hermetic **store git** in a scrubbed sandbox —
  not our git, already isolated.) For the client/user path we **inherit the env**:
  (1) private `git+ssh`/`git+https` inputs need the user's ssh keys/agent/`insteadOf`
  — scrubbing would break them; (2) our git is built **`NO_GETTEXT`** ⇒ always-English
  output ⇒ parsing is locale-immune (no `LC_ALL=C` needed); (3) the one footgun is
  already handled upstream (`GIT_ATTR_CHECK_NO_SYSTEM`). **Consequence:** we inherit
  user config but don't bundle `git-credential-osxkeychain`, so keychain-based git
  creds fall back to netrc/prompt — documented, acceptable (netrc is the supported
  path).
- **#2 keychain (DECIDED):** do **not** bundle `git-credential-osxkeychain` →
  no Keychain integration, netrc-based (as Nix already uses). Minimal macOS
  integration by design.
- **#4 absolute path (DECIDED):** patch Nix at build time so `runProgram("git"…)`
  (and `ssh`, `lsof`) use the absolute install path, not a PATH lookup. Patches
  live in `.github/nix/*.patch`.

### Per-executable analysis (ssh, lsof, bash, hg)

For each bundled exec: (1) calling env, (2) linked libs / BOM, (3) what it shells
out to → patch to absolute path **or** cut with a patch.

| Exec | Base | Link deps after slicing | New libs | Verdict |
|---|---|---|---|---|
| `ssh` | openssh | **openssl, zlib** (shared) — cut libfido2/libcbor/hidapi (FIDO2), ldns (DNSSEC), libedit, cmocka | ~0 | **bundle, client-sliced** |
| `lsof` | lsof | libproc (system API); ncurses cuttable | ~0 | **bundle** (or eliminate: rewrite GC to `proc_pidinfo`) |
| `bash` | bash | readline, ncurses (interactive) | +2 (readline, ncurses return) | **bundle** for the interactive fallback |
| `hg` | mercurial | **python3 + ~20 libs** | ~20 | **CUT via patch** (sentinel) |

- **ssh** — calling env inherits the local environment (`~/.ssh/config`,
  `known_hosts`, agent), sets `NIX_SSHOPTS` + remote `SHELL=/bin/sh`, execs `"ssh"`
  via PATH → **patch to our absolute path**. Slice openssh to the client without
  FIDO2/DNSSEC. Shells out to: remote command, possibly `ssh-askpass`/`ProxyCommand`
  (env-dependent — audit before finalizing).
- **lsof** — `lsof -n -w -F n` in GC (`_NIX_TEST_NO_LSOF` escape exists). Patch to
  absolute path; longer-term drop the exec entirely via `libproc`.
- **bash** — the **fallback builder**: `nix develop`/`nix-shell` build
  `bashInteractive` from `<nixpkgs>` first (store bash, fine) and only **fall back
  to PATH `"bash"`** (Apple 3.2) on failure (develop.cc:642, nix-build.cc:497) →
  patch that fallback to our bash. Re-adds `readline`+`ncurses`. The *derivation*
  builder shell is a store path (unaffected); pager + remote `SHELL` use `/bin/sh`.
- **hg** — **DECIDED: cut the mercurial input-scheme registration via patch** so
  `hg://` yields an explicit "mercurial support not included in this build" error.
  Fetcher already sets `HGPLAIN` (isolates user `.hgrc`). Not bundled ⇒ no Python.

### Principle: deliberate cuts must error explicitly (the "sigil")

Any feature we deliberately exclude (mercurial today; more later) should produce a
clear **"… not included in this build"** error — never a confusing failure like
`hg: command not found`. The explicit error is a **sentinel**: it surfaces any use
of an excluded feature, and marks exactly where a future feature must opt back in
(e.g. one "with the audacity to package `hg`" would remove that patch on purpose).

### Local source checkouts (use these, not the web — per repo tooling prefs)

- git: `~/Code/github.com/git/git` (switched to `v2.54.0`)
- curl: `~/Code/github.com/curl/curl`
- openssl: `~/Code/github.com/openssl/openssl`

Match each to the nixpkgs-pin version/tag before reading (git 2.54.0; curl 8.20.0;
openssl 3.6.2).

## Build phases (topological, leaves first)

Dependencies are built in dependency order — every dep before its dependents.
Tier 0 = deps with no third-party deps of their own; each subsequent tier depends
only on earlier tiers. **Resolved to 7 tiers / 50 libraries** (`bom/tiers.json`);
tier sizes T0=21, T1=15, T2=6, T3=3, T4=3, T5=1, T6=1.

- **Tier 0** (21) — leaves: zlib, xz, bzip2, zstd, brotli, lzo, openssl,
  libsodium, boehm-gc, nlohmann_json, libblake3, editline, lowdown, pcre2, … + the
  aws-c-common leaf
- **Tiers 1–5** — the curl stack, libgit2, libarchive, boost, and the `aws-c-*`
  chain
- **Tier 6** — aws-crt-cpp
- Each **Nix component** built (libutil, libstore, libexpr, libfetchers, …)
- The **`nix` binaries** themselves built

Dependency unit tests are skipped throughout (see locked decisions).

### BIG OPEN QUESTION (likely trivial): how do we represent the build steps?

- **Proposal:** a directory under `.github/` with `<dep>/build.sh` files, executed
  in the correct (tiered/topological) order. **Patches live alongside** as
  `<dep>/*.patch` files (needed for static-build and pkg-config fixups — see
  Open items).
- Subquestions: where does the tier ordering live (derived from the flake eval —
  see Caching — or hand-authored + verified against it?); how is the staging prefix
  / pkg-config path threaded between scripts; how much is shared boilerplate vs
  per-dep.

## Caching (GHA cache, aggressive)

- **Key = the Nix `.drv` hash, sourced from the flake.** For each dependency, take
  its `drvPath` **as evaluated through the flake** (`packages.aarch64-darwin.
  nix-everything` closure) — *not* raw nixpkgs and *not* a hand-replicated
  `.override`, because the flake's `packaging/dependencies.nix` overrides change the
  `.drv` (e.g. boost `enableIcu=false`, blake3 `useTBB=false`). The hash part of that
  `.drv` store path is the cache key. If the dep (source or recipe, incl. overrides)
  changes under a pin bump, the `.drv` changes and the cache invalidates naturally.
  These keys are precomputed in `bom/tiers.json` (`cache_key` per lib) and should be
  recomputed from the flake in-CI.
- **Plus a global salt** in the key so we can rev everything at will. Necessary
  because the `.drv` hash captures nixpkgs' source/recipe but **not our actual
  build environment** (Apple clang version, our `build.sh`, further-sliced options,
  etc.) — bumping the salt forces a clean rebuild of everything.

## Testing

- The Nix **unit tests built**
- The Nix unit tests **executed under the build-time Nix**
- The Nix unit tests **executed on the GHA runner** (against the store-free build)
- Optional: behavior-diff of the store-free `nix` vs a nixpkgs-built `nix`
  (measures the toolchain/static-link divergence)

## Build pipeline (new `macos-build.yml`)

1. `checkout` (macos-26)
2. Install demoted Nix (`cachix/install-nix-action`) — source oracle only
3. From the nixpkgs pin (`localSystem = aarch64-darwin`): resolve versions +
   fetch each dep's source; compute per-dep `.drv` cache keys (+ global salt)
4. Build deps tier-by-tier with Apple clang → static libs into a staging prefix,
   with `.pc` files; dep unit tests skipped; restore/save GHA cache per dep
5. `meson setup build` against the staging prefix: Apple clang, `-Dprefix`,
   `-Ds3-aws-auth=enabled`, lowdown on, deployment target 14.0, seccomp off
6. `ninja` → `nix`
7. **Verify:** `otool -L` shows only `/usr/lib/*` + frameworks (no dylibs, no
   `/nix/store`); `nix --version` runs with `/nix` absent; run the test suite
8. Package → `.pkg`; upload-artifact

## Install (Swift app, ports NixOS/nix-installer minus ceremony)

The `.pkg` runs a small Swift program that performs the install actions. Keeps the
**receipt/ledger** concept (the genuinely valuable part) for clean uninstall.
Each item below has its own add + remove path:

- Swift app **scaffolding** written
- **Build users** (`_nixbld*`) added and removed
- **Shell init** (`bashrc` / `zshrc`) entries added and removed
- **APFS volume** for `/nix` added and removed (root FS is read-only; created via
  `/etc/synthetic.conf` firmlink)
- **launchctl** service for the `nix-daemon` added and removed
- **`/etc/nix/nix.conf`** + install-time configuration flags
  - Use the trick: default `nix.conf` contains **only** `!include nix.install.conf`,
    and all install-time configuration (incl. `experimental-features = nix-command
    flakes`) lands in `nix.install.conf`. Keeps upstream nix.conf pristine and makes
    uninstall able to preserve user config.
- Subquests abound in each; to be expanded.

## Uninstall

- Define what **clean** means.
- Likely an **option to keep `/nix` and `nix.conf`**, especially given the
  `!include` trick (user config in `nix.conf` survives; our `nix.install.conf`
  is removed).

## Upgrade (deferred)

- `nix upgrade-nix` neutered somehow (it assumes a store-delivered Nix).
- Definition of how `.pkg` installs get upgraded.
- Defer the actual work to later.

## Actions to SHA-pin (resolved)

| Action | Tag | SHA |
|---|---|---|
| actions/checkout | v7.0.0 | `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` |
| actions/upload-artifact | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| cachix/install-nix-action | v31.10.6 | `8aa03977d8d733052d78f4e008a241fd1dbf36b3` |

## Workflow cleanup

`git rm` the upstream workflows (all orchestrate `nix build`, opposite of our
goal) and non-CI automation that's inert on a fork:

- `.github/workflows/ci.yml` (dogfoods a prebuilt store Nix)
- `.github/workflows/backport.yml` (gated `github.repository_owner == 'NixOS'`)
- `.github/workflows/labels.yml` (same gate)
- `.github/workflows/upload-release.yml` (needs NixOS secrets/environment)

Salvage only orchestration boilerplate (runner label, checkout, upload-artifact,
concurrency/permissions) into the new `macos-build.yml`.

## Open items / risks

- **Swift installer is its own subproject** — sizeable; the Rust nix-installer is
  the reference.
- **Static libc++**: we deliberately avoid it by using the *system* libc++
  (dynamic, always present, no store path). Watch for any dep insisting on static
  C++ runtime.
- **boost static** on arm64-darwin (context/coroutine asm) — verify the compiled
  boost libs build cleanly.
- **aws-crt-cpp** is the largest extra build surface (13 libs incl. s2n-tls) —
  explore with an open mind; keep unless it proves genuinely intractable.
- **curl audit — COMPLETE** (verified against every `CURLOPT` in
  `src/libstore/filetransfer.cc`; Nix only ever does http/https, with s3→https):

  | curl feature | dep | verdict | proof |
  |---|---|---|---|
  | TLS / HTTP1.1 | openssl | **KEEP** | required |
  | HTTP/2 | nghttp2 | **KEEP** | `enableHttp2` default **true** |
  | HTTP/3 | ngtcp2, nghttp3 | **KEEP** | `http3Support` (fidelity) |
  | gzip/br/zstd | zlib, brotli, zstd | **KEEP** | `ACCEPT_ENCODING ""` = all |
  | netrc/basic/SigV4 | built-in | KEEP | no extra dep |
  | cookies/PSL | libpsl | **CUT** | no cookie engine at all |
  | GSSAPI/Negotiate | krb5 | **CUT** | no `HTTPAUTH`/Negotiate |
  | async DNS | c-ares | **CUT** | only via nghttp2's *apps* |
  | IDN | libidn2 | **KEEP** | recommend keep (cheap; cut breaks Unicode hosts) |
  | SSH scp/sftp | libssh2 | **CUT** | nobody uses it (see git strategy below) |

  Proven-safe cuts (zero behavioral divergence) remove **8 libs**: `libpsl` →
  `libxslt` → `gettext` (PSL), `krb5` → `libedit` → `ncurses` (GSSAPI), `c-ares`
  (build nghttp2 library-only), and `libssh2`. **BOM 50 → 42.** Each parent is
  single, so the subtree drops cleanly. `--without-libpsl --without-gssapi
  --without-libssh2`, nghttp2 without apps; libgit2 `-DUSE_SSH=OFF`.

  `libssh2` resolves once the git strategy is fixed: Nix-libgit2 does no
  transport, git-https uses curl (no ssh), and git-ssh uses the **`ssh` binary**
  (`GIT_SSH_COMMAND`) — so libssh2 is unused by curl *and* libgit2 *and* git.

- **libgit2 does no network I/O.** `git-utils.cc` uses libgit2 for local object
  ops only; **all git fetch/ls-remote/transport shells out to the `git` CLI**
  (git-utils.cc:666). So libgit2's `libssh2`/http transport is compiled-but-unused
  — but see the shell-out problem below before cutting it.
- **openssl trust store — mechanism measured, design set, empirics pending.**
  Cert resolution (from source): Nix uses `NIX_SSL_CERT_FILE` → `SSL_CERT_FILE`
  env → `ssl-cert-file` setting, and only sets `CURLOPT_CAINFO` if non-empty
  (`filetransfer.cc:669`); otherwise openssl's default applies. openssl 3.6.2
  (`x509_def.c`) honors `SSL_CERT_FILE`/`SSL_CERT_DIR` env at runtime, else
  compile-time `OPENSSLDIR/cert.pem`.
  **Design:** build openssl with **`OPENSSLDIR=/etc/ssl`** ⇒ default CA =
  `/etc/ssl/cert.pem` (Apple-maintained, OS-updated) — integrate, don't re-ship;
  keep `SSL_CERT_FILE` as escape hatch; installer regenerates a bundle from the
  Keychain (`security find-certificate -a -p …SystemRootCertificates.keychain`)
  **only if** the system file is absent/incomplete. **No static cacert shipped.**
  Compat is fine (PEM is format-agnostic; no version issue).
  **EMPIRICS DONE — trust store RESOLVED** (probe-trust-store run 28812643834,
  macos-14.8.7/15.7.7/26.4, all arm64):
  - `/etc/ssl/cert.pem` **present on all three**, byte-identical Apple content
    (333,483 B, root:wheel, OS-updated), **128** curated public-CA roots.
  - openssl-family `s_client -CAfile /etc/ssl/cert.pem` → **Verify 0 (ok)** to
    real TLS (cache.nixos.org) on all three; Apple LibreSSL's own compiled
    `OPENSSLDIR=/private/etc/ssl` uses this same file and also validates.
  - ⇒ **Build openssl `OPENSSLDIR=/etc/ssl`** (matches the platform); default CA
    works with no env var, no bundled cacert, no Keychain export. `SSL_CERT_FILE`/
    `NIX_SSL_CERT_FILE` remains the escape hatch.
  - Nuance: the file is a **subset** of the Keychain (128 vs 154–160). Keychain-only
    enterprise/custom roots need the env override — same as every openssl tool on
    macOS. Documented, not a blocker.
- **libarchive needs care around brotli.** Static linking of brotli's three libs
  (`libbrotlicommon`/`dec`/`enc`) + libarchive's detection of them is historically
  finicky. Shouldn't be too bad, but budget for a patch.
- **Static builds are inconsistently supported across the ecosystem.** Expect to
  **patch `.pc` (pkg-config) files** and build scripts. Patches ship as
  `.github/<dep>/*.patch` next to each `build.sh`.
- **`mimalloc`** — confirm it's genuinely unused on darwin (flake closure says so)
  and we're not silently dropping the upstream allocator choice.
- **Build-step representation** — the `.github/<dep>/build.sh` (+ `*.patch`)
  proposal above.
- **Cache correctness** — the flake-sourced `.drv`-hash + global-salt scheme;
  verify it invalidates on the right changes and nothing more.
- **Notarization** deferred until a Developer ID cert exists.
