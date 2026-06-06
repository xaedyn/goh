---
date: 2026-06-06
feature: hardware-attested-provenance
type: approach-memos
---

# Approach Decision Memos — Hardware-attested provenance

The cryptographic design is settled by the research brief (sign raw stored bytes; sshsig-style
self-contained envelope with embedded pubkey + namespace; per-entry vs whole-report granularity;
`kid`+`keys.json` rotation; ECDSA non-determinism → fixtures pin payload+verify not sig bytes;
SE-key feasibility proven on ad-hoc builds). The remaining decision is **what to attest and where the
signatures live** — which determines value, surface, and frozen-format impact.

---

## APPROACH A — The Signed Receipt  *(recommended v1)*

CORE IDEA
A foreground `goh attest` / `goh verify --all --sign` produces a **self-contained, Secure-Enclave-
signed verify report** — a portable proof a recipient verifies offline — and `goh verify-attestation
<file>` checks it. The existing ledger, `gohfile.lock`, and unsigned `verify --all --json` are
untouched.

MECHANISM
Run the existing `verify --all` to get the `VerifyAllReport`; serialize it with the canonical encoder;
sign those exact bytes (wrapped in DSSE-PAE with payload type `dev.goh.verify-report.v1`) using a
Secure Enclave P-256 key; emit a new self-contained artifact `{ "report": <bytes-or-embedded>, "sig":
{ns, alg:ES256, kid, pub, sig} }`. Verification reads the artifact, re-derives the signed bytes from
the embedded report, and calls `isValidSignature` with the embedded `pub` — no private key, no SE, no
network. The SE key (284-byte handle) is created on first use and persisted 0600; a `keys.json` tracks
`kid→pub`. Optional Touch-ID gate (foreground only).

FIT ASSESSMENT
Scale fit: matches — one signature per report; sub-ms sign/verify.
Team fit: fits — CLI-local, mirrors the `--json` flag pattern; reuses the verify pipeline.
Operational: a single SE key + a small `keys.json`; no daemon change.
Stack alignment: fits — CryptoKit (already a dep), Swift Testing, golden fixture (pins payload+verify).

TRADEOFFS
Strong at: the headline demo ("a hardware-signed drift-check you can hand to a collaborator / attach to
a release / verify in CI"); smallest, safest surface; **touches no existing frozen format** (new artifact
is its own versioned shape + fixture); fully testable now.
Sacrifices: it attests a **snapshot** (the report at attest-time), not continuous tamper-evidence of the
live ledger — that's Approach B.

WHAT WE'D BUILD
A `SecureEnclaveSigner` (key create/open/persist via `dataRepresentation`, sign, kid); a
`SignedVerifyReport` envelope type + golden fixture (payload-pinned); `goh attest` / `--sign` +
`goh verify-attestation`; `keys.json` store; the DSSE-PAE canonical signing input.

THE BET
The highest-value attestation is the **portable verify report** (a proof you share), not signing every
ledger entry — so report attestation alone delivers the headline with a fraction of the surface.

REVERSAL COST
Easy — purely additive new verb(s) + artifact; nothing existing changes; remove to revert.

WHAT WE'RE NOT BUILDING
No per-entry ledger signatures; no daemon crypto; no change to `provenance.plist` / `gohfile.lock` /
`verify --all --json`.

INDUSTRY PRECEDENT
SSH signatures (`ssh-keygen -Y sign`) and minisign: self-contained, CA-free, offline-verifiable
signatures over arbitrary content `[VERIFIED]`.

---

## APPROACH B — The Sealed Ledger  *(natural Phase 2; largest surface)*

CORE IDEA
The daemon signs **each provenance entry at record-time** with a Secure Enclave key; `goh which` /
`verify --all` surface a per-entry signature status (valid / unverifiable / unknown-key), giving
continuous tamper-evidence of the whole local ledger.

MECHANISM
On every completion, after recording an entry, the daemon signs the entry's canonical bytes and stores
an additive `sig` block on the entry (`ProvenanceRecord.currentVersion 1→2`, four-round). The CLI read
paths verify each entry's signature against the embedded/`keys.json` pubkey and report status. SE key
+ handle are daemon-owned; headless, non-biometric (the daemon can't prompt Touch ID).

FIT ASSESSMENT
Scale fit: matches (sub-ms per entry) but adds a sign to the hot completion path.
Team fit: requires daemon-side crypto + key lifecycle — the largest new surface.
Operational: a daemon-owned SE key + handle + `keys.json`; signing on every download.
Stack alignment: fits CryptoKit, but bumps a frozen on-disk format (currentVersion) + daemon path.

TRADEOFFS
Strong at: continuous, whole-ledger tamper-evidence (detect malware editing `provenance.plist`).
Sacrifices: biggest surface; touches the frozen ledger format + the daemon hot path + key lifecycle in
the daemon; no Touch-ID option; the "new key, new ledger" residual attack applies to the daemon key too.

WHAT WE'D BUILD
Daemon `SecureEnclaveSigner`; `ProvenanceEntry` additive `sig` (+ currentVersion 2 + new fixture);
sign-on-record in `gohd`; signature-status rendering in `which` / `verify --all` (+ `--json` field →
reportVersion bump); `keys.json`.

THE BET
Users want always-on tamper-evidence of the entire ledger, enough to justify daemon crypto + a frozen-
format bump.

REVERSAL COST
Hard — a frozen on-disk format version (currentVersion 2) and daemon behavior are in play.

WHAT WE'RE NOT BUILDING
No portable shareable report artifact (that's A); no Touch-ID gating.

INDUSTRY PRECEDENT
Transparency-log / signed-append-log designs (per-record signatures) `[UNVERIFIED — first principles]`.

---

## APPROACH C — The Detached Seal  *(zero frozen-format change)*

CORE IDEA
Attest the report and/or ledger but keep **every signature + pubkey in separate sidecar files** — so
**no frozen format (plist or JSON) is modified at all**.

MECHANISM
`goh attest` writes a detached `<target>.sig` (the sshsig-style envelope) next to the verify report
and/or `provenance.plist`; `keys.json` holds `kid→pub`. Verification reads target bytes + the sidecar.
No version bump on any existing format.

FIT ASSESSMENT
Scale fit: matches.
Team fit: fits — pure file-side addition; no format edits.
Operational: extra sidecar files to keep alongside their targets.
Stack alignment: fits; avoids all four-round frozen-format overhead.

TRADEOFFS
Strong at: maximal additivity — literally zero change to existing on-disk/wire formats; cleanest
backward compat.
Sacrifices: looser binding (a `.sig` can be separated from its target / left stale); a sidecar lifecycle
to define; a self-contained single-file artifact (A's strength) is lost unless re-bundled.

WHAT WE'D BUILD
The `SecureEnclaveSigner`; a detached-`.sig` envelope writer/reader; `keys.json`; `goh attest` /
`verify-attestation` operating on target+sidecar pairs.

THE BET
Avoiding any frozen-format version bump is worth a looser, two-file binding.

REVERSAL COST
Easy — sidecars are deletable; nothing in the formats changed.

WHAT WE'RE NOT BUILDING
No embedded self-contained artifact; no in-format signatures.

INDUSTRY PRECEDENT
minisign / GPG detached signatures (`.sig`/`.asc` next to the file) `[VERIFIED]`.

---

## Comparison matrix

| Criterion | A — Signed Receipt | B — Sealed Ledger | C — Detached Seal |
|---|---|---|---|
| AC1 sign+verify; tamper breaks it | STRONG — report signed+verified | STRONG — per entry | STRONG — via sidecar |
| AC2 additive/non-fatal; byte-verify unchanged | STRONG — nothing existing changes | PARTIAL — daemon hot path + format bump | STRONG — zero format change |
| AC3 offline cross-machine verify via embedded pubkey | STRONG — self-contained artifact | PARTIAL — pubkey embedded per entry but no shareable artifact | PARTIAL — needs target+sidecar both |
| AC4 hardware-rooted SE key | STRONG | STRONG | STRONG |
| AC5 frozen-format integrity (additive+versioned) | STRONG — new shape only, no existing format touched | WEAK — bumps ledger currentVersion (+ maybe reportVersion) | STRONG — touches no frozen format |
| Scale fit | STRONG | STRONG (hot-path sign) | STRONG |
| Team fit | STRONG | WEAK — daemon crypto + lifecycle | STRONG |
| Operational burden | STRONG — one key, CLI-only | PARTIAL — daemon key + sign-on-record | PARTIAL — sidecar lifecycle |
| Stack alignment | STRONG | PARTIAL — frozen-format bump | STRONG |

**Recommendation: Approach A (The Signed Receipt).** It delivers the headline — a portable,
hardware-rooted, offline-verifiable proof — with the smallest, safest surface, touches no existing
frozen format, ships the demo that makes "Apple Silicon" earned, and is fully buildable/testable now.
**B (Sealed Ledger)** is the right Phase 2 if continuous whole-ledger tamper-evidence is wanted later.
**C (Detached Seal)** is really a packaging choice (detached vs embedded); A's self-contained artifact
is the more shareable form, so A subsumes C's benefit without the two-file looseness — but C is on the
table if you want literally zero frozen-format change as a hard rule.
