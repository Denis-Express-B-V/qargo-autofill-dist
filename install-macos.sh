#!/bin/bash
# Qargo Autofill - install / repair / update for macOS (Apple silicon and Intel). No administrator rights, no sudo,
# no password. Paste this one line into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main/install-macos.sh | QARGO_SITE=<site code> bash
#
# The installation page puts the site code in the line (its link ends in #s=<site code>): the id of the secret gist
# that holds the site profile, the names the public release only has as placeholders (qargo_launcher.fill_in_site).
# Without it a first install stops with a message; a repair keeps the code it was installed with.
#
# Running it again repairs or updates the installation; the data folder is never touched.
# Everything goes to ~/Library/Application Support/QargoAutofill. The icon "Qargo Autofill" is made on this Mac and
# put in the Applications folder of the home folder, with a link to it on the Desktop.
# Nothing else is changed: no shell profile, no PATH, no system setting.
# Test overrides: QARGO_HOME, QARGO_DIST_URL, QARGO_CHANNEL, QARGO_SHORTCUT_DIRS (colon separated: the icon goes
# into the first folder, links to it into the others), QARGO_NO_OPEN=1 (do not reveal the icon or start the program),
# QARGO_ARCH=x86_64 (take the Intel builds on Apple silicon), QARGO_ICON_KIND=script (the fallback kind of icon).
set -euo pipefail

main() {
  # Only the tools that come with macOS, whatever the user's own PATH holds (and "curl | bash" from a clean
  # environment has no /usr/sbin at all, where sysctl lives).
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  local APP_NAME="Qargo Autofill" BUNDLE_ID="io.github.cagataysunal.qargo-autofill"
  local BASE_URL="https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main"                   # make_release.sh fills in the public address
  local DIST_URL="${QARGO_DIST_URL:-$BASE_URL/${QARGO_CHANNEL:-stable}}"
  local UV_VERSION="0.13.0" PY_SERIES="3.13"             # pinned: uv 0.13 would otherwise pick Python 3.15
  local UV_SHA_ARM64="a9c1b29002cf3c83f07fa9cd8a887a3be0107d90e23189721221e7257db8e3d6"
  local UV_SHA_X86_64="5f44dcbde809b632f47c36fadb241cb4d6f9af71d0c8f172b5d2026d3dde742c"
  local ICON_REV="2"                                     # raise it when the icon recipe below changes
  local ROOT="${QARGO_HOME:-$HOME/Library/Application Support/QargoAutofill}"
  local SHORTCUT_DIRS="${QARGO_SHORTCUT_DIRS:-$HOME/Applications:$HOME/Desktop}"
  local SITE="${QARGO_SITE:-}"

  say()  { printf '\n==> %s\n' "$*"; }
  fail() {
    printf '\n============================================================\n'
    printf '  Qargo Autofill could NOT be installed.\n  %s\n' "$*"
    printf '  Nothing was changed outside this folder:\n  %s\n' "$ROOT"
    printf '  Please call the person who sent you the link.\n'
    printf '============================================================\n'
    exit 1
  }
  sha256() {
    if [ -x /usr/bin/shasum ]; then /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
    else /usr/bin/openssl dgst -sha256 -r "$1" | awk '{print $1}'; fi
  }

  [ "$(uname -s)" = "Darwin" ] || fail "This installer is for a Mac."
  [ "$(id -u)" != "0" ] || fail "Do not use sudo. Run the line as the normal user of this Mac."
  case "$DIST_URL" in *://*) ;; *) fail "This copy of the installer has no download address (it was not made by make_release.sh)." ;; esac
  [ -z "$SITE" ] || [[ "$SITE" =~ ^[0-9a-f]{20,40}$ ]] || fail "The site code in this line is not valid. Copy the line from the page you were sent again."
  # a repair keeps the code it was installed with (state.json); a first install without one would fail at step 3
  [ -n "$SITE" ] || grep -qs '"site"' "$ROOT/app/state.json" \
    || fail "This line has no site code. Open the link you were sent (it ends in #s=...) and copy the line from that page."
  local os_major; os_major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$os_major" -ge 12 ] || fail "macOS 12 or newer is needed (this Mac has $(sw_vers -productVersion))."
  local free_kb; free_kb="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
  [ "$free_kb" -ge 1500000 ] || fail "There is not enough free disk space (1.5 GB is needed)."

  # ---- stop a running copy first: only programs that run from inside our own folder (python, Playwright's driver and browser)
  stop_ours() {
    local sig pids pid comm
    for sig in TERM KILL; do
      # (the pattern has its opening bracket because bash 3.2 cannot read a bare ")" inside "$( )")
      pids="$(ps -axww -o pid=,comm= | while read -r pid comm; do case "$comm" in ("$ROOT"/*) printf '%s ' "$pid" ;; esac; done)"
      [ -n "$pids" ] || return 0
      # shellcheck disable=SC2086
      kill "-$sig" $pids 2>/dev/null || true
      sleep 2
    done
  }
  [ ! -d "$ROOT" ] || stop_ours

  mkdir -p "$ROOT/bin" "$ROOT/data/logs"
  exec > >(tee -a "$ROOT/install.log") 2>&1
  echo "---- $(date '+%Y-%m-%d %H:%M:%S') install-macos.sh, macOS $(sw_vers -productVersion), $(uname -m), from $DIST_URL"

  # ---- 1. uv (private copy, pinned version and checksum)
  local triple="x86_64-apple-darwin" uv_sha="$UV_SHA_X86_64" py_arch="x86_64"
  # hw.optional.arm64 is 1 on Apple silicon, also inside a Rosetta shell (where uname would say x86_64)
  if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] && [ "${QARGO_ARCH:-}" != "x86_64" ]; then
    triple="aarch64-apple-darwin"; uv_sha="$UV_SHA_ARM64"; py_arch="aarch64"
  fi
  local UV="$ROOT/bin/uv"
  if [ "$("$UV" --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]; then
    say "Step 1 of 4: downloading the installer tool (uv $UV_VERSION)"
    local tmp; tmp="$(mktemp -d "$ROOT/tmp.XXXXXX")"
    curl -fL --retry 3 --progress-bar -o "$tmp/uv.tar.gz" \
      "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$triple.tar.gz" </dev/null \
      || fail "The download did not work. Is this Mac connected to the internet?"
    [ "$(sha256 "$tmp/uv.tar.gz")" = "$uv_sha" ] || fail "A downloaded file is damaged (uv: wrong checksum). Try again later."
    tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
    mv -f "$tmp/uv-$triple/uv" "$tmp/uv-$triple/uvx" "$ROOT/bin/"
    rm -rf "$tmp"
  else
    say "Step 1 of 4: the installer tool is already here"
  fi
  echo "uv: $("$UV" --version)"

  # ---- 2. Python (uv-managed, private to this program)
  export UV_PYTHON_INSTALL_DIR="$ROOT/python" UV_CACHE_DIR="$ROOT/uv-cache" UV_MANAGED_PYTHON=1 \
         UV_PYTHON_INSTALL_BIN=0 UV_NO_CONFIG=1 UV_SYSTEM_CERTS=1
  unset VIRTUAL_ENV PYTHONHOME PYTHONPATH UV_PROJECT_ENVIRONMENT || true
  local py_request="cpython-$PY_SERIES-macos-$py_arch-none"
  say "Step 2 of 4: installing Python $PY_SERIES (only for this program)"
  "$UV" python install "$py_request" --no-bin </dev/null || fail "Python could not be installed. Is this Mac connected to the internet?"
  local PY; PY="$("$UV" python find "$py_request" --no-project </dev/null)" || fail "Python $PY_SERIES was not found after installing it."
  echo "python: $PY ($("$PY" -V))"

  # ---- 3. the program: release zip, virtualenv from uv.lock, browser, self-test (all done by the launcher itself)
  say "Step 3 of 4: installing $APP_NAME (the first time this downloads about 300 MB and takes a few minutes)"
  curl -fsSL --retry 3 -o "$ROOT/qargo_launcher.py.new" "$DIST_URL/qargo_launcher.py" </dev/null \
    || fail "The program could not be downloaded. Is this Mac connected to the internet?"
  mv -f "$ROOT/qargo_launcher.py.new" "$ROOT/qargo_launcher.py"
  local rc=0
  QARGO_HOME="$ROOT" QARGO_VERBOSE=1 "$PY" "$ROOT/qargo_launcher.py" install --dist "$DIST_URL" ${SITE:+--site "$SITE"} </dev/null \
    || rc=$?
  [ "$rc" != 4 ] || fail "This line has no site code. Open the link you were sent (it ends in #s=...) and copy the line from that page."
  [ "$rc" = 0 ] || fail "The program could not be installed. The details are in: $ROOT/install.log"

  # ---- 4. the icon
  # What the icon runs. It finds everything from its own place, so nothing here depends on how the folder is spelled.
  cat > "$ROOT/launch.sh" <<'LAUNCH'
#!/bin/sh
# Qargo Autofill: started by the icon. Finder gives a program PATH=/usr/bin:/bin:/usr/sbin:/sbin, so every path is absolute.
ROOT="$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)"
LOG="$ROOT/data/logs/launcher.log"
/bin/mkdir -p "$ROOT/data/logs"
PY=""
for p in "$ROOT"/python/cpython-@PY@-*/bin/python@PY@ "$ROOT"/python/cpython-@PY@.*/bin/python@PY@; do
  if [ -x "$p" ]; then PY="$p"; break; fi
done
# one line per start; "translated=1" would mean the icon runs under Rosetta, which it must not
T="$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null)"
echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') icon: machine=$(/usr/bin/uname -m) translated=${T:-0}" >>"$LOG"
give_up() {       # the launcher itself cannot speak: say it here, in the one sentence it would use
  echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') icon: $1" >>"$LOG"
  [ "$QARGO_HEADLESS" = "1" ] || /usr/bin/osascript -e 'display alert "Qargo Autofill" message "The program could not start. Run the installer again." as critical' >/dev/null 2>&1
  exit 1
}
if [ -z "$PY" ] || [ ! -f "$ROOT/qargo_launcher.py" ]; then give_up "Python or qargo_launcher.py is missing in $ROOT"; fi
QARGO_HOME="$ROOT" "$PY" "$ROOT/qargo_launcher.py" launch >>"$LOG" 2>&1
RC=$?
# 126 and up: Python itself did not run (damaged, or built for another kind of Mac after a move to a new one)
if [ "$RC" -ge 126 ]; then give_up "Python could not be run (exit code $RC): $PY"; fi
exit "$RC"
LAUNCH
  sed -i '' "s/@PY@/$PY_SERIES/g" "$ROOT/launch.sh"
  chmod +x "$ROOT/launch.sh"

  # The icon itself is a tiny AppleScript application made here by osacompile: a real (universal) program, so it runs
  # natively on Apple silicon and never asks for Rosetta; made on this Mac, so macOS does not treat it as a download.
  # It only starts launch.sh in the background and ends at once: every double-click runs the launcher again.
  make_icon() {
    local app="$1/$APP_NAME.app" stamp="$ICON_REV|${QARGO_ICON_KIND:-applet}|$ROOT" esc
    mkdir -p "$1" 2>/dev/null || return 1
    if [ "$(cat "$app/Contents/Resources/qargo-icon" 2>/dev/null)" = "$stamp" ] && /usr/bin/codesign --verify "$app" 2>/dev/null; then
      echo "icon: $app (kept)"; return 0                 # unchanged: keep it, so the Dock and macOS still know it
    fi
    rm -rf "$app"
    local plist="$app/Contents/Info.plist" pb=/usr/libexec/PlistBuddy kind="applet"
    esc="${ROOT//\\/\\\\}"; esc="${esc//\"/\\\"}"          # the folder name inside an AppleScript string
    if [ "${QARGO_ICON_KIND:-applet}" != "applet" ] || ! /usr/bin/osacompile -o "$app" \
         -e "do shell script (quoted form of \"$esc/launch.sh\") & \" >/dev/null 2>&1 &\"" 2>/dev/null; then
      # No AppleScript compiler in this session: a plain script bundle does the same job. Its LSArchitecturePriority
      # (below) is what keeps macOS from taking a program without machine code for an Intel one that needs Rosetta.
      kind="script"
      rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" || return 1
      printf '%s\n' '#!/bin/sh' 'ROOT="$(/bin/cat "$(/usr/bin/dirname "$0")/../Resources/qargo-root")"' \
             '"$ROOT/launch.sh" >/dev/null 2>&1 &' > "$app/Contents/MacOS/applet"
      printf '%s' "$ROOT" > "$app/Contents/Resources/qargo-root"
      chmod +x "$app/Contents/MacOS/applet"
      "$pb" -c "Add :CFBundleExecutable string applet" -c "Add :CFBundleIconFile string applet" \
            -c "Add :CFBundleName string $APP_NAME" -c "Add :CFBundlePackageType string APPL" \
            -c "Add :CFBundleInfoDictionaryVersion string 6.0" -c "Add :NSHighResolutionCapable bool true" "$plist" >/dev/null
    fi
    "$pb" -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$plist"
    "$pb" -c "Add :LSArchitecturePriority array" -c "Add :LSArchitecturePriority:0 string arm64" \
          -c "Add :LSArchitecturePriority:1 string x86_64" "$plist"
    if [ -f "$ROOT/assets/icon.icns" ]; then               # our picture instead of the script icon
      cp "$ROOT/assets/icon.icns" "$app/Contents/Resources/applet.icns"
      rm -f "$app/Contents/Resources/Assets.car"
      "$pb" -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
    fi
    printf '%s' "$stamp" > "$app/Contents/Resources/qargo-icon"
    # the changes above broke osacompile's own seal: sign again (ad hoc, no certificate involved)
    /usr/bin/codesign --force --sign - "$app" 2>/dev/null || [ "$kind" = "script" ] || return 1
    touch "$app"
    echo "icon: $app ($kind)"
  }
  say "Step 4 of 4: making the $APP_NAME icon"
  local first="${SHORTCUT_DIRS%%:*}" rest="" dir
  case "$SHORTCUT_DIRS" in *:*) rest="${SHORTCUT_DIRS#*:}" ;; esac
  make_icon "$first" || fail "The icon could not be made in $first."
  local APP="$first/$APP_NAME.app"
  # Elsewhere (the Desktop) only a link to the icon: one new item and nothing read, so macOS has no reason to ask
  # for permission. If it cannot be made, the icon in Applications is enough.
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    # -n: an existing link must stay a link; without it ln would step through it and write inside the icon itself
    if ln -sn "$APP" "$dir/$APP_NAME" 2>/dev/null; then echo "link: $dir/$APP_NAME"
    elif [ "$(readlink "$dir/$APP_NAME" 2>/dev/null)" = "$APP" ]; then echo "link: $dir/$APP_NAME (kept)"
    else echo "no link in $dir (not needed: the icon is in $first)"; fi
  done <<DIRS
$(printf '%s\n' "$rest" | tr ':' '\n')
DIRS

  printf '\n============================================================\n'
  printf '  Qargo Autofill is installed.\n'
  printf '  Start it with the blue "Qargo Autofill" icon.\n'
  printf '  You can close this window.\n'
  printf '============================================================\n'
  if [ -z "${QARGO_NO_OPEN:-}" ]; then
    open -R "$APP" || true                               # show the icon in a Finder window...
    open "$APP" || true                                  # ...and start the program
  fi
}

main "$@"
