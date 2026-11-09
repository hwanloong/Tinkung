// 「可回忆的对话」页面：只读列表 + 空状态。
//
// 这页最容易出的问题是**没初始化时崩**（ChatArchive 是单例，测试/后台
// 场景可能没配）。这里钉住降级路径：没档案也要能打开、显示空提示。
import 'package:dsh_agent/core/chat_recall.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/chat_memory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('没有跨聊天档案时显示空提示，不崩溃', (WidgetTester tester) async {
    ChatArchive.resetForTest();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const ChatMemoryPage(currentId: 'current'),
      ),
    );
    await tester.pump();

    expect(find.text('跨聊天记忆'), findsOneWidget);
    expect(find.text('还没有其他对话'), findsOneWidget);
  });
}
