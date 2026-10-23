# 认证与隐私

本专题用于密码、生物识别、前后台切换、遮罩和强保护预览相关修改。
产品约定见 [PRODUCT.md](../PRODUCT.md)，备份密码见[备份与恢复](backup-and-restore.md)。

## 会话与生命周期

`AppSessionViewModel` 协调当前空间、认证请求、自动锁定和交互计时；
`AppLockService` 处理密码及锁定状态，`VaultCryptoService` 处理密钥与加密数据。
认证是否成功与密钥是否能安装到当前会话是两个步骤。

生物识别请求由会话管理 `LAContext`、进行中状态和请求 ID。
需要系统认证的 Keychain 读取离开主线程；异步结果只有仍属于当前有效请求时才生效。
锁定、进入后台或密码解锁等状态变动会使旧认证失效。
修改相关代码时检查整个请求与生命周期链路，不额外叠加自动认证入口。

## 空间密码与密钥

每个空间有随机的 256-bit 数据加密密钥（DEK），用于媒体和加密元数据。
当前空间密码经带空间标识的 SHA-256 派生包裹密钥，再用 AES-GCM 包裹 DEK；
包裹后的密钥存于 Keychain，使用 `WhenUnlockedThisDeviceOnly`。
验证密码通过尝试解开包裹密钥完成，App 不保存明文密码。
具体编码与 Keychain 条目以 [`VaultCryptoService.swift`](../SecurityFolder/Core/Services/VaultCryptoService.swift) 为准。

Face ID / Touch ID 使用另一份由 `biometryCurrentSet` 保护的 DEK 副本。
修改空间密码只重新包裹 DEK，不重新加密全部媒体。
胁迫密码以摘要匹配，命中后进入紧急抹除流程；它不同于普通锁定。
本地空间密码方案与备份使用的 PBKDF2 派生方案分别维护，不能混写。

## 屏幕隐私

- 截屏开关控制收到系统截屏通知后的锁定，不能阻止或撤回已保存截图。
- `ScreenPrivacyCover` 使用当前 scene 的非 key window，覆盖后台快照及录屏场景，
  包括 SwiftUI 页面上方的 UIKit 预览。
- 锁定通知 `.vaultDidLock` 会关闭原生照片预览，防止其留在锁定页面之上。
- “安全预览模式”（Secure Preview Mode）用于专用媒体库的内存解密预览，不生成原始内容的临时解密文件；
  普通媒体库的缩略图与预览规则不变。设置的持久化键沿用 `advancedDataProtectionEnabled`。
- 强保护媒体继续使用专用展示与播放路径，不能为统一界面而改走普通预览。

手动解锁的 0.3 秒动画等待是已确认的产品决定，见 [PRODUCT.md](../PRODUCT.md)。

## 引导布局

仅在系统 `onHingeChange` 报告设备铰链时启用 Duo 适配：密码输入与确认页的继续按钮
固定在底部安全区域，键盘出现后仍可见；输入内容和错误说明保留滚动。
按水平尺寸类别复用宽屏居中布局，折叠后回到紧凑布局；不依据铰链角度计算布局。
普通 iPhone、iPad 和 Catalyst 保持原来的布局判断与引导按钮位置。
依据 Apple 的 [Duo 适配说明](https://developer.apple.com/videos/play/tech-talks/111461/)与
[DeviceHinge](https://developer.apple.com/documentation/swiftui/devicehinge)。

## 修改后的检查

运行 [AGENTS.md](../AGENTS.md) 中的认证回归检查并编译受影响平台。
涉及系统认证或生命周期时，检查自动认证、手动密码、取消认证、前后台切换和锁定后的预览。
真实生物识别、截屏与录屏表现需要对应设备验证，脚本或编译通过不代表这些行为已验证。
