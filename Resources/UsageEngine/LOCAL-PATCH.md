# GaoQiNianSan local scanner patch

The base remains Tokscale 4.17.0 at revision `37e347fedf8fee1059742e9fffa2deb8b4ad3bc9`. `pin.json` records the original binary SHA-256, patched source binary SHA-256, patch SHA-256 and toolchain. App packaging signs the executable again with the app's Apple Development identity.

`gqns-3.66.patch` contains these local changes:

- Deduplicate Kimi messages across wire files within the same session. Provider message IDs distinguish progressive snapshots; Kimi Code and ID-less legacy records use session/agent/wire-position provenance. Two equal-valued calls in different positions or sessions remain separate. Rebuild only the Kimi parser cache after introducing the keys.
- Add a numeric `localRecords` field to JSON reports when `GQNS_USAGE_EVENTS=1`. It includes provider response identities hashed with SHA-256, usage amounts, timestamps, session identities and workspace metadata; it excludes prompts, titles and credentials. The field contains source copies so the Swift boundary can reconcile older aggregate observations. Antigravity's provider response identity is independent of its desktop/CLI/extension session ID.
- The Swift ledger stores the union of identified events, separately retains original aggregate baselines and source coverage, and rebuilds only derived totals. Previously observed history without available source logs is preserved. Full application backups retain the SQLite tables; numeric JSON archive format 3 includes events, baselines and coverage, and still accepts formats 1 and 2.

Reproduce the source binary in a temporary checkout:

```sh
curl --fail --location https://codeload.github.com/Javis603/tokscale/tar.gz/37e347fedf8fee1059742e9fffa2deb8b4ad3bc9 -o /tmp/tokscale-base.tar.gz
mkdir -p /tmp/tokscale-gqns
 tar -xzf /tmp/tokscale-base.tar.gz --strip-components=1 -C /tmp/tokscale-gqns
cd /tmp/tokscale-gqns
patch -p1 < /absolute/path/to/gqns-3.66.patch
cargo +stable build --release --locked -p tokscale-cli
```

The release was built with Rust 1.99.0. This code is covered by the bundled MIT license. The application regression `Tests/UsageDuplicateRegression.swift` executes the real bundled binary using isolated synthetic home directories and fresh offline public-price caches; it tests log copies, equal-valued independent calls, legacy correction, missing-source retention, source transitions, export/import and atomic rejection.
