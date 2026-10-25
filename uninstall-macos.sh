#!/bin/bash
# Qargo Autofill - uninstall for macOS. Removes the program and its icon; keeps the data folder (documents, login,
# done list, logs) unless QARGO_REMOVE_DATA=1.
#
#   keep the data:      curl -fsSL https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main/uninstall-macos.sh | bash
#   remove everything:  curl -fsSL https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main/uninstall-macos.sh | QARGO_REMOVE_DATA=1 bash
#
# Test overrides: QARGO_HOME, QARGO_SHORTCUT_DIRS (as in install-macos.sh).
set -euo pipefail

main() {
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"            # only the tools that come with macOS
  local APP_NAME="Qargo Autofill"
  local ROOT="${QARGO_HOME:-$HOME/Library/Application Support/QargoAutofill}"
  local SHORTCUT_DIRS="${QARGO_SHORTCUT_DIRS:-$HOME/Applications:$HOME/Desktop}"
  [ "$(id -u)" != "0" ] || { echo "Do not use sudo. Run the line as the normal user of this Mac."; exit 1; }

  # stop the program: only what runs from inside our own folder (python, Playwright's driver and browser)
  local sig pids pid comm
  for sig in TERM KILL; do
    # (the pattern has its opening bracket because bash 3.2 cannot read a bare ")" inside "$( )")
    pids="$(ps -axww -o pid=,comm= | while read -r pid comm; do case "$comm" in ("$ROOT"/*) printf '%s ' "$pid" ;; esac; done)"
    [ -n "$pids" ] || break
    # shellcheck disable=SC2086
    kill "-$sig" $pids 2>/dev/null || true
    sleep 2
  done

  # the icon: only the one our installer made (it carries our mark), and only links that point to it
  local first="${SHORTCUT_DIRS%%:*}" rest="" dir
  case "$SHORTCUT_DIRS" in *:*) rest="${SHORTCUT_DIRS#*:}" ;; esac
  local APP="$first/$APP_NAME.app"
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if [ "$(readlink "$dir/$APP_NAME" 2>/dev/null)" = "$APP" ]; then rm -f "$dir/$APP_NAME" 2>/dev/null || true; fi
  done <<DIRS
$(printf '%s\n' "$rest" | tr ':' '\n')
DIRS
  if [ -f "$APP/Contents/Resources/qargo-icon" ]; then rm -rf "$APP"; fi

  if [ -d "$ROOT" ]; then
    local item
    for item in "$ROOT"/* "$ROOT"/.[!.]*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      if [ "$(basename "$item")" = "data" ] && [ -z "${QARGO_REMOVE_DATA:-}" ]; then continue; fi
      rm -rf "$item"
    done
    rmdir "$ROOT" 2>/dev/null || true
  fi
  echo
  echo "Qargo Autofill was removed."
  if [ -d "$ROOT/data" ]; then
    echo "Your documents, the Qargo login and the logs were kept in:"
    echo "  $ROOT/data"
  fi
}

main "$@"
