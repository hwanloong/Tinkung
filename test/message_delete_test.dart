// 「删除消息」：长按气泡/正文 → 菜单里的「删除这条消息」→ 确认 → 从会话里消失。
//
// 这里同时钉住两件事：
//  · 菜单入口在用户气泡和 AI 正文上都有；
//  · 删除后真的从 ConversationStore 的消息列表里去掉，而不只是 UI 隐藏。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/plugins/plugin.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Settings settings;
  late ConversationStore conversations;
  late PluginStore plugins;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'apiKey': 'sk-demo',
      'model': 'deepseek-flash',
    });
    settings = await Settings.load();
    tmp = await Directory.systemTemp.createTemp('dsh_delete');
    conversations = ConversationStore(File('${tmp.path}/conv.json'));
    conversations.createNew();
    plugins = PluginStore(File('${tmp.path}/plugins.json'));
  });

  tearDown(() async {
    // Windows 上测试进程可能还握着日志文件句柄，删不掉不影响测试结论。
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: ChatPage(
            settings: settings,
            conversations: conversations,
            plugins: plugins,
            shizuku: ShizukuService(),
            workDir: tmp.path,
            notes: NoteStore(File('${tmp.path}/notes.json')),
            tasks: TaskStore(File('${tmp.path}/tasks.json')),
          ),
        ),
        brightnessResolver: Theme.maybeBrightnessOf,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('删除最新一段：用户气泡和 AI 回复一起消失', (WidgetTester tester) async {
    final Conversation conv = conversations.current!;
    conv.messages.add(ChatMessage(id: 'u1', role: Role.user, content: '帮我看一下'));
    conv.messages.add(
      ChatMessage(id: 'a1', role: Role.assistant, content: '这是要删除的 AI 回复'),
    );
    await pumpChat(tester);

    await tester.longPress(find.text('这是要删除的 AI 回复'));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除最新一段对话？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '删除这段'));
    await tester.pumpAndSettle();

    expect(find.text('帮我看一下'), findsNothing);
    expect(find.text('这是要删除的 AI 回复'), findsNothing);
    expect(conv.messages, isEmpty, reason: '用户气泡和 AI 回复要一起删掉');
  });

  testWidgets('删到空会话：恢复新对话的空白页', (WidgetTester tester) async {
    final Conversation conv = conversations.current!;
    conv.messages.add(
      ChatMessage(id: 'u2', role: Role.user, content: '这条用户消息要删掉'),
    );
    await pumpChat(tester);

    await tester.longPress(find.text('这条用户消息要删掉'));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, '删除这段'));
    await tester.pumpAndSettle();

    expect(find.text('这条用户消息要删掉'), findsNothing);
    expect(conv.messages, isEmpty);
    expect(find.text('直接说你要做什么'), findsOneWidget, reason: '空会话要回到新界面');
  });

  testWidgets('只能从最新一段删：点旧消息只提示，不弹确认', (WidgetTester tester) async {
    final Conversation conv = conversations.current!;
    conv.messages.add(ChatMessage(id: 'u1', role: Role.user, content: '第一段'));
    conv.messages.add(
      ChatMessage(id: 'a1', role: Role.assistant, content: '第一段的回答'),
    );
    conv.messages.add(ChatMessage(id: 'u2', role: Role.user, content: '第二段'));
    conv.messages.add(
      ChatMessage(id: 'a2', role: Role.assistant, content: '第二段的回答'),
    );
    await pumpChat(tester);

    await tester.longPress(find.text('第一段的回答'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pump();

    expect(find.text('只能从最新的一段开始删除'), findsOneWidget);
    expect(find.text('删除最新一段对话？'), findsNothing);
    expect(conv.messages, hasLength(4));
  });
}
