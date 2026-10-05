# BiliBeats

基于 Flutter 开发的哔哩哔哩音频播放器，支持同步 LRC 歌词与离线缓存。

## 下载与安装

- **[最新版本](https://github.com/Aeacu2/BiliBeats/releases/latest)**

---

### Android 安装

1. 在 Latest Release 页面下载 `bilibeats-x.x.x-arm64-v8a.apk` 安装包。
2. 在 Android 设备上打开下载的 `.apk` 文件（需 Android 6.0 及以上版本）。
3. 如系统提示，请在系统设置中允许"安装未知来源应用"以完成安装。

> 自 6.0.0 之后的版本起，应用包名由 `com.bilibeat.bilibeat` 更改为 `com.bilibeats.app`。
> 系统会将其视为另一款应用：旧版本不会被覆盖升级，资料库亦不会迁移，请卸载旧版本后重新安装。

---

### iOS 安装

BiliBeats 未上架 Apple App Store，发布构建以未签名归档包（`bilibeats-x.x.x-unsigned.ipa`）形式提供。iOS 安装前需使用个人开发者证书进行签名（需 iOS 13.0 及以上版本）。

#### 方式一：通过 AltStore 安装（推荐）

AltStore 支持本地安装，并可通过 Wi-Fi 自动续签后台证书。

1. **安装 AltServer**：在 macOS 或 Windows 上从 [altstore.io](https://altstore.io) 下载并运行 AltServer。
2. **部署 AltStore 至设备**：
   - 通过 USB 连接 iOS 设备至电脑，并确认设备信任。
   - 点击菜单栏或系统托盘中的 AltServer 图标，选择 `Install AltStore`，再选择已连接的 iOS 设备。
   - 使用 Apple ID 登录以签发免费开发证书。
3. **信任描述文件**：在 iOS 设备上进入 `设置` > `通用` > `VPN 与设备管理`，在"开发者 App"下找到您的 Apple ID 并选择`信任`。
4. **安装 BiliBeats**：
   - 使用 iOS 设备上的 Safari 下载 `bilibeats-x.x.x-unsigned.ipa`。
   - 打开 AltStore，进入"我的 App"页面，点击 `+` 图标并选择已下载的 `.ipa` 文件。
   - *自动续签*：只要主机电脑与设备处于同一 Wi-Fi 网络且保持运行，AltServer 会自动续签 7 天有效期的证书。

#### 方式二：通过 Sideloadly 安装

Sideloadly 是一款基于桌面端的直装工具，可通过 USB 直接安装已签名安装包。

1. **安装 Sideloadly**：在 macOS 或 Windows 上从 [sideloadly.io](https://sideloadly.io) 下载并安装 Sideloadly。
2. **部署安装包**：
   - 通过 USB 连接 iOS 设备至电脑。
   - 启动 Sideloadly，将 `bilibeats-x.x.x-unsigned.ipa` 拖入应用窗口。
   - 在 `Apple Account` 一栏输入您的 Apple ID，点击 `Start` 开始签名安装。
3. **信任描述文件**：安装完成后，在 iOS 设备的 `设置` > `通用` > `VPN 与设备管理` 中信任与您 Apple ID 关联的证书。

## 签名（Android）

发布构建使用 `android/key.properties` 中的密钥进行签名。首次构建前请执行以下命令生成：

```bash
tool/make_keystore.sh
```

请务必妥善备份 `android/bilibeats-release.jks` 与 `android/key.properties` 两个文件，且切勿提交至仓库（两者均已被 gitignore 排除）。密钥一旦丢失将无法找回——更换密钥将无法对既有安装进行升级。

如缺少上述文件，构建将回退使用调试密钥并给出警告。可使用以下命令核验实际发布产物所使用的签名：

```bash
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

## 构建

```bash
tool/build_release.sh          # Android（默认）
```

```bash
tool/build_release.sh ios
```

```bash
tool/build_release.sh all
```

**Android** — 单一混淆构建的 **arm64-v8a** APK。项目已永久放弃 32 位架构；ARM 笔记本（Apple Silicon、Windows on ARM）同样使用 arm64-v8a，因此该构建可覆盖上述全部设备。**需要 JDK 21 及以上版本**——AGP 内置 lint 在 JDK 17 下会因 `NoSuchMethodError` 失败，报错信息与 Java 版本无关，难以排查。

**iOS** — 混淆构建的**未签名 .ipa**（位于 `build/ios/ipa/`）。本应用未注册 Apple Developer 账号，因此无法上架 App Store；请通过 AltStore / Sideloadly / 自有描述文件签名安装，即以您自己的身份为其签名。构建需 macOS 及 Xcode，支持 iOS 13 及以上版本。

iOS 工程**不依赖 CocoaPods**。本项目使用的全部插件均自带 `Package.swift`，已通过 Swift Package Manager 完成集成，并有意删除了 `ios/Podfile`——残留的 Podfile 会导致构建在未安装 CocoaPods 时报错。若未来某个插件仅支持 Pods 集成，请使用 `flutter create .` 重新生成 Podfile，并在本文件中说明。

混淆意味着发布构建的崩溃堆栈需配合对应构建的符号文件方可解析。符号文件输出至 `symbols/<版本号>/` 目录，请妥善保留（并随发布一并提供），解码命令如下：

```bash
flutter symbolize -i trace.txt -d symbols/<版本号>/app.android-arm64.symbols
```

（iOS 崩溃堆栈使用同一目录下的 `app.ios-arm64.symbols`。）

## 开发

日常开发只需标准 Flutter 工具链：

```bash
flutter analyze   # 静态检查（未使用的成员与死代码在本项目中按错误处理）
flutter test      # 单元测试与 widget 测试
```

调整界面后，可在无设备的情况下将主要页面渲染为图片（输出至 `build/screens/`，需 macOS 自带的中文字体）：

```bash
flutter test test/render_screens.dart --update-goldens
```

代码结构、约定与注意事项见 [CLAUDE.md](CLAUDE.md)。`docs/archive/` 中为历史评审与旧版功能清单，仅供查阅，不再维护。

歌词标题解析（`LyricsEngine.cleanTitle`）的回归语料位于
`test/fixtures/real_bilibili_titles.json`（540 条真实 B 站标题）。
调整解析规则前请先补充或核对语料，避免依赖机器本地的临时文件。

每次 push / PR 由 GitHub Actions（`.github/workflows/ci.yml`）自动执行
`flutter analyze` 与 `flutter test`，Flutter 版本固定为 3.44.8，升级 SDK 时请同步更新。

## 发布流程

```bash
tool/release.sh patch "修复了某某问题"   # 或 minor / major，可跟多条说明
```

脚本会一次性完成：提升 `pubspec.yaml` 版本号与构建号、在 `CHANGELOG.md` 顶部插入条目、
提交并打 `vX.Y.Z` 标签。它**不执行构建**——随后运行 `tool/build_release.sh all`，
并将产物与对应的 `symbols/` 符号文件一同附加到 GitHub Release。
脚本要求工作区干净，确保发布提交只包含版本变更本身。

## 免责声明

- **仅供学习交流**：本项目为个人非商业性质的开源技术研究与学习项目，旨在探索 Flutter 跨平台媒体播放及本地音频管理技术。
- **版权声明**：音视频内容、原声配乐、视频封面、弹幕及歌词等元数据之知识产权均归属哔哩哔哩（Bilibili）平台及原 UP 主 / 版权所有方。
- **纯客户端无托管**：本项目不设立、不运营任何集中式云端中转服务器或音视频转存托管服务；所有搜索、解析与音频下载均由用户设备本地直连完成。
- **无破解与商业化**：本项目严禁用于任何商业牟利行为，不内置任何广告、付费会员或赞助内购，亦不包含任何破解大会员付费内容、绕过付费音乐包或违规盗播功能。
- **合规使用**：请在遵守所在地法律法规及平台服务协议的前提下合理使用。因非正常使用或二次分发造成的任何版权纠纷与法律责任，均由使用者自行承担，与本项目开发者无关。

## 许可证

本项目基于 [GNU General Public License v3.0 (GPL-3.0)](LICENSE) 开源。
