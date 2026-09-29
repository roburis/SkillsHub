#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d /private/tmp/skillshub-local-app-test.XXXXXX)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/open-source/scripts" "$fixture/open-source/SkillsHub.xcodeproj" "$fixture/bin"
cp "$source_root/scripts/prepare-local-app.sh" "$fixture/open-source/scripts/"
cat > "$fixture/open-source/SkillsHub.xcodeproj/project.pbxproj" <<'EOF'
		A19499472FE4AFF60029CD95 /* Debug */ = {
				CURRENT_PROJECT_VERSION = 2;
				MARKETING_VERSION = 1.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = me.ledar.SkillsHub;
		};
		A19499482FE4AFF60029CD95 /* Release */ = {
				CURRENT_PROJECT_VERSION = 2;
				MARKETING_VERSION = 1.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = me.ledar.SkillsHub;
		};
		A194994B2FE4AFF60029CD95 /* Tests */ = {
				CURRENT_PROJECT_VERSION = 1;
		};
EOF

cat > "$fixture/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_XCODEBUILD_EXIT:-0}" -ne 0 ]]; then
  exit "$FAKE_XCODEBUILD_EXIT"
fi
derived_data=""
build=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -derivedDataPath) derived_data="$2"; shift 2 ;;
    CURRENT_PROJECT_VERSION=*) build="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$derived_data" && -n "$build" ]]
app="$derived_data/Build/Products/Release/Skills Hub.app"
mkdir -p "$app/Contents"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleVersion</key><string>$build</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
</dict></plist>
PLIST
EOF
cat > "$fixture/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODESIGN_LOG"
exit "${FAKE_CODESIGN_EXIT:-0}"
EOF
chmod +x "$fixture/bin/xcodebuild" "$fixture/bin/codesign"

project="$fixture/open-source/SkillsHub.xcodeproj/project.pbxproj"
script="$fixture/open-source/scripts/prepare-local-app.sh"
export PATH="$fixture/bin:$PATH" FAKE_CODESIGN_LOG="$fixture/codesign.log"

for expected in 3 4; do
  output="$("$script")"
  app="${output#prepare-local-app: }"
  [[ -d "$app" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$expected" ]]
  [[ "$(awk '/CURRENT_PROJECT_VERSION = / { print $3 }' "$project" | tr -d ';' | tr '\n' ' ')" == "$expected $expected 1 " ]]
done
[[ "$(wc -l < "$FAKE_CODESIGN_LOG" | tr -d ' ')" == 2 ]]

before="$(shasum -a 256 "$project")"
if FAKE_XCODEBUILD_EXIT=65 "$script" > "$fixture/failure.log" 2>&1; then
  echo "expected build failure" >&2
  exit 1
fi
[[ "$(shasum -a 256 "$project")" == "$before" ]]
[[ "$(wc -l < "$FAKE_CODESIGN_LOG" | tr -d ' ')" == 2 ]]
if FAKE_CODESIGN_EXIT=1 "$script" > "$fixture/signature-failure.log" 2>&1; then
  echo "expected signature failure" >&2
  exit 1
fi
[[ "$(shasum -a 256 "$project")" == "$before" ]]
echo "prepare-local-app tests passed"
