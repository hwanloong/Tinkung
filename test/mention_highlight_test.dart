// 输入框里 `@` 引用的**染色**。
//
// 这块只能验证"span 结构对不对"，验证不了"看起来好不好看" ——
// 但结构错的话有两个具体后果，都值得钉住：
//  1. 引用没染色 → 用户看不出自己引用的到底生效没有
//     （`@tool:pdf` 打错一个字母和正确的完全一样）；
//  2. 普通文字被误染色 → 一整句话变成高亮块，比不染还糟。
import 'package:dsh_agent/ui/mention_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 在真实 widget 树里拿 BuildContext（buildTextSpan 需要它）。
  Future<TextSpan> spanOf(WidgetTester tester, String text) async {
    final MentionHighlightController ctl = MentionHighlightController(
      text: text,
    );
    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext ctx) {
            span = ctl.buildTextSpan(
              context: ctx,
              style: const TextStyle(color: Colors.black),
              withComposing: false,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    ctl.dispose();
    return span;
  }

  testWidgets('引用被染色，普通文字保持原样', (WidgetTester tester) async {
    final TextSpan span = await spanOf(tester, '用 @tool:pdf_merge 合并这两个');

    final List<InlineSpan> children = span.children!;
    // 三段：普通文字 / 引用 / 普通文字
    expect(children.length, 3);
    expect((children[0] as TextSpan).text, '用 ');
    expect((children[0] as TextSpan).style?.color, Colors.black);

    final TextSpan mention = children[1] as TextSpan;
    expect(mention.text, '@tool:pdf_merge');
    // 底色必须和页面底色不同（默认主题下强调色是灰的，只靠色相不够）
    // 文字色要和正文不同，否则也看不出来
    expect(mention.style?.backgroundColor, isNotNull);
    expect(mention.style?.fontWeight, FontWeight.w600);

    expect((children[2] as TextSpan).text, ' 合并这两个');
  });

  testWidgets('多个引用各自独立染色', (WidgetTester tester) async {
    final TextSpan span = await spanOf(tester, '@tool:a 和 @plugin:b');
    final List<TextSpan> mentions = span.children!
        .whereType<TextSpan>()
        .where((TextSpan s) => s.text?.startsWith('@') ?? false)
        .toList();
    expect(mentions.length, 2);
    expect(mentions[0].text, '@tool:a');
    expect(mentions[1].text, '@plugin:b');
  });

  testWidgets('没有引用时不在文字上乱加底色', (WidgetTester tester) async {
    final TextSpan span = await spanOf(tester, '普通一句话');
    for (final TextSpan s
        in (span.children ?? <InlineSpan>[]).whereType<TextSpan>()) {
      expect(s.style?.backgroundColor, isNull);
    }
  });

  testWidgets('组词期间引用仍然染色，组词区加下划线', (WidgetTester tester) async {
    // 这条曾经被我写成"组词期间一律不染色"，那是错的：
    // 很多输入法在英文输入时也会挂一个组词区，于是引用完全不显色，
    // 用户看到的是"我刚引用的东西怎么没了"。实测就是这么发现的。
    // 正确行为是两者并存。
    final MentionHighlightController ctl = MentionHighlightController(
      text: '@tool:pdf',
    );
    ctl.value = const TextEditingValue(
      text: '@tool:pdf',
      selection: TextSelection.collapsed(offset: 9),
      // 模拟"整段还在组词"
      composing: TextRange(start: 0, end: 9),
    );
    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext ctx) {
            span = ctl.buildTextSpan(
              context: ctx,
              style: const TextStyle(color: Colors.black),
              withComposing: true,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    ctl.dispose();

    bool sawHighlight = false;
    bool sawUnderline = false;
    void walk(TextSpan s) {
      if (s.style?.backgroundColor != null) sawHighlight = true;
      if (s.style?.decoration == TextDecoration.underline) {
        sawUnderline = true;
      }
      for (final InlineSpan c in s.children ?? <InlineSpan>[]) {
        if (c is TextSpan) walk(c);
      }
    }

    walk(span);
    expect(sawHighlight, isTrue, reason: '组词期间引用也要染色');
    expect(sawUnderline, isTrue, reason: '组词区要有下划线提示还没上屏');
  });
}
