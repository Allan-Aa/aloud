# 念 / Aloud

一款原生 macOS 朗读工具，把编辑器、剪贴板或当前选中的文字转换为语音。

A native macOS text-to-speech app for reading editor text, clipboard content, or the current selection aloud.

当前版本：`0.2.21 (23)` · 最低系统：macOS 14

## 功能 / Features

- 支持 MiniMax、OpenAI 和 macOS 系统语音。MiniMax 与 OpenAI 使用用户自己的 API Key，macOS 系统语音无需云端凭据。
- MiniMax 音色按类别分组并支持搜索；332 个系统音色附带内置离线样音，试听同一音色时无需重复请求 API。
- 在其他 AI 原生桌面 App 中按下设置的全局快捷键，例如 Codex、Claude，可以直接朗读当前前台对话的最新 AI 回复，不必切回对话窗口或手动复制。
- 也支持剪贴板朗读、当前选区朗读、Markdown 清理、播放速度调整、历史记录和 WAV 导出。
- API Key 保存在 macOS 钥匙串中；MiniMax 也可通过本机 1Password CLI 导入。
- Gemini 适配器仍受实验功能与发布审批双重门控，当前发行版不可用。

---

- Supports MiniMax, OpenAI, and macOS system voices. MiniMax and OpenAI use the user's own API key; macOS voices require no cloud credential.
- MiniMax voices are searchable and grouped. The app bundles offline samples for 332 system voices, so replaying those samples does not incur another API request.
- From another AI-native desktop app, such as Codex or Claude, press the configured global hotkey to read the latest reply from the current foreground conversation, without switching back or copying it manually.
- Also includes clipboard and selection reading, Markdown cleanup, playback-speed controls, history, and WAV export.
- API keys are stored in the macOS Keychain. MiniMax can also import through the local 1Password CLI.
- The Gemini adapter remains behind both experimental-feature and release-approval gates and is unavailable in the current release.

## 系统要求 / Requirements

- macOS 14 或更高版本 / macOS 14 or later
- Xcode 或 Swift 6 工具链 / Xcode or a Swift 6 toolchain
- [mpv](https://mpv.io/) 与 [FFmpeg](https://ffmpeg.org/)

使用 Homebrew 安装运行时依赖：

```bash
brew install mpv ffmpeg
```

应用默认在 `/opt/homebrew/bin` 查找这两个程序，也可在高级设置中修改路径。

## 从源码运行 / Run from source

```bash
git clone https://github.com/Allan-Aa/aloud.git
cd aloud
swift build
swift run Aloud
```

首次使用时，在设置中选择服务商、模型和音色。MiniMax 与 OpenAI 需要分别保存对应 API Key；MiniMax 的 1Password 导入要求本机已安装并登录 [1Password CLI](https://developer.1password.com/docs/cli/)，并在 `Private` 保险库中创建名为 `Aloud MiniMax API Key`、字段为 `credential` 的条目。也可以直接在应用内手动保存 Key。项目不会从环境变量或仓库文件读取生产密钥。

For first use, choose a provider, model, and voice in Settings. MiniMax and OpenAI each require their own API key. MiniMax can import through the [1Password CLI](https://developer.1password.com/docs/cli/) from an item named `Aloud MiniMax API Key`, with a `credential` field, in the `Private` vault; manual entry in the app is also supported. The project does not read production credentials from environment variables or repository files.

在 Codex、Claude 等 AI 原生桌面 App 的对话窗口前台显示时，可以在其他 App 中按下设置的全局快捷键，念会读取当前对话的最新 AI 回复并开始播放。这个入口面向支持相应读取方式的 AI 原生桌面 App，不代表所有聊天 App 都提供同样的对话读取能力。

When a conversation is in the foreground in an AI-native desktop app such as Codex or Claude, press the configured global hotkey from another app. Aloud reads the latest reply and starts playback. This entry point targets AI-native desktop apps that support the corresponding extraction path; it does not imply equivalent conversation extraction from every chat app.

## 构建应用包 / Build the app bundle

构建脚本会校验内置样音、编译 release 版本、组装 `build/念.app`，再进行 hardened-runtime 签名：

```bash
./Scripts/build-app.sh
```

默认使用本地临时签名；如需使用自己的开发者签名身份，请在构建前设置 `CODESIGN_IDENTITY`。构建完成后，退出正在运行的旧版本，再通过 Finder 将 `build/念.app` 拖入“应用程序”。

The build script validates bundled samples, builds a release binary, assembles `build/念.app`, and signs it with the hardened runtime. It uses an ad-hoc local signature by default; set `CODESIGN_IDENTITY` before building to use your own signing identity.

## 服务商配置 / Provider setup

| 服务商 / Provider | 凭据 / Credential | 当前状态 / Status |
| --- | --- | --- |
| MiniMax | 手动保存 API Key，或通过 1Password CLI 导入 / Manual API key or 1Password CLI import | 可用 / Available |
| OpenAI | 手动保存 API Key / Manual API key | 可用；首次试听会显示 AI 语音披露 / Available; first preview shows the AI-voice disclosure |
| macOS | 无 / None | 可用，完全本地 / Available and local |
| Gemini | API Key | 发布门控，当前不可用 / Release-gated and currently unavailable |

云端语音可能产生服务商费用。内置 MiniMax 系统音色样音是本地文件；私有、克隆或新生成音色的首次试听可能调用服务商，成功后会复用本地缓存。

Cloud voices may incur provider charges. Bundled MiniMax system-voice samples are local files. A first preview of private, cloned, or newly generated voices may call the provider; successful results are then reused from the local cache.

## 安全与隐私 / Security and privacy

- 不要把 API Key、钥匙串导出、1Password 输出、用户文本或原始服务商响应提交到仓库。
- 生产凭据存储在 macOS 钥匙串中，设置界面不会回显已保存的密钥。
- 自动化测试必须使用假的凭据、网络、播放器和系统边界，不应读取真实钥匙串或调用付费 API。
- 日志与错误提示应保持内容安全，不包含密钥或待朗读文本。

Never commit API keys, Keychain exports, 1Password output, user text, or raw provider responses. Production credentials belong in the macOS Keychain, and automated tests must use fake external boundaries rather than real credentials or paid APIs.

## 测试 / Testing

```bash
swift test
```

提交前还应运行：

```bash
git diff --check
```

涉及界面、快捷键、播放或服务商流程的改动，除自动测试外，还需要在 production build 中完成对应的真实交互验收。测试通过只证明测试覆盖的路径，不代表真实服务商请求已经验证。

Changes to UI, hotkeys, playback, or provider workflows also require interaction checks in a production build. Passing automated tests proves only the covered paths; it is not evidence that a real provider request succeeded.

## 贡献 / Contributing

欢迎提交 issue 和 pull request。请让改动保持聚焦，为行为变化添加回归测试，并在 PR 中写明已验证与未验证的边界。任何真实凭据、个人文字、账户响应或机器私有路径都不得进入提交、测试夹具、日志或审计产物。

Issues and pull requests are welcome. Keep changes focused, add regression coverage for behavior changes, and state both verified and unverified boundaries. Never include real credentials, personal text, account responses, or machine-private paths in commits, fixtures, logs, or audit artifacts.

## 许可证 / License

项目自有的源代码与文档采用 [MIT License](LICENSE)。

`Sources/Aloud/Resources/VoiceSamples/` 中捆绑的 MiniMax 样音不属于本项目的 MIT 授权范围；这些音频仍受 MiniMax 的适用条款约束。MiniMax、OpenAI、Gemini、Apple、1Password、mpv 与 FFmpeg 是其各自权利人的商标或项目，本仓库与这些权利人不存在默认背书关系。

Project-owned source code and documentation are licensed under the [MIT License](LICENSE).

Bundled MiniMax samples under `Sources/Aloud/Resources/VoiceSamples/` are excluded from this project's MIT grant and remain subject to the applicable MiniMax terms. MiniMax, OpenAI, Gemini, Apple, 1Password, mpv, and FFmpeg belong to their respective owners; their mention does not imply endorsement.
