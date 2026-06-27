# vault-unpacker

[English](README.md) · **简体中文** · [繁體中文](README.zh-Hant.md)

一个小巧、跨平台的命令行工具，可以在**不依赖 App** 的情况下解密并提取 PrivyGallery 的
`.vault` 备份文件。把它指向一个备份文件（或装满备份的文件夹），输入备份密码，
它就会把你的原始照片和视频还原成普通文件。

只要能运行 Go，它就能运行：macOS、Linux 和 Windows。

## 它做什么

- 读取 `.vault` 容器，从你的密码派生密钥（PBKDF2-HMAC-SHA256），并对每个块做 AES-GCM 解密。
- 重建内部归档，解压每个媒体块（LZFSE 或原始），并以其原始文件名写出每个项目。
- 支持**多分卷备份**以及**一次处理多个文件**——每个 `.vault` 都是独立的，会被依次解包。
- 绝不修改输入的 `.vault` 文件。

## 安装 / 构建

你需要 [Go](https://go.dev/dl/) 1.24+ 以及一个 C 编译器（LZFSE 解压使用的是 Apple 的参考
实现，通过 cgo 调用）：

- **macOS：** `xcode-select --install`（提供 clang）
- **Linux：** `gcc`（例如 `sudo apt install build-essential`）
- **Windows：** mingw-w64 / gcc 工具链，然后使用 `CGO_ENABLED=1` 构建

```bash
cd tools/vault-unpacker
go build -o vault-unpacker .
```

这会生成一个单独的 `vault-unpacker` 可执行文件，你可以复制到任何地方。

## 用法

```
vault-unpacker [选项] <文件或目录>...

选项：
  -o string   提取媒体的输出目录（默认 "vault-unpacked"）
  -p string   备份密码（省略则会安全地提示输入）
  -l          仅列出内容；不提取任何文件
```

如果你不传 `-p`，工具会提示你输入密码（输入内容会被隐藏）。
密码也可以通过环境变量 `VAULT_PASSWORD` 提供。

### 示例

把一个备份解包到 `./vault-unpacked`：

```bash
vault-unpacker "PrivyGallery Backup.vault"
```

把多分卷备份（或一整个装满 `.vault` 文件的文件夹）解包到指定目录：

```bash
vault-unpacker -o ./restored ~/Backups
```

只查看内部包含什么而不提取：

```bash
vault-unpacker -l "PrivyGallery Backup.vault"
```

## 输出布局

提取出的媒体会以每个项目的原始文件名写入输出目录。导出时位于 App 回收站中的文件会进入
`_Trash/` 子文件夹。文件名冲突时会加上 ` (2)`、` (3)`…… 后缀，因此不会覆盖任何文件。

## 工作原理

`.vault` 格式是一个以密码加密的容器：

1. 一段明文 JSON 头（`SVEX`，版本 2）声明 KDF、盐、加密算法、分块大小以及多分卷的分卷序号。
2. 主体是内部归档（`SVAR`），被切分为多个块并用 AES-GCM 独立封装。每块的认证数据将其
   绑定到格式版本、分卷序号、块序号与归档长度。
3. 内部归档包含一份 JSON 清单（相册 + 媒体元数据），随后是各个媒体数据块，
   以 LZFSE 或原始压缩块的序列形式存储。

本工具正是反向执行这一流程。权威的逐字节布局存在于源码中——见
[`vault.go`](vault.go)，其常量与读取器与 App 的 `VaultExportService` 完全对应。

## 测试

```bash
go test ./...
```

测试会以 App 导出器逐字节相同的方式合成一个 `.vault` 文件——包括一个真实的 LZFSE 压缩块——
并断言解包能逐字节还原原始媒体，且错误密码会被干净地拒绝。
