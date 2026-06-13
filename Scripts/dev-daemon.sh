#!/usr/bin/env bash
set -euo pipefail

# dev-daemon.sh — rebuild the local dev daemon (and CLI), sign them so the signed
# menu .app can still reach them, swap them into the installed location, restart
# the LaunchAgent, and wait until `goh doctor` reports the daemon healthy.
#
# Why this exists: building goh-menu (Scripts/dev-app.sh) does NOT update the
# running daemon. The menu talks to whatever `gohd` is installed, so when you
# change daemon behaviour — or test a newer daemon command like `goh forget` —
# you must push a fresh `gohd`. Doing that by hand is error-prone; this is the one
# safe command.
#
# Two hard-won rules encoded here:
#   1. Sign with the Developer ID but WITHOUT hardened runtime (`--options runtime`).
#      A signed menu .app enforces same-team XPC peer validation, so the daemon
#      needs the same Team ID — but hardened runtime turns on library validation,
#      which the kernel SIGKILLs on a debug `swift build` binary (OS_REASON_CODESIGNING,
#      a silent crash-loop). No hardened runtime keeps the Team ID and launches.
#   2. gohd needs launchd to hand it the mach service; never run it standalone.
#
# Usage: Scripts/dev-daemon.sh        (prompts for sudo to write /usr/local/bin)
#   GOH_APP_SIGN_IDENTITY="Developer ID Application: …"  to override the identity.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
cd "$repo_root"

service_name="dev.goh.daemon"
uid="$(id -u)"
service_target="gui/$uid/$service_name"
launch_agent="$HOME/Library/LaunchAgents/$service_name.plist"

if [[ ! -f "$launch_agent" ]]; then
  echo "error: no LaunchAgent at $launch_agent — install a goh daemon first" >&2
  echo "       (a tester .pkg, or Scripts/dogfood-install.sh)" >&2
  exit 66
fi

# Where the installed daemon binary lives — read it from the LaunchAgent so we
# write back to exactly the path launchd launches. Fall back to the conventional
# location.
daemon_dest="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$launch_agent" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$launch_agent" 2>/dev/null \
  || true)"
daemon_dest="${daemon_dest:-/usr/local/bin/gohd}"
cli_dest="$(dirname "$daemon_dest")/goh"

echo "==> Building debug goh + gohd"
swift build --configuration debug --disable-sandbox >/dev/null
built_gohd="$repo_root/.build/debug/gohd"
built_goh="$repo_root/.build/debug/goh"
[[ -x "$built_gohd" && -x "$built_goh" ]] || { echo "error: build did not produce goh/gohd" >&2; exit 70; }

# Sign so the signed menu .app's same-team XPC validation accepts the daemon.
# NOTE: deliberately NO `--options runtime` — see the header.
identity="${GOH_APP_SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null \
  | grep -o 'Developer ID Application: [^"]*' | head -1)}"
if [[ -n "$identity" ]]; then
  echo "==> Signing with: $identity  (no hardened runtime)"
  codesign --force --sign "$identity" "$built_gohd"
  codesign --force --sign "$identity" "$built_goh"
else
  echo "==> No Developer ID found — ad-hoc signing (NO Team ID)."
  echo "    The daemon will only be reachable if you launch the menu with"
  echo "    GOH_XPC_ALLOW_UNVALIDATED_PEERS=1 (a signed menu .app will reject it)."
  codesign --force --sign - "$built_gohd"
  codesign --force --sign - "$built_goh"
fi

echo "==> Installing to $daemon_dest and $cli_dest (sudo)"
sudo cp "$built_gohd" "$daemon_dest"
sudo cp "$built_goh" "$cli_dest"

echo "==> Restarting $service_target"
launchctl kickstart -k "$service_target"

echo "==> Waiting for the daemon to come up…"
healthy=0
for _ in $(seq 1 30); do
  if "$cli_dest" doctor 2>/dev/null | grep -q "XPC reachable"; then
    healthy=1
    break
  fi
  sleep 0.5
done

if [[ "$healthy" -eq 1 ]]; then
  level_line="$("$cli_dest" doctor 2>/dev/null | grep -i "featureLevel" || true)"
  echo ""
  echo "✅ Daemon healthy. ${level_line:-(featureLevel line not found)}"
  echo "   Retry whatever needed the new daemon (e.g. Forget in the Trust window)."
else
  echo "" >&2
  echo "⚠️  Daemon did not report healthy within 15s. Check its state:" >&2
  echo "    launchctl print $service_target | grep -iE 'state|last exit'" >&2
  echo "    (a 'last exit reason = OS_REASON_CODESIGNING' means a signing problem)" >&2
  exit 75
fi
