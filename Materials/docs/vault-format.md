# SecurityFolder `.vault` 文件格式说明

这份文档描述的是当前 iOS 实现里 `VaultExportService` / `VaultImportService` 实际读写的 `.vault` 备份格式，目标是方便实现一个跨平台解析或恢复工具。

## 1. 总体结论

- 文件扩展名：`.vault`
- 文件头魔数：`SVEX`
- 当前版本号：`1`
- 头部与清单：JSON
- 日期编码：`ISO8601`
- 整个备份的口令派生：`PBKDF2-HMAC-SHA256`
- 清单加密：`AES-GCM`
- 媒体数据加密：按块 `AES-GCM`
- 所有整数长度字段：`big-endian`

## 2. 二进制布局

整个文件按下面顺序排列：

1. `magic`
2. `version`
3. `headerLength`
4. `headerData`
5. `encryptedManifestLength`
6. `encryptedManifest`
7. `blobCount`
8. `blobEntry[0...]`

### 2.1 字段定义

#### `magic`

- 长度：4 字节
- 内容：ASCII `SVEX`

#### `version`

- 长度：1 字节
- 当前值：`0x01`

#### `headerLength`

- 长度：4 字节
- 类型：`UInt32`
- 含义：后续 `headerData` 的字节长度

#### `headerData`

- 编码：UTF-8 JSON
- 对应 Swift 结构：

```json
{
  "exportedAt": "2026-05-08T11:30:00Z",
  "spaceRawValue": "spaceA",
  "kdf": {
    "algorithm": "pbkdf2-sha256",
    "rounds": 600000,
    "saltBase64": "..."
  },
  "cipher": "aes-gcm-chunked-reencrypted-media",
  "chunkSize": 1048576
}
```

字段说明：

- `exportedAt`: 导出时间
- `spaceRawValue`: 导出来源空间，当前常见值是 `spaceA` / `spaceB`
- `kdf.algorithm`: 当前固定为 `pbkdf2-sha256`
- `kdf.rounds`: 当前实现固定为 `600000`
- `kdf.saltBase64`: 32 字节随机盐的 Base64
- `cipher`: 当前固定为 `aes-gcm-chunked-reencrypted-media`
- `chunkSize`: 当前实现固定为 `1048576`，也就是 1 MiB

#### `encryptedManifestLength`

- 长度：8 字节
- 类型：`UInt64`
- 含义：后续 `encryptedManifest` 的字节长度

#### `encryptedManifest`

- 内容：使用导出口令派生出的 32 字节 key，对 manifest 的 JSON 原文执行 `AES-GCM` 加密
- 存储形式：`CryptoKit.AES.GCM.SealedBox.combined`
- 格式等价于：
  - `nonce`
  - `ciphertext`
  - `tag`
  这三部分合在一起

#### `blobCount`

- 长度：4 字节
- 类型：`UInt32`
- 含义：后续 blob 记录条数

## 3. Manifest JSON

清单解密后是 UTF-8 JSON，对应这些字段：

```json
{
  "exportedAt": "2026-05-08T11:30:00Z",
  "spaceRawValue": "spaceA",
  "albums": [...],
  "items": [...],
  "blobEntries": [...]
}
```

### 3.1 `albums`

每一项字段如下：

```json
{
  "id": "UUID",
  "name": "相册名",
  "kindRawValue": "custom",
  "coverItemIDRawValue": "UUID 或 null",
  "coverImageRelativePath": "字符串或 null",
  "coverSymbolName": "字符串或 null",
  "sortOptionRawValue": "newestFirst",
  "customOrderedItemIDs": ["UUID", "..."],
  "showsCover": true,
  "libraryOrderIndex": 5
}
```

注意：

- 当前恢复逻辑只真正导入 `custom` 和 `secureCustom`
- 系统相册如 `allPhotos` / `allVideos` / `archive` / `trash` 不会作为自定义相册重建

### 3.2 `items`

每一项字段如下：

```json
{
  "id": "UUID",
  "name": "显示名",
  "createdAt": "ISO8601",
  "importedAt": "ISO8601",
  "lastExportedAt": "ISO8601 或 null",
  "originalCapturedAt": "ISO8601 或 null",
  "updatedAt": "ISO8601",
  "mediaKindRawValue": "photo 或 video",
  "isInTrash": false,
  "isArchived": false,
  "isStrongProtected": false,
  "relativePath": "VaultStorage/Space_A/Active/xxx.jpg",
  "originalFilename": "IMG_1234.JPG",
  "contentTypeIdentifier": "public.jpeg",
  "locationLatitude": null,
  "locationLongitude": null,
  "albumIDs": ["album-uuid-1", "album-uuid-2"]
}
```

说明：

- `relativePath` 是导出时应用内部的相对路径，用来和 `blobEntries` 对上
- 恢复时不会复用这个路径，而是生成新的目标路径再写入当前空间

### 3.3 `blobEntries`

每一项字段如下：

```json
{
  "relativePath": "VaultStorage/Space_A/Active/xxx.jpg",
  "sourceDomain": 1,
  "byteCount": 1234567
}
```

说明：

- 当前 `sourceDomain` 只支持：
  - `1 = media`
- `byteCount` 是明文媒体大小，不是加密后大小

## 4. Blob 区段布局

每个 blob 记录都按下面顺序存储：

1. `pathLength`
2. `pathData`
3. `sourceDomain`
4. `expectedByteCount`
5. `encryptedChunk[0...]`

### 4.1 字段定义

#### `pathLength`

- 长度：4 字节
- 类型：`UInt32`

#### `pathData`

- 编码：UTF-8
- 内容：对应 manifest 里的 `relativePath`

#### `sourceDomain`

- 长度：1 字节
- 当前值：
  - `1 = media`

#### `expectedByteCount`

- 长度：8 字节
- 类型：`UInt64`
- 含义：解密后的总明文字节数

### 4.2 `encryptedChunk`

之后不是单独再写一个 chunk 数量，而是循环读取：

1. `encryptedChunkLength`，4 字节 `UInt32`
2. `encryptedChunkData`，长度由上一步给出

导入端会持续解密 chunk，直到累计解出的明文字节数达到 `expectedByteCount` 为止。

也就是说，blob 的终止条件不是“读到 chunk 数量结束”，而是“累计明文长度满足 `expectedByteCount`”。

## 5. 口令派生和加密细节

### 5.1 口令派生

- 算法：`PBKDF2-HMAC-SHA256`
- 输出长度：32 字节
- 轮数：写在 header 的 `kdf.rounds`
- 盐：写在 header 的 `kdf.saltBase64`

### 5.2 Manifest 加密

- 算法：`AES-GCM`
- key：上一步派生出的导出 key
- 存储：`SealedBox.combined`

### 5.3 媒体块加密

- 每个媒体会先从应用内部密文解出明文
- 再按 `chunkSize` 切块
- 每块使用同一个导出 key 单独做一次 `AES-GCM`
- 每块直接写 `combined` 结果

因此跨平台工具恢复媒体时，只要：

1. 先解 header
2. 用口令派生 key
3. 解 manifest
4. 按 blob 顺序读取 chunk
5. 对每个 chunk 做 `AES-GCM` 解密
6. 拼出完整明文

就可以拿到原始媒体内容。

## 6. 恢复时的业务行为

当前 iOS 端恢复逻辑还有几条业务规则：

- 自定义相册名冲突会自动改名
- 恢复时只重建 `custom` / `secureCustom`
- 强加密状态由 `isStrongProtected` 恢复
- 恢复到当前空间时，媒体会重新写入当前空间自己的加密存储路径

所以跨平台工具如果只是想“解出内容”，不需要完整模拟这些业务逻辑；如果想做“兼容恢复”，就需要同时处理这些元数据规则。

## 7. 最小解析流程示例

1. 读取前 4 字节，确认是 `SVEX`
2. 读取 1 字节版本号，确认是 `1`
3. 读取 `UInt32` 头部长度
4. 解析 header JSON
5. 用 `PBKDF2-HMAC-SHA256` 派生 32 字节 key
6. 读取 `UInt64` 的 manifest 长度
7. 用 `AES-GCM` 解出 manifest JSON
8. 读取 `UInt32` 的 blob 数量
9. 循环解析每个 blob
10. 对每个 chunk 做 `AES-GCM` 解密并拼接

## 8. 兼容性提醒

当前文档只对应现有实现：

- `magic = SVEX`
- `version = 1`
- `kdf.algorithm = pbkdf2-sha256`
- `cipher = aes-gcm-chunked-reencrypted-media`

如果未来 iOS 端修改了这些字段，跨平台工具应该优先按 header 中实际声明的值来分支处理，而不要把这些值硬编码死。

## 9. 应用密码本身是怎么验证的

这部分不是 `.vault` 文件格式的一部分，但如果你要做跨平台“小工具”或者调试导入/解锁流程，理解应用自己的密码验证方式会很重要。

### 9.1 不是明文比对

应用并不会把主密码明文存起来，然后做字符串比较。

当前实现里，空间密码的验证方式是：

1. 用户输入密码
2. 按密码类型先做规范化
   - 例如四位数字密码、六位数字密码会先标准化
   - 自定义密码则按原文处理
3. 使用下面这段材料派生一个 `wrappingKey`

```text
"SecurityFolder|\(space.rawValue)|\(passcode)"
```

4. 对这段 UTF-8 数据做一次 `SHA256`
5. 把得到的 32 字节结果作为 `AES-GCM` 的 key
6. 用这个 key 去解 Keychain 里保存的“已包裹空间主密钥”
7. 如果能成功解开，并得到合法的空间主密钥，就认为密码正确
8. 如果解不开，就认为密码错误

也就是说，应用本质上是在验证：

> 你输入的密码，能不能正确解开这个空间对应的 DEK 包裹层

而不是在验证：

> 这个字符串是否和某个已存的明文/哈希完全相等

### 9.2 Keychain 里真正存的是什么

每个空间会有一个随机生成的 256-bit 主密钥，也就是 DEK。

首次设置密码时，会做两件事：

1. 生成一个随机 `SymmetricKey(size: .bits256)`
2. 用上面派生出来的 `wrappingKey` 对这个 DEK 做一次 `AES-GCM` 包裹

然后把包裹后的结果存到 Keychain：

- Keychain account:
  - `space.spaceA.wrapped.key`
  - `space.spaceB.wrapped.key`

所以主密码验证成功的判断标准，其实就是：

- 能否用当前输入密码派生出的 wrappingKey，
- 正确解开 `space.<space>.wrapped.key`

### 9.3 Face ID 解锁为什么不需要再输密码

应用还会把同一个原始 DEK 再存一份生物识别入口：

- 也是放在 Keychain
- 但访问控制是 `biometryCurrentSet`

这样 Face ID 成功后，应用直接拿到原始 DEK，不需要再走密码派生那层。

### 9.4 修改密码时为什么不用重加密所有媒体

因为媒体文件本身不是直接用“用户密码”加密的，而是用空间 DEK 加密。

所以改密码时只需要：

1. 先用旧密码解开被包裹的 DEK
2. 再用新密码重新生成 wrappingKey
3. 用新 wrappingKey 重新包裹同一个 DEK
4. 把新的 wrapped key 写回 Keychain

媒体文件本身不用整库重加密。

### 9.5 胁迫密码怎么判断

胁迫密码和主密码不是同一套验证方式。

它当前是：

1. 先按对应密码类型规范化
2. 拼接固定前缀：

```text
"SecurityFolder.Coercion|\(passcode)"
```

3. 做一次 `SHA256`
4. 把摘要存进 Keychain
5. 解锁时先检查这个摘要是否匹配
6. 如果匹配，直接执行紧急抹除

所以胁迫密码是“摘要匹配触发”，主密码是“能否解开 wrapped DEK”。
