#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository_root="$(dirname "$source_root")"
project="$source_root/SkillsHub.xcodeproj/project.pbxproj"

# Match the App target's Debug and Release configuration IDs only.
if ! versions="$(awk '
  /^\t\tA19499472FE4AFF60029CD95 \/\* Debug \*\/ = \{/ { app = 1 }
  /^\t\tA19499482FE4AFF60029CD95 \/\* Release \*\/ = \{/ { app = 1 }
  app && /CURRENT_PROJECT_VERSION = / { build = $3; sub(/;$/, "", build); builds[++count] = build }
  app && /MARKETING_VERSION = / { marketing = $3; sub(/;$/, "", marketing); marketings[count] = marketing }
  app && /^\t\t};$/ { app = 0 }
  END {
    if (count != 2 || builds[1] != builds[2] || marketings[1] != marketings[2]) exit 1
    print builds[1] ":" marketings[1]
  }
' "$project")"; then
  echo "prepare-local-app: inconsistent App version settings" >&2
  exit 1
fi

IFS=: read -r current_build marketing_version <<< "$versions"
if [[ ! "$current_build" =~ ^[0-9]{1,9}$ || ! "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "prepare-local-app: invalid App version" >&2
  exit 1
fi
next_build=$((10#$current_build + 1))

mkdir -p "$repository_root/.tmp"
derived_data="$(mktemp -d "$repository_root/.tmp/SkillsHub-$marketing_version-$next_build.XXXXXX")"
project_hash="$(shasum -a 256 "$project" | awk '{ print $1 }')"

xcodebuild \
  -project "$source_root/SkillsHub.xcodeproj" \
  -scheme SkillsHub \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  "CURRENT_PROJECT_VERSION=$next_build" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  build

app="$derived_data/Build/Products/Release/Skills Hub.app"
plist="$app/Contents/Info.plist"
if [[ ! -d "$app" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" != "$next_build" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" != "$marketing_version" ]]; then
  echo "prepare-local-app: unexpected App version" >&2
  exit 1
fi
codesign --verify --deep --strict "$app"

if [[ "$(shasum -a 256 "$project" | awk '{ print $1 }')" != "$project_hash" ]]; then
  echo "prepare-local-app: project changed during build; build number was not saved" >&2
  exit 1
fi

temporary_project="$(mktemp "$repository_root/.tmp/SkillsHub-project.XXXXXX")"
trap 'rm -f -- "$temporary_project"' EXIT
if ! awk -v old="$current_build" -v new_build="$next_build" '
  /^\t\tA19499472FE4AFF60029CD95 \/\* Debug \*\/ = \{/ { app = 1 }
  /^\t\tA19499482FE4AFF60029CD95 \/\* Release \*\/ = \{/ { app = 1 }
  app && /CURRENT_PROJECT_VERSION = / {
    if (index($0, "CURRENT_PROJECT_VERSION = " old ";") == 0) exit 1
    sub("CURRENT_PROJECT_VERSION = " old ";", "CURRENT_PROJECT_VERSION = " new_build ";")
    count++
  }
  { print }
  app && /^\t\t};$/ { app = 0 }
  END { if (count != 2) exit 1 }
' "$project" > "$temporary_project"; then
  echo "prepare-local-app: unable to update App build number" >&2
  exit 1
fi
chmod "$(stat -f '%Lp' "$project")" "$temporary_project"
mv "$temporary_project" "$project"
echo "prepare-local-app: $app"
