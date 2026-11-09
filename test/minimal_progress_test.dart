// 「极简过程」：消息里只留结论，过程挂在**用户气泡下面**的一行字上。
//
// 要点：
//  · 极简模式下**消息气泡里**不画工具行 / 思考卡片 / 文件卡片；
//  · 过程那一行没有卡片、没有背景，位置在用户气泡下边、AI 正文上边；
//  · 点开才是本轮的全部工具 + 文件修改，且高度有上限；
//  · 关掉极简后，工具行照常回到消息里（对照组）。
//
// 坏了会怎样：要么过程又散落在消息里（不极简），要么那一行跑到输入框上面
// 挡住正文，或者点不开（用户看不到它到底改了什么）。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/plugins/plugin.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/theme/glass.dart';
import 'package:dsh_agent/ui/chat_page.dart';
import 'package:dsh_agent/ui/tool_steps.dart';
import 'package:dsh_agent/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

ToolInvocation _tool(
  InvocationStatus status, {
  Map<String, dynamic> args = const <String, dynamic>{'query': '今天的汇率'},
}) => ToolInvocation(
  id: 't1',
  name: 'web',
  argumentsJson: '{"query":"今天的汇率"}',
  args: args,
  risk: RiskAssessment.safe,
  status: status,
  output: '结果',
);

Widget _host(ChatMessage message, {required bool minimal}) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    body: MessageView(message: message, minimalProgress: minimal),
  ),
);

void main() {
  testWidgets('真实调工具的那一刻：消息里不再画过程', (WidgetTester tester) async {
    // **这就是线上真实状态**：`AgentRunner.run` 拿到模型回复就把
    // pending 置回 false，之后才开始跑工具。上一版测试用的是
    // `pending: true + running`（生产里不存在的组合），所以它绿着、
    // 线上却什么都不显示 —— 这条用例专门钉住那个坑。
    final ChatMessage m = ChatMessage(
      id: 'a1',
      role: Role.assistant,
      pending: false,
      tools: <ToolInvocation>[_tool(InvocationStatus.running)],
    );

    await tester.pumpWidget(_host(m, minimal: true));
    await tester.pump();

    // 过程已经挪到 ChatPage 的「过程」折叠条；消息气泡里什么都不留。
    expect(find.textContaining('正在使用'), findsNothing);
    expect(find.byType(ToolStepGroup), findsNothing);
    expect(find.textContaining('已思考'), findsNothing);
  });

  testWidgets('等模型出下一句：消息里不画加载行', (WidgetTester tester) async {
    final ChatMessage m = ChatMessage(
      id: 'a2',
      role: Role.assistant,
      pending: true,
      tools: <ToolInvocation>[_tool(InvocationStatus.success)],
    );

    await tester.pumpWidget(_host(m, minimal: true));
    await tester.pump();

    expect(find.text('加载中…'), findsNothing);
  });

  testWidgets('跑完之后：过程仍在 ChatPage 折叠条里，消息只留结论', (WidgetTester tester) async {
    final ChatMessage m = ChatMessage(
      id: 'a3',
      role: Role.assistant,
      content: '结论在这里',
      pending: false,
      tools: <ToolInvocation>[_tool(InvocationStatus.success)],
    );

    await tester.pumpWidget(_host(m, minimal: true));
    await tester.pump();

    expect(find.text('加载中…'), findsNothing);
    expect(find.textContaining('正在使用'), findsNothing);
    expect(find.byType(ToolStepGroup), findsNothing);
    expect(find.text('结论在这里'), findsOneWidget, reason: '过程被拿掉了，结论必须还在');
  });

  group('ChatPage 的过程行', () {
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
      settings.minimalProgress = true;
      tmp = await Directory.systemTemp.createTemp('dsh_minimal');
      conversations = ConversationStore(File('${tmp.path}/conv.json'));
      conversations.createNew();
      plugins = PluginStore(File('${tmp.path}/plugins.json'));
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

    testWidgets('气泡下面一句、点开是工具历史 + 文件修改', (WidgetTester tester) async {
      final Conversation conv = conversations.current!;
      conv.messages.add(
        ChatMessage(id: 'u1', role: Role.user, content: '把这份 PPT 改一下'),
      );
      conv.messages.add(
        ChatMessage(
          id: 'a1',
          role: Role.assistant,
          content: '改好了：/sdcard/Download/方案.pptx',
          tools: <ToolInvocation>[_tool(InvocationStatus.success)],
        ),
      );
      await pumpChat(tester);

      final Finder process = find.textContaining('过程 · 1 步');
      expect(process, findsOneWidget);
      expect(find.byType(ToolStepGroup), findsNothing, reason: '折叠时不该露出工具组');
      expect(
        find.ancestor(of: process, matching: find.byType(SurfaceCard)),
        findsNothing,
        reason: '过程那一行不能有卡片背景',
      );

      // 位置：用户气泡下边、AI 正文上边，而不是输入框上方。
      final double userY = tester.getBottomLeft(find.text('把这份 PPT 改一下')).dy;
      final double processY = tester.getTopLeft(process).dy;
      final double aiY = tester.getTopLeft(find.textContaining('改好了')).dy;
      expect(processY, greaterThan(userY - 2));
      expect(processY, lessThan(aiY));

      await tester.tap(process);
      await tester.pumpAndSettle();

      expect(find.byType(ToolStepGroup), findsOneWidget);
      expect(find.textContaining('方案.pptx'), findsWidgets);
      expect(
        find.textContaining('本次涉及的文件'),
        findsNothing,
        reason: '极简过程的文件列表也走 plain：只有文件行，不再套一张卡片',
      );
    });
  });

  testWidgets('关掉极简：工具组照常出现（对照组）', (WidgetTester tester) async {
    final ChatMessage m = ChatMessage(
      id: 'a4',
      role: Role.assistant,
      content: '结论',
      pending: false,
      tools: <ToolInvocation>[_tool(InvocationStatus.success)],
    );

    await tester.pumpWidget(_host(m, minimal: false));
    await tester.pump();

    expect(find.byType(ToolStepGroup), findsOneWidget);
  });
}
