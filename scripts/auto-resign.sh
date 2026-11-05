#!/bin/bash
# Keeps FitSync installed on an iPhone signed with a free Apple ID.
# Free provisioning profiles expire after 7 days, so this rebuilds and reinstalls
# the app over Wi-Fi once a day, leaving six days of slack if the iPhone is away.
#
#   scripts/auto-resign.sh install    install the launchd agent (checks every 4 hours)
#   scripts/auto-resign.sh uninstall  remove the launchd agent
#   scripts/auto-resign.sh run        renew now if due (what the agent runs)
#   scripts/auto-resign.sh force      rebuild and reinstall now
#
# Requirements: Xcode signed in with your Apple ID, the iPhone paired with
# "Connect via network" and on the same Wi-Fi as the Mac.

set -euo pipefail

LABEL="com.fitsync.auto-resign"
RENEW_EVERY_HOURS=24
PROFILE_LIFETIME_HOURS=168
CHECK_INTERVAL_SECONDS=14400

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$REPO_DIR/scripts/$(basename "$0")"
STATE_DIR="$HOME/Library/Application Support/FitSync-resign"
# Holds the expiry (epoch seconds) of the profile last installed on the iPhone.
STAMP_FILE="$STATE_DIR/installed-profile-expiry"
DERIVED_DATA="$STATE_DIR/DerivedData"
LOG_FILE="$HOME/Library/Logs/FitSync-resign.log"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/FitSync.app"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
BUNDLE_ID="$(sed -n 's/^APP_BUNDLE_ID *= *//p' "$REPO_DIR/Config.xcconfig" | tr -d '[:space:]')"

# Device UDID. Override with FITSYNC_DEVICE_UDID; otherwise the first paired iPhone is used.
DEVICE_UDID="${FITSYNC_DEVICE_UDID:-}"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"FitSync\"" >/dev/null 2>&1 || true
}

device_json() {
  local out
  out="$(mktemp)"
  xcrun devicectl list devices --json-output "$out" >/dev/null 2>&1 || true
  cat "$out"
  rm -f "$out"
}

# Prints "<udid> <tunnelState>" for the chosen iPhone.
find_device() {
  device_json | /usr/bin/python3 -I -c '
import json, sys
wanted = sys.argv[1]
devices = json.load(sys.stdin).get("result", {}).get("devices", [])
for d in devices:
    hw = d.get("hardwareProperties", {})
    udid = hw.get("udid", "")
    if hw.get("platform") != "iOS" or (wanted and udid != wanted):
        continue
    print(udid, d.get("connectionProperties", {}).get("tunnelState", "unknown"))
    break
' "$DEVICE_UDID"
}

profile_expiry() {
  security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null
}

to_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}

install_is_due() {
  [[ -f "$STAMP_FILE" ]] || return 0
  local hours_left=$(( ($(cat "$STAMP_FILE") - $(date +%s)) / 3600 ))
  (( hours_left <= PROFILE_LIFETIME_HOURS - RENEW_EVERY_HOURS ))
}

# Xcode keeps reusing a cached profile until it expires, so drop FitSync's own
# profiles to make it fetch a fresh 7-day one. Other apps' profiles are left alone.
remove_cached_profiles() {
  local f app_id
  for f in "$PROFILES_DIR"/*.mobileprovision; do
    [[ -e "$f" ]] || continue
    app_id="$(security cms -D -i "$f" 2>/dev/null \
      | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
    if [[ "$app_id" == *".$BUNDLE_ID" ]]; then
      log "Removing cached profile $(basename "$f")"
      rm -f "$f"
    fi
  done
}

renew() {
  local force="$1"
  mkdir -p "$STATE_DIR"

  if [[ "$force" != "force" ]] && ! install_is_due; then
    return 0
  fi

  local info udid state
  info="$(find_device)"
  if [[ -z "$info" ]]; then
    log "No paired iPhone found, will retry later."
    return 0
  fi
  read -r udid state <<<"$info"
  if [[ "$state" == "unavailable" ]]; then
    log "iPhone $udid is not reachable, will retry later."
    return 0
  fi

  log "Renewing FitSync on $udid"

  if [[ ! -d "$REPO_DIR/FitSync.xcodeproj" ]]; then
    log "Generating Xcode project"
    (cd "$REPO_DIR" && xcodegen generate)
  fi

  remove_cached_profiles

  if ! xcodebuild \
      -project "$REPO_DIR/FitSync.xcodeproj" \
      -scheme FitSync \
      -configuration Release \
      -destination "id=$udid" \
      -derivedDataPath "$DERIVED_DATA" \
      -allowProvisioningUpdates \
      -quiet \
      build; then
    log "Build failed"
    notify "Re-signing failed at build. See ~/Library/Logs/FitSync-resign.log"
    return 1
  fi

  if ! xcrun devicectl device install app --device "$udid" "$APP_PATH"; then
    log "Install failed"
    notify "Re-signing failed at install. Is the iPhone on the same Wi-Fi?"
    return 1
  fi

  local expiry
  expiry="$(profile_expiry "$APP_PATH/embedded.mobileprovision")"
  to_epoch "$expiry" >"$STAMP_FILE"
  log "Installed. Profile expires $expiry"
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG_FILE")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_PATH</string>
    <string>run</string>
  </array>
  <key>StartInterval</key>
  <integer>$CHECK_INTERVAL_SECONDS</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Installed $PLIST (log: $LOG_FILE)"
}

uninstall_agent() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL"
}

case "${1:-}" in
  install) install_agent ;;
  uninstall) uninstall_agent ;;
  run) renew "" ;;
  force) renew force ;;
  *) echo "usage: $0 install|uninstall|run|force" >&2; exit 2 ;;
esac
