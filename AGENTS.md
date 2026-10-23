# PrivyGallery 工作指南

PrivyGallery 是本地加密媒体保险箱，支持 iPhone、iPad 和 Mac Catalyst。
主应用使用 SwiftUI 与 UIKit，媒体播放使用 AVFoundation，
加密与密钥管理使用 CryptoKit、Keychain 和 LocalAuthentication。

## 阅读入口与项目结构

- [PRODUCT.md](PRODUCT.md)：功能、用户体验和已确认的产品决定。
- [ARCHITECTURE.md](ARCHITECTURE.md)：模块边界、数据结构与专题入口。
- `SecurityFolder/App/`：应用入口、会话、锁定和隐私遮罩。
- `SecurityFolder/Core/`：数据模型、加密元数据、文件存储和导入导出。
- `SecurityFolder/Features/`：认证、媒体库、预览播放器和设置。
- `SecurityFolder/Shared/`：公共组件、布局与通知。
- `Share/`：共享扩展及与主应用共用的导入协议。
- `tools/tests/`：通过 Python 调用 Swift 编译器的回归检查。
- `tools/vault-unpacker/`：独立的 Go 备份恢复工具。

修改前阅读相关产品说明、架构专题和现有实现。
按任务读取对应文件；只有排查来源或兼容问题时才追溯历史与归档。

## 工作方式

- 先查看工作区状态和相关 diff，保留已有改动。
- 复杂任务先给出简洁计划，范围明确后自主完成实现与验证。
- 优先复用系统能力、现有实现和成熟组件，保持改动范围集中。
- 只为明确需求和真实输入边界增加校验或恢复逻辑；
  不为假设场景预先增加重试、轮询、兼容层或额外抽象。
- 遵循附近代码的组织方式，避免夹带重构或全文件格式化。
- 修改架构、公共接口或用户行为时，同步更新对应文档。
- 文档记录当前约定、原因和验证方式；实现细节引用源码，
  不复制大段代码，不追加逐轮开发流水账。

## 项目约束

- App 与 Share 目标支持 iOS 18；Mac 使用 Catalyst。
  按可用空间和系统布局能力适配界面，遵循 Apple 平台规范。
- 主应用默认 MainActor 隔离。耗时工作离开主线程，
  跨并发边界传递值快照，避免直接传递可变模型。
- 保持两个空间的数据与密钥隔离，以及普通媒体和强保护媒体的边界。
  数据模型或持久化变动同时检查旧数据与备份兼容性。
- 元数据由加密 manifest 持久化；不要依据遗留代码另建存储体系。
- 修改共享导入协议时同时检查 App 与 Share 的读写双方。
- 用户可见文案使用对应目标的 xcstrings，维护已有本地化。

认证与隐私见 [专题](docs/auth-and-privacy.md)；
媒体库和播放器见 [专题](docs/media-library-and-viewer.md)；
导入导出见 [专题](docs/backup-and-restore.md)；
备份协议见 [格式规范](docs/vault-format.md)。

## 构建与验证

以下 App 命令从仓库根目录运行：

以下关闭签名的命令用于编译检查；安装到模拟器并测试 Keychain 时，使用后面的模拟器命令。

```sh
xcodebuild -project SecurityFolder.xcodeproj -scheme SecurityFolder -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/PrivyGallery-iOS CODE_SIGNING_ALLOWED=NO build

xcodebuild -project SecurityFolder.xcodeproj -scheme SecurityFolder -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /private/tmp/PrivyGallery-Catalyst CODE_SIGNING_ALLOWED=NO build
```

模拟器运行包保留签名和系统生成的权限，避免 Keychain 返回 `errSecMissingEntitlement`：

```sh
xcodebuild -project SecurityFolder.xcodeproj -scheme SecurityFolder -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/PrivyGallery-Simulator CODE_SIGN_IDENTITY=- build
```

按改动范围选择回归检查，不要求每次全部运行：

- 解锁与生命周期：`python3 tools/tests/test_app_lock.py`
- 元数据、相册关系与备份记录：`python3 tools/tests/test_media_metadata.py`
- 搜索：`python3 tools/tests/test_media_search.py`
- 播放器布局：`python3 tools/tests/test_player_layout.py`

解包器需要 Go 1.26.4+ 和 C 编译器。
在 `tools/vault-unpacker/` 下运行：

- 构建：`go build -mod=readonly -o /private/tmp/privygallery-vault-unpacker .`
- 测试：`go test -mod=readonly ./...`

App 代码按受影响平台编译；共享代码影响两端时检查 iOS 与 Catalyst。
行为修复优先补能复现问题的测试；简单文案修改不增加实现镜像测试。
UI 修改检查相关尺寸、方向和大字体；认证与隐私行为按需进行真机验证。
纯文档修改检查内容、链接和命令一致性，不要求重新构建 App。

完成前检查相关 diff 并运行 `git diff --check`。
报告改动、实际执行的验证及未验证部分；
区分脚本测试、编译、模拟器和真机结果，不把编译通过当作功能已验证。
