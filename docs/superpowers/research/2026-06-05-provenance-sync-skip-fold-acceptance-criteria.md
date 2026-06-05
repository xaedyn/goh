---
date: 2026-06-05
feature: provenance-sync-skip-fold
type: acceptance-criteria
---

# Acceptance Criteria — Record provenance for skipped/already-present `goh sync` files

AC1: When `goh sync` resolves a manifest entry as already-present-and-matching (the
`upToDate` path — on-disk SHA-256 equals the manifest pin or the prior lock entry) and
does NOT re-download it, a provenance entry for that file's canonical destination path is
present in `provenance.plist` afterward, such that `goh which <that file>` prints the
recorded `{url, sha256, size, downloadedAt}` instead of "(not recorded)".

AC2: When `goh sync` accepts a present-but-unpinned file with no prior lock entry (the
`firstUse` path) or an accepted tofu-change (the `tofuChange` accepted branch), that file
likewise appears in `provenance.plist` and is reported OK by `goh verify --all` on the
next run (its recorded SHA-256 equals the on-disk SHA-256).

AC3: The provenance entry recorded for a skipped file carries the SAME canonical
destination-path form as the download path uses (`URL(fileURLWithPath:).standardizedFileURL.path`),
so a later download to the same path updates — not duplicates — the entry, and `goh which`
resolves it by path with no double entries.

AC4: If the provenance write cannot be performed during a skip path (e.g. the daemon is
unreachable, or the store write fails), `goh sync` still completes with its pre-feature
exit code for that entry (an all-up-to-date sync that exits 0 today still exits 0), and the
failure is surfaced as a non-fatal warning — recording can never change a sync's success/exit
outcome. (Observable: with the daemon stopped, `goh sync` of an all-present manifest exits 0.)

AC5: The frozen on-disk provenance record format (`ProvenanceRecord.currentVersion`) is
unchanged; sync-verified entries are byte-compatible with download-recorded entries when
read back by `goh which` / `goh verify --all` and by the `provenance-v1.plist` golden round-trip.
