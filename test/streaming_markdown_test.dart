// 流式输出的两条硬规则：
//
//  · **卡片类块先不渲染**：代码块 / 表格 / 图片 / `card:` 富卡片在
//    `streaming` 期间都不能以"定稿卡片"的样子出现 —— 半截内容建出来的
//    表格列数、图片地址、WebView HTML 都可能是错的。
//  · **最后一块正文带扫光**：让"正在长出来的字"和上面已定稿的块区分开。
//
// 这两条都只依赖 `MarkdownView.streaming`，所以可以直接在 widget 层测，
// 不需要真的跑一次网络流。
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/inline_image.dart';
import 'package:dsh_agent/ui/markdown.dart';
import 'package:dsh_agent/ui/shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(
  String text, {
  required bool streaming,
  bool enableCards = false,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: MarkdownView(
          text: text,
          streaming: streaming,
          enableCards: enableCards,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('流式期间代码块只显示裸代码，不出现语言栏 / 复制按钮', (
    WidgetTester tester,
  ) async {
    const String text = '开头一段\n\n```dart\nvoid main() {}\n```\n\n后面一段';

    await tester.pumpWidget(_app(text, streaming: true));
    expect(
      find.text('dart'),
      findsNothing,
      reason: '语言标签是卡片元素，流式期间不该出现',
    );
    expect(
      find.byTooltip('复制代码'),
      findsNothing,
      reason: '复制按钮是卡片元素，流式期间不该出现',
    );
    expect(
      find.text('void main() {}'),
      findsOneWidget,
      reason: '代码本身仍然要显示，只是不套卡片',
    );
    expect(
      find.byType(ShimmerMask),
      findsOneWidget,
      reason: '最后一块正文（后面一段）应该带扫光',
    );

    await tester.pumpWidget(_app(text, streaming: false));
    expect(find.text('dart'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
    expect(
      find.byType(ShimmerMask),
      findsNothing,
      reason: '定稿后扫光必须停掉',
    );
  });

  testWidgets('流式期间表格不渲染，结束后才出现', (WidgetTester tester) async {
    const String text =
        '开头一段\n\n'
        '| 项目 | 值 |\n'
        '|------|-----|\n'
        '| level | 73 |\n\n'
        '结尾一段';

    await tester.pumpWidget(_app(text, streaming: true));
    expect(
      find.text('项目'),
      findsNothing,
      reason: '表格列数会随流式内容变化，先画出来必然错位',
    );
    expect(find.text('level'), findsNothing);

    await tester.pumpWidget(_app(text, streaming: false));
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('level'), findsOneWidget);
  });

  testWidgets('流式期间图片块不建控件', (WidgetTester tester) async {
    const String text =
        '开头一段\n\n'
        '![截图](https://example.com/a.png)\n\n'
        '结尾一段';

    await tester.pumpWidget(_app(text, streaming: true));
    expect(
      find.byType(InlineImage),
      findsNothing,
      reason: '半截 URL 可能还没输出完，流式期间先不建图片控件',
    );
  });

  testWidgets('流式期间 card: 富卡片完全不渲染', (WidgetTester tester) async {
    const String text =
        '开头一段\n\n'
        '```card:html\n'
        '<div>hi</div>\n'
        '```\n\n'
        '结尾一段';

    await tester.pumpWidget(_app(text, streaming: true));
    expect(
      find.text('<div>hi</div>'),
      findsNothing,
      reason: 'card: 在流式期间既不建卡片，也不降级成裸代码',
    );
  });
}
