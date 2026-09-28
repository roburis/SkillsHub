# SkillsHub

SkillsHub is a native SwiftUI app for managing local skill sources and making selected skills available to Codex, Claude Code, and custom agents on macOS.

The app manages and validates files, local metadata, and symbolic links. It does not execute skill scripts.

## Requirements

- macOS 27 or later
- Xcode 27 or later

## Build and test

Open `SkillsHub.xcodeproj` in Xcode, or use the repository scripts:

```sh
./scripts/xcode-verify.sh build
./scripts/xcode-verify.sh unit
```

The scripts build without code signing. To run or archive a signed app in Xcode, select an Apple Developer team in Signing & Capabilities.

## Data and permissions

SkillsHub only works with folders explicitly selected or configured by the user. Local management works offline. Network access is used when adding or updating a public GitHub source.

The app is sandboxed and uses security-scoped access for authorized folders. Its default managed root is `~/ai-projects/skills-hub/`.

## Status

SkillsHub is under active development. The current release focuses on global skill management, local folders, public GitHub repositories, and per-agent enablement.

## Third-party software

Third-party notices are included in `SkillsHub/Resources/ThirdPartyNotices.txt`.

## License

SkillsHub is available under the [MIT License](LICENSE).

## 中文简介

SkillsHub 是原生 macOS SwiftUI App，用于管理本地 skill 来源，并按用户选择将 skill 提供给 Codex、Claude Code 和自定义 Agent。App 只管理和校验文件、元数据与软链接，不执行 skill 脚本。
