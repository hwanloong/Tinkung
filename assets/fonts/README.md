# 字体目录（需自行准备）

**这个目录里的字体文件不随仓库分发。**

本目录在 `.gitignore` 中被排除。**请按下文自行准备，否则构建会因为找不到字体资源而失败。**

> **为什么必须放：** `pubspec.yaml` 的 `fonts:` 段声明了
> `assets/fonts/SanFranciscoDisplay-Regular.otf`。Flutter 打包时会去找它，
> 找不到就**直接报错** —— 它不支持"可选字体资源"。

## 需要哪些文件

```
assets/fonts/
├── SanFranciscoDisplay-Regular.otf   界面正文字体（**必须**）
├── CJK-subset.ttf                    测试出图的中文替身（由脚本生成）
└── Mono.ttf                          测试出图的等宽替身
```

`CJK-subset.ttf` 和 `Mono.ttf` 只给测试用（`test/preview_fonts.dart`
把它们的字形注册到 `sans-serif` / `monospace` 这两个系统族名上），
**但它们在 `pubspec.yaml` 的 `assets:` 里，所以会被打进 APK**。
加起来不到 1 MB，可以接受；真要省体积就得改 `preview_fonts.dart`
的加载方式（改成 `File` 直读），不在这次的范围里。

### SanFranciscoDisplay-Regular.otf（必须）

界面**唯一**的字体，从 macOS / iOS 的字体里取（文件名可能带 `-2` 之类的后缀，
内容一样）。要求：

- **必须是 Regular 一个字重。** 界面上的 `w600` 由 Flutter 合成（fake bold）。
- 字体内部名（name ID 1）应当包含 `San Francisco Display`；
  pubspec 里声明的族名是 `SanFranciscoDisplay`，Flutter 认的是**文件名声明**那个，
  所以内部名不一致不影响，只是不好排查。

> **它不含汉字。** 这份字体的 `cmap` 里只有 745 个码位：拉丁字母、数字、标点。
> 所以界面上的中文完全依赖 `AppFonts.bodyFallback` 里的 `sans-serif` ——
> 真机上由系统解析成 Noto Sans CJK / 苹方之类。**不要删那条兜底链**，
> 删了整个界面会变成一片空心方块。

### CJK-subset.ttf / Mono.ttf（测试出图用）

`test/preview_fonts.dart` 会把它们注册成 `sans-serif` / `monospace`，
这样预览出图里的中文和代码才是汉字/等宽，而不是空方块
（flutter_test 环境没有系统字体）。

**它们只影响 `flutter test --update-goldens` 出来的渲染图。**
缺了也能跑 —— `preview_fonts.dart` 会跳过缺失的字体继续，
只是出图里的中文会变成占位方块。

`CJK-subset.ttf` 是**子集**：只含 `lib/` + `test/` 源码里出现过的汉字。
所以**加了新的中文文案之后必须重新生成**：

```powershell
python tools\subset_font.py C:\Windows\Fonts\NotoSansSC-VF.ttf assets\fonts\CJK-subset.ttf
```

> 源字体用 **`NotoSansSC-VF.ttf`**（Windows 自带的可变字体）。
> 以前文档写的是 `NotoSansCJK-Regular.ttc`，那份文件在项目里**不存在**，
> 照着跑会报 not found。脚本会把可变字体按 `wght=400` 固化成静态实例 ——
> 不做这一步，子集出来的字在 Skia 里画不出来，图上全是空心方块。

## 为什么 San Francisco Display 不随仓库分发

它是**苹果的字体**，随 macOS / iOS 授权给系统使用者，授权范围
**不包括再分发**。把它提交到公开仓库，或分发带这份字体的构建产物，
都属于侵权。在你自己的机器上使用属于正常的系统授权范围。

想换成可自由分发的字体，改两处即可：

1. `pubspec.yaml` 的 `fonts:` 段（资源路径与家族名）
2. `lib/theme/app_theme.dart` 的 `AppFonts.family`（家族名）

> 换字体时**记得同步改 `test/preview_fonts.dart`** ——
> 那里是按族名加载的，不同步的话渲染图会悄悄变成占位字体。

## 排查

出图或运行时不显示预期字体时，按这个顺序查：

```powershell
# 1. 文件齐了没
Get-ChildItem assets\fonts | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB)}}

# 2. 头 4 字节是不是合法 sfnt（OTF/CFF 是 4F 54 54 4F = "OTTO"）
Format-Hex assets\fonts\SanFranciscoDisplay-Regular.otf -Count 4

# 3. 出图看一眼（中文是方块 = 兜底字体没加载）
flutter test test/ui_preview_test.dart --update-goldens
```

相关工具（都在 `tools/` 下，不进 APK）：

- `gen_icon.py` —— 生成启动图标（改色/改形状只需要改它，然后重跑）
- `icon_preview.py` —— 把自适应图标按圆形/圆角方形遮罩裁一遍，确认没被切边
- `extract_ttc.py` —— 从 `.ttc` 字体集合里抽出单个 `.ttf`
