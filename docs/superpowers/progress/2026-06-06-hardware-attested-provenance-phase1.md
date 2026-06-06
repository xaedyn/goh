---
date: 2026-06-06
feature: hardware-attested-provenance
phase: 1
status: not-started
---

# Phase 1 — Crypto core (SE signer, envelope types, key location)

Tasks 1–3. Produces all crypto/type primitives with no CLI surface.
Everything in this phase is unit-testable with a software P256 key;
no Secure Enclave required for the VERIFY side.

## Tasks
- Task 1: `AttestKeyLocation` resolver
- Task 2: `AttestTypes` (envelope, PAE builder, result schema)
- Task 3: `SecureEnclaveSigner`

## Status
- [ ] Task 1 complete
- [ ] Task 2 complete
- [ ] Task 3 complete
