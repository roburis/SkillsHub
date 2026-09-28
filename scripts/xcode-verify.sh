#!/usr/bin/env bash
set -uo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$repository_root/SkillsHub.xcodeproj"
scheme="SkillsHub"
destination="platform=macOS"
derived_data_root="/private/tmp/SkillsHubDerivedData"
lock_directory="/private/tmp/SkillsHubXcodeVerify.lock"
lock_owner_file="$lock_directory/owner"
ui_fixture_parent=""
ui_fixture_bookmark=""
ui_fixture_descriptor=""
ui_fixture_descriptor_created=0

fail() {
  echo "xcode-verify: $*" >&2
  exit 2
}

release_lock() {
  rm -f -- "$lock_owner_file" && rmdir -- "$lock_directory"
}

recover_or_reject_lock() {
  local version repository pid extra

  if [[ ! -f "$lock_owner_file" ]]; then
    fail "unrecoverable verification lock"
  fi

  {
    IFS= read -r version || true
    IFS= read -r repository || true
    IFS= read -r pid || true
    IFS= read -r extra || true
  } < "$lock_owner_file"

  if [[ "$version" != "version=1" || "$repository" != "repository=$repository_root" || ! "$pid" =~ ^pid=[0-9]+$ || -n "$extra" ]]; then
    fail "unrecoverable verification lock"
  fi

  pid="${pid#pid=}"
  if kill -0 "$pid" 2>/dev/null; then
    fail "active verification lock"
  fi

  if ! release_lock; then
    fail "unrecoverable verification lock"
  fi
}

acquire_lock() {
  if [[ -d "$lock_directory" ]]; then
    recover_or_reject_lock
  fi

  if ! mkdir -- "$lock_directory"; then
    fail "unable to acquire verification lock"
  fi

  if ! printf 'version=1\nrepository=%s\npid=%s\n' "$repository_root" "$$" > "$lock_owner_file"; then
    release_lock || true
    fail "unable to record verification lock"
  fi
}

has_external_project_xcodebuild() {
  local line process_id command processes

  if ! processes="$(ps -axo pid=,command=)"; then
    fail "unable to inspect xcodebuild processes"
  fi

  while IFS= read -r line; do
    process_id="${line%% *}"
    command="${line#"$process_id"}"
    if [[ "$process_id" != "$$" && "$command" == *"xcodebuild"* && "$command" == *"$project_path"* ]]; then
      return 0
    fi
  done <<< "$processes"

  return 1
}

cleanup_derived_data() {
  local derived_data="$1"

  case "$derived_data" in
    "$derived_prefix"??????) ;;
    *)
      echo "xcode-verify: refused to clean non-whitelisted DerivedData path" >&2
      return 1
      ;;
  esac

  rm -rf -- "$derived_data"
}

prepare_ui_fixture_bridge() {
  local configured_parent parent_name temporary_name owner_name

  configured_parent="${SKILLSHUB_UI_FIXTURE_PARENT_OVERRIDE:-${HOME}/Library/Containers/me.ledar.SkillsHubUITests.xctrunner/Data/tmp/SkillsHubUITests/.tmp/phase1-ui-tests}"
  ui_fixture_parent="${configured_parent%/}"
  parent_name="$(basename "$ui_fixture_parent")"
  temporary_name="$(basename "$(dirname "$ui_fixture_parent")")"
  owner_name="$(basename "$(dirname "$(dirname "$ui_fixture_parent")")")"

  if [[ "$ui_fixture_parent" != /* || "$parent_name" != "phase1-ui-tests" || "$temporary_name" != ".tmp" || "$owner_name" != "SkillsHubUITests" ]]; then
    echo "xcode-verify: refused non-canonical UI fixture bridge path" >&2
    return 1
  fi
  if [[ -L "$ui_fixture_parent" ]]; then
    echo "xcode-verify: refused symbolic-link UI fixture bridge" >&2
    return 1
  fi
  if ! mkdir -p -- "$ui_fixture_parent"; then
    echo "xcode-verify: unable to create UI fixture bridge" >&2
    return 1
  fi
  ui_fixture_parent="$(cd "$ui_fixture_parent" && pwd -P)" || return 1
  if [[ -n "$(find "$ui_fixture_parent" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "xcode-verify: UI fixture bridge contains unowned entries" >&2
    return 1
  fi
  if ! ui_fixture_bookmark="$(xcrun swift "$repository_root/scripts/create-interprocess-bookmark.swift" "$ui_fixture_parent")" || [[ -z "$ui_fixture_bookmark" ]]; then
    echo "xcode-verify: unable to create UI fixture interprocess bookmark" >&2
    return 1
  fi
  ui_fixture_descriptor="$(dirname "$ui_fixture_parent")/fixture-bridge"
  if [[ -e "$ui_fixture_descriptor" || -L "$ui_fixture_descriptor" ]]; then
    echo "xcode-verify: UI fixture bridge descriptor already exists" >&2
    return 1
  fi
  if ! (umask 077 && printf '%s\n%s\n' "$ui_fixture_parent" "$ui_fixture_bookmark" > "$ui_fixture_descriptor"); then
    echo "xcode-verify: unable to write UI fixture bridge descriptor" >&2
    return 1
  fi
  ui_fixture_descriptor_created=1
}

cleanup_ui_fixture_bridge() {
  if [[ -z "$ui_fixture_parent" ]]; then
    return 0
  fi
  if [[ "$ui_fixture_descriptor_created" -eq 1 ]] && ! rm -f -- "$ui_fixture_descriptor"; then
    echo "xcode-verify: UI fixture bridge descriptor cleanup failed" >&2
    return 1
  fi
  if ! rmdir -- "$ui_fixture_parent"; then
    echo "xcode-verify: UI fixture bridge cleanup refused because the directory is not empty" >&2
    return 1
  fi
}

mode="${1:-}"
if [[ -z "$mode" ]]; then
  fail "missing mode"
fi
shift

case "$mode" in
  build)
    xcode_action="build"
    ;;
  unit|acceptance)
    xcode_action="test"
    ;;
  *)
    fail "unknown mode '$mode'"
    ;;
esac
derived_prefix="${derived_data_root}-${mode}-"

result_bundle=""
only_testing=()
only_testing_count=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --only-testing)
      if [[ "$mode" == "build" || "$#" -lt 2 || -z "$2" || "$2" == --* ]]; then
        fail "unexpected argument '--only-testing'"
      fi
      only_testing+=("$2")
      only_testing_count=$((only_testing_count + 1))
      shift 2
      ;;
    --result-bundle)
      if [[ "$mode" == "build" || "$#" -lt 2 || -z "$2" || "$2" == --* || -n "$result_bundle" ]]; then
        fail "unexpected argument '--result-bundle'"
      fi
      result_bundle="$2"
      shift 2
      ;;
    *)
      fail "unexpected argument '$1'"
      ;;
  esac
done

if [[ "$mode" == "acceptance" ]]; then
  if [[ -z "$result_bundle" ]]; then
    fail "acceptance requires --result-bundle"
  fi
  if [[ "$only_testing_count" -eq 0 ]]; then
    fail "acceptance requires --only-testing"
  fi
fi

if [[ -n "$result_bundle" ]]; then
  if [[ "$result_bundle" != /* ]]; then
    fail "result bundle must be an absolute path"
  fi
  if [[ "$result_bundle" == "$repository_root"/* || "$result_bundle" == "$derived_data_root"* ]]; then
    fail "result bundle must be outside the repository and DerivedData"
  fi
  if [[ -e "$result_bundle" || -L "$result_bundle" ]]; then
    fail "result bundle target already exists"
  fi

  result_parent="$(dirname "$result_bundle")"
  if [[ ! -d "$result_parent" || ! -w "$result_parent" ]]; then
    fail "result bundle parent must exist and be writable"
  fi
fi

if [[ "$mode" == "unit" && "$only_testing_count" -eq 0 ]]; then
  only_testing=("SkillsHubTests")
  only_testing_count=1
fi

acquire_lock
if has_external_project_xcodebuild; then
  release_lock || echo "xcode-verify: failed to release verification lock" >&2
  fail "another xcodebuild process is using this repository"
fi

if ! derived_data="$(mktemp -d "${derived_prefix}XXXXXX")"; then
  release_lock || true
  fail "unable to create DerivedData directory"
fi

if [[ "$mode" == "acceptance" ]]; then
  if ! prepare_ui_fixture_bridge; then
    cleanup_derived_data "$derived_data" || true
    cleanup_ui_fixture_bridge || true
    release_lock || true
    fail "unable to prepare UI fixture bridge"
  fi
fi

xcode_command=(
  xcodebuild
  -project "$project_path"
  -scheme "$scheme"
  -destination "$destination"
  -derivedDataPath "$derived_data"
)

if [[ "$mode" != "acceptance" ]]; then
  xcode_command+=( CODE_SIGNING_ALLOWED=NO )
fi

xcode_command+=( "$xcode_action" )

if [[ -n "$result_bundle" ]]; then
  xcode_command+=( -resultBundlePath "$result_bundle" )
fi

if [[ "$only_testing_count" -gt 0 ]]; then
  for identifier in "${only_testing[@]}"; do
    xcode_command+=( "-only-testing:$identifier" )
  done
fi

"${xcode_command[@]}"
xcode_status=$?

cleanup_status=0
if ! cleanup_derived_data "$derived_data"; then
  cleanup_status=1
  echo "xcode-verify: DerivedData cleanup failed" >&2
fi
if [[ "$mode" == "acceptance" ]] && ! cleanup_ui_fixture_bridge; then
  cleanup_status=1
fi
if ! release_lock; then
  cleanup_status=1
  echo "xcode-verify: verification lock cleanup failed" >&2
fi

if [[ "$xcode_status" -ne 0 ]]; then
  echo "xcode-verify: xcodebuild failed with status $xcode_status" >&2
  exit "$xcode_status"
fi

if [[ "$cleanup_status" -ne 0 ]]; then
  exit 1
fi
