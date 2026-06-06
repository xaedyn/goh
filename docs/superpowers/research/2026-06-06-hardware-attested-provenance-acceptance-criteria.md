---
date: 2026-06-06
feature: hardware-attested-provenance
type: acceptance-criteria
---

# Acceptance Criteria — Hardware-attested provenance

AC1: When goh signs a trust record with its Secure Enclave key, goh can re-verify the signature as
valid; and when the signed content is altered by even one byte after signing, verification reports
the signature as **invalid/broken** — distinctly from (not conflated with) a SHA-256 byte mismatch.
(Observable: a sign→verify round-trip test returns valid; a mutate-after-sign test returns a signature
failure with its own status/exit code, separate from FAILED/MISSING.)

AC2: The signature is **additive and never fatal**. Every existing trust path — `goh verify`,
`goh verify --all [--json]`, `goh which`, and byte re-hashing against the recorded SHA-256 — produces
identical results whether or not a signature is present, and continues to work when the signing key is
absent or reset. Signing that cannot proceed (no key, key reset, SE unavailable) fails with a clear
message and a distinct exit code, and never corrupts or blocks the ledger or the byte-verify path.
(Observable: all existing verify/which tests pass unmodified; an unsigned record verifies normally; a
record whose key was destroyed still byte-verifies; "attest with no key" returns a clean error, exit ≠ 0,
ledger intact.)

AC3: A **recipient on a different machine** can verify a signed report/record **offline**, using only
the public key embedded in the artifact — no private key, no Secure Enclave, no network, no goh account.
(Observable: a test verifies a signature using only the exported public-key bytes carried in the
artifact; a tampered payload fails verification; the verifier has no access to the SE handle.)

AC4: The signature is **hardware-rooted**: the signing private key is a `SecureEnclave.P256.Signing`
key whose private material is non-exportable and is persisted only as the opaque enclave handle
(`dataRepresentation`); verification uses the P-256 public key. (Observable: the persisted key material
is the ~284-byte opaque handle, not a raw private key; the public key round-trips x963/PEM; a unit test
asserts the signer type is the Secure Enclave key, not a software key.)

AC5: **Frozen-format integrity.** The signature is added without breaking existing records: the
`provenance-v1.plist` and `verify-all-report-v1.json` golden fixtures still load/verify, and any new
signed shape carries its own version (and golden fixture) so old + unsigned records remain fully usable
by every current command. (Observable: existing golden-fixture tests pass unmodified; the new signed
format has a version constant + its own golden fixture + encode/round-trip test.)
