# Phase 1 Progress — goh diagnose

Status: COMPLETE — Tasks 1, 2, 3 implemented and passing.

## Tasks completed

- **Task 1:** `DiagnoseConfig`, `DiagnosisReport`, `Verdict` enum, JSON codec,
  `reportVersion = 1` sentinel, `rejections: [String: Int]` (encodes as JSON
  object, not array), `wholeFileMBps` field. Golden-file fixture
  `Tests/GohCoreTests/Fixtures/diagnose-report-v1.json` locks the `--json`
  contract byte-for-byte. `rate()` helper (bytes/seconds → MB/s).

- **Task 2:** `verdict(_:config:)` pure function in `Sources/GohCore/CLI/DiagnoseTypes.swift`.
  Covers all seven v1 `Verdict` cases: `insufficientData`, `rangeUnsupported`,
  `rangeSupportedSizeUnknown`, `rateLimited`, `scaled`, `didNotScaleMultiplexed`,
  `didNotScaleHTTP1`. The honesty mechanism is the protocol-gated split — only an
  exact `http/1.1` (separate TCP connections) yields the link-vs-server-cap
  `didNotScaleHTTP1`; h2/h3/unknown take the conservative `didNotScaleMultiplexed`
  branch (multiplexed transport makes the Tₙ/T₁ ratio ambiguous). There is no
  `isHedged` flag — the hedge is *which case* is selected. The seven raw values are
  the frozen v1 `--json` contract. Exit-code mapping is driven by the typed
  `ProbeTermination`, never by `verdictText` prose.

- **Task 3:** `GohDiagnoseProbe` Phase 0 — speculative open-ended GET, parses
  `Content-Range`, sets `reachable`, `rangeSupported`, `totalBytes`,
  `networkProtocol`. Returns `ProbeTermination` on transport failure / auth /
  HTTP error. Tests cover reachable, range, transport-failure, 401/403 auth,
  non-206 (range not supported), 4xx/5xx error cases.

## Suite results (at Task 3 completion)

All diagnose-related tests passing; full suite green.
