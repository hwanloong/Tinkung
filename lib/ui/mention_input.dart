import 'package:flutter/material.dart';

import '../core/mentions.dart';
import '../theme/app_theme.dart';

/// 输入框控制器：把 `@tool:xxx` / `@plugin:xxx` 这些引用**染色**。
///
/// ## 为什么必须染色，而不是只靠面板
///
/// 引用决定了这一轮会注入什么材料，它是**语义的一部分**，和普通文字不一样。
/// 不标识的话有两个具体问题：
///
///  1. 用户看不出自己引用的到底生效没有。`@tool:pdf`（打错一个字母）
///     和 `@tool:pdf_merge` 在对错上完全一样 —— 都是同色文字，
///     而前者会静默地什么都不注入；
///  2. 一条消息里可以放好几个引用。全是一样颜色时，
///     很难一眼数清楚"我加了几个"。
///
/// ## 为什么用 buildTextSpan 而不是富文本输入框
///
/// Flutter 没有"部分文字有样式的 TextField"。标准做法就是覆写
/// `buildTextSpan` —— 它只影响**绘制**，光标、选择、输入法全都照旧。
/// 自己拼富文本控件等于把 IME 组合、选区拖动重新实现一遍，
/// 那是拿稳定性换外观。
class MentionHighlightController extends TextEditingController {
  MentionHighlightController({super.text});

  /// 变量库占位标记：首尾各一个 NUL，中间是变量名。
  ///
  /// 这个正则必须和 `chat_page.dart` 里 `varChipToken()` 生成的形态一致。
  static final RegExp _varChipPattern = RegExp('\u0000([^\u0000]+)\u0000');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String src = text;
    if (src.isEmpty) return TextSpan(text: '', style: style);

    final TextStyle base = style ?? const TextStyle();
    final List<RegExpMatch> mentions = MentionParser.pattern
        .allMatches(src)
        .toList();
    // 变量库占位标记：`\u0000名字\u0000`。整段替换成一句友好文案，
    // 让输入框里显示的是"已存入变量库"，而不是一串真实存在的文本。
    final List<RegExpMatch> varChips = _varChipPattern.allMatches(src).toList();
    final TextRange composing = value.composing;
    final bool hasComposing =
        withComposing && composing.isValid && !composing.isCollapsed;

    if (mentions.isEmpty && varChips.isEmpty && !hasComposing) {
      return TextSpan(text: src, style: base);
    }

    // ---- 底色不能只靠强调色 ----
    //
    // 这个应用的**默认主题是灰白**（强调色 ≈ #5F5F5F）。用
    // `accent.withAlpha(0.12)` 当底色 + accent 当文字色，在浅色主题下
    // 就是"浅灰底 + 中灰字" —— 技术上画上去了，肉眼完全看不出来
    // （实测渲染出来就是这样，golden 图里根本分不出哪段被引用）。
    //
    // 所以底色改用 `chipBg`（surfaceContainerHigh）：它和页面底色天然有对比，
    // 无论强调色是什么颜色都能看出"这是一块"。
    final AppSurface s = AppSurface.of(context);

    // ---- 组词区间不能整段放弃 ----
    //
    // 早期版本在 `withComposing` 为真时**整段**退回默认样式，结果是：
    // 组词期间（很多输入法英文输入时也会挂一个组词区）引用完全不染色。
    // 实测就是从这里发现的 —— 补全面板正常，但引用一个字都没变色。
    //
    // 正确做法是**按区间分别决定**：组词区加下划线（这是 Flutter 自己
    // 表达"这段还没上屏"的方式），引用区加底色。两者可以并存。
    final Set<int> cuts = <int>{0, src.length};
    for (final RegExpMatch m in mentions) {
      cuts.add(m.start);
      cuts.add(m.end);
    }
    for (final RegExpMatch m in varChips) {
      cuts.add(m.start);
      cuts.add(m.end);
    }
    if (hasComposing) {
      cuts.add(composing.start.clamp(0, src.length));
      cuts.add(composing.end.clamp(0, src.length));
    }
    final List<int> bounds = cuts.toList()..sort();

    final List<InlineSpan> spans = <InlineSpan>[];
    for (int i = 0; i < bounds.length - 1; i++) {
      final int a = bounds[i];
      final int b = bounds[i + 1];
      if (b <= a) continue;

      // ---- 变量库占位：整段换文案 ----
      final RegExpMatch? chip = varChips
          .where((RegExpMatch m) => m.start <= a && b <= m.end)
          .firstOrNull;
      if (chip != null) {
        // `m` 是 `\u0000名字\u0000`（首尾各一个 NUL），取中间那段就是名字。
        final String name = chip.group(1) ?? '';
        spans.add(
          TextSpan(
            text: '▣ 已存入变量库 · $name',
            style: base.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w600,
              backgroundColor: s.chipBg,
            ),
          ),
        );
        continue;
      }

      final bool inMention = mentions.any(
        (RegExpMatch m) => m.start <= a && b <= m.end,
      );
      final bool inComposing =
          hasComposing && composing.start <= a && b <= composing.end;

      TextStyle st = base;
      if (inMention) {
        st = st.copyWith(
          color: s.text,
          fontWeight: FontWeight.w600,
          backgroundColor: s.chipBg,
        );
      }
      if (inComposing) {
        // 组词区加下划线，和 Flutter 默认的表达方式一致
        st = st.copyWith(decoration: TextDecoration.underline);
      }

      spans.add(TextSpan(text: src.substring(a, b), style: st));
    }

    return TextSpan(style: base, children: spans);
  }
}
