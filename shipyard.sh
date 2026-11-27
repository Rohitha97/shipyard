#!/bin/bash
# shipyard.sh — on every new commit on a branch, build the Flutter app once per
# platform and install it on every physical device Flutter can see (USB or Wi-Fi).
#
#   ./shipyard.sh /path/to/flutter/repo [branch]     # watch forever
#   ONCE=1 ./shipyard.sh /path/to/flutter/repo       # check once and exit
#   INTERVAL=30 ./shipyard.sh ...                    # poll seconds (default 60)
#
# Builds in its own git worktree (~/.shipyard/<repo>/src), so your working
# checkout is never touched.
set -uo pipefail

REPO=$(cd "${1:?usage: shipyard.sh <flutter-repo> [branch]}" && pwd) || exit 1
BRANCH=${2:-main}
INTERVAL=${INTERVAL:-60}
HOME_DIR="$HOME/.shipyard/$(basename "$REPO")"
WT="$HOME_DIR/src"
SHA_FILE="$HOME_DIR/last-sha"

# Per-app settings live in ~/.shipyard/<repo>/config (plain shell), e.g.:
#   COPY="assets/fonts config/local.json"   # git-ignored files the build needs, copied from your checkout
#   FLUTTER_ARGS="--dart-define-from-file=config/local.json"
#   export FLUTTER_XCODE_DEVELOPMENT_TEAM=ABCDE12345   # if the Xcode project has no team set
COPY=""; FLUTTER_ARGS=""
[ -f "$HOME_DIR/config" ] && . "$HOME_DIR/config"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Prints "ios <id>" / "android <id>" for each connected physical device.
devices() {
  flutter devices --machine --device-timeout 10 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    p = d.get("targetPlatform", "")
    if not d.get("emulator") and (p == "ios" or p.startswith("android")):
        print(p.split("-")[0], d["id"])'
}

# Installs with devicectl/adb rather than `flutter install`, which uninstalls
# first and wipes the app's data on the device.
install_all() { # $1 = platform, $2 = artifact, stdin = device list
  local id
  grep "^$1 " | while read -r _ id; do
    log "installing on $id"
    if [ "$1" = ios ]; then
      xcrun devicectl device install app --device "$id" "$2" >/dev/null
    else
      adb -s "$id" install -r "$2" >/dev/null
    fi && log "  ok $id" || log "  FAILED $id"
  done
}

ship() {
  git -C "$WT" checkout -q --detach "origin/$BRANCH" || return 1
  cd "$WT" || return 1
  local devs
  devs=$(devices)
  [ -n "$devs" ] || { log "no devices connected, skipping"; return 0; }
  local p
  for p in $COPY; do
    mkdir -p "$(dirname "$p")" && rsync -a "$REPO/$p" "$(dirname "$p")/" || { log "missing $REPO/$p"; return 1; }
  done
  flutter pub get >/dev/null || return 1

  if grep -q '^ios ' <<<"$devs"; then
    # release, not debug: iOS debug builds won't launch from the home screen
    flutter build ios --release $FLUTTER_ARGS && install_all ios build/ios/iphoneos/Runner.app <<<"$devs" \
      || log "iOS build FAILED"
  fi
  if grep -q '^android ' <<<"$devs"; then
    flutter build apk --release $FLUTTER_ARGS && install_all android build/app/outputs/flutter-apk/app-release.apk <<<"$devs" \
      || log "Android build FAILED"
  fi
}

mkdir -p "$HOME_DIR"
git -C "$REPO" fetch -q origin "$BRANCH" || exit 1
[ -d "$WT" ] || git -C "$REPO" worktree add -q --detach "$WT" "origin/$BRANCH" || exit 1

log "watching $REPO ($BRANCH) every ${INTERVAL}s"
while :; do
  if git -C "$REPO" fetch -q origin "$BRANCH"; then
    sha=$(git -C "$REPO" rev-parse "origin/$BRANCH")
    if [ "$sha" != "$(cat "$SHA_FILE" 2>/dev/null)" ]; then
      log "new commit ${sha:0:7}: $(git -C "$REPO" log -1 --format=%s "$sha")"
      (ship)
      # ponytail: marked done even if a build failed or a device was offline,
      # so a broken commit doesn't rebuild forever. Per-device queue comes with the app.
      echo "$sha" >"$SHA_FILE"
    fi
  else
    log "git fetch failed, will retry"
  fi
  [ -n "${ONCE:-}" ] && exit 0
  sleep "$INTERVAL"
done
