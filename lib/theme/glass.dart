import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_theme.dart';

// ============================================================ 行内文本

/// 渲染 `**行内粗体**` 和 `` `行内代码` `` 的 Text。
///
/// **为什么需要它**：项目里到处在 UI 文案里写 `**重点**`、`` `命令` ``
/// （写 markdown 的习惯），但普通 `Text` 不解析 markdown ——
/// 星号和反引号会**原样显示**出来。界面上出现一堆 `**` 和 `` ` ``，
/// 看起来就像哪里坏了，而写的人完全不会意识到。
///
/// 只处理这两种行内标记，不引完整的 markdown 渲染器：
/// UI 文案需要的就这两种，而完整解析器会带进块级排版（标题、列表、代码块），
/// 那些塞在一行提示里只会更乱。真正需要完整 markdown 的地方用 `MarkdownView`。
///
/// 注意区分：**给模型看的**工具描述、提示词里的 `**` 是正确的，不要动 ——
/// 那些文本是发给模型的，它读 markdown。
Widget mdText(
  String text, {
  required TextStyle style,
  TextAlign? textAlign,
  int? maxLines,
  TextOverflow? overflow,
}) {
  final RegExp re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`', dotAll: true);
  final List<InlineSpan> spans = <InlineSpan>[];
  int last = 0;

  for (final RegExpMatch m in re.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }

    final String? bold = m.group(1);
    if (bold != null) {
      spans.add(
        TextSpan(
          text: bold,
          // 封顶 w600：本项目的字重约定就是最高 semibold
          // （见 README 的「字号与字重」）。再粗一档就压过正文了。
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    } else {
      // 行内代码：等宽、比正文小一号，**不换颜色** ——
      // 换了会在灰字提示里突然冒出一块彩色，反而更乱。
      spans.add(
        TextSpan(
          text: m.group(2),
          style: AppFonts.code(
            size: (style.fontSize ?? 13) - 1,
            color: style.color,
          ),
        ),
      );
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));

  // 没有标记时退化成普通 Text 的行为（spans 只有一段），不必特判。
  return Text.rich(
    TextSpan(style: style, children: spans),
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
  );
}

// ============================================================ 玻璃核心

/// 玻璃的视觉层级
enum GlassRole {
  /// 卡片：最轻，细边框 + 一层薄斜面
  card,

  /// 控件：按钮、输入框，斜面更明显，带按压反馈
  control,

  /// 悬浮层：弹窗、面板，投影更重
  floating,
}

class _GlassLayers {
  const _GlassLayers({
    required this.fill,
    required this.onFill,
    required this.shadow,
  });

  final Color fill;
  final Color onFill;
  final Color shadow;

  /// 卡片 / 控件的填色。
  ///
  /// iOS 的层次**不靠投影**，靠两件事：
  ///  · 卡片比页面底**亮一档**（`#FFFFFF` 浮在 `#F2F2F7` 上）；
  ///  · 一条 `#E5E5EA` 的发丝线勾出边界。
  ///
  /// 所以这里只有填色，没有暖色投影 —— 投影在 iOS 设计语言里只属于
  /// 真正浮起来的弹层（见 [BlurSurface] 的 floating 分支）。
  static _GlassLayers of(BuildContext context, GlassRole role) {
    final AppSurface s = AppSurface.of(context);
    final bool dark = s.isDark;

    final Color fill = switch (role) {
      // 卡片：页面底之上的一层。
      GlassRole.card => s.surface,
      // 控件：按钮、输入框。压过一档的灰 —— "可输入/可点"更靠前。
      GlassRole.control => s.codeBg,
      // 悬浮层：面板拖到页面上，仍用卡片那一档，靠投影浮起来。
      GlassRole.floating => s.surface,
    };

    return _GlassLayers(
      fill: fill,
      onFill: s.text,
      // 只给悬浮层留一层中性投影。卡片和控件不需要 ——
      // 它们靠面板底色和描边就已经分层了，再叠投影就是"每样东西都浮着"，
      // 整屏看起来发灰、发脏（这正是之前"太浓"的一部分）。
      shadow: dark
          ? Colors.black.withValues(
              alpha: role == GlassRole.floating ? 0.55 : 0.0,
            )
          : Colors.black.withValues(
              alpha: role == GlassRole.floating ? 0.10 : 0.0,
            ),
    );
  }
}

/// **带模糊的玻璃面**（Android 17 / M3 Expressive 语言）。
///
/// 这是全项目玻璃材质的唯一实现：
///  · `BackdropFilter` 做真实背景模糊（滚动内容从底下透出来时是糊的）；
///  · 半透明的米白填充 + 一条极细的暖色描边 —— 玻璃的边界靠描边，
///    不靠灰色投影；
///  · 只有真的浮起来的东西（弹层、面板）才加投影。
///
/// 从前这里用的是液态玻璃（折射 + 高光 shader）。用户要求"把液态玻璃
/// 全部改回带模糊效果的 Android 17 设计语言"：模糊是主体，折射去掉。
class BlurSurface extends StatelessWidget {
  const BlurSurface({
    super.key,
    required this.child,
    this.radius = AppRadius.card,
    this.role = GlassRole.card,
    this.padding = EdgeInsets.zero,
    this.color,
    this.borderColor,
    this.blur = 20,
    this.shadow = true,
    this.fillOpacity,
  });

  final Widget child;
  final double radius;
  final GlassRole role;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double blur;
  final bool shadow;

  /// 覆盖填充色的不透明度。
  ///
  /// 默认按 [role] 取一档（control 亮色 0.80 / 暗色 0.66）。输入框和顶栏
  /// 按钮要"能看见背后被糊掉的内容"，所以会显式传更低的透明度 ——
  /// 只改 [blur] 不够，填充还是实心的话看起来仍然像一块板。
  ///
  /// 传了就以它为准，不再走 [role] 的默认档位。
  final double? fillOpacity;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final _GlassLayers g = _GlassLayers.of(context, role);

    final bool pill = radius >= 100;
    final BorderRadius br = BorderRadius.circular(pill ? 999 : radius);

    // 半透明度：卡片更实（要读字），弹层更透（能看见背后）。
    final double alpha = switch (role) {
      GlassRole.card => s.isDark ? 0.72 : 0.86,
      GlassRole.control => s.isDark ? 0.66 : 0.80,
      GlassRole.floating => s.isDark ? 0.78 : 0.90,
    };

    // 不做模糊时把填充加实一点。
    //
    // 半透明填充是给"背后真的有东西可透"的场景准备的；卡片背后只有页面底色，
    // 透出来等于把页面底色混进卡片，颜色会发灰。不模糊就当作不透明纸卡。
    //
    // ⚠️ **只在调用方没指定颜色时才改写透明度**。像错误卡片那种
    // `color: danger.withValues(alpha: 0.08)` 是在说"淡淡的红底"，
    // 这里再把它抬到 0.97 就会变成一整块实心红 —— 用户看到的就是
    // "报错卡片怎么全红了"。
    final Color base = color ?? g.fill;
    final double fillAlpha =
        fillOpacity ??
        ((blur <= 0 && color == null)
            ? (s.isDark ? 0.94 : 0.97)
            : alpha);
    final Color fill = base.withValues(alpha: fillAlpha);
    // ---- 描边 = iOS 的发丝线，不是玻璃高光 ----
    //
    // 之前亮色下用 72% 的白边去"勾高光"，那在米黄底上还能读出玻璃感，
    // 在纯中性灰底上就变成一圈**发亮的框** —— 每个卡片、每个按钮都镶
    // 一道白边，整屏的噪音有相当一部分来自这里。
    //
    // iOS 的做法正好相反：边界是一条**比底色深一点点**的线
    // （`separator` / `systemGray5`），它只负责"分开"，不负责"发亮"。
    final Color edge = borderColor ?? s.border;

    // ---- 投影只留给真的浮起来的东西 ----
    //
    // 卡片和控件坐在纯色底上：它们靠"比底亮一档 + 一条发丝线"就已经
    // 分层了，再加投影等于每张卡都在喊"看我"。iOS 的列表页里
    // 一张卡片是没有投影的。
    final List<BoxShadow>? shadows = !shadow || role != GlassRole.floating
        ? null
        : <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: s.isDark ? 0.55 : 0.12),
              blurRadius: 32,
              spreadRadius: -6,
              offset: const Offset(0, 12),
            ),
          ];

    return Container(
      decoration: BoxDecoration(borderRadius: br, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: br,
        child: blur <= 0
            // ---- 不模糊的档位：直接画 ----
            //
            // `BackdropFilter` 是这条界面里最贵的一笔：它要求 GPU 先把这个
            // 矩形背后的整层合成出来、做一次高斯模糊、再贴回去。一个列表里
            // 二十张卡片就是二十次 —— 滚动时每帧都要重做，表现就是掉帧、
            // 发热、启动后头几秒尤其卡。
            //
            // 而卡片/按钮坐在**纯色页面底**上：模糊出来的结果和底色没有区别，
            // 也就是说这些模糊**根本没被看见**，只是花了钱。所以只有真的
            // 有内容会从背后穿过的档位（浮层、顶栏、输入栏）才开模糊，
            // 其余档位走这条分支。
            ? Container(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: br,
                  border: Border.all(color: edge, width: 1),
                ),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: g.onFill),
                  child: Padding(padding: padding, child: child),
                ),
              )
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: Container(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: br,
                    border: Border.all(color: edge, width: 1),
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: g.onFill),
                    child: Padding(padding: padding, child: child),
                  ),
                ),
              ),
      ),
    );
  }
}

/// 玻璃容器的实现核心。所有玻璃组件都走它，保证层次完全一致 ——
/// 否则迟早出现「按钮边框比卡片亮一点」这种细碎的不一致。
class _GlassBox extends StatelessWidget {
  const _GlassBox({
    required this.child,
    required this.radius,
    required this.role,
    this.padding = EdgeInsets.zero,
    this.tint,
    this.borderColor,
  });

  final Widget child;
  final double radius;
  final GlassRole role;
  final EdgeInsetsGeometry padding;
  final Color? tint;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
  /// 卡片/按钮默认**不做背景模糊**，只有 [GlassRole.floating] 才模糊。
  ///
  /// ## 这不是为了省电而牺牲观感
  ///
  /// `SurfaceCard` 全项目 82 处，绝大多数坐在**纯色页面底**上 ——
  /// 背后没有任何内容可以糊，模糊结果和底色完全一样，但每张卡都要
  /// 走一次 `saveLayer` + 高斯滤波，滚动时每帧重算。这是"整个 app 发涩"
  /// 的最大一笔开销，而且**肉眼看不见**。
  ///
  /// 真正有内容从背后穿过的三处 —— 输入框、顶栏按钮、弹出的浮层 ——
  /// 全部保留真模糊（输入框 / 顶栏 30~32，浮层 24）。所以视觉上该糊的地方
  /// 一处没少。
  return BlurSurface(
      radius: radius,
      role: role,
      color: tint,
      borderColor: borderColor,
      padding: padding,
      blur: role == GlassRole.floating ? 24 : 0,
      child: child,
    );
  }
}

// ============================================================ 玻璃栏

/// 顶部 / 底部栏的玻璃。
///
/// 这是整个 app 里**真正会模糊内容**的地方 —— 消息从下面滚过时，
/// 顶部导航栏和底部输入栏会透出模糊。卡片在纯色背景上则靠厚度感区分。
class GlassBar extends StatelessWidget {
  const GlassBar({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.blur = 24,
    this.hairlineTop = false,
    this.hairlineBottom = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double blur;

  /// 在栏的顶部画一条发丝线（底栏用）
  final bool hairlineTop;

  /// 在栏的底部画一条发丝线（顶栏用）
  final bool hairlineBottom;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    const double w = 0.7;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: s.barBackground,
            border: Border(
              top: hairlineTop
                  ? BorderSide(color: s.border, width: w)
                  : BorderSide.none,
              bottom: hairlineBottom
                  ? BorderSide(color: s.border, width: w)
                  : BorderSide.none,
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

// ============================================================ 玻璃卡片

/// 玻璃卡片。页面底色上的主要容器。
///
/// iOS 分组列表的卡片圆角是 10，独立卡片稍大。默认取 [AppRadius.card]（16）——
/// 之前是 30，那是 M3 那种"大圆角夸张化"的量级，iOS 上几乎看不到这么圆的卡片。
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin,
    this.radius = AppRadius.card,
    this.color,
    this.borderColor,
    this.onTap,
    this.role = GlassRole.card,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;

  /// 这块卡片在层次里属于哪一档。
  ///
  /// 默认 `card`（页面上的内容块）。飘在内容**之上**的东西 ——
  /// 弹出的小面板、浮层菜单 —— 传 `floating`：它要更厚的玻璃、
  /// 更重的投影，才不会看起来"贴在页面上"。
  final GlassRole role;

  @override
  Widget build(BuildContext context) {
    final Widget box = _GlassBox(
      radius: radius,
      role: role,
      tint: color,
      borderColor: borderColor,
      padding: padding,
      child: child,
    );

    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: onTap == null ? box : Pressable(onTap: onTap, child: box),
    );
  }
}

// ============================================================ 玻璃按钮

/// 带按压反馈的玻璃胶囊按钮。
///
/// 按下时会轻微缩小并压暗 —— 这点反馈在纯色背景上尤其重要：
/// 没有它，玻璃按钮"按下去没反应"，手感很死。
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.accent = false,
    this.danger = false,
    this.expand = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
    this.fontSize = 14.5,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool accent;
  final bool danger;
  final bool expand;
  final EdgeInsetsGeometry padding;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool enabled = onTap != null;

    // ---- 小卡片式按钮 ----
    //
    // 底色 `surface`（白卡），配一圈发丝边 —— 它读起来是一张
    // "能按的小卡片"，而不是一块塑料。
    // 主操作仍用实心系统蓝，危险操作用红色弱填充。
    final Color bg = accent
        ? AppColors.accent
        : danger
        ? AppColors.danger.withValues(alpha: 0.14)
        : s.surface;
    final Color fg = accent
        ? AppColors.onAccent
        : danger
        ? AppColors.danger
        : s.text;
    final Color edge = accent
        ? Colors.transparent
        : danger
        ? AppColors.danger.withValues(alpha: 0.35)
        : s.border;

    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Pressable(
        onTap: enabled ? onTap : null,
        child: Container(
          width: expand ? double.infinity : null,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.field),
            border: Border.all(color: edge, width: 0.9),
          ),
          padding: padding,
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: fontSize + 3, color: fg),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppFonts.body(
                    size: fontSize,
                    weight: FontWeight.w600,
                    color: fg,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 圆形玻璃图标按钮（液态玻璃）
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 19,
    this.tooltip,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool disabled = onTap == null;

    // 注意 `Icon` **显式给了 color 和 size**：
    // 包的按钮默认从 `IconTheme` 取颜色（CupertinoColors.label）和尺寸，
    // 而这里的 color 承载了语义（危险操作是红的、禁用是灰的），
    // 必须由我们说了算，不能被主题盖掉。
    //
    // iOS 圆形图标钮：半透明底 + 一条发丝线。
    // 圆形是因为图标按钮没有文字，圆在头部/工具栏里更整齐。
    Widget button = SizedBox(
      width: size,
      height: size,
      child: Pressable(
        onTap: disabled ? null : onTap,
        child: BlurSurface(
          radius: AppRadius.pill,
          role: GlassRole.control,
          blur: 16,
          color: s.surface,
          child: Center(
            child: Icon(icon, size: iconSize, color: color ?? s.text),
          ),
        ),
      ),
    );

    if (disabled) {
      button = Opacity(opacity: 0.4, child: button);
    }

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 按压反馈：缩小 + 压暗。
///
/// **为什么公开：** 这个应用关掉了 Material 的水波纹（见 `AppTheme` 的
/// `splashFactory`），因为水波纹是 Material 最强的视觉签名之一。
/// 代价是任何"自己包一层 GestureDetector"的地方都**完全没有按下反馈**，
/// 手感是死的。所以凡是需要可点区域、又不想引入 Material 组件的地方，
/// 都应该用这个包一层 —— 比如对话页顶部那个「点开历史记录」的标题。
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null) return widget.child;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: _down ? 0.82 : 1.0,
          duration: const Duration(milliseconds: 90),
          child: widget.child,
        ),
      ),
    );
  }
}

// ============================================================ 小标签

/// 玻璃小标签（工具名、状态、风险等级）
class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.background,
    this.dense = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final Color? background;
  final bool dense;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    // 传了 color（风险等级、状态标签）时，底色必须是**该颜色的低透明度版本**。
    // 之前一律用 secondaryContainer，会出现「绿色标签配紫色底」这种错配 ——
    // 语义色和容器色打架，看起来就是"按钮有问题"。
    //
    // 没传 color 时用 iOS 的中性灰填充（而不是 M3 的 secondaryContainer，
    // 那是个由种子色推导的色块，一眼就是 Material）。
    //
    // 用局部变量是因为：实例字段不会参与类型提升，`color.withValues` 会被
    // 判为"可能为 null"。局部变量可以提升。
    final Color? tintColor = color;
    final Color fg = tintColor ?? AppColors.accent;
    final Color bgFill =
        background ??
        (tintColor != null
            ? tintColor.withValues(alpha: s.isDark ? 0.26 : 0.15)
            : s.codeBg);

    final Widget chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3.5 : 5,
      ),
      decoration: ShapeDecoration(color: bgFill, shape: const StadiumBorder()),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 11 : 12.5, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: AppFonts.body(
              size: dense ? 11 : 12,
              weight: FontWeight.w600,
              color: fg,
              height: 1.2,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: chip,
    );
  }
}

/// 状态小圆点。用颜色表达状态，含义靠 tooltip / 点击提示补充。
class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.size = 9,
    this.glow = false,
    this.onTap,
    this.tooltip,
  });

  final Color color;
  final double size;
  final bool glow;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final Widget dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow
            ? <BoxShadow>[
                BoxShadow(
                  color: color.withValues(alpha: 0.55),
                  blurRadius: 7,
                  spreadRadius: 1.2,
                ),
              ]
            : null,
      ),
    );

    // 视觉上只有一个小点，但触摸区要够大，否则点不中
    Widget tappable = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: Center(child: dot),
      ),
    );

    if (tooltip != null) {
      tappable = Tooltip(message: tooltip!, child: tappable);
    }
    return tappable;
  }
}
