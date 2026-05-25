# goh release process

This file tracks the release pipeline for `goh`. It is deliberately explicit
about what exists today, what is private release-candidate machinery, and what
still needs real Developer ID credentials.

## Release posture

`goh` is not officially installable yet. The project may build formula, tarball,
PKG, signing, notarization, and stapling machinery ahead of launch, but those
steps are readiness gates, not publication gates.

Until the launch decision is made:

- do not create a public GitHub Release;
- do not publish a Homebrew tap or stable formula checksum;
- do not link users to the release-artifact workflow outputs as an install path;
- do not publish the direct-download PKG or checksum as official artifacts;
- keep README install guidance limited to source builds by people intentionally
  working from the repository.

This allows private end-to-end testing of the exact release path without
accidentally inviting normal users onto an unfinished product surface.

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
- creates `goh-<version>-macos-arm64.pkg`;
- writes a matching `.sha256` file;
- verifies the checksum, archive layout, LaunchAgent plist, and packaged
  `goh --help`;
- verifies the PKG checksum, installer metadata, macOS 26.5+ arm64
  requirement, script-free payload, LaunchAgent plist, and packaged
  `goh --help`;
- uploads the tarball, PKG, and checksums as GitHub Actions artifacts.

These artifacts are private, unsigned release-candidate materials. They are not
the final trusted distribution channel and should not be advertised as an
install path.

## Signing and notarization prerequisites

The credential-backed release workflow needs these inputs before implementation:

- Apple Developer Program membership for the release team.
- A Developer ID Application certificate and private key exported as a password
  protected `.p12` for signing `goh` and `gohd`.
- A Developer ID Installer certificate and private key exported as a password
  protected `.p12` for signing the PKG. Do not sign the installer package with
  the Application certificate.
- App Store Connect notarization credentials. Prefer an API key for CI; an
  Apple ID plus app-specific password is the fallback.
- The Apple Team ID associated with the Developer ID certificate.
- A stable release download location for the PKG and checksum, chosen only when
  the public launch gate opens.

Planned GitHub secrets:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`
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
disk images. The v0.1 direct-download path is a signed, notarized, stapled PKG.
The tarball remains useful as a reproducibility and CI inspection artifact, but
it is not the public installer.

The unsigned PKG produced today is intentionally inert. It installs:

- `/usr/local/bin/goh`
- `/usr/local/bin/gohd`
- `/usr/local/share/doc/goh/LICENSE`
- `/usr/local/share/doc/goh/README.md`
- `/usr/local/share/goh/dev.goh.daemon.plist`

It does not run scripts, copy anything into `~/Library/LaunchAgents`, or start
the daemon. The packaged plist is a reference plist with the direct-install
daemon path (`/usr/local/bin/gohd`), not an active service registration.

For the credential-backed v0.1 release path:

1. Build release binaries.
2. Import the Developer ID Application and Developer ID Installer certificates
   into a temporary keychain.
3. Sign `goh` and `gohd` with hardened runtime and a secure timestamp.
4. Stage the signed binaries, reference LaunchAgent plist, `LICENSE`, and
   `README.md`.
5. Create the PKG with a macOS 26.5+ arm64 requirement and no installer scripts.
6. Sign the PKG with the Developer ID Installer certificate.
7. Submit the signed PKG with `xcrun notarytool submit --wait`.
8. Download and inspect the notary log even on success.
9. Staple the ticket to the PKG.
10. Verify the final installer with `spctl -a -v --type install`.
11. Publish the stapled PKG and checksum only after local verification and the
    explicit public launch decision.

The PKG choice is deliberate. A ZIP is acceptable for notarization, but Apple
documents that stapling cannot be applied directly to ZIP archives, and tickets
cannot currently be stapled to standalone binaries. A stapled PKG gives direct
download users the strongest offline Gatekeeper path while keeping Homebrew as
the preferred CLI-native channel.

## References

- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow)
