<p align="center">
  <img src="Materials/images/app-icon.png" alt="PrivyGallery" width="120" />
</p>

<h1 align="center">PrivyGallery</h1>

<p align="center">
  <strong>双空间保险箱</strong> —— 用于私密照片与视频的本地加密空间。
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <strong>简体中文</strong> ·
  <a href="README.zh-Hant.md">繁體中文</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">App Store</a> ·
  <a href="https://privygallery.cinmou.uk">宣传页</a> ·
  <a href="tools/vault-unpacker/">.vault 解包器</a> ·
  <a href="docs/vault-format.md">备份格式</a> ·
  <a href="SECURITY.md">安全</a> ·
  <a href="PRIVACY.md">隐私</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="在 App Store 下载" height="56" />
  </a>
</p>

---

## 概述

PrivyGallery 是面向 iPhone、iPad 和 Mac Catalyst 的本地加密照片与视频保险箱。不需要账户或后端服务器，不自动上传媒体。

- 两个独立空间，分别设置密码，支持 Face ID / Touch ID、自动锁定与胁迫密码紧急抹除。
- 从系统照片、文件或共享扩展导入，用相册、归档和回收站整理媒体。
- 预览照片、Live Photo 和视频；强保护媒体使用独立的预览路径。
- 创建加密 `.vault` 备份并恢复到空间；大备份会分成多个可独立恢复的分片。

备份先保存在应用内，需要另存或分享副本到外部位置，才能在卸载应用后保留。独立的 [vault-unpacker](tools/vault-unpacker/README.zh-Hans.md) 可以使用备份密码提取文件，不依赖 App。

## 截图

| 媒体库 | 相册 | 播放器 |
| :---: | :---: | :---: |
| <img src="Materials/images/1.PNG" width="220" /> | <img src="Materials/images/2.png" width="220" /> | <img src="Materials/images/6.png" width="220" /> |
| **设置** | **设置** | **备份** |
| <img src="Materials/images/3.PNG" width="220" /> | <img src="Materials/images/4.PNG" width="220" /> | <img src="Materials/images/5.PNG" width="220" /> |

## 开发与文档

使用 Xcode 26 或更新版本打开 `SecurityFolder.xcodeproj`。App 与共享扩展的部署目标为 iOS 18，App 同时支持 Mac Catalyst。真机构建前配置自己的签名团队与 Bundle ID。

- [PRODUCT.md](PRODUCT.md)：当前产品功能、体验与设计决定。
- [ARCHITECTURE.md](ARCHITECTURE.md)：技术栈、模块、数据结构与关键边界。
- [AGENTS.md](AGENTS.md)：开发规则、构建与测试命令。
- 专题：[认证与隐私](docs/auth-and-privacy.md)、[媒体库与播放器](docs/media-library-and-viewer.md)、[备份与恢复](docs/backup-and-restore.md)、[`.vault` 格式](docs/vault-format.md)。

产品与技术文档描述当前工作区；App Store 的可用功能以发行版本为准。历史评审保存在 `docs/archive/`，按需查阅。

应用使用 CryptoKit、Keychain 和 LocalAuthentication，目前没有经过正式的第三方安全审计。安全范围与限制见 [SECURITY.md](SECURITY.md)，数据处理方式见 [PRIVACY.md](PRIVACY.md)。

## 本地化

英语与英国英语、简体中文、台湾和香港繁体中文，以及德语、西班牙语、法语、意大利语、日语、韩语和俄语。

## 许可

[Apache License 2.0](LICENSE)。
