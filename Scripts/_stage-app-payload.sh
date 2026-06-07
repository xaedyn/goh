#!/usr/bin/env bash
# _stage-app-payload.sh — shared payload staging for package-pkg.sh and
# private-release-candidate.sh. Source this file after setting:
#   repo_root, payload_root, version
# This file is sourced, not executed directly.
#
# THE BET (Approach B — All-in-One PKG): engine + tray app are versioned
# together. A single double-click installs CLI, daemon, and the tray app.
# Reversal cost is low: extract goh.app into a standalone DMG later if needed.

# Assemble goh.app into a temp dir, then copy it into the payload.
app_stage_dir="$(mktemp -d)"
app_output_dir="$app_stage_dir"

"$repo_root/Scripts/package-app.sh" "$version" "$app_output_dir"

# Install goh.app into /Applications in the payload.
app_dest="$payload_root/Applications"
mkdir -p "$app_dest"
cp -R "$app_output_dir/goh.app" "$app_dest/"
xattr -cr "$app_dest/goh.app"

# Clean up the temp staging dir (the copy is in payload_root now).
rm -rf "$app_stage_dir"
