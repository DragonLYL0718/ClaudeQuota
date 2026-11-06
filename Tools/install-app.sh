#!/bin/zsh
# Transactional bundle replacement. Source this file to customize the lifecycle hook.

copy_bundle() { ditto "$1" "$2"; }
move_bundle() { mv "$1" "$2"; }
prepare_replacement() { :; }

verify_bundle() {
  local bundle="$1"
  local plist="$bundle/Contents/Info.plist"
  local bundle_id executable
  [[ -d "$bundle" && -f "$plist" ]] || return 1
  plutil -lint "$plist" >/dev/null || return 1
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") || return 1
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist") || return 1
  [[ "$bundle_id" == com.rayleigh.ClaudeQuota && -n "$executable" && "$executable" != */* ]] || return 1
  [[ -x "$bundle/Contents/MacOS/$executable" ]] || return 1
  [[ -d "$bundle/Contents/PlugIns/QuotaRingsWidget.appex" ]] || return 1
  codesign --verify --deep --strict "$bundle" || return 1
}

install_app() (
  set -euo pipefail
  if (( $# != 2 )); then
    echo "Usage: install-app.sh SOURCE.app DESTINATION.app" >&2
    return 2
  fi
  local source_bundle="${1:A}" destination="${2:a}"
  local parent="${destination:h}"
  if [[ ! -d "$source_bundle" || "$destination" != *.app || -L "$destination" || "$source_bundle" == "$destination" ]]; then
    echo "Invalid source or destination app bundle." >&2
    return 1
  fi
  mkdir -p "$parent" || return 1
  local transaction
  transaction=$(mktemp -d "$parent/.QuotaRings-install.XXXXXX") || return 1
  local staged="$transaction/QuotaRings.app" backup="$transaction/previous.app"
  local replacement_attempted=0 committed=0

  cleanup_install() {
    local result_code="$1"
    trap - EXIT INT TERM HUP
    if (( ! committed )); then
      # Inspect the backup itself so interruption immediately after a successful
      # rename cannot leave the original bundle unaccounted for.
      if (( replacement_attempted )) && [[ -e "$destination" ]]; then
        if ! rm -rf "$destination"; then
          echo "Could not remove the failed replacement; recovery files retained at $transaction" >&2
          return 1
        fi
      fi
      if [[ -e "$backup" ]]; then
        if ! move_bundle "$backup" "$destination"; then
          echo "Could not restore the previous app; backup retained at $backup" >&2
          return 1
        fi
        echo "Restored the previous app." >&2
      fi
    fi
    rm -rf "$transaction" || return 1
    return "$result_code"
  }
  trap 'cleanup_install $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if ! copy_bundle "$source_bundle" "$staged"; then
    echo "Could not stage the new app; the installed app was preserved." >&2
    return 1
  fi
  if ! verify_bundle "$staged"; then
    echo "The new app failed validation; the installed app was preserved." >&2
    return 1
  fi
  prepare_replacement || return 1
  if [[ -e "$destination" ]]; then
    if ! move_bundle "$destination" "$backup"; then
      echo "Could not back up the installed app." >&2
      return 1
    fi
  fi
  replacement_attempted=1
  if ! move_bundle "$staged" "$destination"; then
    echo "Could not install the new app." >&2
    return 1
  fi
  if ! verify_bundle "$destination"; then
    echo "The installed app failed validation." >&2
    return 1
  fi
  committed=1
)

if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  install_app "$@"
fi
