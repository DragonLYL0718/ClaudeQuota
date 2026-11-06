#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
source "$PROJECT_ROOT/Tools/install-app.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/quota-install-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
local passed=0

fail() { echo "FAIL: $*" >&2; exit 1; }

# Keep the real filesystem transaction, replacing only copy/validation/move boundaries
# so failures are deterministic and no installed app or running process is touched.
copy_bundle() {
  [[ "$failure" != copy ]] || return 1
  ditto "$1" "$2"
}
verify_bundle() {
  if [[ "$failure" == staged-validation && "$1" != "$destination" ]]; then return 1; fi
  if [[ "$failure" == final-validation && "$1" == "$destination" ]]; then return 1; fi
  [[ -f "$1/version" ]]
}
move_bundle() {
  if [[ "$failure" == backup && "$1" == "$destination" ]]; then return 1; fi
  if [[ ( "$failure" == replacement || "$failure" == rollback ) && "$1" == */QuotaRings.app && "$2" == "$destination" ]]; then
    return 1
  fi
  if [[ "$failure" == rollback && "$1" == */previous.app ]]; then return 1; fi
  mv "$1" "$2" || return 1
  # Simulate interruption after rename, before the caller observes completion.
  if [[ "$failure" == backup-after-move && "$1" == "$destination" ]]; then return 1; fi
  if [[ "$failure" == replacement-after-move && "$2" == "$destination" && "$1" == */QuotaRings.app ]]; then return 1; fi
}
prepare_replacement() { touch "$scenario/prepared"; }

check_case() {
  local case_name="$1" failure="$2" with_previous="$3" expected="$4"
  local scenario="$TEST_ROOT/$case_name"
  local source_bundle="$scenario/source.app" destination="$scenario/installed.app"
  mkdir -p "$source_bundle"
  print -r -- new > "$source_bundle/version"
  if [[ "$with_previous" == yes ]]; then
    mkdir -p "$destination"
    print -r -- old > "$destination/version"
  fi

  local result_code=0
  install_app "$source_bundle" "$destination" > "$scenario/output" 2>&1 || result_code=$?
  if [[ "$expected" == new ]]; then
    (( result_code == 0 )) || fail "$case_name unexpectedly failed: $(cat "$scenario/output")"
    [[ "$(cat "$destination/version")" == new ]] || fail "$case_name did not install new version"
  else
    (( result_code != 0 )) || fail "$case_name unexpectedly succeeded"
    case "$expected" in
      old) [[ "$(cat "$destination/version")" == old ]] || fail "$case_name did not preserve old version" ;;
      absent) [[ ! -e "$destination" ]] || fail "$case_name left a failed first installation" ;;
      backup)
        local backups=("$scenario"/.QuotaRings-install.*/previous.app/version(N))
        (( ${#backups} == 1 )) || fail "$case_name lost the recovery backup"
        [[ "$(cat "$backups[1]")" == old ]] || fail "$case_name backup was changed"
        ;;
    esac
  fi
  [[ "$(cat "$source_bundle/version")" == new ]] || fail "$case_name changed the source bundle"
  if [[ "$failure" == copy || "$failure" == staged-validation ]]; then
    [[ ! -e "$scenario/prepared" ]] || fail "$case_name ran lifecycle operations before validation"
  fi
  if [[ "$expected" != backup ]]; then
    local leftovers=("$scenario"/.QuotaRings-install.*(N))
    (( ${#leftovers} == 0 )) || fail "$case_name left temporary installation files"
  fi
  (( passed += 1 ))
}

check_case replacement-success none yes new
check_case first-install-success none no new
check_case copy-failure copy yes old
check_case staged-validation-failure staged-validation yes old
check_case backup-failure backup yes old
check_case backup-interruption backup-after-move yes old
check_case replacement-failure replacement yes old
check_case replacement-interruption replacement-after-move yes old
check_case final-validation-failure final-validation yes old
check_case first-install-validation-failure final-validation no absent
check_case rollback-failure-retains-backup rollback yes backup

# Run the actual build script with harmless tools in an isolated project. Sourcing
# the installer fails immediately, before any real app lifecycle command can run.
BUILD_FIXTURE="$TEST_ROOT/build-only"
mkdir -p "$BUILD_FIXTURE/bin" "$BUILD_FIXTURE/Tools"
cp "$PROJECT_ROOT/build.sh" "$BUILD_FIXTURE/build.sh"
cat > "$BUILD_FIXTURE/Tools/install-app.sh" <<'SCRIPT'
echo unexpected-install >> "$QUOTA_TEST_LOG"
return 66
SCRIPT
for tool_name in xcodegen xcodebuild; do
  cat > "$BUILD_FIXTURE/bin/$tool_name" <<'SCRIPT'
#!/bin/zsh
echo "${0:t}" >> "$QUOTA_TEST_LOG"
SCRIPT
  chmod +x "$BUILD_FIXTURE/bin/$tool_name"
done
for build_option in --build-only --no-install; do
  operation_log="$BUILD_FIXTURE/$build_option.log"
  PATH="$BUILD_FIXTURE/bin:$PATH" QUOTA_TEST_LOG="$operation_log" \
    /bin/zsh "$BUILD_FIXTURE/build.sh" "$build_option" > /dev/null
  [[ "$(cat "$operation_log")" == $'xcodegen\nxcodebuild' ]] || fail "$build_option invoked installation"
  (( passed += 1 ))
done

echo "✓ $passed installation and build-mode tests passed"
