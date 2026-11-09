// UI 预览渲染器。
//
// 目的：在没有真机/模拟器的情况下，把**真实的 Flutter 控件树**渲染成 PNG，
// 用于确认界面效果。它不是断言型测试，只是借 flutter_test 的渲染管线出图。
//
// 生成方式：
//   flutter test test/ui_preview_test.dart --update-goldens
// 产物在 test/goldens/ 下。
import 'dart:io';

import 'package:dsh_agent/core/folder_tool.dart';
import 'package:dsh_agent/core/learning.dart';
import 'package:dsh_agent/core/model_profile.dart';
import 'package:dsh_agent/knowledge/knowledge_store.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/rules.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/core/terminal_session.dart';
import 'package:dsh_agent/plugins/plugin.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/webview_loader.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/ui/chat_page.dart';
import 'package:dsh_agent/ui/greeting.dart';
import 'package:dsh_agent/ui/home_shell.dart';
import 'package:dsh_agent/ui/knowledge_page.dart';
import 'package:dsh_agent/ui/learning_page.dart';
import 'package:dsh_agent/ui/models_sheet.dart';
import 'package:dsh_agent/ui/rules_page.dart';
import 'package:dsh_agent/ui/teenspace_page.dart';
import 'package:dsh_agent/ui/whats_new_page.dart';
import 'package:dsh_agent/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_fonts.dart';

/// 字体加载统一走 `preview_fonts.dart`：两个预览测试共用一份，
/// 而且缺字体文件时会**跳过**而不是抛异常（字体不进仓库，见该文件注释）。
Future<void> _loadFonts() => loadPreviewFonts();

ToolInvocation _inv({
  required String id,
  required String name,
  required Map<String, dynamic> args,
  required RiskAssessment risk,
  required InvocationStatus status,
  String? output,
}) {
  return ToolInvocation(
    id: id,
    name: name,
    argumentsJson: '{}',
    args: args,
    risk: risk,
    status: status,
    output: output,
  );
}

Conversation _seed() {
  final Conversation c = Conversation(id: 'demo', title: '查电量并清缓存');
  // 时间必须**钉死**：不传 updatedAt 时它默认是 `DateTime.now()`，
  // 而抽屉每行会显示时间（今天给 HH:mm、更早给 MM-DD）——
  // 图里那句日期每天都会变，金图过一夜就红。
  // 把它放在 Greeting.clock 的同一天，显示成固定的 14:30。
  c.updatedAt = DateTime(2026, 1, 1, 14, 30);

  c.messages.addAll(<ChatMessage>[
    ChatMessage(id: 'u1', role: Role.user, content: '查一下手机电量，然后把网易云音乐的缓存清掉'),
    ChatMessage(
      id: 'a1',
      role: Role.assistant,
      content: '好的。我先读取电池信息，再清理缓存。',
      tools: <ToolInvocation>[
        _inv(
          id: 't1',
          name: 'run_shell',
          args: <String, dynamic>{
            'command': "dumpsys battery | grep -E 'level|status'",
          },
          risk: RiskAssessment.safe,
          status: InvocationStatus.success,
          output: 'level: 73\nstatus: 2',
        ),
        _inv(
          id: 't2',
          name: 'run_shell',
          args: <String, dynamic>{'command': 'pm clear com.netease.cloudmusic'},
          risk: const RiskAssessment(RiskLevel.dangerous, <String>[
            'pm clear 会清除目标的全部数据（登录状态、本地文件等），不可撤销',
          ]),
          status: InvocationStatus.success,
          output: 'Success',
        ),
      ],
    ),
    ChatMessage(
      id: 'a2',
      role: Role.assistant,
      content:
          '已清理完成，释放约 **128 MB**。\n\n'
          '### 设备状态\n'
          '- 电池：`level: 73`，*充电中*\n'
          '- 缓存路径：`/data/data/com.netease.cloudmusic/cache`\n'
          '- 建议每周清理一次，不必频繁操作\n\n'
          '```bash\npm clear com.netease.cloudmusic\n# Success\n```\n\n'
          '详见 [Android 存储文档](https://developer.android.com/training/data-storage)。',
    ),
    // 演示「插入网页内容」：抓到的 JSON 会作为消息内容发给模型
    ChatMessage(
      id: 'u2',
      role: Role.user,
      content: '这个接口返回的路线有多长？',
      attachments: <Attachment>[
        Attachment(
          kind: AttachmentKind.web,
          path: 'https://api.mapbox.com/directions/v5/mapbox/driving/120.15,30.27;120.20,30.31',
          name: 'Mapbox Directions API',
          content:
              '{\n'
              '  "routes": [\n'
              '    {\n'
              '      "distance": 12453.2,\n'
              '      "duration": 983.4,\n'
              '      "weight_name": "routability"\n'
              '    }\n'
              '  ],\n'
              '  "code": "Ok"\n'
              '}',
        ),
      ],
    ),
  ]);

  return c;
}

Future<Widget> _buildApp({
  required Brightness brightness,
  required Settings settings,
  required ConversationStore conversations,
  required PluginStore plugins,
  bool chat = false,
  Widget? home,
}) async {
  final ShizukuService shizuku = ShizukuService();

  // 字号必须在**构建主题之前**写进 AppFonts（主题里的 textTheme 会读它）。
  // 字体族本身是常量，不需要在这里设 —— 见 AppFonts 的注释。
  AppFonts.userScale = settings.fontScale;

  // 笔记 / 任务用同一个临时目录，且**两个渲染目标共用**：
  // 首页那几张卡片会显示计数，两边用不同的 store 会让图和数据对不上。
  final NoteStore notes = NoteStore(
    File('${Directory.systemTemp.path}/notes.json'),
  );
  final TaskStore tasks = TaskStore(
    File('${Directory.systemTemp.path}/tasks.json'),
  );

  final Widget app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    // 和 main.dart 保持一致：液态玻璃那个包是 Material-free 的，
    // 不垫这一层透明 Material，测试里的文字会出现黄色下划线。
    builder: (BuildContext context, Widget? child) {
      // **必须和 main.dart 一样在这里重写一次全局色。**
      //
      // `theme:` 和 `darkTheme:` 会**两份都构建**，而 `darkTheme` 在后 ——
      // `AppTheme._build()` 里写的 `AppColors.applyScheme()` 是全局静态，
      // 于是不管当前渲染哪一套，全局都停在深色那份（`accent` = 近白的
      // #F2F2F7）。浅色验收图里所有读 accent 的图标就渲染成白色 ——
      // 那正是"图标看不见/没对齐"的真实原因。
      //
      // 生产侧（main.dart）已经在 builder 里修了；这里不同步的话，
      // golden 会一直拍到一个**生产环境不存在**的白色图标。
      final ThemeData active = Theme.of(context);
      AppColors.applyScheme(
        active.colorScheme,
        dark: active.brightness == Brightness.dark,
      );
      return Material(
        type: MaterialType.transparency,
        child: child ?? const SizedBox.shrink(),
      );
    },
    // 默认渲染**真实的 HomeShell**（= 首页），因为应用现在就从这里开始。
    //
    // `chat: true` 时改挂 ChatPage —— 对话页现在是首页 push 上去的，
    // 不单独渲染一次的话，输入栏（模型胶囊 / 发送键）永远不会进渲染图，
    // 等于那一块一直没被看过。界面改一轮就该看一眼。
    home:
        home ??
        (chat
            ? ChatPage(
                settings: settings,
                conversations: conversations,
                plugins: plugins,
                shizuku: shizuku,
                workDir: Directory.systemTemp.path,
                notes: notes,
                tasks: tasks,
              )
            : HomeShell(
                settings: settings,
                conversations: conversations,
                plugins: plugins,
                shizuku: shizuku,
                workDir: Directory.systemTemp.path,
                notes: notes,
                tasks: tasks,
              )),
  );

  // 不开 adaptiveQuality：它会在启动时跑约 3 秒的性能基准测试，
  // 让测试变慢且结果不稳定。和线上一致的关键部分是亮度解析器 ——
  // 没有它，玻璃的明暗会跟着**系统**走而不是跟着应用主题走。
  return LiquidGlassWidgets.wrap(
    child: app,
    brightnessResolver: Theme.maybeBrightnessOf,
  );
}

void main() {
  late Settings settings;
  late ConversationStore conversations;
  late PluginStore plugins;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await _loadFonts();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'apiKey': 'sk-demo',
      'model': 'deepseek-flash',
    });
    settings = await Settings.load();

    // 把侧边菜单里的"现在"钉死在下午。
    //
    // 问候语按小时变成"早上/下午/晚上"，不钉住的话这两张 golden 会在
    // 一天里的不同时段变红 —— 而那不是界面坏了，只是两个字不同，
    // 却会让"我这次的改动有没有弄坏首页"这个判断失效。
    //
    // 钉子只有一颗：`Greeting.clock`。侧边菜单和首页空白对话的问候
    // 都从它取"现在"（见 greeting.dart），所以钉住它两张图一起稳。
    Greeting.clock = () => DateTime(2026, 1, 1, 15, 0);

    final Directory tmp = await Directory.systemTemp.createTemp('dsh_preview');
    conversations = ConversationStore(File('${tmp.path}/conv.json'));
    conversations.conversations.add(_seed());
    conversations.currentId = 'demo';

    plugins = PluginStore(File('${tmp.path}/plugins.json'));

  });

  Future<void> render(
    WidgetTester tester,
    String name, {
    bool chat = false,
  }) async {
    // 按手机竖屏尺寸渲染
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: name.contains('dark') ? Brightness.dark : Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: chat,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  /// 把设置页滚到某个文字所在的位置。
  ///
  /// 设置是**单页平铺**的，整页比一屏长得多。`ListView` 只构建视口内的
  /// 子项，所以下半页的标题在滚到之前根本不存在 —— 直接 `expect` 会
  /// 报"找不到"。这个辅助函数把目标滚进视口再交回给调用方断言。
  Future<void> scrollSettingsTo(WidgetTester tester, String text) async {
    final Finder target = find.text(text);
    // 已经构建出来就不用滚了
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target.first);
      await tester.pumpAndSettle();
      return;
    }
    final Finder list = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      target,
      300,
      scrollable: list,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
  }

  // 首页。应用现在**从这里开始** —— 底部标签栏已经删掉，
  // 所以这两张图就是"打开应用第一眼看到什么"。
  testWidgets('light', (WidgetTester tester) async {
    await render(tester, 'chat_light');
  });

  testWidgets('dark', (WidgetTester tester) async {
    await render(tester, 'chat_dark');
  });

  // 侧边菜单。**单独出一张图**，因为它是首页唯一的入口 ——
  // 它要是打不开（或长得不对劲），用户就没有任何办法看到历史对话、
  // 计划、笔记、研究和设置。而"点菜单键打开抽屉"这一步依赖
  // `Scaffold.of(context)`，是最容易写错的地方（写错时按钮**毫无反应**，
  // 不报错），所以这里从**点击**开始走完整条路，而不是直接把抽屉挂出来渲染。
  testWidgets('drawer', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 顶栏改版后左上角是返回箭头，不再有菜单图标 —— 直接让 Scaffold
    // 打开抽屉，效果与点菜单一致。
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/drawer.png'),
    );
  });

  // 侧边菜单的两件事：**搜索**和**批量选择**。
  //
  // 都要单独出图：它们只在点过图标之后才出现，别的图永远看不到；
  // 而"点了没反应"（状态没接线）这种错，只有走完整条路才测得出来。
  testWidgets('drawer search', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 顶栏改版后左上角是返回箭头，不再有菜单图标 —— 直接让 Scaffold
    // 打开抽屉，效果与点菜单一致。
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    // 搜索框**默认收起**（侧栏不默认占一条输入框）。用户要搜，得先点
    // 标题栏右边那颗放大镜把它展开 —— 测试走的就是这条真实路径，
    // 而不是直接假设它在。
    //
    // 注意：**不能写 `find.byType(TextField).first`** —— 抽屉背后那个
    // 对话页也有一个输入框，`.first` 抓到的很可能是它（文字打进了一个
    // 看不见的地方，而这张图会照常"通过"）。
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byTooltip('搜索对话'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(TextField),
      ),
      '电量',
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/drawer_search.png'),
    );
  });

  // AutoPilot 已经**整个移除**，侧边栏里不该再出现它的任何入口。
  //
  // 这条是反向断言，钉住"它真的没了"这个事实。哪天有人把它加回抽屉，
  // 这条会红 —— 那正说明移除被回退了。
  testWidgets('drawer 不再有 AutoPilot 入口', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 顶栏改版后左上角是返回箭头，不再有菜单图标 —— 直接让 Scaffold
    // 打开抽屉，效果与点菜单一致。
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('AutoPilot'),
      ),
      findsNothing,
      reason: 'AutoPilot 已整个移除，不该有任何入口',
    );
  });

  testWidgets('drawer edit', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 顶栏改版后左上角是返回箭头，不再有菜单图标 —— 直接让 Scaffold
    // 打开抽屉，效果与点菜单一致。
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    // 全选之后的样子（勾选框、置顶/删除按钮都该是活的）
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/drawer_edit.png'),
    );
  });

  // 消息滚起来之后的顶栏（模糊 + 加浓 + 一条发丝线）。
  //
  // 必须从**滚动**开始走：顶栏在静止时是"同色隐身"的，两个状态只差
  // 一层背景 —— 而"滚动时没变实"这种错，在静止的图里根本看不出来。
  testWidgets('header scrolled', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // ⚠️ 真实 I/O（建 store）在 testWidgets 里要包 runAsync，
    // 这里只是滚动，直接拖就行。
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    // 淡入淡出走完
    await tester.pump(const Duration(milliseconds: 260));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/header_scrolled.png'),
    );
  });

  // 对话页。名字留 `chat_*` 是因为它在应用里就叫这个，
  // 而首页那两张图沿用了旧文件名 —— 图会被 `--update-goldens` 覆盖，
  // 但"哪张图对应哪个页面"必须写清楚，否则以后看文件名会认错。
  testWidgets('chat page light', (WidgetTester tester) async {
    await render(tester, 'chat_page_light', chat: true);
  });

  testWidgets('chat page dark', (WidgetTester tester) async {
    await render(tester, 'chat_page_dark', chat: true);
  });

  // 横屏双栏：左侧聊天、右侧工具调用表，中间分隔条可拖动。
  // 这张图同时钉住颜色语义：成功绿、进行中黄、失败红。
  testWidgets('chat landscape split', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2532, 1170);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final Finder left = find.byKey(const ValueKey<String>('chat_left_pane'));
    final Finder right = find.byKey(const ValueKey<String>('chat_right_pane'));
    expect(left, findsOneWidget);
    expect(right, findsOneWidget);
    final double before = tester.getSize(left).width;

    await tester.drag(
      find.byKey(const ValueKey<String>('chat_split_handle')),
      const Offset(90, 0),
    );
    await tester.pump();
    expect(tester.getSize(left).width, greaterThan(before));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chat_landscape.png'),
    );
  });

  testWidgets('drawer landscape', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2532, 1170);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 顶栏改版后左上角是返回箭头，不再有菜单图标 —— 直接让 Scaffold
    // 打开抽屉，效果与点菜单一致。
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/drawer_landscape.png'),
    );
  });

  testWidgets('model picker landscape', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2532, 1170);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 换模型的入口现在在输入框【+】旁边的模型按钮里：点它是**思考深度**
    // 卡片，卡片底部那行「模型设置」才进模型列表，右上角「管理」进完整设置。
    // 测试跟着用户真正会走的路。
    await tester.tap(find.byKey(const ValueKey<String>('chat.modelButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('模型设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理').first);
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/model_picker_landscape.png'),
    );
  });

  // 空白对话（一条消息都没有的首页）。**单独出一张图**，因为别的预览里
  // 那条会话都是带内容的 —— 而这一屏现在只有一句问候（2026-10-16 改的），
  // 正是"改完之后还剩什么"最需要被看见的地方。
  testWidgets('empty chat', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // ⚠️ 建目录 + 建 store 这些**真实 I/O 必须包在 `runAsync` 里**：
    // `testWidgets` 的函数体跑在 fake async 时区里，那里的时钟由框架推着走，
    // 磁盘 I/O 的完成回调永远轮不到 —— 表现就是这个用例**一声不响地卡住**
    // （不报错、没有超时，因为等待发生在框架的时区之外）。
    // 上面 setUp 里可以直接 await，是因为 setUp 不在那个时区里。
    final ConversationStore blank = (await tester.runAsync(() async {
      final Directory tmp = await Directory.systemTemp.createTemp('dsh_empty');
      final ConversationStore s = ConversationStore(
        File('${tmp.path}/conversations.json'),
      );
      s.createNew();
      return s;
    }))!;

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: blank,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/empty_chat.png'),
    );
  });

  // 设置页。现在是**独立页面**，不再是底部面板。
  testWidgets('settings page', (WidgetTester tester) async {
    // 这一页打开时会去查后台保活状态和悬浮窗权限。测试环境里没有这两个
    // 原生通道，不拦下来会抛 MissingPluginException 把测试打挂。
    const MethodChannel bg = MethodChannel('dsh/bg');
    const MethodChannel overlay = MethodChannel('dsh/overlay');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      bg,
      (MethodCall call) async => false,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      overlay,
      (MethodCall call) async => false,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bg, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        overlay,
        null,
      );
    });

    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // 设置已经移到侧边菜单；头部的两个位置让给了模型 / 工具 / 权限。
    // 顶栏改版后左上角是返回箭头，不再有菜单图标 —— 直接让 Scaffold
    // 打开抽屉，效果与点菜单一致。
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    // 底栏改成一排略缩图标之后，侧栏里**没有「设置」这两个字**了 ——
    // 设置仍是「历史」标题行最右边那颗圆形图标，按 tooltip 点它。
    // 「设置」现在收在底栏的「更多」里（研究 / 浏览器 / 设置）。
    // 先展开再点 —— 这条路径也正是用户要走的那条。
    // 侧栏的底栏已经去掉：设置从**头像**进（点头像 → 菜单里选「设置」）。
    await tester.tap(find.byTooltip('设置 / 换头像'));
    await tester.pumpAndSettle();
    // 抽屉底栏也有一个「设置」图标，`find.text('设置')` 会命中两个 ——
    // 这里要的是**头像菜单里的那一项**，用 ListTile 限定。
    await tester.tap(find.widgetWithText(ListTile, '设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_page.png'),
    );
  });

  // 高级设置页：**默认全是折叠的**。
  //
  // 这张图钉住的是「新手打开设置不会先被一堆开关砸到」——
  // 五组都收着，每组只留一句说明。
  testWidgets('settings advanced page', (WidgetTester tester) async {
    const MethodChannel bg = MethodChannel('dsh/bg');
    const MethodChannel overlay = MethodChannel('dsh/overlay');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      bg,
      (MethodCall call) async => false,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      overlay,
      (MethodCall call) async => false,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bg, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        overlay,
        null,
      );
    });

    // 比常规预览高一截：这一页要把五组折叠标题**一次拍全**，
    // 否则 ListView 只会构建视口内的那几行（懒加载）。
    tester.view.physicalSize = const Size(1170, 4200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    // 「设置」现在收在底栏的「更多」里（研究 / 浏览器 / 设置）。
    // 先展开再点 —— 这条路径也正是用户要走的那条。
    // 侧栏的底栏已经去掉：设置从**头像**进（点头像 → 菜单里选「设置」）。
    await tester.tap(find.byTooltip('设置 / 换头像'));
    await tester.pumpAndSettle();
    // 抽屉底栏也有一个「设置」图标，`find.text('设置')` 会命中两个 ——
    // 这里要的是**头像菜单里的那一项**，用 ListTile 限定。
    await tester.tap(find.widgetWithText(ListTile, '设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 设置现在是**单页平铺**：没有分类卡可点，所有区块直接排在一页里。
    // 所以这里不再有"进分类"这一步 —— 打开就是全部设置。
    //
    // ⚠️ 平铺之后页面比一屏长得多，下半页在视口外**根本没被构建**
    // （ListView 懒加载），直接 expect 会找不到。所以先滚下去。
    await scrollSettingsTo(tester, '安全确认');

    expect(find.text('安全确认'), findsOneWidget);
    // 平铺之后这一组的开关**直接就在页面上**（不再有折叠的入口卡）。
    // 断言它确实出现了，比断言"看不见"更能说明平铺生效了。
    expect(find.text('只读命令自动执行'), findsOneWidget);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_advanced.png'),
    );
  });

  // 「模型与对话」：新手只要看到模型卡片 + 思考开关 + 温度。
  // 其余四组收着 —— 这是整次设置重排的核心。
  testWidgets('settings model page', (WidgetTester tester) async {
    const MethodChannel bg = MethodChannel('dsh/bg');
    const MethodChannel overlay = MethodChannel('dsh/overlay');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      bg,
      (MethodCall call) async => false,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      overlay,
      (MethodCall call) async => false,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(bg, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        overlay,
        null,
      );
    });

    tester.view.physicalSize = const Size(1170, 4200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    tester.firstState<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    // 「设置」现在收在底栏的「更多」里（研究 / 浏览器 / 设置）。
    // 先展开再点 —— 这条路径也正是用户要走的那条。
    // 侧栏的底栏已经去掉：设置从**头像**进（点头像 → 菜单里选「设置」）。
    await tester.tap(find.byTooltip('设置 / 换头像'));
    await tester.pumpAndSettle();
    // 抽屉底栏也有一个「设置」图标，`find.text('设置')` 会命中两个 ——
    // 这里要的是**头像菜单里的那一项**，用 ListTile 限定。
    await tester.tap(find.widgetWithText(ListTile, '设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 单页平铺：没有"模型与对话"这张分类卡可点了，直接滚到模型那一节。
    await scrollSettingsTo(tester, '开启思考模式');

    expect(find.text('开启思考模式'), findsOneWidget);
    expect(find.text('生图'), findsOneWidget);
    expect(find.text('描述改进'), findsOneWidget);
    expect(find.text('输入建议'), findsOneWidget);
    expect(find.text('工具调用次数'), findsOneWidget);
    // 折叠收起时，生图模型输入框不该出现。
    expect(find.text('生图模型名（留空 = 不启用生图）'), findsNothing);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/settings_model.png'),
    );
  });

  // 自学习笔记页。**单独出一张图**：它是 agent 自己维护的复盘本，
  // 页面上刻意没有"添加"入口 —— 这件事只有在图里一眼看得出来。
  testWidgets('learning page', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final LearningStore store = (await tester.runAsync(() async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'dsh_learn_preview',
      );
      final LearningStore s = await LearningStore.configure(
        File('${tmp.path}/learning.json'),
      );
      // 时间必须钉死：默认是 `DateTime.now()`，金图里的日期每天都会变。
      final DateTime when = DateTime(2026, 1, 1, 15, 0);
      s.add(
        '调用 ui_action 前先 ui_tree，按控件名点比坐标稳',
        kind: 'skill',
        createdAt: when,
      );
      s.add('文件路径含空格时要加引号，否则命令会被拆成两段', kind: 'mistake', createdAt: when);
      s.add(
        'HTTP 400 别原样重试，先看返回里的 error.message',
        kind: 'detour',
        createdAt: when,
      );
      return s;
    }))!;

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        home: LearningPage(store: store),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/learning_page.png'),
    );
  });

  // 知识库列表。**单出一张图**：它证明"真 RAG"不是一个隐藏开关，
  // 用户能看见每个库的文档数、片段数和检索模式。
  testWidgets('knowledge page', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final KnowledgeStore store = (await tester.runAsync(() async {
      final Directory tmp = await Directory.systemTemp.createTemp(
        'dsh_kb_preview',
      );
      final KnowledgeStore s = await KnowledgeStore.configure(tmp);
      await s.createBase('产品文档');
      final KnowledgeBase b = s.byName('产品文档')!;
      await s.importText(
        b.id,
        title: '安装与升级',
        text: '下载安装包后，按提示完成安装。升级不会清空本地数据。',
      );
      await s.importText(b.id, title: '常见问题', text: '如果登录失败，先检查网络，再确认账号是否已开通。');
      await s.createBase('售后政策');
      return s;
    }))!;
    expect(store.bases, hasLength(2));

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        home: KnowledgePage(settings: settings),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/knowledge_page.png'),
    );
  });

  // TeenSpace：三档敏感度。
  testWidgets('teenspace', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    AppFonts.userScale = settings.fontScale;

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) => Material(
          type: MaterialType.transparency,
          child: child ?? const SizedBox.shrink(),
        ),
        home: TeenSpacePage(settings: settings),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/teenspace.png'),
    );
  });

  // 「+」四标签页面板。
  //
  // 单独出图是因为它只在 showModalBottomSheet 里渲染，chat_light 截不到；
  // 而这一块是这一轮改动最大的地方，不看等于没验证。
  testWidgets('attach panel', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        // 必须挂 ChatPage：`+` 按钮在对话页的输入栏里，
        // 而首页上（默认渲染目标）根本没有这个按钮。
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // 用 tooltip 定位，比 byIcon 稳（`Icons.add_rounded` 在这一页也不止一个）。
    await tester.tap(find.byTooltip('发送图片或文件'));
    // 不用 pumpAndSettle：面板里只要有永不停止的动画它就会挂死进程。
    // 显式推进到路由动画结束就够了。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/attach_panel.png'),
    );
  });

  // ---- 模型选择器：两层都单独出图 ----
  //
  // 这一块调了很多轮（文字偏、滑条不像滑条、列表背景透明），
  // 而它在整屏 golden 里只是底部一小条 —— 看不清细节。
  // 单独渲染并**放大**，才能一眼确认。
  testWidgets('model picker sheet', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 造几条模型，带上备注和能力标记，好看清"完整信息"长什么样。
    // 共享的 settings 会被前面的用例改过（档案、当前档），这里先清干净，
    // 否则结果取决于跑的顺序 —— 单独跑对、全量跑错就是这么来的。
    settings.profiles.clear();
    settings.activeProfileId = null;
    settings.update(() {
      settings.addProfile(
        ModelProfile(
          id: 'p1',
          name: '日常主力',
          note: '便宜，日常问答用',
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'sk-demo',
          model: 'deepseek-v4-flash',
        ),
        activate: true,
      );
      settings.addProfile(
        ModelProfile(
          id: 'p2',
          name: '长文',
          note: '上下文大，写长报告',
          baseUrl: 'https://api.moonshot.cn/v1',
          apiKey: 'sk-x',
          model: 'kimi-k2',
        ),
      );
      settings.addProfile(
        ModelProfile(
          id: 'p3',
          name: '画图',
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-x',
          model: 'gpt-image-2',
          chat: false,
          tools: <String>[kImageGenTool],
        ),
      );
    });

    AppFonts.userScale = settings.fontScale;

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) => Material(
          type: MaterialType.transparency,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            backgroundColor: AppColors.lightBg,
            body: Center(
              child: TextButton(
                onPressed: () => showModelPicker(context, settings: settings),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    // 等入场淡入和点击水波都走完再拍：固定 500ms 会停在动画中途，
    // 单跑和全量跑停的位置不一样，golden 就时过时不过。
    await tester.pumpAndSettle();

    // 第一层：强度卡片（模型名 + 档位 + 滑块）
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/model_picker.png'),
    );

    // 第二层：点**模型名**那一行 → 完整列表。
    //
    // 上面 addProfile 之后当前模型是最后加进去的那个，所以这里
    // **显式切回 p1**，让卡片顶上显示"日常主力"，再点它 ——
    // 不然按名字找会找不到（显示的是另一个模型的名字）。
    settings.selectProfile('p1');
    await tester.pump();
    await tester.tap(find.text('日常主力').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/model_list.png'),
    );
  });

  // 输入框那一行**放大**：胶囊里的文字是否居中、和发送键是否同轴，
  // 在整屏图里只有几十像素高，看不出来。
  testWidgets('composer strip', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    settings.profiles.clear();
    settings.update(() {
      settings.addProfile(
        ModelProfile(
          id: 'p1',
          name: '日常主力',
          note: '便宜，日常问答用',
          baseUrl: 'https://api.deepseek.com',
          apiKey: 'sk-demo',
          model: 'deepseek-v4-flash',
        ),
        activate: true,
      );
    });

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 只截输入框那一块：`find.byType(TextField)` 的祖先容器。
    // 用 tooltip 定位发送键，再取它的父级区域。
    final Finder composer = find.ancestor(
      of: find.byTooltip('发送图片或文件'),
      matching: find.byType(Row),
    );
    await expectLater(
      composer.first,
      matchesGoldenFile('goldens/composer_strip.png'),
    );
  });

  /// **`@` 引用的补全面板 + 输入框里的染色**。
  ///
  /// 单独出一张图，因为这是"看着才知道对不对"的那类东西：
  /// 染色太淡等于没有，太重在深色主题下发脏；面板太高会把输入框顶出去。
  /// 这些都不是断言能表达的。
  testWidgets('mention panel', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 造一个工具和一个插件，让面板有内容可列
    FolderToolStore.instance.tools
      ..clear()
      ..add(
        FolderTool(
          id: 'pdf_merge',
          title: '合并 PDF',
          description: '把多个 PDF 合成一个',
          whenToUse: '用户要合并 PDF 时',
          body: '1. 装 qpdf\n2. 跑 qpdf --empty --pages',
          // 备注：`@` 面板里显示的应该是**这一行**，而不是 description。
          // 标题和 HTML 注释会被 noteLine 跳过。
          intro:
              '# 合并 PDF · 备注\n\n'
              '<!-- 这个是给自己看的 -->\n\n'
              '需求原话：能把几个 PDF 合成一个。已装过 qpdf。\n',
          folderPath: '/tmp/tools/pdf_merge',
        ),
      )
      ..add(
        FolderTool(
          id: 'weekly_report',
          title: '周报整理',
          description: '把一周的笔记整理成周报',
          folderPath: '/tmp/tools/weekly_report',
        ),
      );
    plugins.plugins
      ..clear()
      ..add(
        CustomPlugin(
          id: 'pl1',
          name: 'get_weather',
          title: '查天气',
          description: '按城市查当前天气',
          kind: PluginKind.http,
          template: 'https://api.x.com/weather?q={{city}}',
        ),
      );

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 在输入框里打一个 `@` 触发面板
    await tester.enterText(find.byType(TextField).last, '用 @');
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/mention_panel.png'),
    );

    // 再截一张**染色后**的输入框。
    // `@tool:pdf_merge` 和 `@plugin:get_weather` 都该是强调色 + 淡底，
    // 而中间那句普通文字保持原样。
    await tester.enterText(
      find.byType(TextField).last,
      '用 @tool:pdf_merge 合并这两个，再 @plugin:get_weather',
    );
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/mention_highlight.png'),
    );
  });

  // **多行输入**时的输入框：两边的圆必须钉在原地不动。
  //
  // 这是用户报过的一个具体错：输入到第二、三行时那一行变高，
  // 两个圆跟着往下跑，看着像"按钮跑到下面、和文字错位了"。
  // 静态单行的图看不出这个 —— 必须真的输入几行。
  testWidgets('composer multiline', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final Finder field = find.descendant(
      of: find.byType(ChatPage),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '第一行\n第二行\n第三行');
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/composer_multiline.png'),
    );
  });

  // 输入框**不再有缩放的形态**。
  //
  // 用户明确要求关掉那套"下滑收成一颗圆"的交互。这条断言两件事：
  //  · 那个"收起"小图标不存在了（旧交互留下的入口）；
  //  · 长按输入框是**选词**，工具条里多一项「全屏模式」。
  testWidgets('长按输入框：选词 + 全屏模式', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 旧的收起入口必须已经不存在
    expect(find.byTooltip('收起输入框'), findsNothing);

    await tester.enterText(find.byType(TextField), '第一行\n第二行');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('收起输入框'), findsNothing);

    await tester.longPress(find.byType(TextField));
    await tester.pumpAndSettle();

    // 自定义项：全屏模式。系统项（复制 / 全选 / 粘贴）由
    // `contextMenuButtonItems` 带出来，不逐个断言 —— 它们随平台和
    // 是否有选区变化，钉死会让这条测试变成"考 Flutter 的版本"。
    expect(find.text('全屏模式'), findsOneWidget, reason: '长按选词的工具条里必须能进全屏');
  });

  // **输入法弹出时底栏收走**。
  //
  // 键盘占了屏幕下半截，三个图标再留着就把"正在写的那一行"挤到中间。
  testWidgets('输入法弹出时底栏隐藏', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // 底栏（聊天 / 卡片）已经随卡片功能一起删掉了，现在输入区就是
    // 最后一块内容。这里改成盯「添加」那颗按钮：它和输入框同生共死，
    // 而且一直可见 —— 量它就能知道"输入区在不在、点不点得到"。
    expect(
      find.byTooltip('发送图片或文件').hitTestable(),
      findsOneWidget,
      reason: '没键盘时输入区应该看得见、点得到',
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 键盘弹出来时输入区**不是被移除**，而是跟着键盘上移 —— 它仍然
    // 可见、仍然在屏幕内。真正要保证的是"输入框没被键盘盖住"。
    expect(
      find.byType(TextField).hitTestable(),
      findsWidgets,
      reason: '输入框在键盘弹出后仍然要能点',
    );

    tester.view.resetViewInsets();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byTooltip('发送图片或文件').hitTestable(),
      findsOneWidget,
      reason: '收起键盘后还在',
    );
  });
  // **字号小于 100%** 时的输入框。
  //
  // 用户报过：字号一调小，输入框里的字就往上飘、和两边的圆对不齐。
  // 根因是这一行**顶部对齐**（为了多行时圆不跟着跑），而字比圆矮时
  // 就贴到顶上去了。现在给了最小高度 + 垂直居中，这张图专门盯它。
  testWidgets('composer small font', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    settings.update(() => settings.fontScale = 0.8);
    addTearDown(() => settings.update(() => settings.fontScale = 1));

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/composer_small_font.png'),
    );
  });

  // 输入区**收到一半**的样子（手指还按着，往下拖了 55 像素）。
  //
  // 这一张盯的是"跟手压缩"：宽度和高度必须**同时**变小。之前高度交给
  // `AnimatedSize` 自动跟，结果是"左右缩完了才开始上下缩" ——
  // 那种错在只有终点的静态图里根本看不出来，只有在半路才看得见。
  testWidgets('composer mid drag', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final Offset start = tester.getCenter(find.byType(TextField));
    final TestGesture g = await tester.startGesture(start);
    // 门槛是 110 像素，拖 55 = 正好压到一半
    for (int i = 0; i < 11; i++) {
      await g.moveBy(const Offset(0, 5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 120));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/composer_mid_drag.png'),
    );
    // 手指还没抬起：这一帧就是"松手前看到的中间态"，不是动画补间的一帧。
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  });

  // 输入区**收起**之后的样子（在输入框上下滑一下）。
  //
  // 顺手把「性能 → 工具调用」那一页也拍了：它是一张**表格**
  // （时间 / 工具 / 内容），三列挤在一行里最容易溢出 ——
  // 而溢出在静态图里只是黄黑条，在真机上却是"内容显示不全"。
  testWidgets('performance tool table', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 顶栏改成了「两个圆按钮」（方案 A）：工具调用收进了右上角
    // 「模型、工具调用、权限」那个 sheet 里，先打开它。
    await tester.tap(find.byTooltip('工具调用与权限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工具调用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('性能'));
    await tester.pumpAndSettle();
    // 左滑到第二页（用页签，等价于左滑那一下的结果）
    await tester.tap(find.text('工具调用'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/performance_tools.png'),
    );
  });

  //
  // 必须单独出一张：收起态是"整块玻璃缩成一个圆 + 右边长出两个按钮"，
  // 而它只在用户滑过之后才出现 —— 别的预览图永远看不到。
  // 这里从**拖动**开始走完整条路（下滑手势写错的话，表现就是"滑了没反应"，
  // 而那种错在静态截图里根本不存在）。
  testWidgets('composer collapsed', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 在输入框上按住往下拖 240 像素（越过"过半即收起"的门槛）。
    final Offset start = tester.getCenter(find.byType(TextField));
    final TestGesture g = await tester.startGesture(start);
    for (int i = 1; i <= 24; i++) {
      await g.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    // 动画跑完（260ms + 余量）
    await tester.pump(const Duration(milliseconds: 500));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/composer_collapsed.png'),
    );
  });

  // 单独渲染「插入网页内容」的卡片：整条会话里它在可视区之外，
  // 只在 chat_light 里截不到。
  // 「全部工具调用」那一行**点开之后**的样子。
  //
  // 折叠状态是交互里最容易写错的一环（点一下没反应、或者点开之后整块
  // 不见了），而它只在"有工具调用 + 用户点过"时才出现 —— 别的预览图
  // 永远看不到。所以这里从**点击**开始走完整条路。
  testWidgets('tools unfolded', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.textContaining('次工具调用'));
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/tools_unfolded.png'),
    );
  });

  // 自定义规则页：**一行一条** + 搜索框（2026-10-16 改的）。
  //
  // ---- 下面这两张是**反向**的回归图（2026-10-16 起）----
  //
  // 它们以前拍的是"浏览器正在使用"贴在输入框上方那一行。那一行后来被
  // 用户要求撤掉了（信息挪到收起态的工具指示圆上），所以这两张图现在
  // 拍的**就是普通的输入区** —— 而这正是它们存在的意义：
  // 谁要是再把那一行加回来，这两张图立刻变样、测试立刻红，
  // 那种改动就必须是**有意**的。
  //
  // 所以别看到"两张一样的图"就删掉它们：一张是"只有浏览器在忙"、
  // 一张是"浏览器和终端都在忙"，两种状态下输入区都该长这样。
  testWidgets('composer with status row', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    WebViewLoader.beginActivity('正在读取 news.ycombinator.com');
    addTearDown(WebViewLoader.endActivity);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/composer_status.png'),
    );
  });

  // 浏览器和终端**同时**在忙时的那一行（2026-10-16 合并成一句）。
  //
  // 两种状态的组合是这里最容易写错的地方：只有浏览器、只有终端、
  // 两个都有 —— 前两种各有一张图（上面那张和 chat_light），
  // 「两个都有」这一句只在真机上同时跑起来才看得到，所以单独钉一张。
  testWidgets('composer both busy', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    WebViewLoader.beginActivity('正在读取 connect.garmin.cn');
    TerminalSession.instance.debugSetRunning('python3 export_activity.py');
    addTearDown(WebViewLoader.endActivity);
    addTearDown(TerminalSession.instance.debugClearRunning);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        chat: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/composer_both.png'),
    );
  });

  testWidgets('whats new', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      await _buildApp(
        brightness: Brightness.light,
        settings: settings,
        conversations: conversations,
        plugins: plugins,
        home: const WhatsNewPage(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/whats_new.png'),
    );
  });

  //
  // 单独出图是因为这一页平时进不去（设置 → 规则，藏在两层里），
  // 而它这次改动不小：规则原文不再铺在列表里、开关缩小、上面多了搜索。
  group('规则页', () {
    Future<RuleStore> seedRules() async {
      final Directory tmp = await Directory.systemTemp.createTemp('dsh_rules');
      final RuleStore store = await RuleStore.configure(
        File('${tmp.path}/rules.json'),
      );
      store.add('我让你查资料时', '先列出三个来源，再给结论；来源要带链接');
      store.add('我发英文给你时', '先翻译成中文再回答');
      store.add('回答技术问题时', '代码块要带注释，并说明适用版本');
      store.toggle(store.rules.last, false);
      store.add('我说"记一下"时', '把它存成笔记，标题用一句话概括');
      return store;
    }

    Future<void> renderRules(
      WidgetTester tester,
      String name, {
      String? search,
    }) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 建 store 是真实磁盘 I/O，必须走 runAsync（见 empty chat 那段说明）。
      final RuleStore rules = (await tester.runAsync(seedRules))!;

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          builder: (BuildContext context, Widget? child) => Material(
            type: MaterialType.transparency,
            child: child ?? const SizedBox.shrink(),
          ),
          home: RulesPage(store: rules),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      if (search != null) {
        await tester.enterText(find.byType(TextField).first, search);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$name.png'),
      );
    }

    testWidgets('列表', (WidgetTester tester) async {
      await renderRules(tester, 'rules_page');
    });

    testWidgets('搜索', (WidgetTester tester) async {
      await renderRules(tester, 'rules_search', search: '翻译');
    });
  });

  testWidgets('web card', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 1560);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final ChatMessage msg = ChatMessage(
      id: 'web',
      role: Role.user,
      content: '这个接口返回的路线有多长？',
      attachments: <Attachment>[
        Attachment(
          kind: AttachmentKind.web,
          path: 'https://api.mapbox.com/directions/v5/mapbox/driving/120.15,30.27;120.20,30.31',
          name: 'Mapbox Directions API',
          content:
              '{\n'
              '  "routes": [\n'
              '    {\n'
              '      "distance": 12453.2,\n'
              '      "duration": 983.4,\n'
              '      "weight_name": "routability"\n'
              '    }\n'
              '  ],\n'
              '  "code": "Ok"\n'
              '}',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: Scaffold(
          backgroundColor: AppColors.lightBg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MessageView(message: msg),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/web_card.png'),
    );
  });
}
