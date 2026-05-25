#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/dogfood-install.sh [install-root]

Installs and starts a marked local dogfood LaunchAgent for dev.goh.daemon.
The default install-root is .build/dogfood/current.
USAGE
}

if [[ $# -gt 1 ]]; then
  usage
  exit 64
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
dogfood_root="$repo_root/.build/dogfood"
install_arg="${1:-.build/dogfood/current}"

case "$install_arg" in
  /*) install_path="$install_arg" ;;
  *) install_path="$repo_root/$install_arg" ;;
esac

if [[ ! -d "$install_path" ]]; then
  echo "dogfood install not found: $install_path" >&2
  echo "run: Scripts/dogfood-build.sh" >&2
  exit 66
fi

install_root="$(cd "$install_path" && pwd -P)"
goh="$install_root/bin/goh"
gohd="$install_root/bin/gohd"

if [[ ! -x "$goh" || ! -x "$gohd" ]]; then
  echo "dogfood install is missing executable goh/gohd under: $install_root/bin" >&2
  exit 65
fi

service_name="dev.goh.daemon"
uid="$(id -u)"
launch_domain="gui/$uid"
service_target="$launch_domain/$service_name"
launch_agent="$HOME/Library/LaunchAgents/$service_name.plist"
marker="goh dogfood local LaunchAgent"
log_dir="$dogfood_root/logs"
log_path="$log_dir/goh.log"
probe_error="$log_dir/install-probe.err"

is_dogfood_plist() {
  [[ -f "$launch_agent" ]] \
    && grep -F "$marker" "$launch_agent" >/dev/null \
    && grep -F ".build/dogfood" "$launch_agent" >/dev/null
}

if [[ -f "$launch_agent" ]] && ! is_dogfood_plist; then
  echo "refusing to overwrite non-dogfood LaunchAgent: $launch_agent" >&2
  echo "stop or move the existing service before local dogfood." >&2
  exit 73
fi

if launchctl print "$service_target" >/dev/null 2>&1; then
  if ! is_dogfood_plist; then
    echo "refusing to overwrite active non-dogfood service: $service_target" >&2
    echo "stop the existing service before local dogfood." >&2
    exit 73
  fi
fi

xml_escape() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

mkdir -p "$(dirname "$launch_agent")" "$log_dir" "$dogfood_root/downloads"

escaped_gohd="$(xml_escape "$gohd")"
escaped_log="$(xml_escape "$log_path")"

cat > "$launch_agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- $marker. Safe to remove with Scripts/dogfood-reset.sh. -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$service_name</string>
    <key>MachServices</key>
    <dict>
        <key>$service_name</key>
        <true/>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>$escaped_gohd</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GOH_XPC_ALLOW_UNVALIDATED_PEERS</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$escaped_log</string>
    <key>StandardErrorPath</key>
    <string>$escaped_log</string>
</dict>
</plist>
PLIST

plutil -lint "$launch_agent" >/dev/null

launchctl bootout "$launch_domain" "$launch_agent" >/dev/null 2>&1 || true
launchctl bootstrap "$launch_domain" "$launch_agent"
launchctl kickstart -k "$service_target" >/dev/null 2>&1 || true

rm -f "$probe_error"
for _ in {1..40}; do
  if GOH_XPC_ALLOW_UNVALIDATED_PEERS=1 "$goh" ls >/dev/null 2>"$probe_error"; then
    cat <<EOF
dogfood_service=$service_target
dogfood_launch_agent=$launch_agent
dogfood_log=$log_path

Manual shell:
  export PATH="$install_root/bin:\$PATH"
  export GOH_XPC_ALLOW_UNVALIDATED_PEERS=1
EOF
    exit 0
  fi
  sleep 0.25
done

echo "dogfood daemon did not become reachable through XPC." >&2
if [[ -s "$probe_error" ]]; then
  echo "--- goh ls error ---" >&2
  cat "$probe_error" >&2
fi
if [[ -s "$log_path" ]]; then
  echo "--- gohd log tail ---" >&2
  tail -40 "$log_path" >&2
fi
exit 69

