<!-- Languages: English · 简体中文 · 繁體中文 -->
**English** · [简体中文](#简体中文) · [繁體中文](#繁體中文)

# Security Policy

## Reporting a vulnerability

If you believe you've found a security vulnerability in PrivyGallery, please report
it **privately** — do not open a public issue.

- Preferred: open a private report via **GitHub Security Advisories**
  (the *"Report a vulnerability"* button on the repository's **Security** tab).
- Alternatively, email the maintainer at the security contact listed in the App
  Store listing / in-app *Contact* screen.

Please include:

- A description of the issue and its potential impact.
- Steps to reproduce, or a proof of concept.
- Affected version (see the app's About screen) and device / iOS version.

We aim to acknowledge reports within a few days. Please give us a reasonable
window to investigate and ship a fix before any public disclosure.

## What is in scope

- The on-device encryption and key-wrapping design.
- The `.vault` backup format and the `vault-unpacker` tool.
- Passcode handling, biometric unlock, and the coercion-passcode wipe flow.
- Anything that could expose decrypted media or keys outside the intended flow.

## What is *not* in scope

- The absence of OS-level guarantees Apple does not provide (e.g. there is no public
  API to globally block screenshots).
- Physical attacks against an unlocked device.
- Social-engineering of the device owner.

## Honest security note

PrivyGallery implements real, local privacy features built on Apple's system
cryptography (`CryptoKit`, the Keychain, and Secure-Enclave-backed biometrics). It
has **not** undergone a formal third-party security audit. The cryptographic design
and the `.vault` format are intentionally **open and documented** so they can be
reviewed — see [`Materials/docs/vault-format.md`](Materials/docs/vault-format.md).

---

<a name="简体中文"></a>
[English](#security-policy) · **简体中文** · [繁體中文](#繁體中文)

# 安全策略

## 报告漏洞

如果你认为在 PrivyGallery 中发现了安全漏洞，请**私下**报告——不要公开提交 issue。

- 推荐方式：通过 **GitHub Security Advisories** 提交私密报告
  （仓库 **Security** 标签页中的 *“Report a vulnerability”* 按钮）。
- 或者：发送邮件至 App Store 页面 / App 内 *联系* 界面中列出的安全联系方式。

请在报告中包含：

- 问题描述及其潜在影响。
- 复现步骤或概念验证（PoC）。
- 受影响的版本（见 App 的“关于”界面）以及设备 / iOS 版本。

我们会尽量在数天内确认收到报告。在我们调查并发布修复之前，请给予合理的时间窗口，
不要提前公开披露。

## 适用范围

- 设备本地的加密与密钥包裹设计。
- `.vault` 备份格式以及 `vault-unpacker` 工具。
- 密码处理、生物识别解锁，以及胁迫密码的抹除流程。
- 任何可能在预期流程之外泄露已解密媒体或密钥的问题。

## 不在适用范围内

- 操作系统未提供的能力所导致的限制（例如：iOS 没有公开 API 可以全局禁止截屏）。
- 针对已解锁设备的物理攻击。
- 针对设备所有者的社会工程攻击。

## 诚实的安全说明

PrivyGallery 基于 Apple 的系统加密能力（`CryptoKit`、钥匙串，以及基于安全隔区的
生物识别）实现了真实的本地隐私保护。它**尚未**经过正式的第三方安全审计。其加密设计
与 `.vault` 格式有意保持**公开且有文档**，以便接受审查——见
[`Materials/docs/vault-format.md`](Materials/docs/vault-format.md)。

---

<a name="繁體中文"></a>
[English](#security-policy) · [简体中文](#简体中文) · **繁體中文**

# 安全性政策

## 回報漏洞

如果你認為在 PrivyGallery 中發現了安全性漏洞，請**私下**回報——請勿公開提交 issue。

- 建議方式：透過 **GitHub Security Advisories** 提交私密回報
  （倉庫 **Security** 分頁中的 *「Report a vulnerability」* 按鈕）。
- 或者：寄送電子郵件至 App Store 頁面 / App 內 *聯絡* 畫面所列的安全聯絡方式。

回報時請包含：

- 問題描述及其潛在影響。
- 重現步驟或概念驗證（PoC）。
- 受影響的版本（見 App 的「關於」畫面）以及裝置 / iOS 版本。

我們會盡量在數天內確認收到回報。在我們調查並發布修補之前，請給予合理的時間，
請勿提前公開揭露。

## 適用範圍

- 裝置本機的加密與金鑰包裹設計。
- `.vault` 備份格式以及 `vault-unpacker` 工具。
- 密碼處理、生物辨識解鎖，以及脅迫密碼的抹除流程。
- 任何可能在預期流程之外洩漏已解密媒體或金鑰的問題。

## 不在適用範圍內

- 作業系統未提供之能力所造成的限制（例如：iOS 沒有公開 API 可以全域禁止截圖）。
- 針對已解鎖裝置的實體攻擊。
- 針對裝置擁有者的社交工程攻擊。

## 誠實的安全性說明

PrivyGallery 以 Apple 的系統加密能力（`CryptoKit`、鑰匙圈，以及基於安全隔離區的
生物辨識）實作了真實的本機隱私保護。它**尚未**經過正式的第三方安全性稽核。其加密設計
與 `.vault` 格式刻意保持**公開且具文件**，以便接受審查——見
[`Materials/docs/vault-format.md`](Materials/docs/vault-format.md)。
