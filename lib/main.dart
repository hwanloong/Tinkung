import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/learning.dart';
import 'core/memory.dart';
import 'knowledge/knowledge_store.dart';
import 'mcp/mcp_store.dart';
import 'core/app_nav.dart';
import 'tools/webview_loader.dart';
import 'core/productivity.dart';
import 'core/python.dart';
import 'core/rules.dart';
import 'core/storage.dart';
import 'core/folder_tool.dart';
import 'core/lock.dart';
import 'core/notify_hub.dart';
import 'core/obj_store.dart';
import 'core/varbank.dart';
import 'core/agent_doc.dart';
import 'core/chat_recall.dart';
import 'core/store.dart';
import 'core/terminal_session.dart';
import 'plugins/plugin.dart';
import 'shizuku/shizuku_service.dart';
import 'theme/app_theme.dart';
import 'ui/assistant_mode_page.dart';
import 'ui/home_shell.dart';
import 'ui/lock_ui.dart';
import 'ui/whats_new_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 竖屏保持正常状态栏；横屏才进入全屏沉浸（见 _OrientationSystemUi）。
  //
  // ⚠️ **不要 await**：这是一次 MethodChannel 往返，排在任何加载之前
  // 等于白等 10~40ms。真正管用的是 `_OrientationSystemUi`（它会在
  // 首帧后按方向重新申明），这里只是让启动窗口尽早进入 edge-to-edge。
  unawaited(
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    ).catchError((Object _) {}),
  );

  // ---- 启动：首帧只等"首屏真的要用"的那几样 ----
  //
  // ## 这一段的形状是**两轮并行**
  //
  // 三次平台调用（`SharedPreferences` / 文档目录 / 外部存储目录）彼此
  // 没有依赖，所以**一次全部发出去**，谁都不用等谁。之前它们是串行的：
  // 先等设置、再等文档目录、最后才拿外部目录 —— 三个往返加在一起
  // 就是白白多出来的 30~120ms。
  //
  // ## 会话历史**不在首帧前面**
  //
  // 这是启动耗时的大头：`conversations.json` 是只增不减的，聊到几千条
  // 消息时是几 MB，解析完要几百毫秒。它现在在 `runApp()` **之后**才
  // 开始等（解析本身还在后台 isolate 里，见 `ConversationStore.load`）。
  //
  // 界面在历史还没到时显示的是**页面底色**，不是白屏；历史一到就
  // `notifyListeners()`，首屏自己补上。
  //
  // ⚠️ 唯一不能延后的判断是**门禁**：它决定要不要先弹锁屏。锁文件很小，
  // 而且它在首帧前判定才不会有"先露出真实界面再盖遮罩"的那一瞬间。
  final Future<Settings> settingsFuture = Settings.load();
  final Future<Directory> docsFuture = getApplicationDocumentsDirectory();
  final Future<Directory?> extFuture = getExternalStorageDirectory();

  final Settings settings = await settingsFuture;
  final Directory docs = await docsFuture;

  final ConversationStore conversations = ConversationStore(
    File('${docs.path}/conversations.json'),
  );
  final PluginStore plugins = PluginStore(File('${docs.path}/plugins.json'));
  final NoteStore notes = NoteStore(File('${docs.path}/notes.json'));
  final TaskStore tasks = TaskStore(File('${docs.path}/tasks.json'));
  appLock = LockStore(File('${docs.path}/lock.json'));
  final ShizukuService shizuku = ShizukuService();

  // 会话历史和门禁**同时发车**：门禁等完才 `runApp`，历史继续在后台跑。
  final Future<void> conversationsLoaded = conversations.load();
  await appLock!.load();

  // 工作目录：只影响工具落盘位置。这次调用从函数开头就在跑了，
  // 走到这里基本已经完成 —— 真要没完成，等的也只是它剩下的那一点。
  Directory? ext = await extFuture;
  ext ??= await getApplicationSupportDirectory();
  final String workDir = '${ext.path}/dsh';

  runApp(
    AgentApp(
      settings: settings,
      conversations: conversations,
      plugins: plugins,
      shizuku: shizuku,
      defaultWorkDir: workDir,
      notes: notes,
      tasks: tasks,
    ),
  );

  // ============================================================ 首帧之后
  //
  // 下面这些**不再阻塞启动**。它们全都只影响"某个入口里的数据"，
  // 加载完各自 notify，界面自动刷新。
  unawaited(() async {
    await conversationsLoaded;

    // 跨聊天记忆：只读地看其他对话。绑内存里的仓库（不读盘、没有写盘延迟），
    // 文件路径作为兜底（后台任务/测试没有 store 时用）。
    //
    // 必须等历史读完再绑：绑早了它看到的是一份空列表，
    // "回忆其他聊天"就会回一句"没有相关记录"。
    final ChatArchive chatArchive = await ChatArchive.configure(
      File('${docs.path}/conversations.json'),
    );
    chatArchive.bind(conversations);

    // ---- 每次冷启动都开一条**新的空对话** ----
    //
    // `load()` 会把当前会话设成最近更新的那条（= 上次聊的那条），
    // 而打开应用的第一件事几乎总是"说点什么"，不是接着上次继续说 ——
    // 要接着说的那条在侧边菜单的「历史对话」里，一步就到。
    //
    // 但**已经有一条空对话时不再建**：反复开关应用会堆出一串一个字都没有的
    // "新对话"，它们除了把真正的历史挤下去，没有任何作用。
    //
    // ⚠️ 这一段必须放在 `load()` **之后**：在历史还是空的时候建会话，
    // 等于凭空多一条空白页（而且它是"当前会话"，首屏就落在它上面）。
    if (conversations.current == null ||
        conversations.current!.messages.isNotEmpty) {
      conversations.createNew();
    }

    _warmUp(
      docs: docs,
      settings: settings,
      plugins: plugins,
      notes: notes,
      tasks: tasks,
      shizuku: shizuku,
      workDir: workDir,
    );
  }());
}

/// 首帧之后的后台预热。
///
/// 单独抽出来是为了让 `main()` 的"关键路径"一眼可见 —— 谁在挡启动、
/// 谁不在，看函数边界就够了。
void _warmUp({
  required Directory docs,
  required Settings settings,
  required PluginStore plugins,
  required NoteStore notes,
  required TaskStore tasks,
  required ShizukuService shizuku,
  required String workDir,
}) {
  Future<void>(() async {
    // 小文件、彼此独立 —— 并行读，别一个个来。
    await Future.wait(<Future<void>>[
      plugins.load(),
      notes.load(),
      tasks.load(),
      NotifyHub.instance.load(File('${docs.path}/unread.json')),
      TerminalSession.instance.loadPreferred(),
      FolderToolStore.instance.configure(Directory('${docs.path}/tools')),
      RuleStore.configure(File('${docs.path}/rules.json')),
      MemoryStore.configure(File('${docs.path}/memory.json')),
      LearningStore.configure(File('${docs.path}/learning.json')),
      McpStore.configure(File('${docs.path}/mcp_servers.json')),
      // 变量库：一个 JSON 文件，很小。放在这一组里（并行读）是因为
      // 用户发消息时**立刻**可能要用到它（长文本存库、引用展开）。
      VarBankStore.configure(File('${docs.path}/varbank.json')),
      // Agent.md：用户对 AI 的最高优先级规范。一个 markdown 文件，
      // 可以直接用别的工具改（就在应用数据目录里）。
      AgentDocStore.configure(File('${docs.path}/Agent.md')),
    ]);

    // 工具目录铺内容比较慢（读资产、写文件），放最后且不 await。
    unawaited(FolderToolStore.instance.seedFromAssets());
    // 只给"启用了但还没成功发现过工具"的服务器补一次发现。
    unawaited(McpStore.instance.refreshMissing());

    // 知识库可能有很多切片索引，单独一条，不拖累上面的。
    unawaited(
      KnowledgeStore.configure(
        Directory('${docs.path}/knowledge'),
        settings: settings,
      ),
    );

    // 对象池只是建目录。
    unawaited(() async {
      final Directory tmp = await getTemporaryDirectory();
      await ObjStore.configure(Directory('${tmp.path}/objpool'));
    }());

    // Shizuku 是一次 IPC，慢的时候能到几百毫秒；加载完会 notify，
    // 有关联的工具/状态会自动出现。
    unawaited(shizuku.init());

    // 启动时清理 7 天前的截图与录屏（工具的中间产物，用户不需要看见）。
    unawaited(StorageManager.clearOldCaptures(workDir, const Duration(days: 7)));

    // 探测内嵌 Python：**首次调用会启动解释器，一两秒**，只影响工具注册。
    //
    // Termux 不在这里探：`ChatPage.initState` 已经会调一次
    // `TermuxService.instance.refresh()`（它必须在会话开始前探完，见那边的
    // 注释），两处都调等于每次启动多发一次 IPC、白等一个往返。
    unawaited(PythonService.instance.refresh());
  });
}

class AgentApp extends StatelessWidget {
  const AgentApp({
    super.key,
    required this.settings,
    required this.conversations,
    required this.plugins,
    required this.shizuku,
    required this.defaultWorkDir,
    required this.notes,
    required this.tasks,
  });

  final Settings settings;
  final ConversationStore conversations;
  final PluginStore plugins;
  final ShizukuService shizuku;

  /// 用户在设置里没指定工作空间时用的目录（应用外部私有目录下的 dsh）。
  final String defaultWorkDir;

  final NoteStore notes;
  final TaskStore tasks;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // 设置一变就重建整棵树。字号、**工作空间**都靠这一步生效 ——
      // 它们都是在 build 里被读出来往下传的，不重建就不会更新。
      animation: settings,
      builder: (BuildContext context, Widget? _) {
        // 字号必须在**构建主题之前**写进 AppFonts ——
        // 主题里的 textTheme 会读它，晚一步就还是旧字号。
        // （字体族本身是常量，不需要在这里设。）
        AppFonts.userScale = settings.fontScale;
        // 供"从代码里推出来的界面"写回设置用（见 app_nav.dart 的说明）。
        appSettings = settings;
        // 抓网页用哪套 UA（见 WebViewLoader.desktopUserAgent）。
        // 和字号同理：必须在**构建之前**写进去，晚一步这次抓取就还是旧 UA。
        WebViewLoader.useDesktopUa = settings.desktopUa;

        // ---- 主题色不再可配 ----
        //
        // 界面固定成一套 **iOS 中性灰阶 + 系统蓝**（见 AppColors）。
        // 种子色选择器已移除 —— 它能选出的配色会把整套表面也染色，
        // 而"界面到处泛着一个色相"正是这一版要根治的东西。

        // ---- 把全局强调色/语义色对齐到**当前实际生效的那套主题** ----
        //
        // 这一步是必须的，不是保险。原因：
        //
        // `AppTheme.light()` 和 `AppTheme.dark()` 都会在 `_build()` 里调
        // `AppColors.applyScheme()`，而那是**写全局静态字段**。
        // `MaterialApp(theme: …, darkTheme: …)` 会**两份都构建**，
        // 而且 `darkTheme` 在后 —— 于是不管当前是什么模式，
        // 全局字段最后都被深色那份覆盖（`accent` 变成近白 `#F2F2F7`）。
        //
        // 后果很具体：浅色界面里所有读 `AppColors.accent` 的东西
        // （设置卡片的图标、@ 面板图标、部分按钮前景）都渲染成**白色**，
        // 在白卡片上等于消失。用户看到的就是"图标没对齐/看不见"，
        // 而真正的问题是**颜色根本不是当前主题的**。
        //
        // 修法：在 builder 里按 `Theme.of(context)`（此刻已经能拿到
        // 生效的那套）重写一次。builder 在子树构建之前执行，
        // 所以这一帧里所有读全局色的组件拿到的都是对的那套。
        final ThemeData active = Theme.of(context);
        AppColors.applyScheme(
          active.colorScheme,
          dark: active.brightness == Brightness.dark,
        );

        // 工作目录：用户指定了就用它，否则用默认的那个。
        //
        // 在这里算而不是在 main() 里算死，是因为**它得跟着设置变**：
        // 用户在设置里换了工作空间，整棵树会重建，这个值也就跟着换，
        // 之后所有工具（截图、录屏、插件脚本）都落到新目录。
        // 在 main() 里算死的话，改了要重启应用才生效 —— 那不像"设置"，像配置。
        final String workDir = settings.workspacePath.trim().isEmpty
            ? defaultWorkDir
            : settings.workspacePath.trim();

        // ---- 品牌色 vs 系统壁纸取色 ----
        //
        // `DynamicColorBuilder` 在 Android 12+ 会拿到系统按**壁纸**推出的两套
        // ColorScheme。但这里**故意不使用**它。
        //
        // 原因：应用主色不该由用户的壁纸决定 —— 那是"系统主题"，
        // 不是"应用主题"；而且它会让所有截图、文档、图标和应用内颜色
        // 对不上，很难排查。现在主题色由**用户在设置里选**（见 themeSeed）。
        //
        // 保留 `DynamicColorBuilder` 的意义在于**知道系统有没有动态取色能力**：
        // 结构留着，以后要开"跟随系统主题色"只需要把下面两行换成
        // `AppTheme.light(fromSystem: lightDynamic)`。AppTheme 那条
        // `fromSystem` 通路是完整可用的（M3 的整套 token 都会跟着走）。
        //
        // 放在 MaterialApp **外面**：主题是 MaterialApp 的参数，
        // 取色要先把值拿到才能建主题。
        // ---- 不再跟随系统壁纸取色（Material You）----
        //
        // 界面是**黑白 + 液态玻璃**：颜色来自玻璃背后的东西（模糊、折射、
        // 高光），而不是一组由壁纸推导出来的彩色 token。开着动态色的话，
        // 系统会给一套带紫/绿相位的灰，压在玻璃里会显出脏色 ——
        // 而"黑白"正是这一版的整套语言。
        return MaterialApp(
              title: 'Tinkung',
              // 工具要能"推一整页给用户看"（见 app_nav.dart 的说明）——
              // 最典型的是让用户去浏览器里登录。没有这个键，
              // 工具就只能回一句"请你自己打开浏览器"，而用户不知道该开哪个网址。
              navigatorKey: appNavigatorKey,
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              // 跟随系统暗色模式
              themeMode: ThemeMode.system,
              // 系统栏（状态栏/导航栏）的图标颜色必须随主题走：
              // 深色模式下用浅色图标，否则图标压在纯黑背景上根本看不见。
              builder: (BuildContext context, Widget? child) {
                final Brightness brightness = MediaQuery.platformBrightnessOf(
                  context,
                );
                // 横屏单独倍率必须在子页面构建前写入：AppFonts 是
                // 静态入口，晚一步这一帧就还是旧字号。
                final bool landscape =
                    MediaQuery.of(context).orientation == Orientation.landscape;
                AppFonts.userScale =
                    settings.fontScale *
                    (landscape ? settings.landscapeFontScale : 1.0);
                return AnnotatedRegion<SystemUiOverlayStyle>(
                  value: AppTheme.systemUiFor(brightness),
                  // 垫一层**透明 Material**。
                  //
                  // 抽屉、面板、InkWell 都需要 Material 祖先；没有它，
                  // Text 会渲染出调试用的黄色下划线 —— 界面看起来像坏了。
                  // 这一层只提供祖先，不上色。
                  child: _OrientationSystemUi(
                    child: Material(
                      type: MaterialType.transparency,
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
              },
              // ---- 启动门禁 ----
              //
              // 只有用户在设置里打开了「打开应用需要验证」才会拦。
              // 包在 HomeShell **外面**：让它整个（含抽屉、聊天页）都在
              // 门禁之后，而不是进去之后再盖一层遮罩 —— 后者会有一瞬间
              // 露出真实界面。
              home: _StartupLock(
                settings: settings,
                child: HomeShell(
                  settings: settings,
                  conversations: conversations,
                  plugins: plugins,
                  shizuku: shizuku,
                  workDir: workDir,
                  notes: notes,
                  tasks: tasks,
                ),
              ),
            );
      },
    );
  }
}

/// 竖屏保留系统状态栏；横屏才切到沉浸式。
///
/// 放在 `MaterialApp.builder` 里而不是 `main()`：横竖屏切换时
/// MediaQuery 会重建，这里是唯一能可靠拿到当前 orientation 的地方。
class _OrientationSystemUi extends StatefulWidget {
  const _OrientationSystemUi({required this.child});

  final Widget child;

  @override
  State<_OrientationSystemUi> createState() => _OrientationSystemUiState();
}

class _OrientationSystemUiState extends State<_OrientationSystemUi> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MediaQueryData? mq = MediaQuery.maybeOf(context);
    final bool landscape = mq?.orientation == Orientation.landscape;
    // 不再用 `_lastLandscape == landscape` 短路。
    //
    // 之前竖屏只在"横竖切换"那一刻才申明一次 edgeToEdge，之后再来的
    // 依赖变化（键盘、主题、字号）全被短路掉了。结果是系统栏可能被别的
    // 页面（横屏沉浸、弹层）留下的模式保持住，于是底部小白条区域的
    // 沉浸没了。现在每次依赖变化都重新申明当前方向该用的模式，
    // 代价只是一次轻量的平台调用，换来的是不会再漂。
    SystemChrome.setEnabledSystemUIMode(
      landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    ).then((_) {
      // ⚠️ **这一步不能省。**
      //
      // `setEnabledSystemUIMode(edgeToEdge)` 在 Android 10+ 会把
      // `setNavigationBarContrastEnforced` 重新打开 —— 系统于是在底部
      // 画一条**半透明/白色的遮罩**（就是那颗"小白条"底下的白带），
      // 内容被它挡住，看起来始终没有沉浸。
      //
      // 而 `AnnotatedRegion` 只在**样式值变化**时才下发生效，上面那次
      // 模式切换会把原生侧改回去、Dart 侧却以为没变 —— 于是遮罩又回来了。
      // 所以在切完模式之后，**显式再声明一次**覆盖样式（里面
      // `systemNavigationBarContrastEnforced: false`），把遮罩压掉。
      if (!mounted) return;
      final Brightness brightness =
          mq?.platformBrightness ?? Brightness.light;
      SystemChrome.setSystemUIOverlayStyle(AppTheme.systemUiFor(brightness));
    }).catchError((Object _) {
      // 测试环境没有原生 SystemChrome 通道；这里失败不影响界面。
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 启动门禁：需要验证「打开应用」时才拦。
///
/// ## 为什么是包一层而不是弹窗
///
/// 如果先渲染 HomeShell、再 `showDialog`，第一帧会**露出真实界面**
/// （抽屉、上一个会话的标题都在里面）。包起来之后，没通过验证之前
/// 界面根本不存在。
class _StartupLock extends StatefulWidget {
  const _StartupLock({required this.child, required this.settings});

  final Widget child;

  /// 首次启动的模式选择要写回它（`assistantMode`）。
  final Settings settings;

  @override
  State<_StartupLock> createState() => _StartupLockState();
}

class _StartupLockState extends State<_StartupLock> {
  /// 是否已通过验证。没设密码时直接 true。
  bool _passed = false;

  @override
  void initState() {
    super.initState();
    // 「打开应用」这个范围关着，或者压根没设密码 → 直接放行。
    _passed = !(appLock?.needsUnlock(LockScope.app) ?? false);
    if (_passed) _showWhatsNewOnce();
  }

  void _showWhatsNewOnce() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _maybeShowWhatsNew();
      await _maybeShowAssistantMode();
    });
  }

  /// 首次启动（或还没选过）先让用户选一个**工作方式**。
  ///
  /// 放在新特性页之后：那页是"这个版本变了什么"，这一页是"以后怎么跟我
  /// 合作"。先看懂变化，再决定方式，顺序才自然。
  ///
  /// 判据是 `assistantMode.isEmpty`：老用户升级上来时它也是空串，
  /// 正好补选一次 —— 这比默认成"日常"更诚实，因为三种模式的差别是
  /// 用户能直接感觉到的。
  Future<void> _maybeShowAssistantMode() async {
    if (widget.settings.assistantMode.trim().isNotEmpty) return;
    final NavigatorState? nav = appNavigatorKey.currentState;
    if (nav == null || !nav.mounted) return;
    await nav.push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext _) => AssistantModePage(
          settings: widget.settings,
          firstRun: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_passed) return widget.child;
    return LockScreen(
      scope: LockScope.app,
      // 通过之后不再走 Navigator.pop（这里没有路由栈），
      // 直接就地换成真实界面。
      onUnlocked: () {
        if (mounted) {
          setState(() => _passed = true);
          _showWhatsNewOnce();
        }
      },
    );
  }
}

/// 这次版本的新特性页只出现一次。
///
/// 用 SharedPreferences 而不是设置项：它不是用户可改的偏好，只是
/// “这个版本已经看过”的一次性标记。新版发布时换 key 即可再次出现。
const String _whatsNewSeenKey = 'whats_new_seen_3_0_0';

Future<void> _maybeShowWhatsNew() async {
  final NavigatorState? nav = appNavigatorKey.currentState;
  if (nav == null) return;
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_whatsNewSeenKey) ?? false) return;
  await prefs.setBool(_whatsNewSeenKey, true);
  if (!nav.mounted) return;
  await nav.push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (BuildContext _) => const WhatsNewPage(),
    ),
  );
}
