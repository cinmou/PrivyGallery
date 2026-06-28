<p align="center">
  <img src="Materials/images/app-icon.png" alt="PrivyGallery" width="120" />
</p>

<h1 align="center">PrivyGallery</h1>

<p align="center">
  <strong>双空间保险箱</strong> —— 一个本地优先、端到端加密的私密照片与视频之家。
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <strong>简体中文</strong> ·
  <a href="README.zh-Hant.md">繁體中文</a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">App Store</a> ·
  <a href="Materials/docs/index.html">宣传页</a> ·
  <a href="tools/vault-unpacker/">.vault 解包器</a> ·
  <a href="Materials/docs/vault-format.md">备份格式</a> ·
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

PrivyGallery 是一款原生 iOS 私密媒体保险箱。你导入的照片和视频在存储之前会先在设备本地
加密，可以组织进相册以及两个完全独立的空间，并且无需依赖任何后端服务器即可保持受保护状态。

一个简单的理念：**你的私密媒体始终留在你的设备上、保持加密、由你掌控**——
没有账户、不上传、无分析。

## 截图

| 媒体库 | 相册 | 媒体播放器 |
| :----: | :--: | :--------: |
| <img src="Materials/images/1.PNG" width="220" /> | <img src="Materials/images/2.png" width="220" /> | <img src="Materials/images/6.png" width="220" /> |
| **设置** | **设置** | **备份** |
| <img src="Materials/images/3.PNG" width="220" /> | <img src="Materials/images/4.PNG" width="220" /> | <img src="Materials/images/5.PNG" width="220" /> |

## 构建于 Apple 的安全能力之上

PrivyGallery 刻意**不自行实现加密算法**，而是以标准方式依赖 Apple 提供的安全能力：

| 能力 | Apple API | 在 PrivyGallery 中的作用 |
| --- | --- | --- |
| 对称加密 | **CryptoKit** `AES-GCM` | 加密每一张照片/视频以及 `.vault` 备份 |
| 密钥存储与包裹 | **钥匙串服务** | 存储每个空间被包裹的数据加密密钥 |
| 生物识别解锁 | **LocalAuthentication** + 钥匙串 `biometryCurrentSet` | 用 Face ID / Touch ID 控制对空间密钥的访问 |
| 硬件级密钥保护 | **安全隔区（Secure Enclave）** | 为密钥的生物识别保护提供底层支撑 |
| 静态数据保护 | **数据保护**（`FileProtectionType.complete`） | 为已存储数据提供操作系统级文件加密 |
| 密钥派生 | `PBKDF2-HMAC-SHA256`（CommonCrypto） | 从你的密码派生出备份密钥 |

由于整体设计依赖经过审计、广为理解的系统原语，而非自制密码算法，其信任模型更易于推理；
而真正关键的部分（`.vault` 格式）则完整公开、可供审查。

## 核心概念

- **两个独立空间**——`Space A` 与 `Space B`，各自拥有独立的密码、被包裹的密钥、
  媒体存储与元数据，彼此之间不共享任何状态。
- **每空间数据加密密钥（DEK）**——随机生成，由从你密码派生的密钥包裹。修改密码只会
  重新包裹 DEK，而**不会**重新加密整个媒体库。
- **胁迫密码**——一个特殊密码可触发本地紧急抹除。
- **高级数据保护**——强加密媒体使用更严格、隔离的预览路径。

## 主要功能

- 🔐 存储前的设备本地 `AES-GCM` 加密
- 🪟 两个拥有独立密码的独立空间
- 🔢 4 位、6 位或复杂字母数字密码
- 🚨 胁迫密码 → 紧急抹除
- 👁️ Face ID / 生物识别解锁，支持自动锁定
- 🗂️ 自定义相册、安全相册、归档与回收站
- 📥 从“照片”或“文件”导入（可选导入后删除）
- 📸 针对截屏 / 录屏场景的屏幕隐私行为
- 💾 可携带、加密的 `.vault` 备份

## `.vault` 备份格式

PrivyGallery 可以把整个空间导出为单个加密的 `.vault` 文件。该格式**公开且有文档**——
目标是透明与避免锁定，而**不是**隐藏设计。

概览（完整规范见 [`Materials/docs/vault-format.md`](Materials/docs/vault-format.md)）：

1. 一段明文 JSON 头（`SVEX`，v2），声明 KDF、盐、加密算法、分块大小以及多分卷信息。
2. 主体是一个内部归档（`SVAR`），被切分为多个块，每块用 `AES-GCM` 独立封装
   （每块都对格式版本、分卷序号、块序号与归档长度进行认证）。
3. 内部归档包含一个 JSON 清单（相册 + 媒体元数据），随后是各个媒体数据块，
   以 LZFSE 或原始（raw）方式压缩存储。

密钥派生使用 `PBKDF2-HMAC-SHA256`；每空间的 App 密钥绝不会写入备份——备份是用从
**导出密码**派生的密钥加密的。

## Go 编写的 `.vault` 解包器

本仓库附带一个独立、跨平台的恢复工具：
**[`tools/vault-unpacker`](tools/vault-unpacker/)**。

### 用途

- 在 **macOS、Linux 或 Windows** 上从 `.vault` 备份中解密并**提取你的原始照片和视频**——
  无需 App，因此你永远不会被锁定。
- 检查备份内容（`-l` 仅列出条目而不提取）。
- 只要你拥有文件和导出密码，即使 iOS App 不可用也能恢复数据。

```bash
cd tools/vault-unpacker
go build -o vault-unpacker .
./vault-unpacker -o ./restored "PrivyGallery Backup.vault"
```

### 它**不做**什么（限制）

- 它是一个**恢复 / 提取**工具，而非完整的重新导入器。它会把明文媒体文件写到一个文件夹，
  但**不会**把它们重新载入 iOS App、不会在 App 内重建相册，也不会恢复 App 状态。
- 它**需要正确的导出密码**。密码一旦丢失便无法恢复——加密是真实有效的。
- 构建时需要 **C 编译器**，因为 LZFSE 解压通过 cgo 使用 Apple 的参考实现
  （以保证解压结果逐字节一致）。
- 相册 / 元数据关系保存在清单中，但仅以文件名 + 一个 `_Trash/` 文件夹的形式呈现，
  并不会重建为 App 对象。

完整用法见 [`tools/vault-unpacker/README.md`](tools/vault-unpacker/README.md)。

## 从源码构建

要求：Xcode 26+、iOS 部署目标 `17.0`、SwiftUI。

```bash
# 标准构建（请在 Xcode 中设置你自己的签名团队）
xcodebuild -scheme SecurityFolder -destination 'generic/platform=iOS' build

# 无签名本地验证
xcodebuild -scheme SecurityFolder -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/SecurityFolderDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

> 项目中的 `DEVELOPMENT_TEAM` 默认留空；在构建到真机之前，请设置你自己的
> Apple Developer 团队与 Bundle Identifier。

## 项目结构

```text
SecurityFolder/
├── SecurityFolder/          # 主 iOS App 目标（App、Core、Features、Shared）
├── Share/                   # 共享扩展目标
├── tools/
│   └── vault-unpacker/      # 跨平台 Go .vault 恢复 CLI
├── Materials/
│   ├── docs/                # 文档 + 宣传页（index.html）
│   └── images/              # 截图
├── LICENSE  · SECURITY.md · PRIVACY.md
└── SecurityFolder.xcodeproj
```

## 本地化

已本地化为简体中文、英文、繁体中文变体、日文与韩文。

## 限制

- iOS 没有完全受支持的公开 API 可以全局禁止截屏；部分加固依赖平台行为，
  应在不同 iOS 版本上进行测试。
- 大相册与大批量导入需要持续的内存压力调优。
- 本仓库以 App 为先，尚未封装为可复用的 SDK。
- **尚未进行正式的第三方安全审计。** 见 [SECURITY.md](SECURITY.md)。

## 许可证

采用 **Apache License 2.0** 授权——见 [LICENSE](LICENSE)。

---

<p align="center">
  为重视隐私的人用心打造。 ·
  <a href="https://apps.apple.com/us/app/privygallery-dual-space-vault/id6765981187">在 App Store 下载</a>
</p>
