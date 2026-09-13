# PrivyGallery `.vault` 备份格式

本文档描述 `VaultExportService` / `VaultImportService` 当前读写的 `.vault` 格式，供跨平台解析或恢复工具参考。参考实现见 [`tools/vault-unpacker/vault.go`](../../tools/vault-unpacker/vault.go)。

## 1. 概览

一个 `.vault` 文件由两层组成：

1. **外层容器 `SVEX`**：明文 JSON 头 + 按块 AES-GCM 加密的正文。
2. **内层归档 `SVAR`**：外层正文解密后得到，包含 JSON 清单和各个数据块（blob）。

通用约定：

- 所有整数都是 **big-endian**。
- JSON 使用 UTF-8，日期为 ISO 8601。
- 备份较大时会拆成多个 `.vault` 分片，每个分片都是独立完整的文件。

## 2. 外层容器 `SVEX`

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| magic | 4 | ASCII `SVEX` |
| containerVersion | 1 | 固定 `2` |
| headerLength | 4 | `UInt32`，header JSON 的字节数 |
| header | headerLength | 明文 JSON，见下 |
| chunk records | 到文件结尾 | 见 2.2 |

### 2.1 Header JSON

```json
{
  "appName": "PrivyGallery",
  "archiveByteCount": 123456789,
  "archiveEncoding": "chunked-lzfse-v1",
  "chunkSize": 8388608,
  "cipher": "aes-gcm-chunked-archive",
  "exportedAt": "2026-09-14T10:00:00Z",
  "formatVersion": 3,
  "kdf": {
    "algorithm": "pbkdf2-sha256",
    "rounds": 600000,
    "saltBase64": "..."
  },
  "partIndex": 0,
  "totalParts": 2
}
```

- `formatVersion`：`2` 或 `3`，区别见第 5 节。
- `kdf`：用 `PBKDF2-HMAC-SHA256(password, salt, rounds)` 派生 32 字节 AES 密钥；salt 为 32 字节随机数。
- `chunkSize`：外层每块明文的最大长度（当前 8 MiB）。
- `archiveByteCount`：内层归档的总明文字节数。

### 2.2 Chunk record

从 `chunkIndex = 0` 开始连续排列，直到文件结束：

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| chunkIndex | 4 | `UInt32`，必须等于上一块 + 1 |
| plaintextLength | 8 | `UInt64` |
| ciphertextLength | 8 | `UInt64` |
| nonceLength | 4 | `UInt32`，当前为 12 |
| nonce | nonceLength | |
| tagLength | 4 | `UInt32`，当前为 16 |
| tag | tagLength | |
| ciphertext | ciphertextLength | |

每块单独做 AES-GCM，附加认证数据（AAD）为 UTF-8 字符串：

```text
SVEX-v2|{partIndex}|{totalParts}|{chunkIndex}|{archiveByteCount}
```

注意 AAD 前缀在 `formatVersion` 为 3 时仍是 `SVEX-v2`。所有块解密后按顺序拼接，总长度必须等于 `archiveByteCount`，得到内层归档。

## 3. 内层归档 `SVAR`

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| magic | 4 | ASCII `SVAR` |
| archiveVersion | 1 | 固定 `1` |
| manifestLength | 8 | `UInt64` |
| manifest | manifestLength | JSON，键按字母排序，见第 4 节 |
| blobCount | 4 | `UInt32` |
| blobs | — | 共 blobCount 个，见 3.1 |

### 3.1 Blob

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| pathLength | 4 | `UInt32` |
| path | pathLength | UTF-8，对应清单中 `blobEntries[].relativePath` |
| sourceDomain | 1 | 数据类型，见 3.2 |
| byteCount | 8 | `UInt64`，该文件的明文总字节数 |
| data chunks | — | 重复读取，直到累计明文长度等于 byteCount |

每个 data chunk：

| 字段 | 长度 | 说明 |
| --- | --- | --- |
| codec | 1 | `0` = 原始数据，`1` = LZFSE 压缩 |
| plaintextLength | 4 | `UInt32` |
| payloadLength | 4 | `UInt32` |
| payload | payloadLength | codec 为 0 时 payloadLength 等于 plaintextLength |

blob 内的数据已是 **明文原始文件**（导出时已从 App 内部加密存储中解出），单块明文不超过 1 MiB。

### 3.2 `sourceDomain`

| 值 | 含义 | path 对应 |
| --- | --- | --- |
| 1 | 媒体文件（照片 / 视频 / Live Photo 静态图） | `items[].relativePath` |
| 2 | Live Photo 的配对视频 | `items[].livePhotoCompanionRelativePath` |
| 3 | 自定义相册封面图 | `albums[].coverImageRelativePath` |

同一分片中，配对视频紧跟在它的静态图之后；封面图位于分片末尾。

## 4. Manifest JSON

```json
{
  "exportedAt": "ISO8601",
  "spaceRawValue": "spaceA",
  "partIndex": 0,
  "totalParts": 2,
  "albums": [],
  "items": [],
  "blobEntries": []
}
```

### 4.1 `albums[]`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| id | String (UUID) | 导出时的相册 ID，跨分片保持一致 |
| name | String | |
| kindRawValue | String | `allPhotos` / `allVideos` / `custom` / `secureLibrary` / `secureCustom` / `trash` / `archive` |
| coverItemIDRawValue | String? | 封面项目 ID；仅当该项目也在本分片时才有值 |
| coverImageRelativePath | String? | 自定义封面图；只有备份中确实包含对应的 domain 3 blob 时才有值 |
| coverSymbolName | String? | SF Symbol 封面 |
| sortOptionRawValue | String | |
| customOrderedItemIDs | [String] | 仅包含本分片内的项目 |
| showsCover | Bool | |
| libraryOrderIndex | Int | |
| colorRawValue | String? | 相册颜色，`#RRGGBB` |

### 4.2 `items[]`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| id | String (UUID) | |
| name | String | App 内显示名 |
| createdAt / importedAt / updatedAt | Date | |
| lastExportedAt / originalCapturedAt | Date? | |
| trashedAt | Date? | 移入回收站的时间（新字段） |
| videoDuration | Double? | 视频时长（秒） |
| mediaKindRawValue | String | `photo` / `video` / `livePhoto` |
| isInTrash / isArchived / isStrongProtected | Bool | |
| relativePath | String | 用于匹配 domain 1 blob |
| livePhotoCompanionRelativePath | String? | 用于匹配 domain 2 blob（新字段） |
| originalFilename | String | |
| contentTypeIdentifier | String | UTI |
| locationLatitude / locationLongitude | Double? | |
| albumIDs | [String] | |

`relativePath` 这类路径只用来和 blob 对应；恢复时会生成新的存储路径。

### 4.3 `blobEntries[]`

```json
{ "relativePath": "VaultStorage/Space_A/Active/xxx.heic", "sourceDomain": 1, "byteCount": 1234567 }
```

`byteCount` 为明文大小。

## 5. 版本与兼容性

- **`formatVersion = 2`**：只包含 domain 1 blob。所有支持 v2 的 App 版本都能恢复。
- **`formatVersion = 3`**：分片中含有 domain 2 或 domain 3 blob。除此之外布局与 v2 完全相同。
  - 不认识 v3 的旧版 App 会提示"不支持这个备份文件"，而不是误报文件损坏。
- 导出时逐个分片判断：没有 Live Photo 视频和封面图的分片仍写成 v2。
- 新增的 JSON 字段都是可选的，读取端应忽略不认识的字段。

## 6. 分片规则

- 每个分片最多 700 个项目，明文大小超过约 2 GiB 时切分。
- 相册记录会出现在每一个引用了它的分片中；没有任何项目的自定义相册放在第 0 片。
- 同一个封面文件只写一次，放在第一个引用其相册的分片里。
- 系统相册（`allPhotos` 等）不会作为相册重建，只是随清单一起写出。

## 7. App 恢复行为

- 只重建 `custom` / `secureCustom` 相册，同名时自动改名。
- 一次恢复多个分片时，按相册 `id` 合并：跨分片的相册只创建一次，后续分片会追加项目和排序。
- 所有 blob 都会用目标空间的密钥重新加密后写入：
  - 媒体和配对视频写入 `Active` / `Trash`；
  - 封面写入 `AlbumCovers`。
- `trashedAt` 缺失时，回收站中的项目用 `updatedAt` 作为移入时间。
- 强加密状态由 `isStrongProtected` 恢复。

## 8. 最小解析流程

1. 校验 `SVEX` 和容器版本 `2`，读取 header JSON，确认 `formatVersion` 为 2 或 3。
2. 用 PBKDF2-HMAC-SHA256 派生密钥。
3. 按顺序解密每个 chunk record（带 AAD），拼出内层归档。
4. 校验 `SVAR` 和版本 `1`，读取 manifest。
5. 依次读取 blob，按 codec 解压拼接；根据 `sourceDomain` 和清单决定输出文件名。

## 9. App 本地密码验证（不属于 `.vault` 格式）

这部分描述 App 如何验证空间密码，便于调试解锁流程。

- 每个空间有一个随机的 256-bit 主密钥（DEK），媒体文件和加密元数据都用它按块 AES-GCM 加密。
- 设置密码时，App 用 `SHA256("SecurityFolder|{space}|{passcode}")` 作为包裹密钥，对 DEK 做 AES-GCM 包裹。
  - 包裹结果存入钥匙串的 `space.{space}.wrapped.key`，访问级别为 `WhenUnlockedThisDeviceOnly`。
- 验证密码 = 用输入的密码派生包裹密钥，看能否解开 wrapped key。App 不保存明文密码。
- Face ID / Touch ID 解锁读取的是另一份受 `biometryCurrentSet` 保护的 DEK 副本。
- 修改密码只重新包裹 DEK，不重新加密媒体。
- 胁迫密码存储的是 `SHA256("SecurityFolder.Coercion|{passcode}")` 摘要；输入匹配时立即执行紧急清空。
