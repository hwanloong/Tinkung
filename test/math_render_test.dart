// 公式渲染的回归测试。
//
// 这里覆盖的都是"模型真的会写、但以前渲染不出来"的写法：
//
//   * 一句话中间的 `$$...$$`（以前会被拆成两个 `$...$`，留下两个美元符号）
//   * 一句话中间的 `\[...\]`
//   * 不带 `$$` 的裸 `\begin{align}...\end{align}`
//   * `\tag` / `&` 对齐、`\ce`、`\abs` 这些包不认识的宏
//
// 断言方式是"有没有真的生成 `Math` 组件" + "正文里还有没有残留的
// `$` / `\begin` 原文"。前者保证渲染，后者保证不会把源码糊到屏幕上。
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _render(WidgetTester tester, String text) async {
  tester.view.physicalSize = const Size(1170, 2400);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: AppColors.lightBg,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: MarkdownView(text: text, baseSize: 15),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// 屏幕上所有文字（含 RichText 里的 span）。
String _visibleText(WidgetTester tester) {
  final StringBuffer buf = StringBuffer();
  for (final Text t in tester.widgetList<Text>(find.byType(Text))) {
    buf.write(t.data ?? '');
    buf.write(t.textSpan?.toPlainText() ?? '');
  }
  return buf.toString();
}

void main() {
  testWidgets('一句话中间的 display 公式不会留下美元符号', (WidgetTester tester) async {
    await _render(tester, r'能量公式 $$E = mc^2$$ 是最有名的。');
    expect(find.byType(Math), findsOneWidget);
    expect(_visibleText(tester), isNot(contains(r'$')));
    expect(_visibleText(tester), contains('是最有名的'));
  });

  testWidgets('一句话中间的方括号公式也能渲染', (WidgetTester tester) async {
    await _render(tester, r'其中 \[x = \frac{-b}{2a}\] 是根。');
    expect(find.byType(Math), findsOneWidget);
    expect(_visibleText(tester), isNot(contains(r'\[')));
    expect(_visibleText(tester), contains('是根'));
  });

  testWidgets('裸的 align 环境按块级公式渲染', (WidgetTester tester) async {
    await _render(
      tester,
      '解：\n'
      r'\begin{align}'
      '\n'
      r'a &= b + c \\'
      '\n'
      r'd &= e'
      '\n'
      r'\end{align}'
      '\n'
      '所以成立。',
    );
    expect(find.byType(Math), findsOneWidget);
    expect(_visibleText(tester), isNot(contains(r'\begin')));
    expect(_visibleText(tester), contains('所以成立'));
  });

  testWidgets('公式后面同一行的说明文字不会被吞掉', (WidgetTester tester) async {
    await _render(tester, r'$$E=mc^2$$ 其中 E 是能量。');
    expect(find.byType(Math), findsOneWidget);
    expect(_visibleText(tester), contains('其中 E 是能量'));
  });

  testWidgets('tag / ce / abs / 顶层 & 都能渲染', (WidgetTester tester) async {
    await _render(
      tester,
      r'$$\tag{1} x=1$$'
      '\n\n'
      r'$$\ce{2H2 + O2 -> 2H2O}$$'
      '\n\n'
      r'$$\abs{x} \le 1$$'
      '\n\n'
      r'\begin{align}'
      '\n'
      r'f(x) &= x^2 \\'
      '\n'
      r'g(x) &= x+1'
      '\n'
      r'\end{align}',
    );
    expect(find.byType(Math), findsNWidgets(4));
    final String text = _visibleText(tester);
    expect(text, isNot(contains(r'\tag')));
    expect(text, isNot(contains(r'\ce')));
    expect(text, isNot(contains(r'\abs')));
    expect(text, isNot(contains(r'\begin')));
  });

  testWidgets('价格区间不会被当成公式', (WidgetTester tester) async {
    await _render(tester, r'价格 $5 到 $10，我都要。');
    expect(find.byType(Math), findsNothing);
    expect(_visibleText(tester), contains(r'$5 到 $10'));
  });

  testWidgets('普通行内公式仍然正常', (WidgetTester tester) async {
    await _render(tester, r'质能方程 $E = mc^2$ 很有名。');
    expect(find.byType(Math), findsOneWidget);
    expect(_visibleText(tester), contains('很有名'));
  });
}
