#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify_script="$repo_root/scripts/xcode-verify.sh"
derived_data_root="/private/tmp/SkillsHubDerivedData"
lock_directory="/private/tmp/SkillsHubXcodeVerify.lock"
if [[ -e "$lock_directory" || -L "$lock_directory" ]]; then
  echo "verification lock already exists" >&2
  exit 2
fi
temporary_directory="$(mktemp -d /private/tmp/skillshub-xcode-verify-test.XXXXXX)"
fake_bin="$temporary_directory/bin"
xcodebuild_log="$temporary_directory/xcodebuild.log"
derived_data_log="$temporary_directory/derived-data.log"
derived_data_paths="$temporary_directory/derived-data-paths.log"
fixture_configuration_log="$temporary_directory/fixture-configuration.log"
sentinel="$temporary_directory/sentinel"
other_derived_data=""

cleanup() {
  if [[ "$other_derived_data" == /private/tmp/SkillsHubDerivedData-build-?????? ]]; then
    /bin/rm -rf -- "$other_derived_data"
  fi
  if [[ -f "$derived_data_paths" ]]; then
    while IFS= read -r path; do
      case "$path" in
        /private/tmp/SkillsHubDerivedData-build-??????|/private/tmp/SkillsHubDerivedData-unit-??????|/private/tmp/SkillsHubDerivedData-acceptance-??????)
          /bin/rm -rf -- "$path"
          ;;
      esac
    done < "$derived_data_paths"
  fi
  rm -rf "$temporary_directory" "$lock_directory"
}
trap cleanup EXIT

mkdir -p "$fake_bin"
printf 'keep\n' > "$sentinel"

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" > "$XCODEBUILD_LOG"
derived_data=""
result_bundle=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data="$2"
    shift 2
  elif [[ "$1" == "-resultBundlePath" ]]; then
    result_bundle="$2"
    shift 2
  else
    shift
  fi
done

if [[ -n "${SKILLSHUB_UI_FIXTURE_PARENT_OVERRIDE:-}" ]]; then
  descriptor="$(dirname "$SKILLSHUB_UI_FIXTURE_PARENT_OVERRIDE")/fixture-bridge"
  descriptor_parent=""
  descriptor_bookmark=""
  descriptor_extra=""
  if [[ -f "$descriptor" ]]; then
    {
      IFS= read -r descriptor_parent || true
      IFS= read -r descriptor_bookmark || true
      IFS= read -r descriptor_extra || true
    } < "$descriptor"
  fi
  printf 'descriptor-present=%s\nparent-match=%s\nbookmark-nonempty=%s\nextra-line-empty=%s\ndescriptor-private=%s\n' \
    "$([[ -f "$descriptor" ]] && printf yes || printf no)" \
    "$([[ "$descriptor_parent" == "$SKILLSHUB_UI_FIXTURE_PARENT_OVERRIDE" ]] && printf yes || printf no)" \
    "$([[ -n "$descriptor_bookmark" ]] && printf yes || printf no)" \
    "$([[ -z "$descriptor_extra" ]] && printf yes || printf no)" \
    "$([[ -f "$descriptor" && "$(stat -f '%Lp' "$descriptor")" == "600" ]] && printf yes || printf no)" \
    > "$XCODEBUILD_FIXTURE_CONFIG_LOG"
fi

if [[ -n "$derived_data" ]]; then
  mkdir -p "$derived_data/Build"
  printf '%s\n' "$derived_data" > "$XCODEBUILD_DERIVED_LOG"
  printf '%s\n' "$derived_data" >> "$XCODEBUILD_DERIVED_PATHS"
fi

if [[ -n "$result_bundle" ]]; then
  mkdir -p "$result_bundle"
fi

exit "${FAKE_XCODEBUILD_EXIT:-0}"
EOF
chmod +x "$fake_bin/xcodebuild"

cat > "$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "swift" && "$2" == */scripts/create-interprocess-bookmark.swift && -d "$3" ]]; then
  printf 'fixture-bookmark'
  exit 0
fi

exit 2
EOF
chmod +x "$fake_bin/xcrun"

cat > "$fake_bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s' "${FAKE_PS_OUTPUT:-}"
EOF
chmod +x "$fake_bin/ps"

cat > "$fake_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
  if [[ -n "${FAKE_RM_FAIL_PREFIX:-}" && "$argument" == "$FAKE_RM_FAIL_PREFIX"* ]]; then
    exit 1
  fi
done

exec /bin/rm "$@"
EOF
chmod +x "$fake_bin/rm"

run_verify() {
  PATH="$fake_bin:$PATH" \
    XCODEBUILD_LOG="$xcodebuild_log" \
    XCODEBUILD_DERIVED_LOG="$derived_data_log" \
    XCODEBUILD_DERIVED_PATHS="$derived_data_paths" \
    XCODEBUILD_FIXTURE_CONFIG_LOG="$fixture_configuration_log" \
    SKILLSHUB_UI_FIXTURE_PARENT_OVERRIDE="$temporary_directory/SkillsHubUITests/.tmp/phase1-ui-tests" \
    "$verify_script" "$@"
}

expect_failure() {
  local expected_message="$1"
  shift

  local output
  : > "$xcodebuild_log"
  if output="$(run_verify "$@" 2>&1)"; then
    echo "expected failure: $*" >&2
    exit 1
  fi

  if [[ "$output" != *"$expected_message"* ]]; then
    echo "missing failure message '$expected_message': $output" >&2
    exit 1
  fi
}

expect_file_contains() {
  local expected="$1"
  if ! grep -Fxq -- "$expected" "$xcodebuild_log"; then
    echo "missing xcodebuild argument '$expected'" >&2
    exit 1
  fi
}

expect_file_excludes_prefix() {
  local unexpected_prefix="$1"
  local argument
  while IFS= read -r argument; do
    if [[ "$argument" == "$unexpected_prefix"* ]]; then
      echo "unexpected xcodebuild argument '$argument'" >&2
      exit 1
    fi
  done < "$xcodebuild_log"
}

expect_failure "unknown mode" unsupported
expect_failure "unexpected argument" build --derived-data /private/tmp/other
expect_failure "unexpected argument" build --result-bundle /private/tmp/build.xcresult
expect_failure "unexpected argument" unit -quiet

other_derived_data="$(mktemp -d /private/tmp/SkillsHubDerivedData-build-XXXXXX)"
printf 'keep\n' > "$other_derived_data/sentinel"
run_verify build
expect_file_contains "build"
expect_file_contains "-project"
expect_file_contains "$repo_root/SkillsHub.xcodeproj"
expect_file_contains "-scheme"
expect_file_contains "SkillsHub"
expect_file_contains "-destination"
expect_file_contains "platform=macOS"
expect_file_contains "-derivedDataPath"
expect_file_contains "CODE_SIGNING_ALLOWED=NO"

build_derived_data="$(< "$derived_data_log")"
if [[ "$build_derived_data" != /private/tmp/SkillsHubDerivedData-build-?????? || -e "$build_derived_data" ]]; then
  echo "build DerivedData was not safely cleaned" >&2
  exit 1
fi
expect_file_contains "$build_derived_data"
if [[ ! -f "$other_derived_data/sentinel" ]]; then
  echo "another run's DerivedData was removed" >&2
  exit 1
fi
/bin/rm -rf -- "$other_derived_data"
other_derived_data=""

if [[ ! -f "$sentinel" ]]; then
  echo "non-whitelisted sentinel was removed" >&2
  exit 1
fi

mkdir "$lock_directory"
printf 'version=1\nrepository=%s\npid=%s\n' "$repo_root" "$$" > "$lock_directory/owner"
expect_failure "active verification lock" build
[[ -d "$lock_directory" ]]
rm -rf "$lock_directory"

mkdir "$lock_directory"
printf 'invalid\n' > "$lock_directory/owner"
expect_failure "unrecoverable verification lock" build
[[ -d "$lock_directory" ]]
rm -rf "$lock_directory"

mkdir "$lock_directory"
printf 'version=1\nrepository=/private/tmp/other\npid=999999\n' > "$lock_directory/owner"
expect_failure "unrecoverable verification lock" build
[[ -d "$lock_directory" ]]
rm -rf "$lock_directory"

mkdir "$lock_directory"
printf 'version=1\nrepository=%s\npid=999999\n' "$repo_root" > "$lock_directory/owner"
run_verify unit
expect_file_contains "test"
expect_file_contains "-only-testing:SkillsHubTests"
expect_file_contains "CODE_SIGNING_ALLOWED=NO"
[[ ! -d "$lock_directory" ]]
unit_derived_data="$(< "$derived_data_log")"
if [[ "$unit_derived_data" != /private/tmp/SkillsHubDerivedData-unit-?????? || -e "$unit_derived_data" || "$unit_derived_data" == "$build_derived_data" ]]; then
  echo "unit DerivedData was not safely cleaned" >&2
  exit 1
fi
expect_file_contains "$unit_derived_data"

run_verify unit --only-testing SkillsHubLibraryControllerTests
expect_file_contains "-only-testing:SkillsHubLibraryControllerTests"
if grep -Fxq -- "-only-testing:SkillsHubTests" "$xcodebuild_log"; then
  echo "explicit unit selection unexpectedly included the default test target" >&2
  exit 1
fi

run_verify unit --configuration Release --only-testing SkillsHubTests
expect_file_contains "-configuration"
expect_file_contains "Release"
expect_file_contains "ENABLE_TESTABILITY=YES"
expect_failure "configuration must be Debug or Release and specified once" build --configuration invalid
expect_failure "configuration must be Debug or Release and specified once" build --configuration
expect_failure "configuration must be Debug or Release and specified once" build --configuration Debug --configuration Release

unit_evidence_parent="$temporary_directory/unit-evidence"
mkdir "$unit_evidence_parent"
unit_result_bundle="$unit_evidence_parent/unit.xcresult"
run_verify unit --result-bundle "$unit_result_bundle" --only-testing Phase1OperationTests
expect_file_contains "test"
expect_file_contains "-resultBundlePath"
expect_file_contains "$unit_result_bundle"
expect_file_contains "-only-testing:Phase1OperationTests"
expect_file_contains "CODE_SIGNING_ALLOWED=NO"
if [[ ! -d "$unit_result_bundle" ]]; then
  echo "unit Result Bundle did not survive cache cleanup" >&2
  exit 1
fi

if [[ ! -f "$sentinel" ]]; then
  echo "non-whitelisted sentinel was removed after lock recovery" >&2
  exit 1
fi

expect_failure "acceptance requires --result-bundle" acceptance --only-testing SkillsHubTests
expect_failure "acceptance requires --only-testing" acceptance --result-bundle "$temporary_directory/evidence.xcresult"
expect_failure "result bundle must be an absolute path" unit --result-bundle relative-unit.xcresult
expect_failure "result bundle must be an absolute path" acceptance --result-bundle relative.xcresult --only-testing SkillsHubTests
expect_failure "result bundle must be outside the repository and DerivedData" acceptance --result-bundle "$repo_root/evidence.xcresult" --only-testing SkillsHubTests
expect_failure "result bundle must be outside the repository and DerivedData" acceptance --result-bundle "$derived_data_root/evidence.xcresult" --only-testing SkillsHubTests

evidence_parent="$temporary_directory/evidence"
mkdir "$evidence_parent"
existing_bundle="$evidence_parent/existing.xcresult"
mkdir "$existing_bundle"
printf 'preserve\n' > "$existing_bundle/sentinel"
expect_failure "result bundle target already exists" acceptance --result-bundle "$existing_bundle" --only-testing SkillsHubTests
[[ -f "$existing_bundle/sentinel" ]]

expect_failure "result bundle parent must exist and be writable" acceptance --result-bundle "$temporary_directory/missing/evidence.xcresult" --only-testing SkillsHubTests

unwritable_parent="$temporary_directory/unwritable"
mkdir "$unwritable_parent"
chmod 500 "$unwritable_parent"
expect_failure "result bundle parent must exist and be writable" acceptance --result-bundle "$unwritable_parent/evidence.xcresult" --only-testing SkillsHubTests
chmod 700 "$unwritable_parent"

result_bundle="$evidence_parent/new.xcresult"
run_verify acceptance --result-bundle "$result_bundle" --only-testing SkillsHubTests --only-testing SkillsHubUITests
expect_file_contains "test"
expect_file_contains "-resultBundlePath"
expect_file_contains "$result_bundle"
expect_file_contains "-only-testing:SkillsHubTests"
expect_file_contains "-only-testing:SkillsHubUITests"
expect_file_excludes_prefix "CODE_SIGNING_ALLOWED="
grep -Fxq "descriptor-present=yes" "$fixture_configuration_log"
grep -Fxq "parent-match=yes" "$fixture_configuration_log"
grep -Fxq "bookmark-nonempty=yes" "$fixture_configuration_log"
grep -Fxq "extra-line-empty=yes" "$fixture_configuration_log"
grep -Fxq "descriptor-private=yes" "$fixture_configuration_log"
[[ ! -e "$temporary_directory/SkillsHubUITests/.tmp/phase1-ui-tests" ]]
if [[ -e "$temporary_directory/SkillsHubUITests/.tmp/fixture-bridge" ]]; then
  echo "UI fixture bridge descriptor was not cleaned" >&2
  exit 1
fi

acceptance_derived_data="$(< "$derived_data_log")"
if [[ "$acceptance_derived_data" != /private/tmp/SkillsHubDerivedData-acceptance-* || -e "$acceptance_derived_data" ]]; then
  echo "acceptance DerivedData was not safely cleaned" >&2
  exit 1
fi

if [[ ! -d "$result_bundle" ]]; then
  echo "Result Bundle did not survive cache cleanup" >&2
  exit 1
fi

: > "$xcodebuild_log"
if xcode_failure_output="$(FAKE_XCODEBUILD_EXIT=7 run_verify build 2>&1)"; then
  echo "expected xcodebuild failure" >&2
  exit 1
else
  xcode_failure_status=$?
fi
if [[ "$xcode_failure_status" -ne 7 || "$xcode_failure_output" != *"xcodebuild failed with status 7"* ]]; then
  echo "xcodebuild failure status was not preserved" >&2
  exit 1
fi
failed_derived_data="$(< "$derived_data_log")"
[[ ! -e "$failed_derived_data" && ! -d "$lock_directory" ]]

if cleanup_failure_output="$(FAKE_RM_FAIL_PREFIX="${derived_data_root}-build-" run_verify build 2>&1)"; then
  echo "expected DerivedData cleanup failure" >&2
  exit 1
else
  cleanup_failure_status=$?
fi
if [[ "$cleanup_failure_status" -eq 0 || "$cleanup_failure_output" != *"DerivedData cleanup failed"* ]]; then
  echo "DerivedData cleanup failure was not reported" >&2
  exit 1
fi
cleanup_failed_derived_data="$(< "$derived_data_log")"
[[ -d "$cleanup_failed_derived_data" && ! -d "$lock_directory" ]]
/bin/rm -rf "$cleanup_failed_derived_data"

if combined_failure_output="$(FAKE_XCODEBUILD_EXIT=7 FAKE_RM_FAIL_PREFIX="${derived_data_root}-build-" run_verify build 2>&1)"; then
  echo "expected combined xcodebuild and cleanup failure" >&2
  exit 1
else
  combined_failure_status=$?
fi
if [[ "$combined_failure_status" -ne 7 || "$combined_failure_output" != *"DerivedData cleanup failed"* || "$combined_failure_output" != *"xcodebuild failed with status 7"* ]]; then
  echo "combined failure did not preserve both outcomes" >&2
  exit 1
fi
combined_failed_derived_data="$(< "$derived_data_log")"
/bin/rm -rf "$combined_failed_derived_data"

: > "$xcodebuild_log"
: > "$derived_data_log"
if external_process_output="$(FAKE_PS_OUTPUT="999 xcodebuild -project $repo_root/SkillsHub.xcodeproj" run_verify build 2>&1)"; then
  echo "expected external project xcodebuild rejection" >&2
  exit 1
fi
if [[ "$external_process_output" != *"another xcodebuild process is using this repository"* || -s "$xcodebuild_log" || -s "$derived_data_log" || -d "$lock_directory" ]]; then
  echo "external project xcodebuild rejection had side effects" >&2
  exit 1
fi

if [[ ! -f "$sentinel" ]]; then
  echo "non-whitelisted sentinel was removed after failure tests" >&2
  exit 1
fi

echo "xcode verification tests passed"
