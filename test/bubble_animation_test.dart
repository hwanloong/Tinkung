// 发送消息时的气泡入场动画。
//
// 关键不是“有动画”，而是**只播一次**：历史消息、滚动重建都不能再动。
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('刚发出的用户气泡：播放一次入场动画并回调', (WidgetTester tester) async {
    int done = 0;
    final ChatMessage m = ChatMessage(
      id: 'u1',
      role: Role.user,
      content: '刚发出的一句话',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: MessageView(
            message: m,
            animateIn: true,
            onBubbleAnimated: () => done++,
          ),
        ),
      ),
    );

    expect(find.text('刚发出的一句话'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400));
    expect(done, 1);
  });

  testWidgets('历史消息不播动画', (WidgetTester tester) async {
    int done = 0;
    final ChatMessage m = ChatMessage(
      id: 'u2',
      role: Role.user,
      content: '历史消息',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: MessageView(
            message: m,
            animateIn: false,
            onBubbleAnimated: () => done++,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(done, 0);
  });
}
