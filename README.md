# BambuRFID

BambuRFID 是一个 Android-only 的极简 Flutter 应用，用手机 NFC 读取兼容的 Bambu Lab 耗材 RFID 标签，并直接展示耗材信息。

## v1.6.2 界面与交互

- 扫描到标签后直接切换当前耗材，不提供“扫描 / 再次扫描”按钮。
- 顶部左侧为 `BambuRFID` 应用标识；点击进入“关于”页面。
- 顶部右侧为 `中 / EN` 切换，和左侧标识垂直对齐。
- 首次启动按设备语言选择中文或英文；用户手动切换后使用 Android `SharedPreferences` 记住选择。
- 主界面保持纯白、单页、无卡片堆叠、无渐变背景、无玻璃拟态。
- 主界面不再使用 `SingleChildScrollView`；采用 360×720 逻辑画布，先按 SafeArea 可用宽高完整适配，再将整套首页视觉统一缩小到适配结果的 90%；不设置会导致短屏溢出的最小缩放下限，因此核心界面始终在一页内完整显示。
- 耗材图片使用重新抠图后的透明双图层：透明线盘固定层 + 可动态换色的耗材明度层。
- 名称下仅显示：`重量 · 生产日期`，已删除价格。
- 信息区显示：
  - 颜色名称 + `#RRGGBB`；双色标签会显示两个 RGB Hex。
  - 直径。
  - 喷嘴温度范围。
  - 烘干参数：温度 + 时间。
- 信息区宽度由最长的一行决定；所有横线等于该宽度；行内容左对齐；整个信息区整体居中。

## RFID 实现

Android 原生层位于：

```text
android/app/src/main/kotlin/com/bamburfid/app/MainActivity.kt
```

主要流程：

1. `NfcAdapter.enableReaderMode` 持续监听 NFC-A 标签。
2. 使用 Android `MifareClassic` API 访问兼容标签。
3. 按公开研究中的 HKDF-SHA256 方式由 4-byte UID 派生扇区 Key A / Key B。
4. 认证并读取前 5 个扇区的数据块。
5. 解析材质、颜色、重量、直径、生产日期、喷嘴温度和烘干参数。
6. 原生层使用单线程 latest-tag 队列处理连续扫描，不再丢弃“上一张标签尚未读完时到达”的新标签。
7. 单次读取失败会自动重试；每若干次事务及失败后会刷新 ReaderMode，降低部分 Android NFC 栈长时间连续读取后进入陈旧状态的概率。
8. 通过 Flutter `EventChannel` 将结果推给 Dart UI；每次成功读取带递增 `scanSequence`，新标签直接替换旧数据。

> Android 手机即使具有 NFC，也不一定支持 MIFARE Classic。实际支持取决于 NFC 控制器和厂商实现。

## 语言记忆

项目不依赖额外的 Flutter preference 插件。

- Dart 首次以 `platformDispatcher.locale.languageCode` 判断设备语言。
- Android 原生层使用 `SharedPreferences` 保存 `zh` / `en`。
- 保存后再次启动优先使用用户选择。

## 耗材图片

运行时资源：

```text
assets/spool_base.png
assets/spool_color_luma.png
```

原始参考图：

```text
tool/reference/spool_reference.png
```

重新抠图脚本：

```text
tool/build_spool_assets.py
```

该脚本仅用于重新生成图片资源，不参与 App 构建。运行脚本需要 Python、Pillow、NumPy、OpenCV。

## 项目仓库与开源声明

项目仓库：

```text
https://github.com/5Breeze/BambuRFID
```

BambuRFID 是完全开源的非商业项目，不以盈利为目的，不涉及任何商业利益，也不参与商业活动。项目代码按 GNU GPL v3.0 发布；第三方项目、数据、SDK 与商标仍受其各自许可和权利条款约束。

## 关于页面 / Credits

“关于 BambuRFID”页面列出了项目使用的技术、研究参考、版权和许可说明。项目主要参考：

- `queengooborg/Bambu-Lab-RFID-Tag-Guide`：RFID 数据结构、读取方式和密钥派生研究。
- `queengooborg/Bambu-Lab-RFID-Library`：标签样本数据和字段验证参考；上游仓库标注 GPL-3.0。
- Flutter SDK：界面框架。
- Android NFC / `MifareClassic`：原生 NFC 访问。

详细说明见 [`NOTICE.md`](NOTICE.md) 和 [`LICENSE`](LICENSE)。

## 构建

要求：Flutter SDK、Android SDK、JDK 17+。

```bash
cd BambuRFID
flutter pub get
flutter build apk --release
```

开发运行：

```bash
flutter run
```

APK 通常输出到：

```text
build/app/outputs/flutter-apk/app-release.apk
```

### Gradle 下载网络受限

项目包含完整的 `android/gradlew`、`android/gradlew.bat` 和 `android/gradle/wrapper/`。如果 `services.gradle.org` 跳转 GitHub 后网络失败，可使用项目根目录：

```bash
chmod +x fix_gradle_local.sh
./fix_gradle_local.sh /path/to/BambuRFID
```

或者给终端 / Gradle 配置本机 HTTP 代理后直接构建。

## Release signing

当前 `release` 构建仍使用 debug signing，方便本地直接生成 APK。正式发布前请在：

```text
android/app/build.gradle.kts
```

替换为你自己的 release keystore 配置。

## License

BambuRFID 项目代码按 GNU GPL v3.0 发布，完整文本见 `LICENSE`。

“Bambu Lab”及相关商标归各自权利人所有。本项目为独立社区工具，与 Bambu Lab 无隶属、授权或背书关系。
