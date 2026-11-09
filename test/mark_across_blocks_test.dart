// 「标记只盖一处」：标一个「的」，不能把每个段落里的「的」都点亮。
//
// ## 这是用户报过的 bug（第二次）
//
// 标记的定位方式是"按原文查找 + 记这是第几次出现"（`occurrence`），
// 因为流式输出会让字符偏移量当场失效。
//
// 但 `occurrence` 是在**整条消息**的原文上算的（创建标记时），
// 而渲染器是**按块**匹配的（一个段落调一次 `_applyMarks`）——
// 两个语境对不上。于是一条 `occurrence = 0` 的标记，会在**每个含有这段
// 文字的段落里各点亮一处**：标一个「的」，三个段落里的第一个「的」全亮了。
//
// 现在渲染时记着"这条标记已经用掉了"，所以一条标记整条消息只盖一处。
// 这个文件就是钉住这件事。
import 'package:dsh_agent/core/text_marks.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三个段落，每段都含一个「的」。
const String kThreeParagraphs = '第一段里有 的 字。\n\n第二段里也有 的 字。\n\n第三段里还是 的 字。';

/// 扫一遍渲染结果：一共亮了多少个字、亮在哪些段落里。
({int chars, List<String> blocks}) scan(WidgetTester tester) {
  int chars = 0;
  final List<String> blocks = <String>[];
  for (final RichText rt in tester.widgetList<RichText>(
    find.byType(RichText),
  )) {
    int n = 0;
    rt.text.visitChildren((InlineSpan s) {
      if (s is TextSpan && s.style?.backgroundColor != null) {
        n += (s.text ?? '').length;
      }
      return true;
    });
    if (n > 0) {
      chars += n;
      blocks.add(rt.text.toPlainText());
    }
  }
  return (chars: chars, blocks: blocks);
}

Future<void> pumpMarkdown(
  WidgetTester tester, {
  required String text,
  required List<TextMark> marks,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: MarkdownView(text: text, marks: marks),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('plainTextOf：计数基准必须是"渲染后的正文"', () {
    test('链接地址里的字不参与计数（"标记飘到别的相同字上"就是这么来的）', () {
      const String src = '看这个 [文档](https://x.com/的) 然后 的 这个字';
      final String plain = MarkdownView.plainTextOf(src, AppSurface.light);

      expect('的'.allMatches(src).length, 2, reason: '原文里「的」出现两次：链接地址里一次、正文里一次');
      expect('的'.allMatches(plain).length, 1, reason: '渲染后只剩正文那一次 —— URL 不是正文');
      expect(plain.contains('x.com'), isFalse);
    });

    test('加粗与列表符号被去掉', () {
      final String plain = MarkdownView.plainTextOf(
        '**加粗**的字\n\n- 列表项一\n- 列表项二',
        AppSurface.light,
      );
      expect(plain, contains('加粗的字'));
      expect(plain, isNot(contains('**')));
      expect(plain, contains('列表项一'));
    });

    test('代码块不算进计数（渲染器不会在它上面盖标记）', () {
      final String plain = MarkdownView.plainTextOf(
        '正文 的 字\n\n```\n代码里的 的 不算\n```',
        AppSurface.light,
      );
      expect('的'.allMatches(plain).length, 1, reason: '代码块里的「的」不该参与标记的次序');
    });
  });

  testWidgets('一条标记只盖一处，不会在每个段落里各亮一次', (WidgetTester tester) async {
    await pumpMarkdown(
      tester,
      text: kThreeParagraphs,
      marks: <TextMark>[
        TextMark(
          text: '的',
          kind: MarkKind.mark,
          occurrence: 0,
          color: MarkColor.yellow,
        ),
      ],
    );

    final r = scan(tester);
    expect(r.chars, 1, reason: '标一个「的」却亮了 ${r.chars} 个字 —— 这就是"其他相同的文字也被标上"');
    expect(r.blocks.length, 1, reason: '亮在了 ${r.blocks.length} 个段落里');
    expect(r.blocks.first, contains('第一段'));
  });

  testWidgets('标记落在"全文第 N 次出现"的那一处', (WidgetTester tester) async {
    // 第二段的「的」是全文第 2 次出现 → occurrence: 1
    await pumpMarkdown(
      tester,
      text: kThreeParagraphs,
      marks: <TextMark>[
        TextMark(
          text: '的',
          kind: MarkKind.mark,
          occurrence: 1,
          color: MarkColor.yellow,
        ),
      ],
    );

    final r = scan(tester);
    expect(r.chars, 1);
    expect(
      r.blocks.single,
      contains('第二段'),
      reason: '次序算对了就该落在第二段；落在第一段说明"次数"和"块"又对不上',
    );
  });

  testWidgets('两条标记各盖一处，互不干扰', (WidgetTester tester) async {
    await pumpMarkdown(
      tester,
      text: kThreeParagraphs,
      marks: <TextMark>[
        TextMark(
          text: '的',
          kind: MarkKind.mark,
          occurrence: 0,
          color: MarkColor.yellow,
        ),
        TextMark(
          text: '的',
          kind: MarkKind.mark,
          occurrence: 2,
          color: MarkColor.green,
        ),
      ],
    );

    final r = scan(tester);
    expect(r.chars, 2, reason: '两条标记应该正好盖两个字');
    expect(r.blocks.length, 2);
  });
}
