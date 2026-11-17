// 公式渲染的回归测试。
//
// 背景：用户报"数学公式显示不出来，比如 \frac 这些"。
// 根因不在解析器（`\frac` 本身能解析），而在**入口识别**：
//  · `$ \frac{a}{b} $`（`$` 两边带空格）被严格规则漏掉，原样显示；
//  · 单独成行的裸 `\frac{a}{b}`（没有 `$`）被当成普通段落。
// 这两类都是模型真实会写的。这组测试盯的就是"屏幕上不会露出反斜杠"。
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/markdown.dart';

Future<int> _mathCount(WidgetTester tester, String text) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 360,
            child: MarkdownView(text: text, baseSize: 16),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.widgetList(find.byType(Math)).length;
}

void main() {
  group('公式入口识别', () {
    testWidgets('各种定界符都能渲染成 Math', (WidgetTester tester) async {
      const Map<String, String> cases = <String, String>{
        r'$\frac{3}{4}$': '无空格行内',
        r'$ \frac{3}{4} $': '两边带空格',
        r'\( \frac{3}{4} \)': '反斜杠括号',
        r'$\displaystyle \frac{3}{4}$': '带 displaystyle',
        r'a $$\frac{3}{4}$$ b': '句中双美元',
        r'$\frac12$': '不带括号的 frac',
        r'$\frac {3} {4}$': '命令后带空格',
        r'$$ \frac{3}{4} $$': '整块公式',
        r'\frac{3}{4}': '裸 frac',
        r'\sqrt{x^2 + y^2} = r': '裸根号',
      };
      for (final MapEntry<String, String> e in cases.entries) {
        expect(
          await _mathCount(tester, e.key),
          1,
          reason: '${e.value}：${e.key}',
        );
      }
    });

    testWidgets('不是公式的东西不能被误判', (WidgetTester tester) async {
      const Map<String, String> cases = <String, String>{
        r'价格是 $5 到 $10 之间': '货币',
        r'C:\Users\foo\bar.txt': 'Windows 路径',
        r'这是一个 \frac 的说明': '中文正文里提到命令',
        r'https://example.com/a?x=1&y=2': '网址',
      };
      for (final MapEntry<String, String> e in cases.entries) {
        expect(
          await _mathCount(tester, e.key),
          0,
          reason: '${e.value}：${e.key}',
        );
      }
    });
  });
}
