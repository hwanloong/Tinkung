// 「描述改进」开着时，**连点发送不能发出去两条**。
//
// 这是用户报过的一个真实 bug，成因是一段等待：
// 改写要一两秒，而原来是"先改写、拿到结果才把消息加进会话"，于是那段时间里
//   · 会话里什么都没有（看起来没发出去）；
//   · `_busy` 还是 false —— 发送键**还是发送键**；
//   · 输入框里的字也还在。
// 三条加在一起：用户再点一次，就有第二个 `_send()` 同时在跑。他点几次，
// 这条消息就发几遍 —— 而每一条都会真的打一次 API。
//
// 现在的顺序是"消息先显示（原文）→ 再做改进"，并且在那段等待开始之前
// 就把 `_busy` 置起来。这个文件钉住的就是那个顺序。
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Settings settings;
  late ConversationStore conversations;
  late PluginStore plugins;
  late Directory tmp;

  setUp(() async {
    // 不配真实地址也无所谓：测试环境里 HttpClient 是假的，
    // 请求会立刻拿到 400 —— 于是 `PromptImprover.improve` 直接返回 null，
    // 走"改写失败就用原话"那条正常路径，不会真的联网。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'apiKey': 'sk-demo',
      'model': 'deepseek-flash',
    });
    settings = await Settings.load();
    tmp = await Directory.systemTemp.createTemp('dsh_send');
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

  int userMessageCount() => conversations.current!.messages
      .where((ChatMessage m) => m.role == Role.user)
      .length;

  testWidgets('改进期间连点发送，只会发一条', (WidgetTester tester) async {
    settings.improvePrompt = true;
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), '帮我看看那个文件');
    await tester.pump();

    final Finder send = find.byTooltip('发送');
    expect(send, findsOneWidget);

    // 连点两次、中间**不 pump**：两下都打在同一帧那颗按钮上 ——
    // 这正是"按多几次"的样子（界面还没来得及重建）。
    await tester.tap(send);
    await tester.tap(send);
    await tester.pump();

    expect(userMessageCount(), 1, reason: '第二次点击必须是空操作。多出来的每一条都会真的打一次 API');

    // 注意这里**不断言**"发送键变成了停止键"。测试环境里 HttpClient 是假的、
    // 立刻返回 400，于是改写瞬间就结束、agent 也瞬间跑完一轮 ——
    // "正在忙"那个中间态在这一层根本抓不到。抓得到的、也是用户真正在意的，
    // 是上面那条：**消息只有一条**。
    //
    // （真实设备上那个中间态靠的是两个同步动作：`_busy = true` 和
    // `_input.clear()`，两个都发生在第一个 await 之前 —— 见 _send。）

    // 收尾：把树拆掉，免得 agent 那边的异步回调在测试结束后还在动。
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('原文立刻显示，不等改写结果', (WidgetTester tester) async {
    settings.improvePrompt = true;
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), '把那张图的背景换掉');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    // 只推进一帧：这时改写**还没回来**（甚至可能还在等网络）。
    await tester.pump();

    expect(
      find.text('把那张图的背景换掉'),
      findsWidgets,
      reason:
          '原话要马上进会话。卡在输入框里用户会以为没发出去，'
          '然后接着按发送 —— 那正是发重的原因',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
