# PrivyGallery 架构

产品行为见 [PRODUCT.md](PRODUCT.md)，构建测试命令见 [AGENTS.md](AGENTS.md)。
本文记录现行结构，专题按涉及的模块读取。

## 技术栈与构建

- Xcode 工程 `SecurityFolder.xcodeproj`，App 目标与 scheme 为 `SecurityFolder`，产品名为 PrivyGallery。
- 共享扩展目标与 scheme 为 `Share`；App 构建同时构建并嵌入扩展。
- App 与扩展的 iOS 部署目标为 18.0，启用 Mac Catalyst；Swift 语言模式为 5.0。
  构建使用 Xcode 26 或更新版本的 SDK，部署目标不等于构建 SDK 版本。
- App 默认 MainActor 隔离；后台任务使用明确的非隔离实现与可传递值。
- SwiftUI 组织页面，UIKit 承担媒体网格、缩放、转场和播放器；AVFoundation 处理视频。
- CryptoKit 与 Keychain 负责空间加密和密钥；LocalAuthentication 负责生物识别。
  Photos/PhotosUI 处理系统照片，StoreKit 处理购买状态。
- `tools/vault-unpacker/` 是独立 Go 模块，要求 Go 1.26.4+，经 cgo 使用 LZFSE 解压。

## 模块职责

| 目录 | 职责 |
| --- | --- |
| `SecurityFolder/App/` | 会话、当前空间、认证生命周期和窗口级隐私遮罩 |
| `SecurityFolder/Core/Models/` | 空间、相册、媒体、排序和设置模型 |
| `SecurityFolder/Core/Services/` | 加密、文件和元数据持久化、导入导出、备份文件管理 |
| `SecurityFolder/Features/` | Authentication、Library、MediaViewer、Settings 的界面与业务协调 |
| `SecurityFolder/Shared/` | 跨功能的视图组件、布局选择与通知 |
| `Share/` | App Group 中的共享导入队列及扩展界面 |
| `tools/tests/` | 编译实际 Swift 源码或抽取声明后运行的轻量回归检查 |
| `tools/vault-unpacker/` | 无需 App 的备份解密和原始文件提取工具 |

Xcode 使用文件系统同步目录；部分 `Share/` 源码也被 App 编译。
新增共享文件时检查目标归属，不能只凭所在目录判断会被哪个目标编译。

## 数据与持久化

`VaultItem` 与 `VaultAlbum` 是可变引用模型，通过 UUID 标识。
媒体与相册为多对多关系；相册颜色属于相册，不是第二套媒体标签。
Live Photo 的静态图和配对视频属于同一媒体项目。

`EncryptedMetadataStore` 将相册、媒体与关系保存为每空间独立的加密 JSON manifest，
加载时重建对象关系。当前持久化不使用 SwiftData；App 中保留的旧 store 清理代码用于遗留数据处理。
媒体由 `VaultFileStorageService` 与 `VaultCryptoService` 管理；设置等偏好使用 UserDefaults。

## 关键边界与专题

| 涉及的修改 | 应阅读的专题与实现入口 |
| --- | --- |
| 密码、生物识别、锁定、屏幕隐私 | [认证与隐私](docs/auth-and-privacy.md)；`AppSessionViewModel`、`AppLockService`、`VaultCryptoService` |
| 相册、搜索、照片转场、视频 | [媒体库与播放器](docs/media-library-and-viewer.md)；`MediaLibraryViewModel`、`AlbumDetailView`、`MediaViewerController` |
| 系统导入、共享扩展、备份和恢复 | [备份与恢复](docs/backup-and-restore.md)；`SharedImportSupport`、`VaultExportService`、`VaultImportService` |
| 备份协议、跨平台恢复工具 | [格式规范](docs/vault-format.md)；Swift 导入导出服务与 `tools/vault-unpacker/vault.go` |

两个空间各有独立的媒体、元数据与密钥。普通媒体和强保护媒体使用不同的展示与操作路径。
搜索只处理当前空间已解密的内存元数据，不新增持久化索引。
共享导入队列是 App Group 中的暂存输入，主应用解锁对应空间后才加密入库。
备份使用独立的导出密码，不把 App 的空间密钥写入 `.vault`。

## 验证边界

当前没有 XCTest 目标或统一 lint 配置。四个 Python 脚本检查认证、元数据、搜索和布局；
Go 测试检查独立解包器。它们不能替代完整 UI、系统权限或真实生物识别测试。
UI 问题需要相关尺寸和状态的界面检查，认证及隐私问题按需补真机验证。
历史材料保存在 `docs/archive/`，不参与默认阅读。
