# iCloud 同步审计（2.2 规划）

> 本文是设计审计，功能**尚未实现**。目的是在动手前确认：哪些数据可以离开设备、以什么形态离开、
> 以及哪些必须永远留在本机。产品定位仍以 [PRODUCT.md](../PRODUCT.md) 为准。

## 1. 结论摘要

| 数据域 | 现状存储 | 适合同步 | 结论与做法 |
| --- | --- | --- | --- |
| 媒体密文（照片 / 视频 / Live Photo 静态图） | `Documents/VaultStorage/Space_X/Active/*.svlt` | **适合** | 原样上传密文，作为 `CKAsset` 分块上传；文件名（UUID）在云端换成记录名 |
| 配对视频密文 | 同上 | **适合** | 跟随静态图的记录，`CKAsset` 第二个字段 |
| 相册封面密文 | `.../AlbumCovers/` | **适合** | 小文件，挂在相册记录上 |
| 回收站 / 归档状态 | manifest 字段 + `Trash/` 密文 | **适合** | 作为记录字段同步，配 `trashedAt` 墓碑 |
| 相册结构、相册颜色、排序、封面引用 | 单一加密 manifest | **有条件** | 必须拆成 per-album 记录；`customOrderedItemIDs` 需要定序冲突策略 |
| 媒体元数据（名称、原名、时间、时长、经纬度） | 同一 manifest | **有条件** | 只能以**密文**形式进记录，且不能进任何云端明文索引 |
| 空间 DEK / 生物识别密钥 | Keychain（`ThisDeviceOnly`） | **不适合原样同步** | 需要新的跨设备密钥方案，见 §3.1 |
| 胁迫密码摘要 | Keychain `com.cinmouice.SecurityFolder.coercion` | **绝不适合** | 胁迫机制是本机行为，同步会同时放大泄露与误抹除风险 |
| 缩略图缓存 | `Caches/MediaThumbnailCache/*.jpg`（**明文**） | **不适合** | 可派生；明文上传即破坏产品承诺 |
| 临时解密文件 | `tmp/`、`VaultCryptoService` 临时目录 | **不适合** | 明文，随用随删 |
| 共享导入队列 | App Group `SharedImports/`（**明文**） | **不适合** | 明文暂存，且只在同机 App ↔ 扩展之间有意义 |
| 备份文件 `.vault` | `Application Support/BackupFiles/` | **不适合** | 已是加密二次副本，体积翻倍；导出密码丢失后云端只剩孤儿 |
| 强保护媒体（secureLibrary） | 与普通媒体同样的密文 | **有条件** | 用户把最敏感内容放这里，建议默认不同步、单独开关 |
| 空间 B 全部数据 | 同空间 A | **有条件** | 默认不同步：同步会让「存在第二个空间」暴露给 iCloud 账户侧 |
| 主题 / 语言 / 排序 / 回收站天数 | UserDefaults | **适合** | 走 `NSUbiquitousKeyValueStore`，无隐私含义 |
| 自动锁定时长 / 生物识别路由 / 屏幕隐私开关 | UserDefaults | **不适合** | 属于本机安全策略，iPad 与 iPhone 的诉求本就不同 |
| 空间显示名 | UserDefaults | **不适合** | 名称本身可能是敏感词（"工作""私人"） |
| 购买状态 | StoreKit | **不需要** | 由 Apple ID 处理 |
| 安装标记 / 迁移标记 / 提示已读 | UserDefaults | **不适合** | 纯设备本地状态 |
| 搜索 | 无持久化索引 | **不需要** | 搜索只作用于已解密的内存元数据 |

一句话：**可以同步的是「密文 + 结构 + 非敏感偏好」，不能同步的是「明文派生物、密钥、胁迫机制、设备本地状态」。**

## 2. 现状盘点

### 2.1 加密与密钥

- 媒体文件格式为 `SVLT` + 版本 1 + 1 MiB 分块，每块独立 `AES.GCM`，**没有 AAD**，
  因此密文与路径没有绑定关系，可以整体挪到云端再落回任意路径
  （`SecurityFolder/Core/Services/VaultCryptoService.swift:32-36,461-497`）。
- 每个空间一把随机 256-bit DEK。DEK 用
  `SHA256("SecurityFolder|\(space)|\(passcode)")` 包成 `AES.GCM` 密文存 Keychain，
  **没有 PBKDF2 迭代**，靠 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 兜底
  （`VaultCryptoService.swift:625-700,755-759`）。
- 生物识别另存一份**裸 DEK**，带 `.biometryCurrentSet` + `ThisDeviceOnly`
  （`VaultCryptoService.swift:655-667`）：这份永远无法跨设备，必须在新设备重建。

### 2.2 存储布局

| 路径 | 内容 | 是否加密 |
| --- | --- | --- |
| `Documents/VaultStorage/Space_A|Space_B/Active/` | 媒体密文 | 是（空间 DEK） |
| `.../Trash/` | 回收站媒体密文 | 是 |
| `.../AlbumCovers/` | 相册封面密文 | 是 |
| `.../metadata.manifest` | 整个空间的相册 + 媒体列表 | 是（同一把 DEK） |
| `Caches/MediaThumbnailCache/` | 缩略图 | **否** |
| `Application Support/BackupFiles/` | `.vault` 备份 | 是（导出密码，独立 KDF） |
| App Group `SharedImports/` | 共享扩展暂存 | **否** |

### 2.3 与 iCloud 的关系（今天）

- 工程**没有任何** iCloud / CloudKit / ubiquity / aps 权限
  （`SecurityFolder/SecurityFolder.entitlements`、`...-Mac.entitlements`、`Share/Share.entitlements`），
  全仓库没有 `CKContainer` / `NSUbiquitous` 使用。
- 代码里**没有** `isExcludedFromBackup`，所以 `Documents` 下的全部密文今天就会进入
  **iCloud 设备备份**。但 Keychain 项是 `ThisDeviceOnly`：换机恢复后密钥不存在，
  密文既解不开也删不掉——这是现在就该修的一个「半吊子云化」，与同步功能无关。

## 3. 三个必须先定的问题

### 3.1 密钥如何跨设备可达

同步的密文在第二台设备上要能解开。可选方案只有三类：

| 方案 | 机制 | 优点 | 代价 |
| --- | --- | --- | --- |
| A. 云端存「口令包裹的 DEK」 | 把 wrapped DEK 作为 CloudKit 记录（密文）上传，新设备输入同一密码解锁 | 与现有「密码即边界」一致；开发者仍无法解密 | 密码必须换成抗离线的 KDF（PBKDF2-SHA256 60 万轮起）；**4 位数字密码等于没有保护**（10⁴ × 60 万 ≈ 分分钟可爆破）；忘记密码 = 云端数据也永久不可解 |
| B. iCloud Keychain 持钥 | 用 `kSecAttrSynchronizable` 同步 DEK（或超长恢复密钥），生物识别/设备密码放行 | 真·免密跨设备，端到端加密且硬件保护 | 保密边界从 App 密码变成 Apple ID；「忘记密码就无法恢复」的产品承诺失效；与胁迫密码模型冲突 |
| C. 恢复码 | 生成一次性 256-bit 恢复码，用户抄走；云端只存恢复码包裹的 DEK | 不依赖 Apple ID，也不依赖弱密码 | 多一步用户负担；恢复码丢失同样不可恢复 |

**建议**：先做 A 的加强版——保留「密码即边界」，但把包裹 KDF 从 SHA256 单次换成
PBKDF2-SHA256（≥60 万轮，与 `.vault` 保持一致），并**把启用同步的门槛提到 6 位以上密码或自定义密码**；
4 位用户要么不开同步，要么先改密码。C 可作为 A 的补充（恢复码备份），B 不建议作为默认。

### 3.2 空间 B 的存在性

两个空间各有独立密钥（`ARCHITECTURE.md:53`），但 CloudKit 容器是**整个 App 一个**。
即使记录名是 UUID、内容是密文，空间 B 的记录条数、资产大小和上传时间仍能被持有该 iCloud 账户的人观察到。
对「隐藏第二空间」这个产品诉求来说，这等于泄露存在性。

**建议**：空间 B 默认不参与同步（开关明确写「可能暴露该空间的存在」），
或两个空间共用一个 zone、记录里不区分空间、由本机维护「空间 ↔ 记录名」映射。
第二种更隐蔽，但把隔离责任从密钥层挪到了代码层，需要额外的映射表加密。

### 3.3 胁迫抹除与云端

现在的胁迫密码命中后 `EmergencyWipeService` 只清本机（`EmergencyWipeService.swift:8-30`）。
一旦有云同步，「触发抹除 → 本机清空 → 攻击者从 iCloud 恢复」就成了新的失败路径。
同一次抹除必须能删掉云端 zone；但删 zone 需要网络，且删除本身在云端是可观察事件。

**建议**：抹除时先记录「待删除 zone」标记，后台尽力删除并重试；
同时在设置里明确「紧急抹除会删除 iCloud 中的同步数据」。
不能承诺「抹除后云端无痕」——删除事件本身可能被账户侧看到。

## 4. 逐项审计细节

### 4.1 适合直接同步

- **媒体密文**：已经是不透明分块密文，且不绑定路径，天然适合对象存储。
  单文件可达数 GB 视频，需要分块上传 + 断点续传，不能整文件塞进 `CKRecord` 的 1 MB 限制。
- **相册封面密文**：小图，挂在相册记录上即可。
- **回收站 / 归档状态**：纯字段（`isInTrash`、`trashedAt`、`isArchived`），
  配合 30 天保留期（`AppSettingsKey.trashRetentionDays`）做墓碑清理。
- **非敏感偏好**：主题、语言、排序、回收站天数，走 `NSUbiquitousKeyValueStore`（上限 1 MB，够用）。

### 4.2 有条件

- **元数据 manifest**：现在是「每空间一个加密 JSON，整包重写」
  （`EncryptedMetadataStore.swift:38-82`）。原样同步会有两个硬伤：
  1. 改一个标题就要重传整个空间的清单，库大了直接不可用；
  2. 两台设备同时写，后写者整包覆盖，对方的新增全部丢失。
  必须拆成 per-item / per-album 记录（记录名 = UUID），字段级合并，才能谈冲突。
- **相册排序 `customOrderedItemIDs`**：是一个有序数组，天然冲突。
  建议改成每条「相册-媒体」关系单独一条记录、带 `sortIndex`，冲突时按记录粒度 last-write-wins。
  这同时顺带解决了现在「相册关系塞在媒体记录里」的耦合。
- **强保护媒体**：技术上与普通媒体同构，但产品语义是「独立且更严」。
  默认不同步，给单独开关，并在开启时二次确认。
- **空间 B**：见 §3.2。

### 4.3 不适合

- **缩略图**：明文 JPEG，且可从密文随时重建（`MediaThumbnailService.swift:521,533-539`）。
  同步它等于把「媒体内容」以明文形式放进云端，直接违背产品承诺。设备间各自重建即可。
- **临时解密文件**：同上，且生命周期本就是「随用随删」。
- **共享导入队列**：App Group 明文暂存，只在同一台设备上有意义。
- **胁迫密码摘要**：同步它既泄露「这台设备设置了胁迫密码」，又会让一台设备上的抹除触发变成全局行为。
- **生物识别密钥**：`.biometryCurrentSet` 与 Secure Enclave 绑定，物理上不可迁移，只能在新设备重建。
- **备份文件 `.vault`**：已经是加密副本，再同步一遍是双倍占用；
  且导出密码与空间密码无关，云端出现孤儿文件的概率很高。
- **设备本地状态**：`installMarker`、`legacySecondary1111CleanupCompleted`、
  `lockButtonHintShown`、`lastBackupRecoveryNotice` 等，同步没有收益，只会造成错误分支。
- **自动锁定时长 / 生物识别路由 / 屏幕隐私开关**：属于「这台设备该怎么保护自己」，
  iPad 与 iPhone 的合理取值不同，同步反而制造矛盾。

## 5. 建议的同步架构

不在本版实现，仅记录方向，避免后续推翻：

- **CloudKit 私有库 + 自定义 zone**，每空间一个 zone（或 §3.2 的合并方案）。
  自定义 zone 才能用 `CKFetchRecordZoneChangesOperation` + 变更令牌做增量拉取。
- **记录模型**：`Item`、`Album`、`AlbumMembership`、`Asset`、`Tombstone`。
  记录名一律 UUID；任何用户可见字符串（相册名、文件名）只出现在加密字段里。
- **资产**：媒体密文用 `CKAsset`，按 1 MiB 分块与本地存储对齐，支持断点续传；
  不要试图把密文塞进 `CKRecord` 字段（1 MB 上限）。
- **冲突**：字段级 last-write-wins + `updatedAt`；删除一律写 `Tombstone` 记录，保留 30 天后清理。
- **触发**：进入后台/手动刷新时推送本地变更；用 `CKDatabaseSubscription` + 静默推送拉取。
  需要新增 `INFOPLIST_KEY_UIBackgroundModes = remote-notification` 与 aps 权限（目前都没有）。
- **权限**：三个 entitlements 都要加 `com.apple.developer.icloud-services = CloudKit` 与
  `icloud-container-identifiers = iCloud.com.cinmouice.MediaVault`；共享扩展是否需要取决于它是否直接写云端。
- **配额**：资产计入用户的 iCloud 空间，需要展示占用、允许按相册或按时间范围选择同步，
  并在空间不足时降级为「只同步元数据」而不是反复失败。

## 6. 动手前需要改造的现有结构

1. **manifest 拆分**：`EncryptedMetadataStore` 目前只有「整包读写」两个入口，
   需要新增按记录读写的能力，同时保留整包读用于迁移旧数据。
2. **路径与记录解耦**：`relativePath` 是本地存储路径（`VaultStorage/...`），
   同步层要用记录名 + 资产标识，落盘时再映射回本地路径（`VaultFileStorageService` 已经支持按文件名反查）。
3. **导出/导入复用**：`.vault` 的清单结构与同步记录高度重合（`docs/vault-format.md` §4），
   可以把「记录 → 清单」的映射抽出来共享，避免出现两套序列化。
4. **缩略图按需重建**：新设备首次进入时不能等全量缩略图，需要可见区域优先生成。

## 7. 风险与验证清单

- 双设备同时编辑同一相册：结构不丢、顺序符合预期。
- 同步中断（飞行模式 / 后台被杀）后重进，资产不重复上传、不产生半片密文。
- 4 位密码用户尝试开启同步：被拒绝并给出改密码路径。
- 空间 B 开启同步后，另一台设备在空间 A 会话下看不到任何 B 的痕迹。
- 胁迫抹除后：本机清空、云端 zone 删除（或留下待删除标记并在下次启动重试）。
- 新设备首次登录：能拉取记录、能解密、缩略图渐进出现、不阻塞首屏。
- iCloud 空间不足 / 未登录 iCloud / 关闭 iCloud 云盘：三条路径都要有明确文案且不丢本地数据。
- 卸载重装（数据仍在云端）与「关闭同步后本地保留」两种状态切换正确。

## 8. 明确不做

- 不做开发者可读的服务端；不做自建后端。
- 不把密钥、胁迫摘要、生物识别密钥放进云端。
- 不上传任何明文派生物（缩略图、临时解密文件）。
- 不用 iCloud Drive 目录镜像作为主方案：文件级镜像解决了密文搬运，却解决不了元数据记录的冲突，
  最终仍要一套记录层，反而多一套同步源。

相关背景见[认证与隐私](auth-and-privacy.md)、[备份与恢复](backup-and-restore.md)与[格式规范](vault-format.md)。
