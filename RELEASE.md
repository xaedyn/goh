# goh release process

This file tracks the release pipeline for `goh`. It is deliberately explicit
about what exists today and what still needs real Developer ID credentials.

## Current automated release checks

Every PR runs the normal CI workflow:

- `ruby -c Formula/goh.rb`
- `brew style Formula/goh.rb`
- `swift build -Xswiftc -warnings-as-errors`
- `swift test`
- `swift run -c release goh-bench hash-overhead 256`

The release-artifact workflow runs on manual dispatch, `v*` tag pushes, and PRs
that touch packaging or build inputs. It currently:

- builds `goh` and `gohd` in release mode;
- creates `goh-<version>-macos-arm64.tar.gz`;
- writes a matching `.sha256` file;
- verifies the checksum, archive layout, LaunchAgent plist, and packaged
  `goh --help`;
- uploads the tarball and checksum as GitHub Actions artifacts.

These artifacts are unsigned release-candidate materials. They are not the final
trusted distribution channel.

## Signing and notarization prerequisites

The credential-backed release workflow needs these inputs before implementation:

- Apple Developer Program membership for the release team.
- A Developer ID Application certificate and private key exported as a password
  protected `.p12`.
- App Store Connect notarization credentials. Prefer an API key for CI; an
  Apple ID plus app-specific password is the fallback.
- The Apple Team ID associated with the Developer ID certificate.
- A final decision on direct-download format: ZIP, PKG, or DMG.

Planned GitHub secrets:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_KEY_P8_BASE64`

If the project uses Apple ID credentials instead of a Notary API key, replace
the three `APPLE_NOTARY_*` key secrets with:

- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

## Packaging policy

Apple's notarization guidance requires Developer ID-signed software for direct
distribution and supports notarizing ZIP archives, flat installer packages, and
disk images. The current tarball is useful for reproducibility checks, but the
credential-backed release workflow should produce a notarization submit artifact
in an Apple-supported format.

For v0.1, the likely direct-download path is:

1. Build release binaries.
2. Import the Developer ID Application certificate into a temporary keychain.
3. Sign `goh` and `gohd` with hardened runtime and a secure timestamp.
4. Stage the signed binaries, LaunchAgent plist, `LICENSE`, and `README.md`.
5. Create a ZIP for notarization.
6. Submit with `xcrun notarytool submit --wait`.
7. Download and inspect the notary log even on success.
8. Publish the signed ZIP and checksum only after local verification.

One important constraint: Apple documents that stapling cannot be applied
directly to ZIP archives, and tickets cannot currently be stapled to standalone
binaries. If offline Gatekeeper ticket availability becomes a v0.1 requirement,
switch the direct-download format to a PKG or DMG design before implementing the
credential-backed workflow.

## References

- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow)
