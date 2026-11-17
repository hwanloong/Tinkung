import '../core/custom_font.dart';

/// 一种可选字体。
///
/// [family] 是 Flutter 的 `fontFamily`：可以是打包进 APK 的族名（`Inter`）、
/// 系统族名（`serif` / `monospace`），也可以是运行时导入的自定义字体
/// （`UserFontLatin` 之类，见 `core/custom_font.dart`）。null = 交给平台默认。
///
/// [fallback] 只会被追加到全局兜底链里 —— 中文字体就是这么起作用的：
/// 它排在西文族后面，接住西文字体没有的字形。
class FontOption {
  const FontOption({
    required this.id,
    required this.label,
    required this.family,
    this.fallback = const <String>[],
    this.note = '',
  });

  final String id;
  final String label;
  final String? family;
  final List<String> fallback;
  final String note;
}

/// 英文字体（同时决定界面文字）。
///
/// 只有 `Inter` 是**打包进 APK** 的（见 `pubspec.yaml` 的 `fonts:`）；
/// 其余都是系统族名，由 ROM 自己映射到对应的字形。这样不增加包体，
/// 也给得出"衬线 / 等宽 / 窄体"这些真实存在的选择。
const List<FontOption> kLatinFonts = <FontOption>[
  FontOption(
    id: 'inter',
    label: 'Inter',
    family: 'Inter',
    fallback: <String>['sans-serif'],
    note: '内置 · 紧凑无衬线',
  ),
  FontOption(
    id: 'system',
    label: '跟随系统',
    family: null,
    fallback: <String>['sans-serif'],
    note: '和系统应用一致',
  ),
  FontOption(
    id: 'serif',
    label: '系统衬线',
    family: 'serif',
    fallback: <String>['sans-serif'],
    note: 'Times 风格',
  ),
  FontOption(
    id: 'mono',
    label: '系统等宽',
    family: 'monospace',
    fallback: <String>['sans-serif'],
    note: '每个字符同宽',
  ),
  FontOption(
    id: 'condensed',
    label: '系统窄体',
    family: 'sans-serif-condensed',
    fallback: <String>['sans-serif'],
    note: '一屏能多放几个字',
  ),
  FontOption(
    id: 'light',
    label: '系统细体',
    family: 'sans-serif-light',
    fallback: <String>['sans-serif'],
    note: '笔画更细',
  ),
];

/// 中文字体：只参与**兜底链**（西文字体没有的字形才落在这里）。
const List<FontOption> kCjkFonts = <FontOption>[
  FontOption(
    id: 'system',
    label: '跟随系统',
    family: null,
    note: '各 ROM 默认黑体',
  ),
  FontOption(
    id: 'serif',
    label: '宋体 / 衬线',
    family: 'serif',
    note: '横细竖粗，适合长文',
  ),
  FontOption(
    id: 'mono',
    label: '等宽',
    family: 'monospace',
    note: '每个汉字同宽',
  ),
];

/// 代码字体。
const List<FontOption> kCodeFonts = <FontOption>[
  FontOption(
    id: 'monospace',
    label: '系统等宽',
    family: 'monospace',
    fallback: <String>['monospace', 'sans-serif'],
    note: '默认 · 对齐最稳',
  ),
  FontOption(
    id: 'system',
    label: '跟随系统',
    family: null,
    fallback: <String>['monospace', 'sans-serif'],
    note: '用界面同一套字',
  ),
  FontOption(
    id: 'serif',
    label: '系统衬线',
    family: 'serif',
    fallback: <String>['monospace', 'sans-serif'],
    note: '带衬线的等宽回退',
  ),
  FontOption(
    id: 'sans',
    label: '系统无衬线',
    family: 'sans-serif',
    fallback: <String>['monospace'],
    note: '窄，但等宽性不保证',
  ),
];

/// 给列表补上"自定义"这一项（只有真的导入过文件才显示）。
List<FontOption> withCustom(
  List<FontOption> base,
  String slot, {
  List<String> fallback = const <String>['sans-serif'],
}) {
  if (!CustomFont.loaded(slot)) return base;
  return <FontOption>[
    ...base,
    FontOption(
      id: 'custom',
      label: '自定义字体',
      family: CustomFont.familyOf(slot),
      fallback: fallback,
      note: CustomFont.nameOf(slot),
    ),
  ];
}

/// 按 id 取选项；找不到时回落到 [fallback]（默认第一项）。
///
/// "找不到"是真实会发生的：用户导入的字体文件被删了、或者老存档里存着一个
/// 已经下线的 id。回落到第一项比抛异常好 —— 界面必须能打开。
FontOption resolveFont(
  List<FontOption> options,
  String id, {
  FontOption? fallback,
}) {
  for (final FontOption o in options) {
    if (o.id == id) return o;
  }
  return fallback ?? options.first;
}
