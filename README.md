# ColorGrader 调色工坊

一个**完全离线**运行的 Flutter 图片调色 App：相簿选图调色 + 摄像头实时滤镜取景，7 个滑块实时生效，模板以 JSON 存在应用沙盒，成片写进系统相册。没有后端、没有网络请求、没有账号。

推送 GitHub 后由 GitHub Actions 自动构建 release APK 并作为 Artifact 上传。

---

## 一、功能与实现对照

| 需求 | 本项目的实现 |
| --- | --- |
| 相簿选图 | `image_picker`（Android 13+ 走系统 Photo Picker） |
| 摄像头实时取景 | `camera` 的 `startImageStream`（YUV420 帧）+ 常驻 worker isolate 逐帧渲染 |
| 实时滤镜 | 每帧在 worker 里做 YUV→RGB → 亮度/对比度/色温 LUT → 高光阴影 → 饱和度 → 锐化 |
| 快门拍照 | 先 `stopImageStream` → `takePicture()` 得到**原始 JPEG** → 对原始 JPEG 套当前参数 → 存相册 |
| 7 个参数 | 亮度、对比度、饱和度、色温、锐化、高光、阴影 |
| 模板系统 | `getApplicationSupportDirectory()/templates/color_templates.json`，只存 7 个参数，不存图 |
| 模板操作 | 保存 / 列表一键加载 / 删除 |
| 强制逻辑① | 相簿预览永远从「原图缩略图的原始像素」副本重算，导出永远重新读**原始文件** |
| 强制逻辑② | 相机预览每帧套参数；成片 = 原始照片 + 当前参数（一次性计算） |
| 重置 | 一键回到 `AdjustParams.neutral` |
| 导出 | 全分辨率重新计算 → JPEG(92) → MediaStore 相册 `ColorGrader` |
| 权限 | CAMERA 运行时申请；相簿走 Photo Picker；写相册走 MediaStore（Android 10+ 免权限） |

---

## 二、目录结构

```
color_grader/
├── lib/
│   └── main.dart                      # 全部代码（约 1200 行，带注释，单文件可直接跑）
├── pubspec.yaml                        # 依赖配置
├── analysis_options.yaml               # lint 配置
├── .github/
│   └── workflows/
│       └── build_apk.yml               # push 即构建 release APK 并上传 Artifact
├── android/                            # 必须一起提交，CI 依赖它构建
│   ├── app/
│   │   ├── build.gradle                # applicationId / minSdk / targetSdk
│   │   └── src/main/
│   │       ├── AndroidManifest.xml     # 相机、存储权限
│   │       └── kotlin/.../MainActivity.kt
│   ├── build.gradle
│   ├── settings.gradle
│   ├── gradle.properties
│   └── gradle/wrapper/                 # gradlew + gradle-wrapper.jar
├── README.md
└── .gitignore
```

`main.dart` 内部按 7 个区块组织：

1. 调色参数模型 `AdjustParams`（含 JSON 序列化）
2. 像素引擎 `PixelEngine` / `applyColorPipeline` / `applySharpen`（纯函数，可在任意 isolate 执行）
3. 摄像头帧 `FrameRequest` / `FrameResponse` + worker isolate 入口
4. 图片解码 / 导出（`Isolate.run`，主线程不卡）
5. 模板仓库 `TemplateRepository`
6. App 入口
7. 主界面 `GraderPage`（状态机 + UI）

---

## 三、本地构建

前置：Flutter **3.47.x**（Dart 3.12）、JDK **17**、Android SDK（compileSdk 36，可自动下载）。

```bash
# 0. 自检
flutter doctor -v

# 1. 装依赖
cd color_grader
flutter pub get

# 2. 连真机跑（模拟器没有摄像头流，实时滤镜一定要真机测）
flutter run

# 3. 出 release APK
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk

# 4. 装机
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

> release 包默认用 debug keystore 签名（Flutter 模板行为），可以正常安装使用，但不能上架应用商店。要正式签名见「五、坑点 · 6」。

---

## 四、推送 GitHub + 自动构建 APK

```bash
git init
git add .
git commit -m "feat: ColorGrader 图片调色 App"
git branch -M main
git remote add origin git@github.com:<你的账号>/color-grader.git
git push -u origin main
```

推送后在仓库 **Actions → Build Release APK** 里就能看到构建，结束后：

- 页面底部 **Artifacts → `color-grader-release-apk`** 下载 zip，里面就是 `app-release.apk`；
- 也可以进一次 **Actions run → Summary** 直接看到产物列表。

发版本（可选）：打 tag 会自动把 APK 挂到 GitHub Release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

工作流关键点（`.github/workflows/build_apk.yml`）：

- `subosito/flutter-action@v2` 固定 `flutter-version: 3.47.9`，带 pub cache；
- `actions/setup-java@v4` 固定 JDK 17（AGP 8.x 必须 17，用 21 也能跑但别用 8/11）；
- `flutter analyze --no-fatal-infos --no-fatal-warnings`：只让真错误阻断构建；
- `actions/upload-artifact@v4` 上传 `build/app/outputs/flutter-apk/app-release.apk`，`if-no-files-found: error` 保证不会"静默成功"；
- `permissions: contents: write` 是 `softprops/action-gh-release` 发 Release 需要的。

> 注意：`android/` 目录（含 `gradle/wrapper/gradle-wrapper.jar`）必须一起提交。很多"CI 构建失败"都是因为 `.gitignore` 把 `android/` 或 wrapper 漏掉了。

---

## 五、坑点清单（按你关心的四类整理）

### 1. 安卓权限（Android 13+ / API 33+）

| 权限 | 什么时候要 | 本项目怎么处理 |
| --- | --- | --- |
| `CAMERA` | 必须 | `Permission.camera.request()`，拒绝则提示并保留相簿模式可用 |
| `READ_MEDIA_IMAGES` | 只在"直接读相册文件"时需要 | 用 `image_picker` 的 Photo Picker，**不需要**这个权限也能选图；manifest 里仍声明，兼容性更好 |
| `READ_EXTERNAL_STORAGE` | Android 12 及以下 | manifest 加 `android:maxSdkVersion="32"` |
| `WRITE_EXTERNAL_STORAGE` | Android 9 及以下（API ≤ 28） | manifest 加 `android:maxSdkVersion="28"`；Android 10+ 由 `gal` 走 MediaStore，**不需要任何存储权限** |
| 相机硬件声明 | 影响安装/上架过滤 | `<uses-feature android:name="android.hardware.camera" android:required="false"/>` |

额外注意：

- 用户勾了"不再询问"后 `request()` 会直接返回 `permanentlyDenied`，此时要么引导用户去设置页（`openAppSettings()`），要么降级到相簿模式 —— 本项目选择后者并在 UI 提示；
- Android 14 起 `Permission.photos` / `videos` 有 `READ_MEDIA_VISUAL_USER_SELECTED` 的"部分授权"，只要你不用它，就不要碰这些权限，走 Photo Picker 最省事；
- manifest 里声明了权限 ≠ 一定需要申请，**权限申请时机**比声明更容易翻车：本项目只在切到相机模式时才申请相机权限。

### 2. 摄像头帧性能（这里是最容易卡成 PPT 的地方）

1. **绝不在 UI isolate 做像素循环**。`startImageStream` 的回调跑在主 isolate，一帧 1280×720 的 YUV→RGB + 7 参数 ≈ 几十毫秒，直接在主线程算必定掉帧。本项目用**常驻 worker isolate**（`_frameWorkerEntry`），只 spawn 一次，避免每帧新建 isolate 的开销。
2. **每帧必须拷贝平面数据**。`CameraImage.planes[i].bytes` 底层 buffer 会被插件复用，回调里不拷贝就走，画面会撕裂。本项目在回调内 `Uint8List.fromList` 再发出去。
3. **降分辨率**。处理长边压到 480px（`_kFrameMaxEdge`），用整数步长最近邻降采样（不是每帧先 resize，省一次全图遍历）。
4. **丢帧而不是排队**。`_frameBusy` 标记 + `_latestSentSeq` 序号：worker 忙时新帧直接丢弃，回来的帧若序号不是最新的也丢弃，画面始终"跟手"而不是"追帧"。
5. **只做一次 YUV→RGB 转换**。用定点矩阵（359/88/183/454）代替浮点，和调色融进同一个循环，避免多次遍历缓冲区。
6. **参数快照随帧发送**。滑块一动，下一帧就用新参数，不需要重建流。
7. `ResolutionPreset.high`（720p）是画质/开销的平衡点；要更高拍照分辨率可改成 `max`，但帧拷贝和降采样开销会明显上升。
8. 前摄要**镜像**、Android 的 `sensorOrientation` 通常是 90°，不处理就是躺着的画面。本项目做了逆映射旋转 + 镜像，并给了一个"画面方向校正"按钮兜底个别机型。

### 3. 原图 / 预览分离（防"二次叠加调色"）

这是最容易埋雷的逻辑，本项目的三条铁律：

1. `_thumbSource`（`Uint8List`）保存的是**原图缩略图的原始 RGB(A)**，是相簿预览的唯一数据源；每次渲染都 `Uint8List.fromList(source)` 出副本再算，源永不被写坏。
2. 导出/保存时**重新从 `_originalPath` 读原始文件字节**，用当前参数一次性计算，不读 `_previewImage`、不读任何已处理的缓冲。
3. 相机模式保留 `_lastCapturePath`（`takePicture()` 的原始 JPEG），所以拍完再改参数、再点"导出保存"依然是"原始照片 + 当前参数"，不会在已调色的图上再叠一层。

反例（一定要避开）：

```dart
// ❌ 错：拿处理结果当下一轮输入，每次导出都叠一层，颜色越调越偏、画质逐代劣化
previewBytes = process(previewBytes, params);
// ✅ 对：永远从原始像素派生
previewBytes = process(originalThumbBytes, params);
```

同理，预览用**缩略图**、导出用**原图**：预览只为流畅，导出才是画质担当，两者共用同一套参数和同一份算法。

### 4. 摄像头拍照与 ImageStream 冲突

Android 上 `startImageStream` 期间调 `takePicture()` 会报错或拍到空帧。正确顺序：

```
stopImageStream() → takePicture() → 处理/保存 → startImageStream()
```

本项目按这个顺序做，并在 `finally` 里恢复取景，所以快门后只会闪一下（约 0.5~1 秒），不会一直黑屏。

### 5. 模板存放的沙盒路径

```
/data/user/0/<applicationId>/files/templates/color_templates.json
```

- `getApplicationSupportDirectory()` 就是 `/data/user/0/<applicationId>/files`，**不需要任何存储权限**；
- 换 applicationId（`android/app/build.gradle` 里的 `applicationId`）路径会跟着变；
- 沙盒文件在卸载 App 后会被系统删除，要长期保存就让用户把 JSON 导出/备份（本项目在模板弹窗底部直接显示了真实路径，方便 adb 拉取：`adb shell run-as <applicationId> cat files/templates/color_templates.json`）；
- JSON 结构固定为 `{"version":1,"templates":[{"id","name","createdAt","params":{7 项}}]}`，**不含图片**。

### 6. 其它容易踩的

- **JDK / AGP / Gradle 版本**：AGP 8.x 需要 JDK 17，Gradle 8.x。CI 里一定固定 JDK 17，否则报 `Unsupported class file major version`；
- **正式签名**：release 默认 debug 签名。要自建 keystore：

  ```bash
  keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias color
  ```

  在 `android/key.properties` 写 `storeFile/storePassword/keyAlias/keyPassword`（**别提交进 Git**），再在 `app/build.gradle` 的 `signingConfigs` 里引用；CI 上把这些放进 `secrets` 并解码成文件；
- **HEIC**：`image` 包不支持 HEIC/HEIF，个别机型相册图会解码失败，本项目会给出明确提示；
- **超大图内存**：48MP 图解码后 RGBA 约 200MB，容易 OOM。本项目把导出长边限制在 4096px（`_kPhotoMaxEdge`）；
- **竖屏**：App 锁竖屏（`setPreferredOrientations`），旋转角度按竖屏推导，锁屏能避开 90% 的旋转 bug；
- **相册里看不到图**：`gal` 存到 `ColorGrader` 相簿，部分国产 ROM 相册需要下拉刷新或重启相册 App 才显示；
- **`--split-per-abi`**：能显著减小体积（每 ABI 一个 APK），但用户要挑对架构；本项目默认出**通用 APK**（兼容性优先）。

---

## 六、调色算法口径（预览与导出完全一致）

所有参数归一化到 `-1..1`（锐化 `0..1`），处理顺序：

| 步骤 | 公式 | 说明 |
| --- | --- | --- |
| 亮度 | `c' = c + 0.35·b` | 加性偏移 |
| 对比度 | `c' = (c' - 0.5)·(1 + 0.9·k) + 0.5` | 围绕中灰，0.1x~1.9x |
| 色温 | `R += 0.12·t`，`B -= 0.12·t`，`G += 0.018·t` | 正=暖 |
| 高光 / 阴影 | 按亮度加权：`d = 0.3·hi·L² + 0.3·sh·(1-L)²`，三通道同加 `d` | L 为 0.299R+0.587G+0.114B |
| 饱和度 | `c' = L + (c - L)·(1 + s)` | 0 完全灰度，2 双倍 |
| 锐化 | 两趟 3 点差分 `out = in + a·(2·in - 左 - 右)` | 横向 + 纵向，不需要整帧拷贝 |

前 3 步合并为 3 张 256 项 LUT（查表代替浮点），高光/阴影预计算成 256 项 `tone` LUT，所以单像素只有几次查表和整数乘加 —— 这是能在 480px 上跑到 15~25fps 的原因。

---

## 七、二次开发入口

| 想改什么 | 改哪里 |
| --- | --- |
| 参数范围 / 强度 | `PixelEngine._build`（0.35 / 0.9 / 0.12 / 0.30 这几个系数） |
| 新增参数 | `AdjustParams` 加字段 → `_kSpecs` 加一行滑块 → `PixelEngine._build` 加计算 → 三处共用自动生效 |
| 预览清晰度 | `_kThumbMaxEdge`（相簿）/ `_kFrameMaxEdge`（相机） |
| 拍照分辨率 | `ResolutionPreset.high` → `max` |
| 导出质量 | `processPhotoBytes` 里的 `quality: 92`、`_kPhotoMaxEdge` |
| 相册名 | `_kAlbumName` |
