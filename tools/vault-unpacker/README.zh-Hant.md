# vault-unpacker

[English](README.md) · [简体中文](README.zh-Hans.md) · **繁體中文**

一個小巧、跨平台的命令列工具，可以在**不依賴 App** 的情況下解密並擷取 PrivyGallery 的
`.vault` 備份檔案。把它指向一個備份檔案（或裝滿備份的資料夾），輸入備份密碼，
它就會把你的原始照片和影片還原成一般檔案。

只要能執行 Go，它就能執行：macOS、Linux 和 Windows。

## 它做什麼

- 讀取 `.vault` 容器，從你的密碼衍生金鑰（PBKDF2-HMAC-SHA256），並對每個區塊做 AES-GCM 解密。
- 重建內部封存檔，解壓縮每個媒體區塊（LZFSE 或原始），並以其原始檔名寫出每個項目。
- 支援**多分卷備份**以及**一次處理多個檔案**——每個 `.vault` 都是獨立的，會被依序解包。
- 絕不修改輸入的 `.vault` 檔案。

## 安裝 / 建構

你需要 [Go](https://go.dev/dl/) 1.24+ 以及一個 C 編譯器（LZFSE 解壓縮使用的是 Apple 的參考
實作，透過 cgo 呼叫）：

- **macOS：** `xcode-select --install`（提供 clang）
- **Linux：** `gcc`（例如 `sudo apt install build-essential`）
- **Windows：** mingw-w64 / gcc 工具鏈，然後使用 `CGO_ENABLED=1` 建構

```bash
cd tools/vault-unpacker
go build -o vault-unpacker .
```

這會產生一個單獨的 `vault-unpacker` 執行檔，你可以複製到任何地方。

## 用法

```
vault-unpacker [選項] <檔案或目錄>...

選項：
  -o string   擷取媒體的輸出目錄（預設 "vault-unpacked"）
  -p string   備份密碼（省略則會安全地提示輸入）
  -l          僅列出內容；不擷取任何檔案
```

如果你不傳 `-p`，工具會提示你輸入密碼（輸入內容會被隱藏）。
密碼也可以透過環境變數 `VAULT_PASSWORD` 提供。

### 範例

把一個備份解包到 `./vault-unpacked`：

```bash
vault-unpacker "PrivyGallery Backup.vault"
```

把多分卷備份（或一整個裝滿 `.vault` 檔案的資料夾）解包到指定目錄：

```bash
vault-unpacker -o ./restored ~/Backups
```

只檢視內部包含什麼而不擷取：

```bash
vault-unpacker -l "PrivyGallery Backup.vault"
```

## 輸出佈局

擷取出的媒體會以每個項目的原始檔名寫入輸出目錄。匯出時位於 App 垃圾桶中的檔案會進入
`_Trash/` 子資料夾。檔名衝突時會加上 ` (2)`、` (3)`…… 後綴，因此不會覆寫任何檔案。

## 運作原理

`.vault` 格式是一個以密碼加密的容器：

1. 一段明文 JSON 標頭（`SVEX`，版本 2）宣告 KDF、鹽、加密演算法、分塊大小以及多分卷的分卷序號。
2. 主體是內部封存檔（`SVAR`），被切分為多個區塊並以 AES-GCM 獨立封裝。每塊的驗證資料將其
   綁定到格式版本、分卷序號、區塊序號與封存長度。
3. 內部封存檔包含一份 JSON 清單（相簿 + 媒體中繼資料），隨後是各個媒體資料區塊，
   以 LZFSE 或原始壓縮區塊的序列形式儲存。

本工具正是反向執行這一流程。權威的逐位元組佈局存在於原始碼中——見
[`vault.go`](vault.go)，其常數與讀取器與 App 的 `VaultExportService` 完全對應。

## 測試

```bash
go test ./...
```

測試會以 App 匯出器逐位元組相同的方式合成一個 `.vault` 檔案——包括一個真實的 LZFSE 壓縮區塊——
並斷言解包能逐位元組還原原始媒體，且錯誤密碼會被乾淨地拒絕。
