# SkillsHub

[English](#english) | [简体中文](#简体中文)

## English

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

## Releases

See [Releases](https://github.com/roburis/SkillsHub/releases) for user-facing changes in each published version.

## Third-party software

Open **Skills Hub → About Skills Hub** to read the bundled third-party notices. The source text is in `SkillsHub/Resources/ThirdPartyNotices.txt`.

## License

SkillsHub is available under the [MIT License](LICENSE).

## 简体中文

SkillsHub 是一款原生 SwiftUI macOS App，用于管理本地 skill 来源，并按用户选择将 skill 提供给 Codex、Claude Code 和自定义 Agent。

App 管理和校验文件、本地元数据与软链接，不执行 skill 脚本。

## 系统要求

- macOS 27 或更高版本
- Xcode 27 或更高版本

## 构建与测试

使用 Xcode 打开 `SkillsHub.xcodeproj`，或运行仓库脚本：

```sh
./scripts/xcode-verify.sh build
./scripts/xcode-verify.sh unit
```

脚本构建时不进行代码签名。若要在 Xcode 中运行或归档已签名的 App，请在“Signing & Capabilities”中选择 Apple Developer 团队。

## 数据与权限

SkillsHub 只访问用户明确选择或配置的文件夹。本地管理可离线使用；添加或更新公开 GitHub 来源时需要网络连接。

App 使用沙盒，并通过 security-scoped access 访问已授权的文件夹。默认管理根目录为 `~/ai-projects/skills-hub/`。

## 当前状态

SkillsHub 正在积极开发中。当前版本聚焦于全局 skill 管理、本地文件夹、公开 GitHub 仓库，以及按 Agent 启用 skill。

## 版本发布

各已发布版本的变更介绍见 [Releases](https://github.com/roburis/SkillsHub/releases)。

## 第三方软件

通过 **Skills Hub → 关于 Skills Hub** 阅读应用内完整第三方声明。声明原文位于 `SkillsHub/Resources/ThirdPartyNotices.txt`。

## 许可证

SkillsHub 使用 [MIT 许可证](LICENSE)。
