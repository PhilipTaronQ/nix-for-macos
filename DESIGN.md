# nix-for-macos — Design & Requirements

Status: **draft for redline**. This document records the locked requirements
from the design discussion. Nothing here is built yet.

## 1. Goal

Build a macOS Nix **outside of Nix**, using the stock macOS toolchain, and ship
it as a `.pkg`. The resulting binary:

- links only against macOS system libraries and frameworks;
- has **no dependency on the Nix store** — no "seed store" baked in;
- statically links every third-party dependency (as static as macOS allows —
  the goal is a store-free `nix`, not a fully-static executable, which is
  impossible on macOS).

Nix is still *installed* during the build, but **demoted** to a source/version
oracle: it tells us exactly which dependency sources, at which versions, the
pinned nixpkgs would use. The compiler and build environment are a stock GitHub
Actions macOS runner (Apple clang).

## 2. Milestones

1. **Store-free binary.** Produce the store-free `nix` on CI (pipeline in §9).
2. **Package.** Wrap it in a `.pkg` with the Swift installer (§11).
3. **Prove it.** Ship our own GitHub Action — our answer to
   `cachix/install-nix-action` — that installs the `.pkg` on a runner and
   builds a real project to completion, proving the artifact end-to-end.

## 3. Governing principle

> **Maximize fidelity to upstream Nix built from the pinned nixpkgs.** Keep
> defaults on, keep optional libraries, match versions. Diverge only when
> physically impossible.

The point is to minimize "huh, that behavior diverged" bugs between the
`.pkg`-delivered Nix and a normal nixpkgs-built Nix. The principle also
auto-answers most dependency-of-dependency questions ("does libgit2 include
libssh2? which libarchive formats? openssl 3 or 1.1? which boost libs?"):
**whatever the pinned nixpkgs ships by default for `aarch64-darwin`.**

### Refinement: versions are pinned; build *options* may be sliced

The principle pins **versions**, not every upstream `configure` flag. A
dependency's build options may be reduced to what Nix actually uses, provided
Nix's behavior is unaffected. Example: curl is enormous, but Nix uses a narrow
slice of it — LDAP and other exotic protocols can be removed without changing
how Nix behaves. This is a per-dependency investigation, not a blanket rule.
(The curl investigation is complete; see §6.3.)

### The two unavoidable divergences

Both are forced by the goal. Both are seams to watch, and the behavior-diff
test in §10 exists to measure them.

1. **Static vs. dynamic linking.** nixpkgs' `nix` links its dependencies
   dynamically from the store. We forbid the store, so we link the *same
   libraries at the same versions*, statically. In practice this should be
   behaviorally inert for Nix's dependency set, but it is the one axis we
   cannot keep identical.
2. **Toolchain.** Upstream-via-nixpkgs compiles with nixpkgs' Clang/libc++. We
   use **Apple clang + the system libc++**. Accepted because Apple's toolchain
   is the most heavily tested on this platform, and a recent runner's
   Clang/libc++ should meet or exceed nixpkgs' LLVM — but we measure this
   rather than assume it.

## 4. Locked decisions

| Area | Decision |
|---|---|
| Build runner | `macos-26` (arm64; newest Xcode/SDK) |
| Target arch | **arm64-only** (aarch64-darwin). x86_64-darwin dropped. |
| Deployment target | `MACOSX_DEPLOYMENT_TARGET=14.0` (widest base; bump to 15 when macOS 27 is widely deployed, ~Jan) |
| Compiler / stdlib | Apple clang from Xcode + system `libc++.1.dylib` |
| Allowed dynamic links | Only `libSystem`, `libc++`, `/usr/lib/libiconv.dylib` + `/usr/lib/libcharset.1.dylib` (§6.5), `/usr/lib/libresolv.9.dylib` (ssh only, §7.2), and `/System/**/Frameworks/*`. Everything else static. |
| Demoted Nix | Installed via `cachix/install-nix-action`; used only as source/version oracle |
| Dependency versions | From the pinned nixpkgs, evaluated for `aarch64-darwin` |
| Dependency build options | Sliced to Nix's actual usage where provably safe (§3 refinement) |
| Dependency unit tests | **Skipped with prejudice** — not useful, unlikely to work on static builds |
| S3 support (`aws-crt-cpp`) | **Keep** (`-Ds3-aws-auth=enabled`) — matches upstream surface |
| Docs (`lowdown`) | **Keep** |
| `libcpuid` | **Dropped** — x86-only, unused on Apple Silicon (zero divergence) |
| `libcurl` | **Built from nixpkgs source** — meson requires curl ≥ 8.17.0 and every macOS system curl is older. OpenSSL TLS backend. |
| TLS trust store | openssl built with `OPENSSLDIR=/etc/ssl`, using Apple's OS-maintained `/etc/ssl/cert.pem`; no bundled cacert (§8) |
| `libiconv` | **System dylib** (`/usr/lib/libiconv.dylib`) — neither BOM copy is built (§6.5) |
| Components shipped | Full default install: `nix` + legacy `nix-*` + `nix-daemon` + man pages |
| Config deviation | `experimental-features = nix-command flakes` on by default (via install-time conf, §11) |
| Bundled executables | `git`, `ssh`, `lsof`, `bash` bundled; `hg` cut with a sentinel error (§7) |
| `.pkg` signing | **Unsigned for now** (no Developer ID cert yet); notarize later |

## 5. The nixpkgs pin (source of truth)

- Locked rev: **`714a5f8c4ead6b31148d829288440ed033ccc041`** (nixos-26.05.3494),
  taken from `flake.lock` (the tarball input, not the moving channel URL).
- **Evaluation must target `aarch64-darwin`.** The dependency *graph* is
  platform-dependent (`buildInputs` differ on darwin) even though most `.src`
  fetches are not. On the arm runner this is native; anywhere else (e.g. a
  Linux host), force it with `import nixpkgs { localSystem = "aarch64-darwin"; }`
  or `--system aarch64-darwin` for pure eval.
- The workflow reads versions and sources from this pin at build time
  (`nix eval`, `nix build nixpkgs#<pkg>.src`) rather than hardcoding them, so
  the build cannot drift from what upstream would use.

## 6. Library dependencies (bill of materials)

### 6.1 How the BOM was derived

The BOM is the `buildInputs` + `propagatedBuildInputs` closure of
`packages.aarch64-darwin.nix-everything`, **evaluated through the flake** so
that `packaging/dependencies.nix` overrides are applied exactly as upstream
applies them (not hand-replicated). Nix's own components and the dependencies'
unit-test frameworks are pruned; `nativeBuildInputs` (build tools) are
excluded.

Result: **50 third-party libraries.** The full machine-readable graph,
including a per-library `cache_key`, lives in `bom/tiers.json`.

Selected versions: boost **1.89.0**, openssl **3.6.2**, sqlite **3.51.2**,
curl **8.20.0** (satisfies the ≥ 8.17 requirement), libgit2 **1.9.3** (upstream
override bumps it to 1.9.4), libarchive **3.8.7**, boehm-gc **8.2.12**
(largeConfig), nlohmann_json **3.12.0**, toml11 **4.4.0**, libsodium
**1.0.22**, zstd **1.5.7**, brotli **1.2.0**, editline **1.17.1**, lowdown
**3.0.1**, libblake3 **1.8.5**.

Facts established by the flake eval:

- **The AWS subsystem costs 13 of the 50 libraries** (all `aws-c-*`,
  `aws-checksums`, and `s2n-tls` 1.7.2 — which the CRT tree *does* pull on
  darwin, via `aws-c-io`/`http`/`auth`). It occupies the whole of tiers 3–6.
- **`mimalloc` is not in the darwin `nix-everything` closure**, despite being
  defined in `packaging/dependencies.nix`. It is therefore not in the BOM
  (confirming this is an open item, §14).
- **Not applicable on this platform:** libcpuid (x86-only), seccomp (Linux),
  libjail (FreeBSD).
- **Build tools we never compile** (they come from the demoted Nix): meson,
  ninja, cmake, pkg-config.

### 6.2 Upstream's own slicing (`packaging/dependencies.nix` is authoritative)

Upstream Nix already ships dependency overrides. These define the fidelity
baseline, and we replicate them:

- **boost:** `enableIcu = false`; only `container, context, coroutine,
  iostreams, url` are compiled. Nix uses `boost::regex` with no ICU (verified:
  no `u32regex` / `boost::locale` anywhere in `src/`). Consequence: **icu4c
  never enters the graph** — that is upstream's slice, not one we invented.
- **libblake3:** `useTBB = !(… || isStatic || libcxx.isLLVM)`. We are static
  *and* on Apple's LLVM libc++, so upstream itself builds blake3 **without
  TBB** in our configuration. Consequence: onetbb, hwloc, and expat drop for
  free, *matching* upstream. (Keeping TBB would be the divergence, and would
  hit the libc++ test failures upstream deliberately avoids.)
- **curl:** `http3Support` on (so ngtcp2 and nghttp3 stay), plus
  zstd/brotli/zlib; everything else at nixpkgs defaults.
- **boehmgc:** largeConfig + the mark-stack cflag.
- **libgit2:** bumped to 1.9.4 (exact tag + hash; sourced via a per-dep
  fetch override, §9.2 — raw `nixpkgs#libgit2` would give 1.9.3).
- **sqlite:** nixpkgs sets ~20 `SQLITE_ENABLE_*` feature defines via CFLAGS
  (FTS5, JSON1, RTREE, `MAX_VARIABLE_NUMBER=250000`, …). These are
  behavior-critical to Nix's database and are mirrored verbatim (oracle:
  `nix eval …#sqlite.env.NIX_CFLAGS_COMPILE`).

### 6.3 Our slicing: the curl audit (complete)

Curl was the one dependency worth slicing below upstream's own configuration.
The audit verified every `CURLOPT` Nix sets in `src/libstore/filetransfer.cc`;
Nix only ever speaks http/https (s3 URLs resolve to https).

| curl feature | dep | verdict | proof |
|---|---|---|---|
| TLS / HTTP1.1 | openssl | **KEEP** | required |
| HTTP/2 | nghttp2 | **KEEP** | `enableHttp2` defaults to true |
| HTTP/3 | ngtcp2, nghttp3 | **KEEP** | `http3Support` (fidelity) |
| gzip/br/zstd | zlib, brotli, zstd | **KEEP** | `ACCEPT_ENCODING ""` = all |
| netrc/basic/SigV4 | built-in | KEEP | no extra dep |
| IDN | libidn2 | **KEEP** | cheap; cutting it breaks Unicode hostnames |
| cookies/PSL | libpsl | **CUT** | Nix enables no cookie engine at all |
| GSSAPI/Negotiate | krb5 | **CUT** | Nix sets no `HTTPAUTH`/Negotiate |
| async DNS | c-ares | **CUT** | only reached via nghttp2's *apps*, not its library |
| SSH scp/sftp | libssh2 | **CUT** | unused by curl, libgit2, *and* our git (§7.1) |

The cuts remove clean single-parent subtrees, **8 libraries total**:
`libpsl → libxslt → gettext` (libxslt and gettext are only libpsl's build-time
PSL generators — dead code to Nix), `krb5 → libedit → ncurses`, `c-ares`, and
`libssh2`. **BOM: 50 → 42.**

Implementation: curl `--without-libpsl --without-gssapi --without-libssh2`;
nghttp2 built library-only (no apps); libgit2 `-DUSE_SSH=OFF`.

Two clarifications from building the cuts: **libxml2 is not part of the
cut** — libxslt goes, but libarchive independently needs libxml2 (xar
support), so it stays in the 42. And the HTTP/3 keep is **de-risked**:
`libngtcp2_crypto_ossl.a` builds and links against the pinned openssl 3.6.2
(the openssl-QUIC TLS API), which was the least-traveled corner of the
whole stack.

These cuts are deliberate divergences below upstream's curl config, so they are
validated by the behavior-diff gate in §10.

### 6.4 Build tiers (topological, leaves first)

Every dependency builds before its dependents. Tier 0 has no third-party deps;
each later tier depends only on earlier ones. The resolved graph
(`bom/tiers.json`) has **7 tiers**: T0=21, T1=15, T2=6, T3=3, T4=3, T5=1, T6=1.

- **Tier 0** (21 leaves): zlib, xz, bzip2, zstd, brotli, lzo, openssl,
  libsodium, boehm-gc, nlohmann_json, libblake3, editline, lowdown, pcre2, …,
  plus the `aws-c-common` leaf.
- **Tiers 1–5:** the curl stack, libgit2, libarchive, boost, and the
  `aws-c-*` chain.
- **Tier 6:** `aws-crt-cpp`, alone atop the entire AWS chain.

After the dependency tiers: each Nix component (libutil, libstore, libexpr,
libfetchers, …), then the `nix` binaries themselves.

**Status (2026-07-06): tiers 0–2 are built** — 34 of the 42 BOM entries,
zero patches (`.github/deps/`, §9.2). Remaining: curl and the upper AWS
chain (aws-c-http, -event-stream, -auth, -mqtt, -s3, aws-crt-cpp), tiers
3–6.

### 6.5 libiconv — use the system dylib (decided)

Nix itself contains no iconv call sites; iconv is purely transitive. The
BOM's two libiconv entries resolve as follows: **Apple's libiconv 113** is
what `pkgs.libiconv` *means* on aarch64-darwin at the pin (built from
`apple-oss-distributions/libiconv`), and **GNU 1.19** (`libiconvReal`)
enters through exactly one edge — libunistring's propagated dependency
(libunistring survives the §6.3 cuts because libidn2 keeps it).

**Decision: link `/usr/lib/libiconv.dylib`; build neither copy.** The §4
allowlist grows by this one entry.

- **Consumers after slicing:** libidn2/libunistring (non-ASCII hostnames →
  punycode); the bundled git (`compat/precompose_utf8.c` — darwin filename
  NFC/NFD handling, genuinely load-bearing on macOS — plus commit
  re-encoding and `working-tree-encoding`); libgit2 (darwin `USE_ICONV`,
  same precompose concern); boost (vestigial — iconv serves Boost.Locale,
  which is not among our five sliced boost libs).
- **The known complaints target the implementation, not the linking mode.**
  Since macOS 14, Apple's libiconv is a Citrus/FreeBSD reimplementation that
  reports itself as "GNU libiconv 1.11". Documented bugs (R project blog,
  2024-12): silent transliteration of non-representable characters, BOM
  state lost across resets/incomplete sequences (breaks iterative UTF-16/32
  decoding), and an EILSEQ-cascade crash. But **the pinned nixpkgs
  `libiconv-113` is this same Citrus code** — avoiding the system dylib does
  not avoid the bugs; only a GNU-everywhere divergence would, and that
  breaks fidelity to upstream's own darwin choice.
- **Exposure:** the bugs live in streaming/stateful corners. Nix's iconv
  surface is short, stateless, whole-buffer hostname/filename conversions.
  git's `working-tree-encoding=UTF-16` is the one path nearby — and Apple's
  own git links the same system iconv, so the bundled git has exact platform
  parity.
- **ABI:** `libiconv.2.dylib` has kept its install name for ~20 years, lives
  in the dyld shared cache, and every SDK ships its `.tbd`. The GNU-header
  symbol trap (GNU's `iconv.h` rewrites `iconv_open` → `libiconv_open`;
  MacPorts #57821) cannot occur here: staging contains no GNU iconv, so
  everything compiles against the SDK's `iconv.h`.
- **Accepted divergences:** libunistring's GNU-1.19 edge becomes
  Apple-Citrus, and the version drifts with the OS (which mostly means
  receiving Apple's fixes). **Escape hatch** if a real encoding bug bites:
  statically build GNU 1.19 for the affected consumer — the same move CRAN
  made with its static libiconv-64.
- **Companion library:** libarchive's iconv detection also emits
  `-lcharset`. `/usr/lib/libcharset.1.dylib` ships from the same Apple
  libiconv project and is allowlisted alongside (§4).

**This closes tier 0:** 18 of its 21 BOM entries are built
(`.github/deps/`), both libiconv entries resolve to the system dylib, and
c-ares, ncurses, and publicsuffix-list are §6.3 cuts.

## 7. Bundled executables (runtime shell-outs)

The library BOM misses one class of dependency: programs Nix `exec`s at
runtime. Depending on a macOS-provided binary is the seed-store problem in
disguise — version-locked to the OS and divergent from upstream — so per the
governing principle we **bundle our own** where feasible.

Inventory, from auditing every `runProgram`/`exec` call site:

| Program | Why Nix execs it | macOS provides | Decision |
|---|---|---|---|
| `git` | all git-fetcher network I/O (fetch, ls-remote), flake ops, signature verify | ⚠️ /usr/bin/git | **bundle** (§7.1) — the biggest item |
| `ssh` | SSH stores / remote builders, git-lfs over ssh | ⚠️ /usr/bin/ssh | **bundle**, client-sliced (§7.2) |
| `lsof` | GC: find processes holding roots | ⚠️ /usr/sbin/lsof | **bundle** (§7.2) |
| `bash` / `/bin/sh` | pager, `nix develop` / `nix-shell -i`, remote `SHELL` | ⚠️ Apple bash 3.2 | **bundle** for the interactive fallback (§7.2) |
| `hg` | mercurial fetcher | ✗ opt-in install | **CUT** via patch, with sentinel error (§7.3) |
| own `nix`/`nix-env`, derivation builders, user hooks | channels, upgrade, builds | ✓ | fine — our binary, store paths, or the user's choice |

Two things we do *not* need to bundle, confirmed from source:

- The macOS **build sandbox is a libSystem API**
  (`sandbox_init_with_parameters` in `darwin-derivation-builder.cc`), not the
  `sandbox-exec` binary.
- **Unpacking is libarchive**, not a `tar` shell-out.

All bundled executables are invoked by **absolute install path**: Nix is
patched at build time so `runProgram("git"…)` (likewise `ssh`, `lsof`) resolves
to our installed binary rather than a `PATH` lookup. Patches live in
`.github/nix/*.patch`.

### 7.1 git — bundle our own (decided)

**Strategy:** bundle git **v2.54.0** (the nixpkgs-pin version), built static.
Nix keeps shelling out to git, but to *our* absolute path. No rewrite of Nix's
git transport. This removes the Apple-git dependency and settles the libssh2
question.

**The recursion converges — net new libraries ≈ 0.** gitMinimal's closure
overwhelmingly reuses our existing BOM (curl, openssl, zlib, libiconv). Git's
unique dependencies are all removable for Nix's usage via standard Makefile
knobs: `NO_EXPAT` (push-only feature), `NO_GETTEXT` (translations are a
liability when Nix parses git output), `NO_PERL`/`NO_PYTHON`/`NO_TCLTK`, no
`USE_LIBPCRE`. Hashing uses git's bundled `DC_SHA1` and bundled SHA-256 — no
openssl-for-hash, no Apple CommonCrypto.

**One sliced curl serves both Nix and git** (git's https transport is curl's
remote-https). git's ssh transport execs the `ssh` *binary*, not
curl or libssh2 — which is why libssh2 is unused by curl, libgit2, and git
alike, and safe to cut (§6.3).

**Environment isolation — resolved: inherit the environment (match
upstream).** There are two execution contexts, and only one ever touches our
git:

- The **client/user path**: `nix-fetchers` is linked by `libexpr`/`libflake`
  only — *not* by `libstore` or `nix-daemon` — so native git fetches always run
  client-side as the user. Here we inherit the user's environment, because
  (1) private `git+ssh` / `git+https` inputs need the user's ssh keys, agent,
  and `insteadOf` config — scrubbing would break them; (2) our git is built
  `NO_GETTEXT`, so its output is always English and parsing is locale-immune
  (no `LC_ALL=C` needed); (3) the one known footgun is already handled upstream
  via `GIT_ATTR_CHECK_NO_SYSTEM`.
- The **daemon path** never runs our git: the daemon's only git use is a
  nixpkgs `fetchgit` fixed-output derivation, built under `_nixbld` with a
  hermetic store git in a scrubbed sandbox — already isolated.

**Keychain — decided: no Keychain integration.** We do not bundle
`git-credential-osxkeychain`. Since we inherit user config but omit the helper,
keychain-based git credentials fall back to netrc or prompting. netrc is the
path Nix already supports; this is documented and acceptable. Minimal macOS
integration by design.

**libgit2 stays, but does no network I/O.** `git-utils.cc` uses libgit2 for
local object operations only; all fetch/ls-remote/transport shells out to the
git CLI (git-utils.cc:666). libgit2's transport code is compiled-but-unused,
which is why `-DUSE_SSH=OFF` is safe.

### 7.2 ssh, lsof, bash

For each bundled executable we analyzed (1) its calling environment, (2) its
link dependencies after slicing, (3) what *it* shells out to.

| Exec | Base | Link deps after slicing | New libs | Verdict |
|---|---|---|---|---|
| `ssh` | openssh | openssl, zlib (both already in BOM); cut libfido2/libcbor/hidapi (FIDO2), ldns (DNSSEC), libedit, cmocka | ~0 | **bundle, client-sliced** |
| `lsof` | lsof | libproc (a system API); ncurses cuttable | ~0 | **bundle** (or eliminate the exec: rewrite GC onto `proc_pidinfo`) |
| `bash` | bash | readline, ncurses (interactive use) | +2 | **bundle** for the interactive fallback |

- **ssh.** Nix inherits the local environment (`~/.ssh/config`, `known_hosts`,
  agent), sets `NIX_SSHOPTS` and remote `SHELL=/bin/sh`, and execs `"ssh"` via
  PATH → patched to our absolute path. We slice openssh to the client, without
  FIDO2 or DNSSEC. ssh itself may exec `ssh-askpass` or a `ProxyCommand`
  depending on the user's environment — **audit before finalizing** (§14).
  As built, the ssh binary links `/usr/lib/libresolv.9.dylib` (Apple's
  OS-stable resolver, allowlisted in §4) in addition to libSystem.
- **lsof.** Nix runs `lsof -n -w -F n` during GC (the `_NIX_TEST_NO_LSOF`
  escape hatch exists). Patch to the absolute path now; longer-term, drop the
  exec entirely by using `libproc`.
- **bash.** This is only the **fallback** builder shell: `nix develop` /
  `nix-shell` first build `bashInteractive` from `<nixpkgs>` (a store bash —
  fine) and fall back to PATH `"bash"` (Apple's 3.2) only on failure
  (develop.cc:642, nix-build.cc:497). We patch that fallback to our bash. This
  re-adds readline and ncurses to the BOM. The *derivation* builder shell is a
  store path and is unaffected; the pager and remote `SHELL` use `/bin/sh`.

### 7.3 hg — cut (decided)

Bundling mercurial would mean bundling Python plus ~20 libraries. Instead we
**patch out the mercurial input-scheme registration**, so any `hg://` input
yields an explicit *"mercurial support not included in this build"* error.
(The fetcher already sets `HGPLAIN`, so there is no user-`.hgrc` isolation
issue to solve.)

### 7.4 Principle: deliberate cuts must fail loudly (the sentinel)

Any feature we deliberately exclude — mercurial today, possibly more later —
must produce a clear **"… not included in this build"** error, never a
confusing failure like `hg: command not found`. The explicit error is a
sentinel: it surfaces every use of an excluded feature in the wild, and it
marks exactly where a future contributor (one with the audacity to package
`hg`) would remove the patch to opt back in.

## 8. TLS trust store — resolved

**Decision: build openssl with `OPENSSLDIR=/etc/ssl`.** The default CA bundle
becomes `/etc/ssl/cert.pem` — Apple-maintained and OS-updated. We integrate
with the platform rather than re-shipping Mozilla's bundle: **no static cacert
is shipped**, and `SSL_CERT_FILE` / `NIX_SSL_CERT_FILE` remain the escape
hatch. The installer regenerates a bundle from the Keychain
(`security find-certificate -a -p … SystemRootCertificates.keychain`) **only
if** the system file is absent or incomplete.

How cert resolution works (from source): Nix consults `NIX_SSL_CERT_FILE` →
`SSL_CERT_FILE` → the `ssl-cert-file` setting, and sets `CURLOPT_CAINFO` only
if the result is non-empty (`filetransfer.cc:669`); otherwise openssl's default
applies. openssl 3.6.2 (`x509_def.c`) honors `SSL_CERT_FILE`/`SSL_CERT_DIR` at
runtime, else falls back to the compile-time `OPENSSLDIR/cert.pem`. PEM is
format-agnostic, so there is no compatibility concern.

Empirical validation (workflow run 28812643834; macos-14.8.7 / 15.7.7 / 26.4,
all arm64):

- `/etc/ssl/cert.pem` is **present on all three**, byte-identical Apple content
  (333,483 B, root:wheel, OS-updated), containing **128** curated public-CA
  roots.
- `s_client -CAfile /etc/ssl/cert.pem` verifies real TLS (cache.nixos.org) on
  all three: **Verify 0 (ok)**. Apple's own LibreSSL, compiled with
  `OPENSSLDIR=/private/etc/ssl`, uses this same file and also validates.
- Known nuance: the file is a **subset** of the Keychain (128 roots vs.
  154–160). Keychain-only enterprise/custom roots need the env-var override —
  exactly like every other openssl-based tool on macOS. Documented, not a
  blocker.

## 9. Build pipeline

### 9.1 Workflow steps (new `macos-build.yml`)

1. `checkout` on `macos-26`.
2. Install the demoted Nix (`cachix/install-nix-action`) — source oracle only.
3. From the nixpkgs pin (`localSystem = aarch64-darwin`): resolve versions,
   fetch each dependency's source, and compute per-dep `.drv` cache keys
   (plus the global salt, §9.3).
4. Build dependencies tier-by-tier (§6.4) with Apple clang into a staging
   prefix as static libs with `.pc` files. Dependency unit tests skipped.
   Restore/save the GHA cache per dependency.
5. `meson setup build` against the staging prefix: Apple clang, `-Dprefix`,
   `-Ds3-aws-auth=enabled`, lowdown on, deployment target 14.0, seccomp off.
6. `ninja` → `nix`.
7. **Verify:** `otool -L` shows only `/usr/lib/*` + frameworks (no other
   dylibs, no `/nix/store`); `nix --version` runs with `/nix` absent; run the
   test suite (§10).
8. Package into the `.pkg`; upload-artifact.

### 9.2 Build-step representation (settled — as built, tiers 0–2)

Build knowledge is checked in under `.github/deps/` — information
architecture, not a shared framework; each script is as bespoke as its
dependency demands.

- **`<dep>/build.sh`** — run from the unpacked source root with `$STAGING`
  set. Comments record upstream's flags — read from the oracle
  (`nix eval …#<attr>.configureFlags` / `.cmakeFlags` /
  `.env.NIX_CFLAGS_COMPILE`) — and every deliberate divergence.
- **`fetch.sh <attr> <dest>`** — pin read from `flake.lock`; normalizes the
  two source shapes (tarball vs `fetchFromGitHub` directory).
- **`<dep>/fetch.sh`** (optional override) — for flake-overridden deps:
  libgit2 pins tag+hash in lockstep with `packaging/dependencies.nix`.
- **`dep.sh <name>`** — fetch-or-build with a version stamp under
  `staging/.built/`; also confines `PKG_CONFIG_LIBDIR` to staging, so
  ambient Homebrew trees on the runner can never leak into feature
  detection.
- **`build-all.sh` + `order.txt`** — tier order, hand-authored and verified
  against the flake-derived `bom/tiers.json`; not-built-by-design entries
  (cuts, libiconv) are recorded as comments where a build would otherwise
  be missed.
- **Build tools come from the demoted Nix**: cmake/meson/ninja/pkg-config,
  plus autoconf/automake/libtool/m4 for git-snapshot sources needing
  autoreconf (with `ACLOCAL_PATH` wired to libtool's m4 dir — the
  autoreconfHook plumbing), and bmake (lowdown).
- **Known divergence:** libxml2 and libarchive build via cmake with
  upstream's feature flags mirrored — their git-snapshot trees don't
  survive a fresh autoreconf under the nix-shell toolchain. Features, not
  build system, are the fidelity surface.
- **Patches** (`<dep>/*.patch`) remain the escape hatch; none have been
  needed through tier 2 (34 libraries).

The original proposal's subquestions are all settled: ordering lives in
`order.txt` (verified against the eval), the staging prefix threads through
the `STAGING` env var, and there is no shared boilerplate.

### 9.3 Caching (GHA cache, aggressive)

- **Cache key = the dependency's `.drv` hash, sourced from the flake.** Take
  each dep's `drvPath` as evaluated through
  `packages.aarch64-darwin.nix-everything` — *not* raw nixpkgs and *not* a
  hand-replicated `.override` — because the flake's
  `packaging/dependencies.nix` overrides change the `.drv` (boost
  `enableIcu=false`, blake3 `useTBB=false`, …). The hash part of the `.drv`
  store path is the key. If a dep's source or recipe (including overrides)
  changes under a pin bump, the `.drv` changes and the cache invalidates
  naturally. Keys are precomputed in `bom/tiers.json` (`cache_key` per lib) and
  should be recomputed from the flake in CI.
- **Plus a global salt.** The `.drv` hash captures nixpkgs' source and recipe
  but **not our build environment** — Apple clang version, our `build.sh`
  contents, further-sliced options. Bumping the salt forces a clean rebuild of
  everything.

### 9.4 Actions to SHA-pin (resolved)

| Action | Tag | SHA |
|---|---|---|
| actions/checkout | v7.0.0 | `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` |
| actions/upload-artifact | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| cachix/install-nix-action | v31.10.6 | `8aa03977d8d733052d78f4e008a241fd1dbf36b3` |
| tailscale/github-action | main (post-v4.1.3; v4.1.3 lacks `log-mode`) | `508737e1960abaf049b2ca9e6519b8b4291dbf2d` |

### 9.5 Interactive debug sessions (`debug-session.yml`)

Iterating on 42 static builds by push-and-wait would be unbearable, so a
`workflow_dispatch` workflow turns a runner into a temporary dev box:

- The runner **joins the tailnet as an ephemeral node** via
  `tailscale/github-action`. macOS support verified in the action's source
  (local checkout `~/Code/github.com/tailscale/github-action`): on macOS it
  builds Tailscale from Go source (cached per version, so only the first run
  pays), and runs `tailscaled` as root with kernel networking — a real utun
  interface, so **inbound connections reach the host's sshd**. Auth is an
  API-minted auth key (`TS_AUTHKEY` repo secret): reusable + ephemeral +
  preauthorized, tagged `tag:gha-debug` (tagOwner added to the tailnet
  policy 2026-07-06). OAuth clients cannot be created via the Tailscale API,
  and auth keys live at most 90 days — **renewal due 2026-10-04** (the mint
  command is in the workflow header).
- Tailscale provides the network path only — login is macOS's **native sshd**
  (Remote Login), authorized against the dispatching user's GitHub public
  keys (`https://github.com/<actor>.keys`). No dependency on Tailscale SSH
  server support on macOS.
- **Containment + log hygiene:** the tailnet ACL's only rule is
  `src: autogroup:member → *:*`, so tagged runner nodes can be *reached* but
  cannot initiate anything into the tailnet — which also caps the blast
  radius of a leaked `TS_AUTHKEY` at "an inert, reachable node." Run logs
  are public: the action runs `log-mode: quiet` (its normal output prints
  the tailnet's MagicDNS name), and the session-info step prints only the
  deterministic hostname, never the tailscale IP.
- The SSH hold is a **middle step, not the end of the job**: ending the
  session (`touch /tmp/session-done`, or timeout) lets the remaining steps
  run — artifact upload today, per-dep GHA cache saves once tier builds
  exist. The session writes to the **same cache namespace as the real
  pipeline** (§9.3), so interactive progress is permanent progress.
- Setup before the hold mirrors `macos-build.yml` (checkout, demoted Nix,
  cache restore), so the session lands paused at pipeline step 4.
- Hosted jobs hard-stop at 6 hours: a session is a working morning, not a
  pet. Versus a local Mac, the runner is also guaranteed free of permanently
  installed cruft.

### 9.6 Workflow cleanup

`git rm` the inherited upstream workflows — they all orchestrate `nix build`,
the opposite of our goal — plus fork-inert automation:

- `.github/workflows/ci.yml` (dogfoods a prebuilt store Nix)
- `.github/workflows/backport.yml` (gated on `github.repository_owner == 'NixOS'`)
- `.github/workflows/labels.yml` (same gate)
- `.github/workflows/upload-release.yml` (needs NixOS secrets/environment)

Salvage only the orchestration boilerplate (runner label, checkout,
upload-artifact, concurrency/permissions) into `macos-build.yml`.

## 10. Testing

- Nix's **unit tests are built**.
- They are **executed under the build-time Nix**.
- They are **executed on the GHA runner** against the store-free build.
- Optional: a **behavior-diff** of the store-free `nix` against a
  nixpkgs-built `nix`. This is the gate that measures the two unavoidable
  divergences (§3) and validates the deliberate curl cuts (§6.3).

Dependency unit tests are skipped throughout (§4).

## 11. Install (`.pkg` + Swift app)

The `.pkg` runs a small Swift program that performs the install — a port of
NixOS/nix-installer (Rust) minus the ceremony. It keeps the
**receipt/ledger** concept (the genuinely valuable part of nix-installer),
so every action has a matching removal path for clean uninstall:

- Swift app scaffolding (written)
- **Build users** (`_nixbld*`) — add / remove
- **Shell init** (`bashrc` / `zshrc`) entries — add / remove
- **APFS volume** for `/nix` — add / remove (the root FS is read-only; the
  mount point is created via an `/etc/synthetic.conf` firmlink)
- **launchctl** service for `nix-daemon` — add / remove
- **`/etc/nix/nix.conf`** and install-time configuration. Trick: the default
  `nix.conf` contains **only** `!include nix.install.conf`, and all
  install-time configuration (including `experimental-features = nix-command
  flakes`) lands in `nix.install.conf`. This keeps upstream's `nix.conf`
  pristine and lets uninstall preserve user config.

Every item above still needs its own detailed breakdown.

## 12. Uninstall

- Define precisely what **clean** means.
- Likely offer an **option to keep `/nix` and `nix.conf`** — the `!include`
  trick makes this natural (user config in `nix.conf` survives; our
  `nix.install.conf` is removed).

## 13. Upgrade (deferred)

- `nix upgrade-nix` must be neutered somehow — it assumes a store-delivered
  Nix.
- Define how `.pkg` installs get upgraded.
- Actual work deferred.

## 14. Open items / risks

- **The Swift installer is its own sizeable subproject.** The Rust
  nix-installer is the reference implementation.
- **Static libc++.** We deliberately use the *system* libc++ (dynamic, always
  present, no store path). Watch for any dependency that insists on a static
  C++ runtime.
- **aws-crt-cpp** is the largest single remaining build (tier 6, C++). The
  chain below it is de-risked — 7 of the 13 AWS libs already build cleanly
  through aws-c-io — so the residual risk is crt-cpp itself.
- **ssh sub-execs.** ssh may invoke `ssh-askpass` / `ProxyCommand` depending on
  user environment — audit before finalizing the ssh bundling (§7.2).
- **Static-build patching has proven far tamer than budgeted:** 34 libraries
  through tier 2 with zero patches. `.pc` fixups may still surface at the
  final link (Libs.private chains are only exercised then); patches ship as
  `.github/deps/<dep>/*.patch` if needed (§9.2).
- **`mimalloc`.** Confirm it is genuinely unused on darwin (the flake closure
  says so) and that we are not silently dropping upstream's allocator choice.
- **Cache correctness.** Verify the flake-sourced `.drv`-hash + global-salt
  scheme invalidates on exactly the right changes and nothing more. (The
  debug-session staging cache, §9.5, deliberately uses looser version stamps
  — the `.drv` scheme is for `macos-build.yml`.)
- **Notarization** — deferred until a Developer ID cert exists.

## Appendix: local source checkouts

Per the repo's research preferences, read these checkouts instead of the web.
Switch each to the nixpkgs-pin tag before reading:

- git: `~/Code/github.com/git/git` (at `v2.54.0`)
- curl: `~/Code/github.com/curl/curl` (use tag for 8.20.0)
- openssl: `~/Code/github.com/openssl/openssl` (use tag for 3.6.2)
