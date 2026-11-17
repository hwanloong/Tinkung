# Tinkung 的 Material You UI 实现指南

本文说明 Tinkung 如何实现 Material You（Material 3）视觉风格，以及新增或调整界面时如何沿用现有主题体系。它记录的是仓库当前的实现约定，不是要求把每个页面都改成默认 Material 外观。

## 设计目标

- **颜色成套变化：** 主题种子色或 Android 系统壁纸色不仅影响按钮，也影响表面、容器、描边和文字。
- **亮暗模式一致：** 两种模式都从相同的颜色来源生成语义色，组件不在各处自行猜测颜色。
- **品牌色适度出现：** 强调色用于主要操作、选中态和交互反馈；错误、成功、警告仍保留清楚稳定的语义。
- **尊重 Tinkung 的既有界面：** Material 3 负责色彩系统、组件基础和交互状态；Tinkung 可以在主题层调整圆角、密度或玻璃效果，不必把所有页面变成卡片。

## 当前实现概览

主题主要定义在 `lib/theme/app_theme.dart`，应用入口及系统动态取色接入在 `lib/main.dart`。

| 能力 | 当前实现 |
|---|---|
| Material 3 | `ThemeData(useMaterial3: true)` |
| 默认种子色 | `AppColors.defaultSeed`（陶土橙 `#D97757`） |
| 种子色配色 | `ColorScheme.fromSeed`，变体为 `DynamicSchemeVariant.tonalSpot` |
| Android 壁纸动态色 | `dynamic_color` 的 `DynamicColorBuilder`；用户启用跟随系统颜色时使用系统提供的浅色/深色方案 |
| 不支持动态色时 | 回退到用户种子色生成的方案；未设置种子色则使用默认品牌色 |
| 表面语义 | `AppSurface` 以 `ThemeExtension` 暴露页面底色、卡片、芯片、描边、文字和气泡颜色 |
| 旧调用点兼容 | `AppColors.applyScheme` 将当前方案同步给无法访问 `BuildContext` 的静态调用点 |
| 明暗模式 | `ThemeMode.system`，浅色与深色主题分别构建 |

## 颜色如何贯穿整个界面

避免只让主按钮变色、而页面仍使用固定灰色。当前主题把同一个 `ColorScheme` 用作三处颜色来源：

1. **Material 组件：** `ThemeData.colorScheme` 提供标准语义颜色和状态色。
2. **Tinkung 自定义组件：** `AppSurface.fromScheme` 将 Material 3 的 `surface`、`surfaceContainerLow`、`surfaceContainerHigh`、`surfaceContainerHighest`、`outlineVariant` 等映射到应用自己的表面角色。
3. **无上下文的既有调用点：** `AppColors.applyScheme` 同步更新强调色和页面背景等静态入口。

颜色大致按以下语义使用：

| 视觉用途 | 推荐来源 |
|---|---|
| 页面背景 | `AppSurface.of(context).pageBg` 或 `Theme.of(context).colorScheme.surface` |
| 卡片/面板表面 | `AppSurface.of(context).surface` |
| 芯片、较高层级的容器 | `AppSurface.of(context).chipBg` |
| 输入框、代码块底色 | `AppSurface.of(context).codeBg` |
| 主文字与次要文字 | `AppSurface.of(context).text` / `.muted` |
| 主要操作、选中态、链接 | `Theme.of(context).colorScheme.primary` |
| 错误、成功、警告 | 相应语义色；不要让它们随品牌种子色改变含义 |

在 widget 中优先使用 `Theme.of(context).colorScheme` 和 `AppSurface.of(context)`。新增全局静态颜色前先确认调用点确实无法取得上下文；不要为单个页面重新定义一套固定灰阶或固定强调色。

### 新增界面组件示例

```dart
final ColorScheme colors = Theme.of(context).colorScheme;
final AppSurface surfaces = AppSurface.of(context);

Scaffold(
  backgroundColor: surfaces.pageBg,
  body: Card(
    color: surfaces.surface,
    child: ListTile(
      title: Text('主题设置', style: TextStyle(color: surfaces.text)),
      subtitle: Text('使用系统动态颜色', style: TextStyle(color: surfaces.muted)),
      trailing: Icon(Icons.palette_outlined, color: colors.primary),
    ),
  ),
);
```

示例只展示取色方式。对于普通设置行，遵循现有页面的条目式布局，不要为了使用 Material You 而额外包卡片。

## 动态颜色与种子色

在 `lib/main.dart` 中，`DynamicColorBuilder` 提供设备支持时的动态浅色和深色 `ColorScheme`。设置启用跟随系统颜色后，应用将这些方案传给 `AppTheme.light` 和 `AppTheme.dark`；否则主题按用户设置的种子色生成。

因此实现时应遵循：

- 使用主题传入的 `ColorScheme`，不要在 widget 中再次读取壁纸或手动生成颜色。
- 系统动态色不可用时，确保种子色回退仍能独立工作（例如旧 Android 版本和非 Android 设备）。
- 若添加颜色角色，检查浅色和深色方案都能读清文字、图标、边界及状态。
- 改动通过静态颜色字段影响全局时，检查 `MaterialApp.builder` 中对**当前生效主题**的同步逻辑，避免浅色模式误用深色方案的值。

## 组件形态与交互

`AppTheme._build` 已集中设置 AppBar、对话框、输入框、卡片、按钮、芯片、分隔线、底部面板、导航栏、开关和滑块等主题。请优先在主题层调整跨页面共用的样式，而不是在几十个页面里复制配置。

Tinkung 的视觉风格也包含既有的克制圆角、条目式设置、聊天输入框玻璃效果和底部导航处理。采用 Material You 的动态色并不意味着必须移除这些产品特征。修改时注意：

- 表面层级优先靠 `surface` 色调阶梯区分，避免堆叠过重阴影和边框。
- 圆角使用 `AppRadius` 的统一刻度；不要在新页面散落任意数值。
- 保留清晰的点击、按下、焦点和选中状态；不要把所有水波纹或状态层设为透明。
- 玻璃、模糊和半透明表面应检查真机显示；widget 测试不能完整证明 shader 和系统合成效果。
- 让动态文字尺寸、字体回退和中文显示继续通过 `AppFonts` 的统一机制处理。

## 添加或调整主题的工作流程

1. 阅读 `lib/theme/app_theme.dart` 中的 `AppColors`、`AppRadius`、`AppSurface` 和 `AppTheme`。
2. 先为颜色确定语义角色，再将其接入 `ColorScheme` 或 `AppSurface`；避免直接写入页面颜色常量。
3. 同时检查种子色、系统动态色、浅色模式和深色模式。
4. 保持状态色的语义稳定，并确认前景/背景有足够对比度。
5. 运行格式化、静态分析和测试：

   ```bash
   dart format lib/theme/app_theme.dart lib/main.dart
   flutter analyze lib
   flutter test
   ```

6. 若改动影响界面预览，按需更新并检查 golden：

   ```bash
   flutter test test/ui_preview_test.dart --update-goldens
   ```

   预览图可验证布局与颜色；玻璃效果、系统栏和壁纸取色仍应在目标 Android 设备上实际检查。

## 相关文件

- `lib/theme/app_theme.dart` — 字体、颜色、表面角色、圆角和组件主题。
- `lib/main.dart` — 系统动态色、用户种子色、明暗模式与 `MaterialApp` 的接入。
- `pubspec.yaml` — `dynamic_color` 依赖及 Flutter Material 图标配置。
- `docs/README.md` — 工程界面约定和预览图测试说明。
