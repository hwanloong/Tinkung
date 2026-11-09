import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/agent.dart';
import '../ai/input_suggestions.dart';
import '../ai/prompt_improver.dart';
import '../core/background.dart';
import '../core/file_diff.dart';
import '../core/image_compress.dart';
import '../core/linux.dart';
import '../core/metrics.dart';
import '../core/model_profile.dart';
import '../core/folder_tool.dart';
import '../core/mentions.dart';
import '../core/models.dart';
import '../core/overlay.dart';
import '../core/phone_control.dart';
import '../core/productivity.dart';
import '../core/store.dart';
import '../core/termux.dart';
import '../core/terminal_session.dart';
import '../core/text_marks.dart';
import '../core/voice_input.dart';
import '../core/varbank.dart';
import '../plugins/plugin.dart';
import '../shizuku/shizuku_service.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../tools/android_tools.dart';
import '../tools/browser_tool.dart';
import '../tools/device_tools.dart';
import '../tools/folder_tool_tool.dart';
import '../tools/pc_tool.dart';
import '../tools/notify_tool.dart';
import '../tools/obj_tools.dart';
import '../tools/varbank_tool.dart';
import '../tools/writer_tool.dart';
import '../tools/unlock_tool.dart';
import '../tools/plugin_tool.dart';
import '../tools/extra_tools.dart';
import '../tools/image_gen_tool.dart';
import 'terminal_page.dart';
import '../cwt/cwt_hub.dart';
import '../interaction/interaction_hub.dart';
import '../mcp/mcp_store.dart';
import '../tools/cwt_tool.dart';
import '../tools/chat_alarm_tool.dart';
import '../tools/chat_recall_tool.dart';
import '../tools/interaction_tool.dart';
import '../tools/knowledge_tool.dart';
import '../tools/learning_tool.dart';
import '../tools/mcp_admin_tool.dart';
import '../tools/plan_tool.dart';
import '../tools/multibot_tool.dart';
import '../tools/mcp_tool.dart';
import '../tools/memory_tool.dart';
import '../tools/mark_tool.dart';
import '../tools/model_tool.dart';
import '../tools/productivity_tools.dart';
import '../tools/python_tool.dart';
import '../tools/rule_tool.dart';
import '../tools/termux_tool.dart';
import '../tools/ui_tools.dart';
import '../tools/webview_loader.dart';
import '../tools/tool.dart';
import 'browser_page.dart';

import 'deep_research_page.dart';
import 'greeting.dart';
import 'context_compress.dart';
import 'anchored_card.dart';
import 'fullscreen_input_page.dart';
import 'cwt_page.dart';
import 'interaction_panel.dart';
import 'markdown.dart';
import 'mention_input.dart';
import 'models_sheet.dart';
import 'performance_sheet.dart';
import 'productivity_pages.dart';
import 'settings_sheet.dart';
// `ToolIcon` / `kToolIconSize`：`@` 面板要显示工具自己的图标，
// 且尺寸必须和工具列表页一致。
import 'tools_page.dart';
import 'tool_steps.dart';
import 'tool_call_table.dart';
import 'tool_line.dart';
import 'widgets.dart';
import 'image_viewer.dart';
import 'working_pulse.dart';

/// 输入超过这么多字符就**自动存进变量库**，请求里只发引用。
///
/// 2000 字是个经验值：短于它的内容塞进上下文没多大代价（也就一两千 token），
/// 而"随手存成变量"反而增加了用户的认知负担（他得知道那条消息变成了引用）。
/// 超过之后成本开始显著（几千字到几万字），存库的收益才盖过这点负担。
const int kVarBankAutoStoreChars = 2000;

/// 输入框里代表"一段已存进变量库的长文本"的占位标记。
///
/// 用 NUL 包起来，是因为 `\u0000` **不可能**出现在用户正常输入的文本里
/// （输入法、粘贴、语音都不产生它），所以这个记号不会和真实内容混淆。
/// 首尾各一个 NUL，是为了判断"删到了整块"时有明确边界。
const String kVarBankChipToken = '\u0000var\u0000';

/// 给自动存进变量库的内容挑一句说明（note）：取开头一行有内容的文字。
///
/// 只用来在变量列表和消息气泡里做提示，所以**取不到也无所谓** ——
/// 内容本身是完整的，note 只是让人一眼知道"这坨是什么"。
String _previewNote(String text) {
  for (final String raw in text.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty) continue;
    return line.length > 40 ? '${line.substring(0, 40)}…' : line;
  }
  return '';
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.settings,
    required this.conversations,
    required this.plugins,
    required this.shizuku,
    required this.workDir,
    required this.notes,
    required this.tasks,
    this.drawer,
  });

  final Settings settings;
  final ConversationStore conversations;
  final PluginStore plugins;
  final ShizukuService shizuku;
  final String workDir;
  final NoteStore notes;
  final TaskStore tasks;

  /// 侧边菜单。给了它就等于"这一屏是首页"：左上角变成菜单图标（而不是
  /// 返回键），并且从屏幕边缘往内滑能把它拉出来。
  ///
  /// 是从别处 push 上来的对话页（历史、研究页里打开的）**不给**这个参数 ——
  /// 那种情况下用户需要的是"退回上一屏"，不是"去菜单"。
  final Widget? drawer;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final MentionHighlightController _input = MentionHighlightController();
  final ScrollController _scroll = ScrollController();

  /// 输入框**内部**那个滚动条（[TextField] 自己用它滚多行文本）。
  ///
  /// 为什么要把它抓在手里：`EditableText` 只在**用户输入**时把光标滚进
  /// 视野，源码里那句注释写得很清楚 —— *Programmatic changes to
  /// textEditingValue do not trigger the behavior*。而代码里往输入框塞字
  /// 的路径很多（引用片段、语音结果、放回消息、变量库展开……），
  /// 每一条都会让框里出现"后面一大块不显示文字"：
  /// 内容有几屏，滚动位置却停在 0，用户只看到开头几行。
  ///
  /// 拿到这个 controller 之后，凡是**程序化**写入完都能自己把光标对
  /// 回视野（见 [_revealInputCaret]）。
  final ScrollController _inputScroll = ScrollController();

  /// 消息 widget 的复用缓存（见 `_messageList` 里那段说明）。
  ///
  /// 键 = 消息下标 + 渲染签名；值是**上一次构建出来的 widget 实例**。
  /// 内容没变就能原样返回，Flutter 会跳过整棵子树（公式、代码块、图片
  /// 都不会重排）。上限 200 条，超了整体清空 —— 一次滚动回看时会重建，
  /// 但那是可接受的代价，也避免了长期持有旧会话的 widget。
  final Map<String, Widget> _msgCache = <String, Widget>{};

  /// 开始语音识别时输入框里已有的文字。
  ///
  /// 识别结果要**接在它后面**：用户可能先打了半句、再补一句口述。
  /// 每段识别（partial）都整段替换，所以基准必须固定，不能累加。
  String _voiceBase = '';

  /// 当前正在输入的 `@` 引用片段（`@tool:xxx` / `@plugin:xxx`）。
  ///
  /// `null` = 不在引用语境里（不显示补全面板）。
  /// 之所以存在组件状态里而不是每次 build 现算：光标位置在
  /// `TextEditingController` 里，而 `onChanged` 拿不到它 ——
  /// 必须在这一刻读一次并记住，否则面板会跟着光标乱跳。
  ({MentionKind? kind, String query})? _mention;

  /// 待发送的附件（还没发出去）
  final List<Attachment> _pending = <Attachment>[];

  // ---------------------------------------------------------- 输入建议
  //
  // 建议只显示、不自动发送：点一下填进输入框，发不发仍然由用户决定。
  List<String> _suggestions = <String>[];
  bool _suggesting = false;
  Timer? _suggestTimer;
  String _suggestKey = '';
  bool _suggestFromImage = false;

  /// 用户手动关掉了这一轮建议。下一轮 AI 生成结束后自动解除，
  /// 所以"关掉一次"不会永久关闭这个功能。
  bool _suggestDismissed = false;

  // ---------------------------------------------------------- 互动面板
  InteractionSession? _panelSession;
  double _panelHeight = 320;
  StreamSubscription<InteractionSession>? _panelSub;

  // 用户操作 → AI 的实时通道（我点一下、它回一步）
  Timer? _panelReactTimer;
  Timer? _panelReactRetry;
  Map<String, dynamic>? _panelReactEvent;
  InteractionSession? _panelReactSession;
  int _panelReactRetries = 0;

  // ---------------------------------------------------------- 修改选框
  //
  // 用户框选完成后，修改请求先挂在输入框上方（带背景的清单），
  // **发送之后**才真正进对话、AI 才开始改。这样"框选"和"执行"分成两步。
  final List<CwtResult> _pendingCwt = <CwtResult>[];
  StreamSubscription<CwtRequest>? _cwtSub;

  /// 极简模式：输入框上方「过程」折叠条是否展开。
  bool _processOpen = false;
  String? _processFileCache;
  int _processCacheKey = -1;

  /// 横屏导航条里「更多」是否展开（研究 / 浏览器 / 设置）。
  ///
  /// 和抽屉底栏同一个规矩：横屏最缺的是宽度，一排七个入口会把
  /// 新对话/历史挤到要靠横向滚动，而这三项一天用不到一次。
  bool _landscapeMore = false;

  /// 刚发出、正在播放入场动画的用户消息。播完就移出，历史消息永不重播。
  final Set<String> _enteringBubbles = <String>{};

  // （`_fetchingWeb` 已随「从网上」入口一起删除 —— 那个标志只用来在抓取
  //   期间禁用附件面板里的联网项，现在面板里没有联网项了。）

  /// 每个会话各自一个 runner：A 在跑时，B 仍然可以发消息。
  final Map<String, AgentRunner> _runners = <String, AgentRunner>{};
  final Set<String> _busyConvIds = <String>{};

  /// 正在跑**实时互动回合**的会话。
  ///
  /// 这类回合是"用户点一下 → AI 走一步"，消息不进聊天记录、界面不重绘，
  /// 所以通知栏 / 悬浮窗 / 打字动画一概不参与。
  final Set<String> _silentConvIds = <String>{};

  /// 这次任务是否**真的在控制手机**（语义点击、滑动、绘制、am start 等）。
  ///
  /// 悬浮窗只在这种情况下显示：普通任务（写代码、查资料）用户切到后台时，
  /// 界面上没有需要他看的东西，再压一个浮窗纯属打扰。
  bool _phoneControl = false;

  /// **这一轮发送的序号**。每开始一次发送 +1，`_stop()` 也 +1。
  ///
  /// 「描述改进」是个要等一两秒的 await，而它夹在"消息已经显示"和
  /// "agent 开始跑"之间 —— 那段时间里用户能按到的只有停止键。
  /// 用序号比对来判断"这次发送还算不算数"，比加一堆布尔标志稳：
  /// 停止、连点、切会话都只会让序号往前走，不会留下互相矛盾的状态。
  final Map<String, int> _sendSeqByConv = <String, int>{};

  /// 「+」面板上次停在哪个标签页。
  ///
  /// 记在 State 里而不是每次重置为 0：用户连调两次参数是常态，
  /// 每次都弹回第一个标签会让他重新点一遍。

  /// 是否已经滚到底部。用来决定要不要显示「回到底部」按钮。
  bool _atBottom = true;

  /// 消息列表滚离顶部了吗？顶栏据此决定是"同色隐身"还是"模糊 + 加浓"。
  bool _scrolled = false;

  /// 输入框里的长文本**已经存进变量库**时，那个变量叫什么。
  ///
  /// 用户粘一大段内容时，输入框不该显示那几万字 —— 它会把输入区撑很高、
  /// 每敲一个字都重排一遍。所以超过 [kVarBankAutoStoreChars] 之后：
  ///  · 全文立刻存进变量库（[VarBankStore]）；
  ///  · 输入框里只留 [kVarBankChipToken] 这个占位标记；
  ///  · 发送时请求里带的是 `{{名字}}`，不是正文（见 [ChatMessage.varRefs]）。
  ///
  /// 为什么在**输入时**就存、而不是等发送：用户看到的是"输入框变简洁了"，
  /// 这个变化必须发生在他粘贴的那一刻。
  String? _varChipName;

  /// 输入框里那个占位标记的文本形式。首尾各一个 NUL，用来判断整块删除。
  static String varChipToken(String name) => '\u0000$name\u0000';

  /// 顶栏那层背景的淡入淡出。比输入区的形变快一点（200 vs 260）：
  /// 它跟的是滚动这个高频动作，慢了会显得"拖"。
  // ignore: unused_field
  static const Duration _headerFade = Duration(milliseconds: 180);

  /// 输入框那一行里两个圆的直径。
  ///
  /// 42 而不是 46：46 的圆配上原来的内边距时上下只剩 4 像素余量，
  /// 看着像"从框里凸出来"（用户的反馈）。
  /// 42 + 6 的外框内边距 = 四周都留着 10 像素，圆才像**嵌在框里**。
  /// 整行的高度靠文字的内边距撑（见 `_inputField` 的 contentPadding），
  /// 不靠把按钮做大。
  /// 输入框里那颗发送/停止圆的直径。
  ///
  /// **36**：输入框那一行本身只有 40 高，42 的圆在里面是"撑出去"的 ——
  /// 上下各压出 1 像素，整块面板跟着变高。36 配 40 的行高，四周各留 2，
  /// 圆真正"装"在框里，而不是把框顶大。
  static const double _circleInRow = 36;

  /// `@` 补全面板和输入框之间那条缝。
  ///
  /// 这条缝是**两张卡的分界**，不是随手留的空白：贴到 0 的时候面板读起来
  /// 就是"输入框被拉高了一段"（面板以前长在玻璃里，正是这个观感）；
  /// 8 刚好让人一眼看出上面是浮着的一张卡。再宽（14 以上）又会显得它和
  /// 输入框没关系 —— 用户会以为它是消息列表里的一条。
  static const double _mentionGap = 8;

  /// 「全部工具调用」现在是合上的吗（见 [ToolFoldAllRow]）。
  ///
  /// 默认**合上**：agent 跑一件复杂的事会连着调几十次工具，
  /// 展开状态下聊天流会被工具行占满，正文被推到看不见 —— 那正是
  /// 用户要折叠它们的理由。
  ///
  /// 存在 State 里而不是 Settings 里：它是"我想怎么看这一屏"的临时选择，
  /// 和主题、模型那些跨会话的偏好不是一类东西。切走再回来会重新合上，
  /// 这符合直觉（"我上次点开是为了看那一步"）。
  bool _toolsFolded = true;

  /// 横屏左右两栏的分割比例（左栏占可用宽度的比例）。
  double _splitFraction = 0.50;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 横屏顶部横向导航条的高度（聊天消息的 topInset 要加上它）。
  static const double _landscapeNavHeight = 36;

  /// 竖屏顶栏的标题行在**系统状态栏之下**还要留多少（逻辑像素）。
  ///
  /// ## 为什么必须有这一项，而且必须加在 `padding.top` 之上
  ///
  /// 竖屏用的是 `SystemUiMode.edgeToEdge`（见 main.dart 的
  /// `_OrientationSystemUi`）：状态栏**浮在应用上面**，不占布局位置。
  /// 所以 `MediaQuery.padding.top` 正好是状态栏（+ 挖孔）的高度，
  /// 而 `padding.top + 0` 就是"标题行顶端紧贴状态栏下沿"。
  ///
  /// 这一行原来写的是 `topInset + 2`，注释的理由是"系统栏已经由
  /// immersiveSticky 隐藏"—— 那句话在**只有横屏**才隐藏状态栏之后就不成立了：
  /// 竖屏的状态栏回来了，`padding.top` 从 0 变成 24~48，
  /// 而留给标题和状态栏之间的余量还是那 2 像素。用户看到的"顶栏太高了、
  /// 内容贴着状态栏"就是这个 2。
  ///
  /// 8 是 iOS 导航栏的规格（导航栏内容距状态栏 8pt），也正好是
  /// 原来这块还是 `GlassBar` 时的值（`topInset + 8`）。
  ///
  /// 为什么**只用相对量**：`padding.top` 在挖孔/刘海上会更大，
  /// 加常数而不是写死绝对位置，标题才会跟着系统栏一起下移；
  /// 写死"顶栏高 66"在别的机型上不是压住状态栏就是空出一大条。
  ///
  /// 横屏不加（见 [_header]）：横屏是 `immersiveSticky`，状态栏被隐藏
  /// （`padding.top == 0`），顶上紧接着就是横向导航条，它本身就是分界；
  /// 再加 8 会把标题和导航条一起往下推 —— 横屏最缺的就是高度。
  static const double _headerGap = 8;

  @override
  void initState() {
    super.initState();
    // 观察生命周期：进度浮窗只在**应用不在前台**时显示。
    // 前台时界面本身就有进度（工具卡片、转圈），再压一个浮窗是纯噪音。
    WidgetsBinding.instance.addObserver(this);
    widget.settings.addListener(_onExternalChange);
    widget.conversations.addListener(_onExternalChange);
    widget.plugins.addListener(_onExternalChange);
    widget.shizuku.addListener(_onExternalChange);
    InteractionHub.instance.addListener(_onInteractionChanged);
    InteractionHub.instance.onEvent = _onPanelEvent;
    _panelSub = InteractionHub.instance.opens.listen(_onPanelOpen);
    _cwtSub = CwtHub.instance.opens.listen(_onCwtOpen);
    _inputFocus.addListener(_onInputFocus);
    _scroll.addListener(_onScroll);

    // 同 `HomeShell.build` 里的守卫：历史可能是**还在读**（启动初期
    // 列表天然为空），这时候建会话会多出一条空白页。只有 `loaded`
    // 之后才谈得上"一条都没有"。
    if (widget.conversations.loaded &&
        widget.conversations.conversations.isEmpty) {
      widget.conversations.createNew();
    }
    // 探一下两条命令通道。
    //
    // **必须在会话开始前探完**：系统提示词里会写"Linux 环境可用 / 未安装"，
    // 而那句话决定模型会不会想到用 `termux` 工具。
    // 不探的话它默认是"没装"，模型就会以为没有 Linux 可用。
    LinuxService.instance.refresh();
    TermuxService.instance.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 离开页面时一定要收掉浮窗 —— 否则它会一直挂在屏幕上，
    // 而且再也没人能关掉它（那个 State 已经销毁了）
    OverlayService.dismissActivity();
    widget.settings.removeListener(_onExternalChange);
    widget.conversations.removeListener(_onExternalChange);
    widget.plugins.removeListener(_onExternalChange);
    widget.shizuku.removeListener(_onExternalChange);
    InteractionHub.instance.removeListener(_onInteractionChanged);
    InteractionHub.instance.onEvent = null;
    _panelReactTimer?.cancel();
    _panelReactRetry?.cancel();
    _panelSub?.cancel();
    _cwtSub?.cancel();
    _inputFocus.removeListener(_onInputFocus);
    _scroll.removeListener(_onScroll);
    _inputScroll.dispose();
    _suggestTimer?.cancel();
    _cancelUpdateTimers();
    // 离开对话页时如果还在识别，把它停掉：否则麦克风会一直占着。
    unawaited(VoiceInput.cancel());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    // 留点余量，不要求严丝合缝贴底
    final bool atBottom = p.pixels >= p.maxScrollExtent - 48;
    // 顶栏要不要变"实"：只要滚离顶部一点点就算。用 6 而不是 0：
    // 手指微抖、惯性回弹都会让 offset 在 0 附近跳，
    // 阈值太紧会让顶栏在松手瞬间闪一下。
    final bool scrolled = p.pixels > 6;
    if ((atBottom != _atBottom || scrolled != _scrolled) && mounted) {
      setState(() {
        _atBottom = atBottom;
        _scrolled = scrolled;
      });
    }
  }

  void _onExternalChange() {
    if (!mounted) return;
    // 切换会话时把面板同步成"这条聊天自己的那一个"；
    // 没有就收起（不关掉，切回来还能继续）。
    final InteractionSession? active = InteractionHub.instance.forConv(
      _conv.id,
    );
    setState(() {
      if ((active?.id ?? '') != (_panelSession?.id ?? '')) {
        _panelSession = active;
      }
    });
  }

  void _onPanelOpen(InteractionSession s) {
    if (!mounted || s.convId != _conv.id) return;
    setState(() {
      _panelSession = s;
      _panelHeight = 320;
    });
  }

  void _onInteractionChanged() {
    if (!mounted) return;
    final InteractionSession? s = _panelSession;
    if (s != null && s.closed) {
      // ---- 关闭本身就是结束：默认不发任何消息 ----
      //
      // 唯一例外：这类面板**没有**实时回合（`auto_react:false`，比如敲木鱼
      // ——每敲一下都叫一次模型既慢又贵），整场只有关闭这一次机会让 AI
      // 说句话。此时把汇总塞进**工作流**（用户消息不显示），AI 的回复
      // 照常出现在聊天里。
      final String brief = (!s.autoReact && s.closedByUser)
          ? _panelCloseBrief(s)
          : '';
      setState(() => _panelSession = null);
      if (brief.isNotEmpty && !_running(_conv.id)) {
        unawaited(
          _send(
            preset:
                '$brief\n'
                '用户已经关闭了面板。请用一两句话回应/收尾，'
                '不要复述过程，也不要重新打开面板。',
            silentPrompt: true,
          ),
        );
      }
      return;
    }
    final InteractionSession? active = InteractionHub.instance.forConv(
      _conv.id,
    );
    if ((active?.id ?? '') != (_panelSession?.id ?? '')) {
      setState(() => _panelSession = active);
    }
  }

  /// 关闭时的汇总：如果全是同类「敲一下」事件，只报最终计数。
  ///
  /// 敲木鱼敲 80 下就写 80 行 `{event: tap, count: n}` 没有必要 ——
  /// 模型只需要知道"敲了多少下"，剩下的是噪声。
  String _panelCloseBrief(InteractionSession s) {
    if (s.events.isEmpty) return '';
    final List<Map<String, dynamic>> taps = s.events
        .where((Map<String, dynamic> e) => e['event'] == 'tap')
        .toList();
    if (taps.length == s.events.length) {
      final Object? count = s.events.last['count'] ?? taps.length;
      return '用户在「${s.title}」里敲了 $count 下，然后关闭了面板。';
    }
    return InteractionHub.instance.summary(s.id);
  }

  void _closePanel() {
    final InteractionSession? s = _panelSession;
    if (s != null) {
      InteractionHub.instance.close(s.id, byUser: true);
    }
  }

  /// **实时接口**：页面里 `App.send(...)` → hub → 这里 → 一个**静默** AI 回合。
  ///
  /// 「静默」= 不进聊天记录、不重绘聊天区、不弹通知：
  /// 用户看到的效果只有面板上多了一手棋 / 状态变了。
  /// 事件本身是 AI 工作流里的一拍，不是用户发的一条消息。
  ///
  /// 不关闭面板：AI 的 `act` 直接改页面，用户接着点下一步。
  void _onPanelEvent(InteractionSession s, Map<String, dynamic> event) {
    if (!mounted || s.convId != _conv.id || s.closed) return;
    _panelReactSession = s;
    _panelReactEvent = event;
    _panelReactRetries = 0;
    _panelReactTimer?.cancel();
    _panelReactTimer = Timer(const Duration(milliseconds: 260), _runPanelReact);
  }

  void _runPanelReact() {
    final InteractionSession? s = _panelReactSession;
    final Map<String, dynamic>? e = _panelReactEvent;
    if (s == null || e == null || s.closed || !mounted) return;

    if (_running(_conv.id)) {
      // AI 还在上一轮：等它收尾，最多等约 5 秒。
      if (_panelReactRetries++ < 8) {
        _panelReactRetry = Timer(
          const Duration(milliseconds: 700),
          _runPanelReact,
        );
      }
      return;
    }

    _panelReactEvent = null;
    _panelReactRetries = 0;
    // 选择类且"选完就收起"：这是一次**结论**，AI 的回应要留在聊天里。
    // 棋类/自定义页面：纯工作流，AI 只 act，不产生可见消息。
    final bool closeNow =
        s.kind == 'ask' && s.autoCloseOnChoice && e.containsKey('choice');
    final bool visibleReply = closeNow;
    final String text = closeNow
        ? '【互动面板·选择】面板 id=${s.id}（${s.title}）\n'
              '用户选了：${jsonEncode(e)}\n'
              '面板已经收起。请直接按这个选择继续下一步，给出结果；'
              '不要输出"我收到了"这类空话。'
        : '【互动面板·实时】面板 id=${s.id}（${s.title}）\n'
              '用户刚刚：${jsonEncode(e)}\n'
              '这是你的回合：**只调用 interact 的 act**，把这一步的结果写进页面'
              '（落子 / 更新状态 / 给出下一步）。\n'
              '不要输出说明文字；不要 open / play 重新打开面板；不要 close。';
    // 选择类：用户点了选项 = 这一步已经确定，自动收起面板；
    // 游戏/自定义页面保持打开，等用户自己关或明确说结束。
    if (closeNow) InteractionHub.instance.close(s.id);
    s.reactedEvents++;
    unawaited(
      _send(preset: text, silent: !visibleReply, silentPrompt: visibleReply),
    );
  }

  void _resizePanel(double h) {
    final double max = MediaQuery.sizeOf(context).height * 0.55;
    final bool keepBottom = _atBottom;
    setState(() => _panelHeight = h.clamp(44.0, max));
    // 拖面板时如果用户正看到最新消息，就让列表跟着保持在底部，
    // 否则压缩后会出现"被压上去但停在半截"的观感。
    if (keepBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToEnd(force: false);
      });
    }
  }

  Future<void> _onCwtOpen(CwtRequest req) async {
    if (!mounted || req.convId != _conv.id) return;
    final CwtResult? result = await showChangeWhatYouThink(
      context,
      request: req,
      workDir: widget.workDir,
    );
    if (result == null || result.boxes.isEmpty || !mounted) return;
    setState(() {
      _pendingCwt.add(result);
      _suggestions = <String>[];
    });
    _snack('已加入 ${result.boxes.length} 处修改；发送后 AI 才开始改');
  }

  /// 输入框上方的「修改请求」清单：带背景、可整体移除。
  // ---------------------------------------------------------- 极简过程
  //
  // 极简模式下，过程**不画在消息里**，而是输入框上方一条可展开的「过程」：
  //
  //  · 外面只有一句「正在研究如何… / 正在获取…」；
  //  · 点开才看到历史的工具调用和文件改动；
  //  · 回答结束后它不消失，随时能回看。
  //
  // 为什么不放在消息气泡里：一**轮**任务会被拆成多个 assistant 消息
  // （每调一轮工具就多一条），单条消息里的 tools 只是那一轮，拼不出
  // "历史"。这里从整场会话取，才真的是过程全貌。

  /// 当前这一轮从哪条消息开始：上一条**可见用户消息**之后。
  ///
  /// 过程条只展示"这次任务"的历史，不把半年前的 200 次工具调用都翻出来。
  int get _processStart {
    for (int i = _conv.messages.length - 1; i >= 0; i--) {
      final ChatMessage m = _conv.messages[i];
      if (!m.hidden && m.role == Role.user) return i;
    }
    return 0;
  }

  List<ToolInvocation> get _processTools => <ToolInvocation>[
    for (int i = _processStart; i < _conv.messages.length; i++)
      if (!_conv.messages[i].hidden) ..._conv.messages[i].tools,
  ];

  ToolInvocation? get _runningProcessTool {
    for (final ToolInvocation t in _processTools.reversed) {
      if (t.status == InvocationStatus.running) return t;
    }
    return null;
  }

  /// 极简状态行的一句话：只说"在干什么"，不铺参数。
  String _liveProcessLabel(ToolInvocation t) {
    final Map<String, dynamic> a = t.args;
    String? pick(List<String> keys) {
      for (final String k in keys) {
        final dynamic v = a[k];
        if (v == null) continue;
        final String text = v.toString().trim();
        if (text.isNotEmpty) return text;
      }
      return null;
    }

    final String? raw = pick(<String>[
      'query',
      'url',
      'path',
      'command',
      'prompt',
      'title',
      'package',
      'id',
    ]);
    final String short = raw == null
        ? ''
        : (raw.length > 22 ? raw.substring(0, 22) : raw);

    switch (t.name) {
      case 'web':
        final String action = a['action']?.toString() ?? '';
        if (short.isEmpty) return '正在获取资料';
        return action == 'search' ? '正在搜索「$short」' : '正在获取「$short」';
      case 'browser':
        return short.isEmpty ? '正在打开网页' : '正在打开「$short」';
      case 'read_image':
      case 'open_file':
      case 'file_op':
      case 'pc':
        return short.isEmpty ? '正在获取文件' : '正在获取「$short」';
      case 'knowledge':
        return '正在研究如何从知识库找答案';
      case 'change_think':
        return short.isEmpty ? '正在研究如何修改文件' : '正在研究如何修改「$short」';
      case 'python':
      case 'termux':
      case 'run_shell':
        return short.isEmpty ? '正在研究如何执行' : '正在研究如何完成「$short」';
      case 'generate_image':
        return short.isEmpty ? '正在生成' : '正在生成「$short」';
      case 'ui_action':
      case 'app_manage':
      case 'system_settings':
      case 'screen_capture':
      case 'get_location':
      case 'draw_path':
        return '正在研究如何操作手机';
      default:
        final (IconData _, String name) = ToolDisplay.of(t.name);
        return short.isEmpty ? '正在研究如何「$name」' : '正在研究如何「$name」：$short';
    }
  }

  /// 整场会话里出现过的文件路径文本（只在展开时才算，避免流式输出时每帧扫）。
  String get _processFileText {
    final int start = _processStart;
    int key = start * 131;
    for (int i = start; i < _conv.messages.length; i++) {
      final ChatMessage m = _conv.messages[i];
      key += m.content.length + m.tools.length * 31;
    }
    final String? cached = _processFileCache;
    if (cached != null && key == _processCacheKey) return cached;

    final List<String> parts = <String>[];
    for (int i = start; i < _conv.messages.length; i++) {
      final ChatMessage m = _conv.messages[i];
      if (m.hidden) continue;
      if (m.content.trim().isNotEmpty) parts.add(m.content);
      for (final ToolInvocation t in m.tools) {
        parts.add(t.argumentsJson);
        final String out = t.output ?? '';
        if (out.trim().isNotEmpty) {
          parts.add(out.length > 3000 ? out.substring(0, 3000) : out);
        }
      }
    }
    final String text = parts.join('\n');
    _processFileCache = text;
    _processCacheKey = key;
    return text;
  }

  List<FileChange> get _processChanges => <FileChange>[
    for (final ToolInvocation t in _processTools) ...t.changes,
  ];

  /// 极简过程：**气泡下面一行字**，没有卡片、没有背景。
  ///
  /// 位置见 `_messageList`：挂在最后一条用户消息之后、AI 正文之前，也就是
  /// “气泡下边、AI 原文顶部左边”。默认只有一句「正在研究如何… / 正在获取…」；
  /// 点开才显示这一轮的全部工具调用和文件修改，而且内容在固定高度里滚动，
  /// 不会再把聊天页顶走。
  Widget _minimalProcessRow(AppSurface s) {
    final List<ToolInvocation> tools = _processTools;
    final ToolInvocation? running = _runningProcessTool;
    final bool busy = _busyFor(_conv);
    final bool hasHistory = tools.isNotEmpty;
    if (!hasHistory && !busy) return const SizedBox.shrink();

    final bool expanded = _processOpen && hasHistory;
    final double bodyCap = math.min(
      240.0,
      MediaQuery.sizeOf(context).height * 0.28,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasHistory
                ? () => setState(() => _processOpen = !_processOpen)
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  if (running != null || busy)
                    // 和上面静止时的 `timeline_rounded` 同形同尺寸：
                    // 状态在"进行中/已完成"之间切换时，图标不跳。
                    WorkingPulse(
                      size: 14,
                      icon: Icons.timeline_rounded,
                      color: s.muted,
                    )
                  else
                    Icon(Icons.timeline_rounded, size: 14, color: s.muted),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      running != null
                          ? _liveProcessLabel(running)
                          : busy
                          ? (hasHistory ? '正在研究下一步' : '正在研究如何回答')
                          : '过程 · ${tools.length} 步',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 12,
                        color: s.muted,
                        height: 1.3,
                      ),
                    ),
                  ),
                  if (hasHistory) ...<Widget>[
                    const SizedBox(width: 2),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: s.muted,
                    ),
                  ],
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            alignment: Alignment.topCenter,
            child: !expanded
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(left: 19, top: 2, bottom: 4),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: bodyCap),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            ToolStepGroup(tools: tools, collapse: false),
                            GeneratedFiles(
                              text: _processFileText,
                              live: running != null,
                              plain: true,
                              changes: _processChanges,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _cwtStrip(AppSurface s) {
    final int total = _pendingCwt.fold<int>(
      0,
      (int n, CwtResult r) => n + r.boxes.length,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
      decoration: BoxDecoration(
        // 不透明底色：这块挂在输入框上方，用半透明会和后面的聊天内容糊在一起，
        // 看起来像"没有背景"。混合一个 accent 底色，但仍然是不透明色。
        color: Color.alphaBlend(
          AppColors.accent.withValues(alpha: 0.13),
          s.surface,
        ),
        borderRadius: BorderRadius.circular(AppRadius.field),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: 0.38),
          width: 0.9,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.crop_free_rounded, size: 15, color: AppColors.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'ChangeWhatYouThink · $total 处修改',
                  style: AppFonts.body(
                    size: 12,
                    weight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 15),
                tooltip: '移除修改请求',
                color: s.muted,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(_pendingCwt.clear),
              ),
            ],
          ),
          for (final CwtResult r in _pendingCwt)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '《${r.path.split(RegExp(r'[/\\]')).last}》'
                '${r.boxes.map((CwtBox b) => b.description).join('；')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 11, color: s.text, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  /// 最近一次的"正在干什么"文案。
  /// 切到后台时要立刻显示浮窗，那时得有个已知的文案可用，
  /// 不能等下一次 onUpdate（可能还要几秒）。
  String _lastActivity = '正在工作';

  /// 应用是否在前台。
  ///
  /// 浮窗的显示条件就是它 —— **应用内绝不显示浮窗**：
  /// 界面上本来就有进度（工具卡片、转圈），再压一个浮窗是纯视觉噪音。
  bool _appInForeground = true;

  /// 应用前后台切换。
  ///
  /// ⚠️ **判断必须只看 paused / hidden，不能用 `state == resumed`。**
  ///
  /// `AppLifecycleState` 有五档，中间那个 `inactive` 很容易被忽略：
  /// 拉下通知栏、弹系统对话框、权限提示、分屏 —— 这些都会进 `inactive`，
  /// **而应用仍然可见**。把 `!resumed` 当后台，就会出现
  /// "拉一下通知栏，浮窗冒出来了"。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;

    final bool background =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;

    _appInForeground = !background;

    if (background && _busyConvIds.isNotEmpty && _phoneControl) {
      // 真的切出去了且正在干活 → 才显示浮窗
      OverlayService.showActivity(_lastActivity);
    } else if (!background) {
      // resumed 和 inactive 都收起 —— inactive 时应用还看得见，
      // 界面上的进度已经够了
      OverlayService.hideActivity();
    }
  }

  Conversation get _conv {
    final Conversation? c = widget.conversations.current;
    if (c != null) return c;
    return widget.conversations.createNew();
  }

  // ------------------------------------------------------------------ 工具表

  ToolRegistry _buildRegistry() {
    final ToolRegistry r = ToolRegistry();

    // 需要 shell 的工具只在 Shizuku 就绪时注册。
    // 未就绪时注册它们只会让模型反复调用然后拿到一堆「无法执行」，
    // 白白浪费轮次，还会让用户以为整个应用不能用。
    if (widget.shizuku.ready) {
      r.registerAll(<AgentTool>[
        const ShellTool(),
        const AppManagerTool(),
        const FileTool(),
        const SettingsTool(),
        const CaptureTool(),
      ]);
    }

    // 这两个不依赖 Shizuku，任何情况下都可直接用
    r.registerAll(<AgentTool>[
      const WebTool(),
      const BrowserTool(),
      const ImageTool(),
      // 手机控制：控件树 / 语义动作 / 连续绘制。依赖无障碍服务，
      // 但**无条件注册** —— 没开时工具会返回一句可执行的开启提示，
      // 比"工具根本不存在、模型以为做不到"清楚。
      const UiTreeTool(),
      const UiActionTool(),
      const DrawPathTool(),
      // 笔记与任务：agent 要能真的写进去，"记一下""提醒我"才有意义
      const NotesTool(),
      const TasksTool(),
    ]);

    // 生图：**无条件注册**。
    //
    // 这里原来还要求"当前模型档案上开了对应开关"，那是个**错位的判断**：
    // 这个工具发的请求**根本不用当前对话模型** —— 它走的是设置里
    // 单独填的「生图模型名」，配上当前档案的地址和密钥
    // （一个中转站常常是"一条档案、多个模型"）。也就是说对话模型能不能
    // 画图，和这件事毫无关系，那个开关从诞生起就拦错了东西。
    //
    // 而这个错位有一个很具体的后果：**中转站批量导入进来的档案，
    // 工具集是显式的空数组**（见 relay_import_page），于是用户平时
    // 聊天用的那些模型一个都没有 `generate_image` —— 说"画一张图"，
    // 模型回一句"我没有这个能力"，而设置里的「生图模型名」填了也白填。
    // （用户反馈的原话就是"图片生成没做成 ai 能调用的工具"。）
    //
    // 没配生图模型时，工具会返回一句"去设置里填模型名" —— 那是**有用**
    // 的信息；而工具不存在时，模型只能回"我不会"，用户永远不知道该去
    // 哪里配置。和 Python / Linux 那两处同一个取舍：
    // 把失败藏起来比失败本身更糟。
    r.register(const ImageGenTool());

    // 打开文件 / 定位：无条件的本地能力。
    //
    // 不需要"能力开关"：它们不产生费用、不改任何状态，
    // 而且"打开生成的文件"是**唯一**让用户看到那些文件的途径
    // （它们在应用私有目录里，文件管理器看不到）。
    // 定位在首次调用时才弹权限，用户拒绝后工具会给出可操作的提示。
    r.register(const OpenFileTool());
    r.register(const LocationTool());

    // **插件管理**：让 agent 能看、能改自己的工具集。
    //
    // 插件本身是"用一条 shell/HTTP 模板新增一个工具"，所以这个工具
    // 实际是让模型**给自己扩能力**。无条件注册 —— 没有它的时候
    // 用户说"帮我加个查快递的工具"是没人接的。
    r.register(const PluginManageTool());

    // **文件夹工具（Tool）**：成套的做法，按需读取。
    // 只注册一个入口，不把每个 Tool 都注册成工具 ——
    // 见 LoadToolTool 的注释（工具列表越长，模型选错越多）。
    r.register(const FolderToolTool());

    // **电脑控制**：和电脑上的 `pc_agent.exe` 通信（exec / read / write / ls）。
    //
    // 无条件注册。没连过时它会明确说"先在电脑上跑 exe，然后 connect"，
    // 那是有用的下一步；而工具不存在时模型只会说"我碰不到电脑" ——
    // 那是错的，用户手里就有那个 exe。
    r.register(const PcTool());

    // **密码工具**：模型判断某一步危险时，请用户亲自验证一次
    //（密码 / 指纹 / 面部）。真正的强制在权限系统，这一条是"让用户
    // 看见模型要干什么"的协作式保险。
    r.register(const UnlockTool());

    // **提醒用户**：模型在后台完成任务时通知人（含红点）。
    r.register(const NotifyTool());

    // **风险告示**：在回复下面挂一条警告（医疗 / 法律 / 财务 / 安全）。
    //
    // 无条件注册。它不做任何实际操作，只是给界面一个"这里要警告"的
    // 信号；注册条件不该让它变得时有时无 —— 模型看到工具不在，
    // 就会老老实实地把警告写进正文，那正是"容易被漏看"的那种写法。
    r.register(const ChatAlarmTool());

    // Linux 环境（`termux` 工具）的注册条件。
    //
    // ## 为什么"有内置环境就注册"而不是"装好了才注册"
    //
    // 这里原来只在 Termux 可用时才注册，于是**内置的 Alpine 装好之后
    // 模型也不知道有这个工具** —— 用户问"装个 ffmpeg"，模型会说做不到。
    // （用户反馈的原话就是"ai 不知道有 termux 在里面"。）
    //
    // 现在只要**平台支持内置环境**就注册：真没装的话工具会返回一句
    // "让用户去设置里点一下安装"，那是有用的信息；
    // 而工具**不存在**时模型只会说"我没有这个能力" —— 那是错的。
    //
    // 和下面 Python 那处同一个取舍：把失败藏起来比失败本身更糟。
    if (TermuxService.instance.canAttempt || LinuxService.instance.supported) {
      r.register(const TermuxTool());
    }

    // 内嵌 Python 是**应用自带**的，**无条件注册**。
    //
    // 这里原来写成"可用时才注册"，结果是个很糟的失败模式：
    // Python 起不来 → 工具从注册表消失 → agent 压根不知道有这东西
    // → 用户看到的是"agent 引用不了 python"，**完全看不到真正的原因**。
    //
    // 把失败藏起来比失败本身更糟。现在无条件注册，
    // 真出问题时工具会返回明确的错误信息，用户和模型都能看到。
    r.register(const PythonTool());

    // 自定义规则：让 agent 能把用户的长期偏好**落成真实规则**，
    // 而不是嘴上说"记住了"下一轮就忘。所有写操作都会被风险分级
    // 拦下并要求用户确认。
    r.register(const RuleTool());

    // 长期记忆。和 RuleTool 同一个理由：让 agent 自己判断什么值得记，
    // 而不是让用户去设置页手填。
    r.register(const MemoryTool());

    // 自学习：agent 把走过的弯路 / 犯过的错 / 学到的技能写成自己的
    // 操作笔记。用户只能看和删 —— 所以它必须一直由 agent 自己维护。
    r.register(const LearnTool());

    // 计划树：多步任务先拆节点、再逐节点推进。
    // 计划本身存在 workDir/plans/<convId>.json，提示词每轮都会带上。
    r.register(const PlanTool());

    // 子智能体（multibot）：主模型派出几件独立的活并行干，结论回收。
    // 子智能体的工具表里会自动去掉它自己，防止套娃（见 AgentRunner）。
    r.register(const MultibotTool());

    // 知识库：真 RAG 检索。用户导入的文档先切片入库，需要时只召回
    // 相关片段（带出处），不把整库塞进上下文。
    r.register(const KnowledgeTool());

    // 互动面板：需要问清楚 / 做选择 / 一起进行活动时，让 AI 打开一页
    // 可交互的 HTML；用户操作会回传给它，关闭时还会自动带摘要继续。
    r.register(const InteractionTool());

    // ChangeWhatYouThink：修改文件的"某一块"时，让用户在原文件上框选。
    // 工具只负责打开选框页；用户发送修改清单之后 AI 才真正改。
    r.register(const ChangeWhatYouThinkTool());

    // MCP：用户在设置里接的远程服务器，把它们的工具**原样**挂进来。
    // 用缓存的那一份（上一次成功发现的），所以离线也不会少工具；
    // 调用时如果服务器不在，会由工具自己报错。
    //
    // 名单本身的增删另有一个 `mcp_admin` 工具：模型看到一堆 `mcp_xxx`
    // 不会想到"还能加一台"，而 `mcp_admin` 的名字和说明里都写明了。
    if (McpStore.maybeInstance != null) {
      r.register(const McpAdminTool());
    }
    for (final McpServer server
        in McpStore.maybeInstance?.enabledServers ?? const <McpServer>[]) {
      for (final McpToolInfo info in server.tools) {
        // 极端情况下和内置/插件重名（比如用户把服务器起名叫 mcp_…）
        // 也不覆盖：先注册的赢，避免工具表里出现两个同名函数。
        if (r.byName(info.exposedName) != null) continue;
        r.register(McpTool(server: server, info: info));
      }
    }

    // **系统层能力**：找文件 / 读文件 / 跑脚本 / 对象池。
    //
    // 这四个是一组，解决同一个问题：大内容经不经过模型的嘴。
    // 以前模型只能 `file_op read` 把整个文件塞进上下文（还被截到 12k），
    // 或者把大内容拼进 shell 命令（撞 ARG_MAX）。有了对象池之后，
    // 大内容只以 `obj://a` 的句柄进上下文，正文按需取。
    //
    // **无条件注册**：它们不碰系统权限（除了 sheller 走终端通道，
    // 那条由 TerminalSession 自己判断可不可用），而且"工具不存在"
    // 会让模型误以为做不到 —— 比"存在但报错"糟糕得多。
    r.registerAll(<AgentTool>[
      const FileSearchTool(),
      const ReaderTool(),
      const WriterTool(),
      const ShellerTool(),
      const GeterTool(),
      // 变量库：和对象池并列，但管的是**长期的、有名字的**语料。
      // 用户说"把这段存起来，以后引用"时用它；模型自己为省 token 搬
      // 一次输出用 `geter`。两者都不碰系统权限。
      const VarBankTool(),
    ]);

    // 标记原文：让模型能把它自己回答里的重点标出来。
    // 只改对话里的显示数据，没有任何副作用，所以无条件注册。
    r.register(const MarkTool());

    // 跨聊天记忆：只读检索**其他对话**。关掉开关就不注册 —— 模型看不到
    // 这个能力，也就不会去调一个注定被拒绝的工具。
    if (widget.settings.crossChatMemory) {
      r.register(const ChatRecallTool());
    }

    // 模型管理：让 agent 能按用户要求新增/修改/切换模型和思考深度。
    // 除 list 外都会被风险分级拦下并要求确认。
    r.register(const ModelManagerTool());

    for (final PluginTool t in widget.plugins.enabledTools()) {
      if (r.byName(t.name) != null) continue;
      if (!widget.shizuku.ready && t.plugin.kind == PluginKind.shell) continue;
      r.register(t);
    }

    // 档案白名单。内置免费档只拿到基础工具，shell / Termux / 浏览器
    // 等高权限能力不会出现在模型看到的工具表里。
    final List<String>? allow = widget.settings.activeProfile?.toolAllowlist;
    if (allow != null) {
      r.retainWhere((AgentTool t) => allow.contains(t.name));
    }

    return r;
  }

  // ------------------------------------------------------------------ 附件

  /// 单个附件的体积上限。
  ///
  /// 超过这个数就直接拒绝并说明原因，而不是硬着头皮复制：
  /// 一个 2GB 的视频复制到应用私有目录既慢又几乎肯定写不下，
  /// 中途失败还会留下半个文件。
  ///
  /// **50 MB**（用户指定）：再大的文件在应用私有目录里复制一份、
  /// 发送时再 base64 内联进请求，光这一项就会让内存和流量爆掉。
  static const int maxAttachmentBytes = 50 * 1024 * 1024; // 50 MB

  /// 图片压缩后的上限。和 `ImageDataCache` 的单张 12 MB 发送上限对齐：
  /// 压完还超过这个数，说明压缩没生效（少见格式），发出去也只会被跳过。
  static const int maxImageBytes = 12 * 1024 * 1024; // 12 MB

  Future<Attachment?> _persist(XFile x, {required AttachmentKind kind}) async {
    // 写了一半失败时用来清理的路径（见下面的 catch）。
    String? created;
    try {
      // 先看大小再动手：省掉一次注定失败的整份复制。
      int declared = 0;
      try {
        declared = await x.length();
      } catch (_) {
        // 拿不到长度就算了，下面按实际写入的字节数兜底。
      }
      if (declared > maxAttachmentBytes) {
        _snack(
          '「${x.name}」太大（${(declared / 1024 / 1024).round()} MB），'
          '单个附件上限 ${maxAttachmentBytes ~/ (1024 * 1024)} MB',
        );
        return null;
      }
      if (kind == AttachmentKind.image &&
          declared > ImageCompressor.skipAboveBytes) {
        _snack(
          '「${x.name}」这张图太大（${(declared / 1024 / 1024).round()} MB），'
          '换一张小一点的，或先压缩再上传',
        );
        return null;
      }

      final Directory dir = Directory('${widget.workDir}/attachments');
      await dir.create(recursive: true);

      final String rawName = x.name.isEmpty ? 'file' : x.name;
      final String ext = rawName.contains('.')
          ? rawName.split('.').last
          : (kind == AttachmentKind.image ? 'jpg' : 'dat');
      String path = '${dir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext';
      created = path;
      // ---- 流式拷贝，绝不把整个文件读进内存 ----
      //
      // 原来这里是 `await x.readAsBytes()` 再 `writeAsBytes`：一个 20MB 的
      // 视频就把 20MB 举在堆上，多选十个文件时 GC 来不及回收 ——
      // 在低内存机型上直接 OOM 闪退（用户报的"多文件上传会闪退"）。
      //
      // 这里用 `addStream` 而不是 `for (chunk) sink.add(chunk)`：
      // `add` 只是入队、不等磁盘写完，读得比写得快时队列会一直涨；
      // `addStream` 有背压，磁盘慢就暂停读，堆占用始终只有几十 KB 的块。
      int size = 0;
      bool tooBig = false;
      final IOSink sink = File(path).openWrite();
      try {
        final Stream<List<int>> limited = x.openRead().transform(
          StreamTransformer<Uint8List, List<int>>.fromHandlers(
            handleData: (Uint8List chunk, EventSink<List<int>> out) {
              size += chunk.length;
              if (size > maxAttachmentBytes) {
                // 声明大小不可信（有的 content:// 给 0）时在这里兜住。
                tooBig = true;
                out.close();
                return;
              }
              out.add(chunk);
            },
          ),
        );
        await sink.addStream(limited);
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (tooBig) {
        try {
          await File(path).delete();
        } catch (_) {}
        _snack('「$rawName」超过单个附件上限，已取消');
        return null;
      }

      // ---- 图片：落盘就压一次 ----
      //
      // 详见 `ImageCompressor`：发送时再解码原图会把"多选大图"变成
      // 一串几百 MB 的位图分配，那是闪退的主因。这里逐张、按目标尺寸
      // 解码（内存和原图大小无关），压完再返回。
      //
      // 串行是刻意的：`_addPicked` 本来就是一张一张处理，压缩也一张一张来，
      // 峰值内存始终只有一张缩略图。
      if (kind == AttachmentKind.image) {
        final ImageShrink shrunk = await ImageCompressor.shrinkInPlace(path);
        // 压成功时可能是新的 `.jpg` 路径（原文件已被删）。
        path = shrunk.path;
        created = path;
        size = shrunk.size;
        if (size > maxImageBytes) {
          try {
            await File(path).delete();
          } catch (_) {}
          _snack(
            '「$rawName」压缩后仍有 ${(size / 1024 / 1024).round()} MB，'
            '超过图片上限 ${maxImageBytes ~/ (1024 * 1024)} MB',
          );
          return null;
        }
      }

      return Attachment(kind: kind, path: path, name: rawName, size: size);
    } catch (e) {
      // 流式复制中途失败会留下半个文件，清掉；否则用户每失败一次
      // 就多占一份磁盘，而且它永远不会被用到。
      if (created != null) {
        try {
          await File(created).delete();
        } catch (_) {}
      }
      _snack('保存附件失败：$e');
      return null;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      // 相册**支持多选**（用户要求批量上传）；拍照只能一张一张来。
      List<XFile> picked = const <XFile>[];
      if (source == ImageSource.gallery) {
        // 不在 picker 里做 `imageQuality` 压缩：那会让它把每张图
        // **解码成位图再重编码**，多选十几张大图时这一步自身就会 OOM。
        // 压缩交给上传前那一步（`ImageCompressor`，长边 1600），
        // 那里是逐张、有上限地做。
        //
        // `limit` 让系统相册**自己**限制可选数量：不设的话用户能框选
        // 几百张，插件在返回结果前就要处理整批 —— 还没轮到我们的
        // 防抖逻辑，进程已经先被拖垮了。
        picked = await ImagePicker().pickMultiImage(limit: maxPickAtOnce);
      } else {
        // 拍照也不在 picker 里压：`imageQuality` 会让插件先把整张照片
        // 解码成位图再重编码，高像素机型上这一步自身就可能 OOM。
        // 交给 `ImageCompressor` 按目标尺寸解码，峰值内存小一个数量级。
        final XFile? one = await ImagePicker().pickImage(source: source);
        if (one != null) picked = <XFile>[one];
      }
      await _addPicked(picked, kind: AttachmentKind.image);
    } catch (e) {
      _snack('选取图片失败：$e');
    }
  }

  Future<void> _pickFile() async {
    try {
      // 文件同样多选：`openFiles` 允许一次框选多个。
      final List<XFile> picked = await openFiles();
      await _addPicked(picked);
    } catch (e) {
      _snack('选取文件失败：$e');
    }
  }

  /// 把一次选中的多个文件**逐个落盘并挂到输入框上方**。
  ///
  /// 为什么不并行：`_persist` 的命名靠 `microsecondsSinceEpoch`，
  /// 并发写同一个目录有小概率撞名；而且写盘、刷新界面都需要按顺序来，
  /// 一次把几十个文件同时处理只会把主 isolate 卡住。
  ///
  /// 图片解析建议只对**第一张**触发：那是"这条消息在问什么"的提示，
  /// 十张图各跑一次视觉模型既慢又费钱。
  ///
  /// ## 单次上限
  ///
  /// 一次最多处理 [maxPickAtOnce] 个。不是性能考虑，而是**防闪退**：
  /// 有的相册/文件应用一次能框选上百个，逐个复制到缓存目录要走很多次
  /// 磁盘 IO 和大文件流 —— 极低内存的机器上仍可能被系统杀掉。
  /// 超出的部分不静默丢弃，而是明确告诉用户"只加了前 N 个"。
  ///
  /// **10**（用户指定）：这个数同时是"一次框选的上限"和"待发附件的
  /// 总数上限"（见 [_addPicked]）。10 个附件配上 50 MB 的单文件上限，
  /// 最坏情况是 500 MB 待发内容 —— 已经在内存和磁盘的安全边界内。
  static const int maxPickAtOnce = 10;

  /// 待发附件的**总字节**上限。单个文件有 [maxAttachmentBytes] 兜着，
  /// 但 50 个 500 MB 的视频能把手机磁盘写满 —— 磁盘满时系统会杀进程，
  /// 表现和"闪退"一模一样。这里留 1.5 GB 余量。
  static const int maxPendingBytes = 1536 * 1024 * 1024;

  Future<void> _addPicked(List<XFile> files, {AttachmentKind? kind}) async {
    if (files.isEmpty) return;

    List<XFile> todo = files;
    // 上限针对**总待发数**：用户可能分几次选，累积到几十张同样会吃光内存。
    final int room = maxPickAtOnce - _pending.length;
    if (room <= 0) {
      _snack('待发附件已达上限 $maxPickAtOnce 个，先发出去或删掉一些');
      return;
    }
    if (files.length > room) {
      todo = files.take(room).toList();
      _snack('一次最多 $maxPickAtOnce 个附件，先加前 ${todo.length} 个');
    }

    int ok = 0;
    int failed = 0;
    bool suggested = false;
    int pendingBytes = _pending.fold<int>(
      0,
      (int sum, Attachment a) => sum + a.size,
    );
    for (final XFile x in todo) {
      if (pendingBytes >= maxPendingBytes) {
        _snack(
          '待发附件总大小已达 ${maxPendingBytes ~/ (1024 * 1024)} MB 上限，'
          '先发出去或删掉一些',
        );
        break;
      }
      final bool isImage =
          kind == AttachmentKind.image || _looksLikeImage(x.name);
      final Attachment? a = await _persist(
        x,
        kind: isImage ? AttachmentKind.image : AttachmentKind.file,
      );
      if (a == null) {
        failed++;
        continue;
      }
      if (!mounted) return;
      ok++;
      pendingBytes += a.size;
      setState(() => _pending.add(a));
      if (isImage && !suggested) {
        suggested = true;
        unawaited(_loadImageSuggestions(a));
      }
      // 每处理完一个就让出一次事件循环：压缩/写盘之后堆上会留下临时
      // 缓冲，连续 20+ 个不给 GC 喘息的机会，低内存机型仍可能被杀。
      await Future<void>.delayed(Duration.zero);
    }
    if (ok > 1) _snack('已添加 $ok 个附件');
    if (failed > 0 && ok == 0) {
      _snack('添加失败 $failed 个，可能是文件太大或没有存储权限');
    }
  }

  /// 按扩展名判断是不是图片（`openFiles` 不带 MIME，只能看名字）。
  static bool _looksLikeImage(String name) {
    final String lower = name.toLowerCase();
    return <String>[
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
    ].any((String e) => lower.endsWith('.$e'));
  }

  // ------------------------------------------------------------------ 输入建议

  /// 给「图片解析 / 上下文揣测」用的工具上下文。
  ToolContext _suggestCtx(Conversation conv) => ToolContext(
    settings: widget.settings,
    shizuku: widget.shizuku,
    conversation: conv,
    workDir: widget.workDir,
    searchApiKey: widget.settings.searchApiKey,
    visionBaseUrl: widget.settings.visionBaseUrl,
    visionApiKey: widget.settings.visionApiKey,
    visionModel: widget.settings.visionModel,
    mainApiKey: widget.settings.apiKey,
    mainBaseUrl: widget.settings.baseUrl,
    mainModel: widget.settings.model,
    modelSeesImages: widget.settings.modelSeesImages,
    modelGeneratesImages: widget.settings.modelGeneratesImages,
    imageGen: widget.settings.imageGenConfig,
    searchEngine: widget.settings.searchEngine,
    webSearchMode: widget.settings.webSearchMode,
    selfHostedSearchUrl: widget.settings.selfHostedSearchUrl,
    notes: widget.notes,
    tasks: widget.tasks,
    plugins: widget.plugins,
  );

  /// 图片一挂上来就先解析，再给建议 —— 不是固定的四句话。
  Future<void> _loadImageSuggestions(Attachment a) async {
    if (!widget.settings.inputSuggestEnabled || _suggestDismissed) return;
    setState(() {
      _suggesting = true;
      _suggestions = <String>[];
      _suggestFromImage = true;
    });
    final List<String> list = await InputSuggestionService.forImage(
      ctx: _suggestCtx(_conv),
      image: a,
    );
    if (!mounted || _pending.isEmpty || _suggestDismissed) return;
    setState(() {
      _suggesting = false;
      _suggestions = list;
      _suggestKey = '';
    });
  }

  void _onInputFocus() {
    if (_inputFocus.hasFocus) _scheduleSuggestions();
  }

  void _scheduleSuggestions() {
    _suggestTimer?.cancel();
    if (!widget.settings.inputSuggestEnabled || _suggestDismissed) {
      if (_suggestions.isNotEmpty || _suggesting) {
        setState(() {
          _suggestions = <String>[];
          _suggesting = false;
          _suggestFromImage = false;
        });
      }
      return;
    }
    final Conversation conv = _conv;
    final String q = _input.text.trim();
    // 已经写很长了就不要再猜"你想说什么"；忙碌时也不打扰。
    if (q.length > 12 || _busyFor(conv)) {
      if (_suggestions.isNotEmpty && !_suggestFromImage) {
        setState(() => _suggestions = <String>[]);
      }
      return;
    }
    final String key = '${conv.id}|${conv.messages.length}|$q';
    if (key == _suggestKey && _suggestions.isNotEmpty) return;
    _suggestTimer = Timer(const Duration(milliseconds: 900), () {
      unawaited(_loadContextSuggestions(conv, key));
    });
  }

  Future<void> _loadContextSuggestions(Conversation conv, String key) async {
    if (!mounted || !widget.settings.inputSuggestEnabled) return;
    if (_busyFor(conv)) return;
    setState(() => _suggesting = true);
    final List<String> list = await InputSuggestionService.forContext(
      settings: widget.settings,
      messages: conv.messages,
      effort: widget.settings.inputSuggestEffort,
      profileId: widget.settings.inputSuggestProfileId,
    );
    if (!mounted || _conv.id != conv.id || _suggestDismissed) return;
    setState(() {
      _suggesting = false;
      _suggestKey = key;
      _suggestions = list;
      _suggestFromImage = false;
    });
  }

  void _applySuggestion(String text) {
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
    _revealInputCaret();
    _inputFocus.requestFocus();
    setState(() {
      _suggestions = <String>[];
    });
  }

  /// 输入框上方的建议条。只显示，不自动发送。
  Widget _suggestBar(AppSurface s) {
    final List<String> items = _suggestions.length > 3
        ? _suggestions.sublist(0, 3)
        : _suggestions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.auto_awesome_rounded,
                size: 13,
                color: AppColors.accent,
              ),
              const SizedBox(width: 6),
              Text(
                _suggestFromImage ? '图片建议' : '你可能想说',
                style: AppFonts.body(
                  size: 11,
                  weight: FontWeight.w600,
                  color: s.muted,
                ),
              ),
              if (_suggesting) ...<Widget>[
                const SizedBox(width: 8),
                // 和左边 `auto_awesome_rounded` 同形同尺寸，亮着就表示还在生成。
                WorkingPulse(
                  size: 13,
                  icon: Icons.auto_awesome_rounded,
                  color: AppColors.accent,
                ),
              ],
              const Spacer(),
              // 手动关闭：只关掉**这一轮**的建议；下一次 AI 回答结束后
              // 用户再输入，会重新出现（见 _send 的 finally）。
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, size: 14),
                  tooltip: '关闭建议',
                  color: s.muted,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _suggestDismissed = true;
                    _suggestions = <String>[];
                    _suggesting = false;
                  }),
                ),
              ),
            ],
          ),
          if (items.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                for (final String t in items)
                  GestureDetector(
                    onTap: () => _applySuggestion(t),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: s.chipBg,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        border: Border.all(color: s.border, width: 0.8),
                      ),
                      child: Text(
                        t,
                        style: AppFonts.body(size: 11.5, color: s.text),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 选择模型。
  ///
  /// 和从前那个"只有两个 DeepSeek 型号"的写死列表不同，这里列的是用户
  /// **真正绑定过的**模型（可能是从中转站批量导入的几十个），
  /// 而且面板里还带一个「模型参数」入口。
  Future<void> _pickModelForComposer() async {
    final String? picked = await showModelPicker(
      context,
      settings: widget.settings,
      anchorBuilder: () => _rectOfComposer() ?? _fallbackComposerAnchor(),
      align: CardAlign.left,
    );
    if (picked == null || !mounted) return;
    await widget.settings.update(() {
      widget.settings.selectProfile(picked);
    });
    if (mounted) setState(() {});
  }

  /// 「+」面板：四个标签页。
  ///
  /// 之前是一串平铺的选项，模型、参数、附件混在一起。改成标签页是因为
  /// **这四类东西性质不同**：
  /// · 模型设置 —— 这一轮**怎么想**
  /// · 附件添加 —— 给模型**看什么**
  /// · 工具调用 —— 它**能做什么**
  /// · 性能工具 —— **花了多少**
  ///
  /// 平铺时用户每次都要在一堆无关选项里找自己那一项；分组之后
  /// 手指落到哪个标签是有预期的。
  /// 「+」面板：**只剩"往这条消息里放东西"**。
  ///
  /// 从前这里有三个标签（附件添加 / 模型设置 / 工具调用），现在只留第一个：
  ///
  /// · **模型设置搬到了输入框上**（点模型选择器就能调温度和思考深度）。
  ///   为什么搬：那些参数是"我这句想问得更发散还是更严谨"的**即时**决定，
  ///   和"我要发什么"是同时发生的；藏在「+」里的第三个标签下面，
  ///   等于要用户为了调一次温度离开输入动作两次。
  /// · **工具调用列表删掉**。它是一张**只读**的清单（"本次对话有哪些工具"），
  ///   既不能点、也不改任何东西，纯占地方。真要看有哪些工具，
  ///   直接问模型"你有哪些工具"更快。
  /// 在子树里按 ValueKey 找一个 Element（找不到返回 null）。
  static Element? _findByValueKey(Element root, ValueKey<String> key) {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget.key == key) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// 输入框那块玻璃在屏幕上的矩形。
  ///
  /// 输入框上弹出来的卡片（附件 / 思考深度 / 模型设置）**一律用它当锚点**。
  /// 不能拿里面那颗小按钮当锚点：
  ///  · 它们都在输入框的**底排**，卡片底边会压进输入框里，
  ///    看起来像从输入框中间长出来一截；
  ///  · 输入框变高（多行 / 挂了附件 / 深入研究标签）时，卡片会跟着按钮
  ///    往下沉，但按钮和输入框上沿的距离一直在变 —— 卡片就"跑"了。
  ///
  /// 拿玻璃本身当锚点，卡片永远贴在输入框**上沿**，左沿也对得齐。
  Rect? _rectOfComposer() => rectOfKey(_composerGlassKey);

  /// 量不到输入区时的兜底矩形（屏幕底部中间一块）。
  ///
  /// 只在首帧之前/极端情况下用得到，但不能给 null —— 那样卡片会贴到
  /// 屏幕左上角，看起来像 UI 崩了。
  Rect _fallbackComposerAnchor() {
    final Size size = MediaQuery.sizeOf(context);
    return Rect.fromLTWH(12, size.height - 160, size.width - 24, 120);
  }

  void _showAttachMenu() {
    // 附件面板：锚定在**输入框**上的玻璃小卡片（用户要求：是卡片，不是半屏，
    // 而且要跟着输入框走）。
    //
    // 对齐方式 `right`：卡片从输入框**右沿**往左长。
    // 「+」按钮就在这一行的最右边，卡片贴着它弹出来才对得上 ——
    // 靠左长的话，落点离触发它的那颗按钮隔着大半屏，眼睛要横着找一下。
    showAnchoredCard<void>(
      context,
      anchorBuilder: () => _rectOfComposer() ?? _fallbackComposerAnchor(),
      width: 240,
      gap: 6,
      align: CardAlign.right,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: _attachFilesTab(ctx, s),
        );
      },
    );
  }

  /// 这个会话目前占了多少 token（粗略估算）。
  ///
  /// 只算正文会**明显低估**：真正发出去的是系统提示词 + 工具表 +
  /// 工具输出 + 推理链 + 附件内容。工具表算不进这里（要建注册表），
  /// 但工具输出往往是最大的一块，不能漏。
  int _contextTokens() {
    int sum = 0;
    for (final ChatMessage m in _conv.messages) {
      sum += AppMetrics.estimate(m.content);
      sum += AppMetrics.estimate(m.reasoning);
      for (final Attachment a in m.attachments) {
        sum += AppMetrics.estimate(a.content);
      }
      for (final ToolInvocation t in m.tools) {
        sum += AppMetrics.estimate(t.argumentsJson);
        sum += AppMetrics.estimate(t.output ?? '');
      }
    }
    return sum;
  }

  /// 「+」面板的内容：把东西放进这条消息。
  ///
  /// 按设计稿，它是一个**小卡片里的四行**：图片 / 拍照 / 文件 / 深入研究。
  /// 不再分组、不再每项套一张子卡片 —— 嵌套卡片会让 240 宽的面板
  /// 显得像抽屉里的抽屉。
  Widget _attachFilesTab(BuildContext ctx, AppSurface s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _attachOption(
          s,
          icon: Icons.photo_library_outlined,
          label: '图片',
          desc: '可多选',
          onTap: () {
            Navigator.of(ctx).pop();
            _pickImage(ImageSource.gallery);
          },
        ),
        _attachOption(
          s,
          icon: Icons.photo_camera_outlined,
          label: '拍照',
          onTap: () {
            Navigator.of(ctx).pop();
            _pickImage(ImageSource.camera);
          },
        ),
        _attachOption(
          s,
          icon: Icons.attach_file_rounded,
          label: '文件',
          desc: '可多选',
          onTap: () {
            Navigator.of(ctx).pop();
            _pickFile();
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Divider(height: 1, color: s.border),
        ),
        _attachOption(
          s,
          icon: Icons.travel_explore_rounded,
          label: '深入研究',
          desc: '在对话里直接引用，不进入新页面',
          color: AppColors.research,
          onTap: () {
            Navigator.of(ctx).pop();
            // 深入研究直接在原聊天里做：只在输入框挂一个蓝色标签，
            // 不进新页面（按设计稿）。
            setState(() => _pendingResearch = true);
            _inputFocus.requestFocus();
          },
        ),
      ],
    );
  }

  /// 面板里的一行：图标 + 文字，整行可点。
  ///
  /// 高度压到 46，和侧边菜单的入口行同一档 —— 面板是"小卡片"，
  /// 不是一屏列表，行高再大就变成半屏面板了。
  Widget _attachOption(
    AppSurface s, {
    required IconData icon,
    required String label,
    String? desc,
    required VoidCallback onTap,
    Color? color,
  }) {
    final Color fg = color ?? s.text;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 19, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: AppFonts.body(
                      size: 14,
                      weight: FontWeight.w600,
                      color: fg,
                      height: 1.3,
                    ),
                  ),
                  if (desc != null) ...<Widget>[
                    const SizedBox(height: 1),
                    Text(
                      desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 11,
                        color: s.muted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 发送

  Future<void> _send({
    String? preset,
    bool silent = false,
    bool silentPrompt = false,
  }) async {
    String text = (preset ?? _input.text).trim();
    // ---- 输入框里的"已存变量库"占位标记 → 变量引用 ----
    //
    // 输入框里那段 `\u0000名字\u0000` 是给**界面**看的占位（见
    // [_maybeStashLongInput]）。真正发给模型的是 `{{名字}}`：
    //  · 正文不进上下文（减少 token、避免几万字挤掉别的东西）；
    //  · 模型需要完整内容时自己展开 `{{名字}}`，或按范围取。
    //
    // 变量名先记下来，下面挂到 `ChatMessage.varRefs` 上 —— 那条路径
    // 决定请求里发什么（见 `buildApiMessages`）。
    final List<String> varRefs = <String>[];
    if (text.contains(kVarBankChipToken)) {
      final RegExp chip = RegExp('\u0000([^\u0000]+)\u0000');
      text = text.replaceAllMapped(chip, (Match m) {
        final String name = m.group(1)!;
        if (VarBankStore.instance.has(name)) {
          if (!varRefs.contains(name)) varRefs.add(name);
          return '{{$name}}';
        }
        // 变量已经不在了（用户在设置里删了）：留个空，别把名字当正文发出去。
        return '';
      }).trim();
    }
    // 「深入研究」标签：把这一条当作研究请求发出去，发完标签清掉。
    // 没写内容也允许 —— 标签本身就是"请做深入研究"的意思。
    if (_pendingResearch && !silent && !silentPrompt) {
      final String topic = text.isEmpty ? '（见上文）' : text;
      text =
          '请对下面的主题做深入研究：多轮检索、交叉验证，最后给出一份带出处的报告。'
          '\n\n主题：$topic';
      _pendingResearch = false;
    }
    // 静默回合（实时互动）与"只藏提问"的回合（关闭时的收尾反馈）
    // 都不该带上待发附件、框选请求或引用 —— 它们不是用户发起的对话。
    final bool hidePrompt = silent || silentPrompt;
    final List<Attachment> atts = hidePrompt
        ? <Attachment>[]
        : List<Attachment>.from(_pending);
    final Conversation conv = _conv;
    final String cwtText = hidePrompt
        ? ''
        : _pendingCwt.map((CwtResult r) => r.toPrompt()).join('\n\n');
    final bool hasCwt = cwtText.isNotEmpty;
    if ((text.isEmpty && atts.isEmpty) && !hasCwt) {
      return;
    }
    // 用户主动说话时，正在跑的**静默互动回合**让路：
    // 它只是工作流里的一拍，不能挡住真正的对话。
    // （低头下棋时突然想打字，消息必须发得出去。）
    if (!silent &&
        !silentPrompt &&
        _silentConvIds.contains(conv.id) &&
        _running(conv.id)) {
      _runners[conv.id]?.abort();
      _runners.remove(conv.id);
      _busyConvIds.remove(conv.id);
      _silentConvIds.remove(conv.id);
    }
    if (_running(conv.id)) return;

    // ChangeWhatYouThink 的修改要求放在最前面：AI 先看到"改哪、怎么改"，
    // 再看到用户补的一句话。
    //
    // ---- 显示用正文：占位标记换回**变量全文** ----
    //
    // `text` 里那段 `{{名字}}` 是**发给模型**的形式（见上面）——
    // 而消息气泡要给用户看的是他**实际存了什么**。两者不一样：
    //  · 按钮上/占位符里显示"已存入变量库"；
    //  · 点开气泡看到的是原文（`content` 就是原文，见 widgets 的
    //    `_VarBankBubble`）。
    //
    // 用户补充打的话（比如"照这个做"）原样保留在原文后面。
    final String displayText = varRefs.isEmpty
        ? text
        : text.replaceAllMapped(RegExp(r'\{\{([^{}]+)\}\}'), (Match m) {
            final String n = m.group(1)!.trim();
            final Variable? v = VarBankStore.instance.get(n);
            return v?.text ?? m.group(0)!;
          });

    final String content = !hasCwt
        ? displayText
        : (displayText.isEmpty ? cwtText : '$cwtText\n\n$displayText');

    // ---- 先拦"用仅生图模型聊天" ----
    //
    // 这不是"多此一举的提示"：那个错误**用户无从自救**。服务端返回
    // `This model is not supported on chat completions endpoint`，
    // 而他只是选了列表里的一个模型、在输入框里打了句话 ——
    // 从用户视角看"发消息"是唯一能做的事。
    //
    // 所以直接给一条出口：换模型。
    if (_activeModelChatless) {
      final bool switchIt = await _confirmChatless();
      if (!mounted) return;
      if (switchIt) {
        await _pickModelForComposer();
      }
      // 无论换没换都不继续发 —— 发出去只会又失败一次，
      // 而失败会在会话里留下一条报错消息，把历史弄脏。
      return;
    }

    if (!widget.settings.configured) {
      _snack('还没有配置 API Key，请先到设置里填写');
      await showSettingsSheet(
        context,
        settings: widget.settings,
        workDir: widget.workDir,
        plugins: widget.plugins,
        conversations: widget.conversations,
        notes: widget.notes,
        tasks: widget.tasks,
      );
      return;
    }

    final MessageQuote? quote = hidePrompt ? null : _pendingQuote;

    // ---- 先把用户消息**放进会话**，再去做「描述改进」 ----
    //
    // ## 顺序为什么是反的（这里修的是一个真实 bug）
    //
    // 原来是"先改写、拿到结果才把消息加进会话"。改写要一两秒，那段时间里：
    //  · 会话里什么都没有 —— 用户以为没发出去；
    //  · `_busy` 还是 false —— 发送键**还是发送键**；
    //  · 输入框里的字也还在（`_input.clear()` 排在后面）。
    // 三条加在一起：用户再点一次发送，就是**第二个 `_send()` 同时在跑**
    // —— 他点几次，这条消息就发几遍。
    //
    // 现在：消息立刻显示、输入框立刻清空、`_busy` 立刻为 true（发送键变停止）。
    // 改写结果回来之后再补上 `improvedPrompt`。
    //
    // 至于原来担心的"先闪一下原话、再变成改写版"——那个顾虑是错的：界面本来
    // 就设计成**原话保留 + 改进版折在下面**（见 ChatMessage.improvedPrompt），
    // 所以原话先出现正是它该有的样子，改进版随后补进那个折叠块。
    // `@` 引用在这里**展开一次**并挂在消息上。
    //
    // 为什么现在就展开、而不是发请求时再算：
    //  · 用户可能发完就去把那个工具改了/删了，之后再算出来的内容
    //    和当时看到的不是一回事；
    //  · 重发同一条消息（重试）应该发出**同样的内容**，
    //    否则"上次为什么那么答"无法复现。
    final String mentionCtx = MentionParser.buildContext(
      text,
      tools: FolderToolStore.instance,
      plugins: widget.plugins,
    );

    // ---- 长文本自动存进变量库 ----
    //
    // 两条路径都会走到这里：
    //  · 输入框那一侧已经存过（`_maybeStashLongInput` 检测到超长时），
    //    此时 `varRefs` 已非空，这里**不再重复存**；
    //  · 没走输入框路径的长文本（比如 `preset` 直接灌进来、或阈值
    //    刚刚好越过），在这里补存一次。
    //
    // 为什么不问用户"要不要存"：这是**性能路径**，不是功能选择 ——
    // 问一次，用户下次粘大段内容时还是会忘。而存进去是可逆的
    // （气泡上点一下就展开，也能在设置里删），代价远低于"上下文被塞满"。
    if (!hidePrompt &&
        varRefs.isEmpty &&
        content.length > kVarBankAutoStoreChars) {
      final VarBankStore bank = VarBankStore.instance;
      final String name = freshVarName(bank);
      if (bank.set(name, content, note: _previewNote(content)) == null) {
        varRefs.add(name);
      }
    }

    final ChatMessage sent = ChatMessage(
      id: 'u_${DateTime.now().microsecondsSinceEpoch}',
      role: Role.user,
      content: content,
      varRefs: varRefs,
      attachments: atts,
      quote: quote,
      mentionContext: mentionCtx.isEmpty ? null : mentionCtx,
      // 实时互动：进上下文，但不画进聊天记录。
      hidden: hidePrompt,
    );
    setState(() {
      conv.messages.add(sent);
      if (!hidePrompt) {
        _enteringBubbles.add(sent.id);
        _pending.clear();
        _pendingCwt.clear();
        _pendingQuote = null;
        _quoteAnchor = null;
        _suggestions = <String>[];
        _suggesting = false;
      }
      _busyConvIds.add(conv.id);
      if (silent) _silentConvIds.add(conv.id);
      _phoneControl = false;
    });
    if (!hidePrompt) {
      _input.clear();
      // 占位标记随清空一起失效 —— 不清的话，下一条消息进来时
      // `_maybeStashLongInput` 会以为"标记还在"，于是不再处理新长文本。
      _varChipName = null;
    }
    // 静默回合不更新"最近聊过"的排序：用户没在聊天，是在下棋。
    if (!silent) widget.conversations.touch(conv);

    // 静默回合没有新气泡，滚动会打断用户看棋盘。
    if (!silent) _scrollToEnd();

    if (!hidePrompt && widget.settings.improvePrompt) {
      // 记下这是第几轮发送：改写期间用户按了停止（或者又开了新一轮）
      // 就把序号推进，下面比对不上就**真的取消**。
      final int seq = (_sendSeqByConv[conv.id] ?? 0) + 1;
      _sendSeqByConv[conv.id] = seq;
      final String? improved = await PromptImprover.improve(
        text,
        settings: widget.settings,
      );
      if (!mounted) return;

      if (seq != (_sendSeqByConv[conv.id] ?? 0)) {
        // 真的取消：把刚显示的那条收回去、输入框还原、附件放回待发区。
        //
        // 不能只是"不发了"就完事 —— 会话里躺着一条永远不会有回答的消息，
        // 用户只能猜"到底发出去没有"，而那条消息还会一直留在历史里。
        setState(() {
          conv.messages.remove(sent);
          _enteringBubbles.remove(sent.id);
          _pending.addAll(atts);
          _input.text = text;
          _input.selection = TextSelection.collapsed(offset: text.length);
          _busyConvIds.remove(conv.id);
        });
        // 放回去的可能是一大段（本来是长消息），光标落在末尾才看得到结尾。
        _revealInputCaret();
        widget.conversations.save();
        _snack('已取消发送');
        return;
      }

      // improved 为 null = 改写失败或没必要改 → 用原话，正常继续。
      // **绝不能因为改写失败就不发消息。**
      setState(() {
        sent.improvedPrompt = improved;
      });
    }

    final AgentRunner runner = AgentRunner(
      settings: widget.settings,
      shizuku: widget.shizuku,
      registry: _buildRegistry(),
      workDir: widget.workDir,
      notes: widget.notes,
      tasks: widget.tasks,
      plugins: widget.plugins,
    );
    _runners[conv.id] = runner;

    // 开始后台保活。**agent 一开始跑就挂上**，而不是等它变慢才挂 ——
    // 因为进程被回收往往发生在任务中途，那时候再挂已经晚了。
    //
    // 静默回合不挂：通知栏会冒出「正在思考…」，而用户只是在下一盘棋。
    if (!silent) await BackgroundService.instance.start('正在思考');

    try {
      await runner.run(
        conversation: conv,
        silent: silent,
        onUpdate: () {
          if (!mounted) return;
          // 静默回合不重绘聊天区：它没有可见消息，重绘只会让
          // 互动面板跟着整棵树重建（历史上就因此把 WebView 重新加载了）。
          if (silent) return;
          // 走节拍器：每个 token 都重建整页 + 写盘是"越聊越卡"的主因，
          // 见 _scheduleUpdate 的说明。
          _scheduleUpdate(conv);
        },
        onConfirm: (ToolInvocation inv) async {
          if (!mounted) return ConfirmDecision.deny;
          // 工具名用**调用当时**记下的那一份，不再现场重建注册表：
          // 重建出来的可能是另一个工具（插件删了、档案切了），
          // 而且这一步在弹窗前，越便宜越好。见 ToolInvocation.title。
          final String title = inv.title.isEmpty ? inv.name : inv.title;
          final String command = inv.summary.isNotEmpty
              ? inv.summary
              : (inv.args['command']?.toString() ?? inv.argumentsJson);

          // 优先走系统悬浮窗：工具很容易把别的应用切到前台
          // （am start、拉起设置页等），应用内弹窗会被盖住，
          // 用户必须先切回来才能确认。悬浮窗始终在最上层。
          if (widget.settings.useOverlayConfirm &&
              await OverlayService.canDraw()) {
            return OverlayService.showConfirm(
              title: title,
              command: command,
              reasons: inv.risk.reasons,
              dangerous: inv.risk.isDangerous,
            );
          }

          if (!mounted) return ConfirmDecision.deny;
          return showRiskConfirmDialog(
            context,
            invocation: inv,
            toolTitle: title,
          );
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          conv.messages.add(
            ChatMessage(
              id: 'e_${DateTime.now().microsecondsSinceEpoch}',
              role: Role.assistant,
              error: e.toString(),
              hidden: silent,
            ),
          );
        });
      }
    } finally {
      // 只清理这条会话自己的状态；别的会话可能还在跑。
      // 如果停止后用户又发了一条，_runners 里已经是新的 runner，
      // 旧这次收尾不能把新任务的 busy 状态删掉。
      final bool owner = identical(_runners[conv.id], runner);
      if (mounted) {
        if (owner) {
          setState(() {
            _busyConvIds.remove(conv.id);
            _silentConvIds.remove(conv.id);
            _phoneControl = false;
            // 新一轮回答结束：如果用户之前手动关过建议，
            // 下次输入时允许它重新出现。静默回合不算"回答"。
            if (!silent) _suggestDismissed = false;
          });
        }
        if (silent) _pruneSilentHistory(conv);
        widget.conversations.touch(conv);
      }
      // **一轮结束时必定落盘一次**：节拍器把存盘降到 1.5s 一次，
      // 这一下是"最终状态"，不能省。
      await widget.conversations.save();
      if (owner) _runners.remove(conv.id);
      if (_busyConvIds.isEmpty) {
        _cancelUpdateTimers();
        // 所有会话都跑完了才撤前台服务和浮窗。
        await BackgroundService.instance.stop();
        await OverlayService.dismissActivity();
      }

      // **干完了就把用户带回来。**
      // 他切出去等结果，完成时不该还需要自己想起来切回来看看。
      //
      // 只在应用不在前台时拉 —— 已经在前台还 startActivity 是多余的，
      // 而且可能打断用户正在做的事。
      if (!silent && !_appInForeground) {
        await OverlayService.bringToFront();
      }

      // ---- 上下文快满了就主动问 ----
      //
      // 放在**所有收尾之后**：先把通知/浮窗撤掉、把用户拉回来，
      // 再弹这个面板。顺序反过来的话，用户切回来看到的第一个东西
      // 是一个盖住对话的面板，而他还没看到刚才那轮的结果。
      //
      // 只在应用在前台时弹：不在前台时用户看不到面板，
      // 它会在切回来时以"凭空出现"的方式挡在眼前。
      if (!silent &&
          mounted &&
          _appInForeground &&
          widget.conversations.current?.id == conv.id) {
        await _maybeWarnContext(conv);
      }
    }
  }

  /// 用量接近上限时弹压缩面板。
  ///
  /// 判断放在**一轮结束后**而不是发送前：发送前用户的输入还没进去，
  /// 估算必然偏低；而且那时弹面板会打断"我正在打字"这个动作。
  Future<void> _maybeWarnContext(Conversation conv) async {
    final int limit = widget.settings.contextLimit;
    if (limit <= 0) return;

    final int used = ContextCompressor.estimate(conv);
    if (used < limit * ContextCompressor.warnRatio) return;
    // 太短的会话压了也没用（摘要本身也要 token），直接跳过。
    if (conv.messages.length <= ContextCompressor.keepTail + 2) return;

    if (!mounted) return;
    final bool done = await CompressPrompt.show(
      context,
      conversation: conv,
      settings: widget.settings,
    );
    if (!done) return;
    if (!mounted) return;

    // 压缩改的是消息列表，得落盘，否则下次启动又变回没压的样子。
    await widget.conversations.save();
    if (mounted) setState(() {});
  }

  /// 从会话的最后一个工具调用里读出"现在在干什么"，同步给通知和悬浮窗。
  ///
  /// 数据来源是 `ToolInvocation.status` —— agent 循环会把它置成 running/success，
  /// 所以**不需要给 AgentRunner 加回调**，读现成的状态就够了。
  /// 静默回合的上下文修剪。
  ///
  /// 一盘棋可以走几百步，每一步都往会话里塞"事件 + act + 工具结果"，
  /// 上下文很快就会被这些过程撑满。这里**每攒到 60 条一次性收到 30 条**：
  /// 太早的走法已经体现在页面上了，需要时还能用 `interact read`
  /// 从 hub 里取（那里保留最近 100 条事件）。
  ///
  /// 只删 `hidden` 的消息，聊天记录一条不动；删完把引用跳转的 GlobalKey
  /// 表按新下标重排，屏幕上已有的消息不会因为"换了 key"被重建。
  static const int _silentLimit = 60;
  static const int _silentKeep = 30;

  void _pruneSilentHistory(Conversation conv) {
    final List<int> hidden = <int>[
      for (int i = 0; i < conv.messages.length; i++)
        if (conv.messages[i].hidden) i,
    ];
    if (hidden.length <= _silentLimit) return;
    final Set<int> drop = hidden.take(hidden.length - _silentKeep).toSet();
    final Map<int, int> remap = <int, int>{};
    final List<ChatMessage> kept = <ChatMessage>[];
    for (int i = 0; i < conv.messages.length; i++) {
      if (drop.contains(i)) continue;
      remap[i] = kept.length;
      kept.add(conv.messages[i]);
    }
    conv.messages
      ..clear()
      ..addAll(kept);
    // 下标右移：把旧 key 搬到新下标上，别清空（清空会让可见消息重建）
    final Map<int, GlobalKey> moved = <int, GlobalKey>{};
    for (final MapEntry<int, GlobalKey> e in _messageKeys.entries) {
      final int? to = remap[e.key];
      if (to != null) moved[to] = e.value;
    }
    _messageKeys
      ..clear()
      ..addAll(moved);
  }

  void _syncAgentActivity(Conversation conv) {
    if (conv.messages.isEmpty) return;

    final ChatMessage last = conv.messages.last;
    final List<ToolInvocation> tools = last.tools;

    // 找正在跑的那个
    for (final ToolInvocation inv in tools.reversed) {
      if (inv.status == InvocationStatus.running) {
        final bool control = isPhoneControlCall(inv.name, inv.args);
        if (control) _phoneControl = true;
        // 用调用当时记下的名字/摘要。这里原来每次重绘都重建一遍注册表
        // （遍历 MCP 服务器、插件、权限判断），而这个回调是**每个 token
        // 都会走**的热路径 —— 重建的结果还未必是当时那个工具。
        final String label = inv.title.isEmpty ? inv.name : inv.title;
        final String detail = inv.summary.isNotEmpty
            ? inv.summary
            : (inv.args['command']?.toString() ??
                  inv.args['query']?.toString() ??
                  inv.args['path']?.toString() ??
                  '');
        final String text = detail.isEmpty
            ? '正在执行：$label'
            : '正在执行：$label · ${detail.length > 40 ? '${detail.substring(0, 40)}…' : detail}';
        _pushActivity(text);
        // 工具**开始执行时**应用已经在后台：生命周期回调早就过去了，
        // 这里补一次显示，否则第一下启动别的应用就看不到浮窗。
        if (control && !_appInForeground) {
          OverlayService.showActivity(text);
        }
        return;
      }
    }

    // 没有正在跑的工具 —— 说明在等模型
    _pushActivity('正在思考');
  }

  /// 把"现在在干什么"同时推给**通知**和**浮窗**。
  ///
  /// 两个地方用同一份文案 —— 分开维护迟早会出现"通知说在搜索、
  /// 浮窗说在写代码"这种自相矛盾。
  void _pushActivity(String text) {
    _lastActivity = text;
    BackgroundService.instance.update(text);
    // 浮窗只在后台显示，但这里不判断前后台 ——
    // 原生侧会记住状态：没显示时 update 只是更新文案，
    // 等切到后台时会用最新的文案显示出来
    OverlayService.updateActivity(text);
  }

  void _stop() {
    final Conversation conv = _conv;
    // 推进这条会话的发送序号：改写那几秒里按停止也要真的停下来。
    _sendSeqByConv[conv.id] = (_sendSeqByConv[conv.id] ?? 0) + 1;
    _runners.remove(conv.id)?.abort();
    setState(() {
      _busyConvIds.remove(conv.id);
      _phoneControl = false;
    });
  }

  /// 暂停「全部放行」。
  ///
  /// 先问一句，不是多此一举：这个按钮就在发送键旁边，误触一次就等于
  /// 把用户刚刚授权的那一整套放行悄悄收回去，而长任务跑到一半突然开始
  /// 弹确认框，比一直弹更让人措手不及。代价是多次点击。
  Future<void> _pauseAutoApprove() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('暂停全部放行？'),
        content: const Text(
          '暂停之后，工具调用会重新弹确认框（危险命令还会额外标红）。\n'
          '下次想省事时，在任意一个确认框里再点「全部运行」就行。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续放行'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('暂停'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() {});
    await widget.settings.update(() => widget.settings.autoApproveAll = false);
  }

  /// 滚到底。
  ///
  /// [force] = false 时**用户自己往上翻着看历史就不再抢**：
  /// 原来流式期间每个 token 都无条件滚到底，用户往上划一下立刻被拽回来 ——
  /// 这就是"执行任务时划不动"的直观来源（内容在长，而且不让你看上面）。
  void _scrollToEnd({bool force = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (!force && !_atBottom) return;
      _clampScrollNow();
      final double target = _scroll.position.maxScrollExtent;
      // 已经在底了就别再起一次动画（播放动画本身也要花掉一帧）
      if ((target - _scroll.position.pixels).abs() < 2) return;
      _scroll
          .animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          )
          .whenComplete(() {
            // 动画期间内容可能变短（发送后建议条/附件清空、输入区变矮），
            // 目标位置就"超"了 —— 动画结束再夹一次。
            if (mounted) _clampScrollNow();
          });
    });
  }

  /// 把滚动位置夹回合法范围。
  ///
  /// ## 为什么需要它
  ///
  /// 发消息后建议条和待发附件会被清空，输入区变矮 → 列表的
  /// `bottomInset` 跟着变小 → `maxScrollExtent` 也变小。
  /// 而 `_scrollToEnd` 是按**变化前**的目标位置滚过去的，
  /// 于是 `pixels` 停在比 `maxScrollExtent` 更大的地方：
  /// 屏幕上表现为"整片内容被顶到屏幕外，底部一片空白，
  /// 得往下拖一下才回来"。
  ///
  /// `ScrollPosition` 只有在**用户滚动**时才会自动夹紧，
  /// 程序化 `animateTo` 之后不会。所以这里手动收一次。
  void _clampScrollNow() {
    if (!mounted || !_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    if (p.pixels > p.maxScrollExtent) {
      _scroll.jumpTo(p.maxScrollExtent);
    }
  }

  /// 这场对话里有没有 AI 的回复（决定末尾要不要署名）。
  ///
  /// 静默回合不算：它们在聊天记录里根本不存在。
  static bool _hasAssistantReply(Conversation c) => c.messages.any(
    (ChatMessage m) =>
        !m.hidden && m.role == Role.assistant && m.content.trim().isNotEmpty,
  );

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 用户气泡的入场动画播完了：把标记收回来。
  ///
  /// 不做这一步的话，列表回收/重建时同一条历史消息可能又播一遍 ——
  /// 用户滚动回看时会觉得“怎么突然又动了”。
  void _bubbleEntered(String id) {
    if (!mounted) return;
    if (_enteringBubbles.remove(id)) setState(() {});
  }

  // ------------------------------------------------------------------ 刷新节拍

  Timer? _updateTimer;
  Timer? _saveTimer;

  /// 把流式更新**合并成一个节拍**，而不是每个 token 重建一次。
  ///
  /// ## 为什么必须合并（"执行任务时卡、划不动、最后闪退"的主因）
  ///
  /// 模型吐 token 是每秒几十个，而 `onUpdate` 原来对**每一个 token** 做一整套
  /// 重活：
  ///  · `setState` —— 重建整页，含 markdown 重排和每条消息的状态卡片；
  ///  · `_scrollToEnd` —— 起一次滚动动画（上一次还没跑完就被打断）；
  ///  · **`conversations.save()` —— 把整个会话 JSON 序列化后写盘**；
  ///  · `_syncAgentActivity` —— 同步通知栏与悬浮窗。
  ///
  /// 写盘那条最要命：会话越长（工具输出动辄几十 KB）单次代价越大，
  /// 于是"聊得越久越卡"，最后把内存顶爆 —— 表现就是闪退。
  /// 而**每个 token 存一次盘毫无意义**：中途崩溃是小概率，
  /// 每次更新都存盘是必然成本。
  ///
  /// 现在：界面最多 33ms 刷一次（≈30fps，看着是连续的），
  /// 存盘最多 1.5s 一次；一轮结束时 `_send` 的 finally 里**必定**再存一次，
  /// 所以"最后的状态"永远是落盘的。
  void _scheduleUpdate(Conversation conv) {
    if (!mounted) return;

    // ---- 刷新间隔按"当前这条有多长"自适应 ----
    //
    // 重建一次的成本主要花在**正在长的这条消息**上：它每帧都要重新排版
    // 整棵 Markdown 组件树。答案越长，这一下越贵 —— 用户看到的就是
    // "短回答顺，长回答一卡一卡"。
    //
    // 所以间隔跟着长度走：
    //  · 短（< 2k 字）：50ms，约 20fps，看起来是连续的；
    //  · 中（< 8k 字）：90ms，约 11fps，读长文时仍然够顺；
    //  · 长（≥ 8k 字）：160ms，约 6fps —— 这个长度下人是"读"而不是
    //    "看着字冒出来"，降帧几乎无感，但 CPU 占用能降一个档。
    final int len = conv.messages.isEmpty
        ? 0
        : conv.messages.last.content.length;
    final int ms = len > 8000 ? 160 : (len > 2000 ? 90 : 50);

    _updateTimer ??= Timer(Duration(milliseconds: ms), () {
      _updateTimer = null;
      if (!mounted) return;
      setState(() {});
      // 只有当前正在看的会话才自动滚到底；后台会话更新不能把用户
      // 正在读的另一条聊天拽下去。
      if (widget.conversations.current?.id == conv.id) {
        _scrollToEnd(force: false);
      }
      _syncAgentActivity(conv);
    });

    _saveTimer ??= Timer(const Duration(milliseconds: 1500), () {
      _saveTimer = null;
      widget.conversations.save();
    });
  }

  /// 收掉节拍器（一轮结束、页面销毁时用）。
  void _cancelUpdateTimers() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  // ------------------------------------------------------------------ 构建

  // 顶部/底部栏的实测高度。
  //
  // 为什么要量：玻璃的模糊只能作用于"从它下面经过的内容"。
  // 原来头部和输入栏是 Column 的兄弟节点，消息列表夹在中间 ——
  // **列表永远不会滚到栏下面**，BackdropFilter 一直在跑却什么都模糊不到。
  //
  // 改成 Stack 之后列表铺满整个高度，用 padding 让开两条栏的位置，
  // 滚动时内容就真的从栏下穿过，模糊才看得见。
  // 而 padding 必须等于栏的实际高度，所以这里量一次。
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _composerKey = GlobalKey();

  /// 输入框那块**玻璃**本身（比 [_composerKey] 少一圈外边距）。
  ///
  /// 弹层要贴的是玻璃的上沿和左沿，不是整块输入区的留白 ——
  /// 用 [_composerKey] 当锚点的话，卡片会离输入框远 6~12 像素，
  /// 而且左右各差 12，看着就是"没对齐"。
  final GlobalKey _composerGlassKey = GlobalKey();

  double _headerH = 0;
  double _composerH = 0;

  void _measureBars() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final double h =
          (_headerKey.currentContext?.findRenderObject() as RenderBox?)
              ?.size
              .height ??
          0;
      final double c =
          (_composerKey.currentContext?.findRenderObject() as RenderBox?)
              ?.size
              .height ??
          0;
      // 只在真的变了才 setState，否则会无限重建
      if ((h - _headerH).abs() > 0.5 || (c - _composerH).abs() > 0.5) {
        setState(() {
          _headerH = h;
          _composerH = c;
        });
        // 输入区变矮会让列表的最大滚动距离跟着变小，而当前位置可能
        // 还停在旧值上（发消息后建议条/附件被清空时必现）—— 收一次。
        _clampScrollNow();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    // ---- 历史还在读：先给一块**和启动窗口同色**的底 ----
    //
    // 首帧不等历史（见 `main()`），此时 `current` 是 null。如果照常往下走，
    // `_conv` 会在 build 里同步 `createNew()` → `notifyListeners()` →
    // 构建期间 setState，Flutter 会直接抛 "setState() called during build"。
    //
    // 所以这一小段只画背景色：和 Android 启动窗口的 `#FFF8F5EE`
    // 一模一样，用户看到的是一块连续的米白，而不是白闪或空白页。
    // 历史一到就 `notifyListeners()`，`_onExternalChange` 重建这一层。
    if (!widget.conversations.loaded) {
      return Scaffold(
        key: _scaffoldKey,
        backgroundColor: s.pageBg,
        body: const SizedBox.expand(),
      );
    }

    final Conversation conv = _conv;
    _measureBars();

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: s.pageBg,
      // 首页形态下这里是侧边菜单（新对话 / 历史对话 / 计划 / 笔记 / 研究 /
      // 设置）。
      //
      // ## 只挂左边（不要 `endDrawer`）
      //
      // 以前两侧都挂同一份，理由是"往哪边滑每个用户直觉不同"。
      // 但那带来了一个具体的坏结果：**右划左出来**会和消息列表里的
      // 横向滚动打架 —— 代码块、表格、长图片本来就是横滑的，
      // 从右边一划就把菜单拽出来，看起来像"我只是想看看这行代码的结尾"。
      //
      // 现在只保留"从左往右划出"，也就是常见的抽屉方向；右滑留给内容本身。
      drawer: widget.drawer,
      // 从边缘往里划**拉出侧边菜单**。
      //
      // 默认只有 20 逻辑像素（还要再扣掉屏幕圆角和手势区），手机上实际
      // 能划到的是一条很窄的带子 —— 用户体验到的就是"我往右划了，
      // 但什么都没发生"，然后放弃。放宽到 64：仍然是"从边上划"的手感，
      // 但不必贴着边框精准起手。再宽就会开始和消息列表里的横向滚动
      // （代码块、表格、图片轮播）抢手势。
      drawerEdgeDragWidth: 64,
      // ---- 页面底：**纯色**，没有渐变 ----
      //
      // 这里原来铺了一道从左上到右下的米黄渐变，理由是"让玻璃的边缘
      // 弯出一点明暗"。但整个屏幕上只有输入栏和顶栏那一小块真的会模糊，
      // 而代价是**每一屏都垫着一层可见的色带** —— 上下深浅不同，
      // 翻页时颜色还在变。用户说的"颜色太浓、界面发闷"，有一部分
      // 就来自这层渐变本身。
      //
      // iOS 的页面底从来是纯色：`#F2F2F7` 或纯白，一整个平铺到底。
      // 分层靠卡片（更亮一档）和发丝线，不靠底色。
      body: ColoredBox(
        color: s.pageBg,
        child: _isLandscape ? _landscapeBody(conv) : _portraitBody(conv),
      ),
    );
  }

  bool get _isLandscape =>
      MediaQuery.of(context).orientation == Orientation.landscape;

  Widget _portraitBody(Conversation conv) {
    final double navInset = _isLandscape ? _landscapeNavHeight : 0;
    // 互动面板占的是**真实高度**，不是盖在消息上：把消息列表的底部
    // 内边距一起加上，拖高面板时聊天内容会跟着往上压，而不是被遮住。
    final bool panelHere =
        _panelSession != null && _panelSession!.convId == conv.id;
    final double panelExtra = panelHere
        ? _panelHeight.clamp(44.0, MediaQuery.sizeOf(context).height * 0.55) + 8
        : 0;
    // 用 Stack 而不是 Column：列表要**铺满整个高度**并从两条栏下面穿过，
    // 否则玻璃模糊没有作用对象（详见 _measureBars 的注释）。
    return Stack(
      children: <Widget>[
        Positioned.fill(
          key: const ValueKey<String>('chat.messages'),
          // ---- 为什么要这层 RepaintBoundary ----
          //
          // 聊天页是"整页 setState"：每敲一个字、每 ~33ms 的流式刷新，
          // 都会重建整棵树。没有这层边界时，消息列表会跟着重画 ——
          // 而输入框的 BackdropFilter 又要把它重新采样一遍，于是
          // "打字卡 / 整机发涩"。
          //
          // 隔开之后：输入区那一小条的模糊照旧真的在糊，但采样的是
          // 消息列表**已经画好的缓存层**，不再触发整屏重绘。
          child: RepaintBoundary(
            child: _messageList(
              conv,
              topInset: _headerH + navInset,
              bottomInset: _composerH + panelExtra,
            ),
          ),
        ),
        // 往上翻看历史时，一键跳回最新消息
        //
        // ---- 每个孩子都带 key：这条不是洁癖 ----
        //
        // Stack 的 children 会**按位置**配对 Element。这个列表里有两个
        // 条件孩子（回到底部按钮、互动面板），滚动时 `_atBottom` 一变，
        // 按钮就出现/消失，它后面所有孩子的位置一起挪一格 ——
        // Flutter 会认为"这里是另一个 WebView"，把旧的销毁重建。
        // 用户看到的就是：点一下/拖一下 → 面板闪一下 → 重新加载、
        // 刚落的子全没了。加上稳定 key 之后 Element 按 key 配对，
        // 条件孩子增删不会再动到面板的 AndroidView。
        if (!_atBottom)
          Positioned(
            key: const ValueKey<String>('chat.jumpBottom'),
            right: 16,
            bottom: _composerH + panelExtra + 14,
            child: GlassIconButton(
              icon: Icons.arrow_downward_rounded,
              tooltip: '回到底部',
              size: 38,
              iconSize: 19,
              onTap: _scrollToEnd,
            ),
          ),
        // ---- 顶部渐隐带 ----
        //
        // 顶栏是**透明**的（用户要求沉浸），内容从标题和状态栏后面直接
        // 滚过去 —— 滚到顶时正文会和状态栏的时钟/图标、以及返回键叠在
        // 一起，读起来是糊的。
        //
        // 这里在顶栏**下面**铺一条竖直渐变：最上面是不透明的页面底色
        // （盖住状态栏那一条），往下 40 像素淡到全透明（让正文"浮出来"）。
        //
        // 只有一块小矩形，不做全列表 shader —— 之前那层 `ShaderMask`
        // 是整屏离屏图层，长文本时会把 GPU 吃满，已经删了。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          // ---- 高度和浓度都提了一档（用户："顶部的虚化效果强一点"）----
          //
          // 原来 `_headerH + 14`：顶栏底边往下只淡 14px，几乎是一道硬边，
          // 正文滚上去时上半截直接贴在标题下面，很挤。
          //
          // 现在 `_headerH + 26`，并且把中间那一段的浓度从 0.75 提到 0.88：
          // 顶点是全实（盖住状态栏），到顶栏底边仍然接近全实，再往下 26px
          // 才淡干净。视觉上正文是**从顶栏下面浮出来**的，而不是被切掉。
          height: _headerH + 26,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    AppSurface.of(context).pageBg,
                    AppSurface.of(context).pageBg.withValues(alpha: 0.92),
                    AppSurface.of(context).pageBg.withValues(alpha: 0.55),
                    AppSurface.of(context).pageBg.withValues(alpha: 0),
                  ],
                  // 前三段全落在顶栏内部：内容不会在标题那一行还露着；
                  // 最后 22% 用来"淡出"，那一段才是正文开始透出来的地方。
                  stops: const <double>[0.0, 0.62, 0.78, 1.0],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          key: const ValueKey<String>('chat.header'),
          top: 0,
          left: 0,
          right: 0,
          child: KeyedSubtree(key: _headerKey, child: _header()),
        ),
        if (_isLandscape)
          Positioned(
            key: const ValueKey<String>('chat.landscapeNav'),
            top: _headerH,
            left: 0,
            right: 0,
            child: _landscapeNav(),
          ),
        // ---- 输入区：贴底，但**高度上限是整块 body** ----
        //
        // `top: 0` + `Align` 这一对是给 [_composer] 里那个 `Flexible` 用的：
        // 只写 `bottom: 0` 的话 Positioned 给孩子的约束是"高度 0..∞"，
        // 而 `Flexible` 在无界的主轴上**不生效**（RenderFlex 会把它当普通
        // 子项，按自己的内容排版）—— 那样"面板不许把输入框顶出屏幕"就只是
        // 一句口号，全靠一个按屏幕高度估的上限去碰运气。
        //
        // 补上 `top: 0` 之后 Align 拿到的是**紧**的整块高度，它再 `loosen`
        // 交给输入区：输入区照旧按内容长、照旧贴底（`bottomCenter`），
        // 但 Column 知道自己最多能用多高，`Flexible` 于是真的能分到
        // "减掉输入框之后剩下的空间"。
        //
        // ---- 互动面板：浮在输入框上方，可上下拖、可收成小条 ----
        //
        // ⚠️ 这个槽位**永远存在**（不显示时高度 0），不要写成 `if (...)`。
        // Stack 是按位置配对 Element 的：孩子时有时无，后面的孩子就会
        // 被当成"新的"销毁重建。互动面板里是原生 WebView，一重建就等于
        // 刷新页面 —— 用户刚落的子会消失。槽位固定 + key 固定之后，
        // 面板只会在 `session.id` 真的变化（换了一页）时才重来。
        Positioned(
          key: const ValueKey<String>('chat.panelSlot'),
          left: 8,
          right: 8,
          bottom: _composerH + 8,
          height: panelHere
              ? _panelHeight.clamp(
                  44.0,
                  MediaQuery.sizeOf(context).height * 0.55,
                )
              : 0,
          child: !panelHere
              ? const SizedBox.shrink()
              : InteractionPanel(
                  key: ValueKey<String>('chat.panel.${_panelSession!.id}'),
                  session: _panelSession!,
                  height: _panelHeight,
                  onHeightChanged: _resizePanel,
                  onClose: _closePanel,
                ),
        ),
        // `_composerKey` 留在 Align **里面**：量到的必须是输入区本身的高度
        // （消息列表的底部内边距按它算），不是整块 body。
        Positioned(
          key: const ValueKey<String>('chat.composer'),
          top: 0,
          bottom: 0,
          left: 0,
          right: 0,
          child: Align(
            alignment: Alignment.bottomCenter,
            // ---- 为什么要这层 RepaintBoundary ----
            //
            // 输入区里有一层真实的 BackdropFilter。流式输出时整页每 50ms
            // 重建一次，但**输入区这一帧其实没有任何变化**（文字都在上面
            // 的消息里）。没有边界时它会被一起重绘，模糊就跟着重算 ——
            // 白白花掉全屏最贵的一笔。
            //
            // 隔开之后：消息在变，输入区不动，模糊层直接复用上一帧。
            // 打字时它仍然会重绘（文字确实变了），但那只发生在你敲键的那一瞬。
            child: RepaintBoundary(
              child: KeyedSubtree(key: _composerKey, child: _composer()),
            ),
          ),
        ),
      ],
    );
  }

  Widget _landscapeBody(Conversation conv) {
    final double width = MediaQuery.sizeOf(context).width;
    const double divider = 12;
    final double minPane = width < 700 ? 240 : 300;
    final double usable = (width - divider)
        .clamp(1.0, double.infinity)
        .toDouble();
    final double minFraction = (minPane / usable).clamp(0.25, 0.48).toDouble();
    final double maxFraction = 1 - minFraction;
    final double leftWidth =
        (usable * _splitFraction.clamp(minFraction, maxFraction))
            .clamp(minPane, width - divider - minPane)
            .toDouble();

    return Row(
      children: <Widget>[
        SizedBox(
          key: const ValueKey<String>('chat_left_pane'),
          width: leftWidth,
          child: _portraitBody(conv),
        ),
        _splitHandle(
          width: divider,
          onDrag: (double dx) {
            if (usable <= 0) return;
            setState(() {
              _splitFraction = ((leftWidth + dx) / usable)
                  .clamp(minFraction, maxFraction)
                  .toDouble();
            });
          },
        ),
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey<String>('chat_right_pane'),
            child: _toolPane(conv),
          ),
        ),
      ],
    );
  }

  /// 横屏时把左侧边栏的入口压成一条横向导航条。
  ///
  /// 竖屏的 Drawer 在横屏会占掉半屏高度，而横屏最缺的正是高度；
  /// 所以这里只保留"去哪里"的入口，历史列表仍然从「历史」打开原抽屉。
  Widget _landscapeNav() {
    final AppSurface s = AppSurface.of(context);
    Widget item(IconData icon, String label, VoidCallback onTap) {
      return TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: s.text,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: AppFonts.body(size: 11, height: 1.15),
        ),
      );
    }

    return Container(
      height: _landscapeNavHeight,
      decoration: BoxDecoration(
        color: s.pageBg,
        border: Border(bottom: BorderSide(color: s.border, width: 0.6)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          children: <Widget>[
            item(Icons.add_rounded, '新对话', () {
              widget.conversations.createNew();
              if (mounted) setState(() {});
            }),
            item(Icons.history_rounded, '历史', () {
              _scaffoldKey.currentState?.openDrawer();
            }),
            item(Icons.checklist_rounded, '计划', () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => TasksPage(store: widget.tasks),
                ),
              );
            }),
            item(Icons.sticky_note_2_outlined, '笔记', () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => NotesPage(store: widget.notes),
                ),
              );
            }),
            // 「更多」：研究 / 浏览器 / 设置 默认收起，点开才出现。
            //
            // 同一排七个入口时，新对话和历史会被挤到要靠横向滚动才看得见 ——
            // 而那两个才是这一条栏最常用的。收成 +3 之后，最常用的始终在最左。
            item(
              _landscapeMore
                  ? Icons.expand_less_rounded
                  : Icons.expand_more_rounded,
              _landscapeMore ? '收起' : '更多',
              () => setState(() => _landscapeMore = !_landscapeMore),
            ),
            if (_landscapeMore) ...<Widget>[
              item(Icons.travel_explore_rounded, '研究', () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) => DeepResearchPage(
                      settings: widget.settings,
                      shizuku: widget.shizuku,
                      workDir: widget.workDir,
                      notes: widget.notes,
                      tasks: widget.tasks,
                      plugins: widget.plugins,
                    ),
                  ),
                );
              }),
              item(Icons.public_rounded, '浏览器', () {
                BrowserPage.open(
                  context,
                  url:
                      WebViewLoader.liveUrl ??
                      browserHomeUrl(widget.settings.searchEngine),
                );
              }),
              item(Icons.settings_outlined, '设置', () {
                showSettingsSheet(
                  context,
                  settings: widget.settings,
                  workDir: widget.workDir,
                  plugins: widget.plugins,
                  conversations: widget.conversations,
                  notes: widget.notes,
                  tasks: widget.tasks,
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _splitHandle({
    required double width,
    required ValueChanged<double> onDrag,
  }) {
    final AppSurface s = AppSurface.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (DragUpdateDetails d) => onDrag(d.delta.dx),
        child: Container(
          key: const ValueKey<String>('chat_split_handle'),
          width: width,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Container(
            width: 4,
            height: 64,
            decoration: BoxDecoration(
              color: s.muted.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolPane(Conversation conv) {
    final AppSurface s = AppSurface.of(context);
    final List<ToolInvocation> tools = <ToolInvocation>[
      for (final ChatMessage m in conv.messages)
        if (!m.hidden) ...m.tools,
    ];
    final int running = tools
        .where(
          (ToolInvocation t) =>
              t.status == InvocationStatus.running ||
              t.status == InvocationStatus.awaitingConfirm,
        )
        .length;
    final int failed = tools
        .where(
          (ToolInvocation t) =>
              t.status == InvocationStatus.failed ||
              t.status == InvocationStatus.rejected,
        )
        .length;

    return Container(
      color: s.pageBg,
      child: SafeArea(
        left: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 10, 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '工具调用',
                    style: AppFonts.body(
                      size: 15,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${tools.length} 次'
                    '${running > 0 ? ' · $running 进行中' : ''}'
                    '${failed > 0 ? ' · $failed 失败' : ''}',
                    style: AppFonts.body(size: 11.5, color: s.muted),
                  ),
                  const Spacer(),
                  _splitLegend(s),
                ],
              ),
            ),
            Expanded(
              child: ToolCallTable(
                tools: tools,
                emptyText: '这次对话还没有工具调用',
                onOpen: _showToolInvocation,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _splitLegend(AppSurface s) {
    Widget item(Color c, String label) => Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label, style: AppFonts.body(size: 10.5, color: s.muted)),
        ],
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        item(AppColors.success, '成功'),
        item(AppColors.warning, '进行中'),
        item(AppColors.danger, '失败'),
      ],
    );
  }

  Future<void> _showToolInvocation(ToolInvocation inv) async {
    final AppSurface s = AppSurface.of(context);
    final (IconData icon, String label) = ToolDisplay.of(inv.name);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: AppColors.accent),
            const SizedBox(width: 8),
            Text(
              label,
              style: AppFonts.body(
                size: 16,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(
                  inv.argumentsJson,
                  style: AppFonts.code(size: 11.5, color: s.text),
                ),
                if ((inv.output ?? '').trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    '结果',
                    style: AppFonts.body(
                      size: 12,
                      weight: FontWeight.w600,
                      color: s.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    inv.output!.trim(),
                    style: AppFonts.code(size: 11.5, color: s.text),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          GlassButton(label: '关闭', onTap: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
  }

  Future<void> _showToolCallsSheet() async {
    final AppSurface s = AppSurface.of(context);
    final Conversation conv = _conv;
    final List<ToolInvocation> tools = <ToolInvocation>[
      for (final ChatMessage m in conv.messages)
        if (!m.hidden) ...m.tools,
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => Container(
        height: MediaQuery.sizeOf(ctx).height * 0.72,
        decoration: BoxDecoration(
          color: s.pageBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: AppColors.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '工具调用',
                    style: AppFonts.body(
                      size: 16,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${tools.length} 次',
                    style: AppFonts.body(size: 12, color: s.muted),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      showPerformanceSheet(
                        context,
                        settings: widget.settings,
                        contextTokens: _contextTokens(),
                        conversation: _conv,
                      );
                    },
                    child: const Text('性能'),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, size: 20, color: s.muted),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ToolCallTable(
                tools: tools,
                emptyText: '这次对话还没有工具调用',
                onOpen: _showToolInvocation,
              ),
            ),
          ],
        ),
      ),
    );
  }


  /// 顶栏「更多」：把模型、工具调用、权限三项收在一起。
  /// 右上角圆钮在屏幕上的矩形（按 ValueKey 找）。
  Rect? _rectOfHeaderMoreButton() {
    final Element? el = _findByValueKey(
      context as Element,
      const ValueKey<String>('chat.moreButton'),
    );
    final RenderBox? box = el?.renderObject as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _showHeaderMore() {
    final AppSurface s = AppSurface.of(context);
    // 右上角菜单：锚定在右上角那颗圆钮旁边的**小卡片**（用户要求：
    // 是卡片，不是底部半屏）。按设计稿只放「工具调用」和「权限」两项 ——
    // 模型选择已经移到输入框旁边，这里不再重复。
    //
    // ⚠️ 卡片里**不要再套 SafeArea**。这个卡片挂在屏幕顶部，底部安全区
    // 那 24~48 的留白会原样变成卡片底部的一条空白 —— 两个选项看着
    // 就是"上下各顶着一块空气"。锚点在下方的卡片才需要躲系统手势条，
    // 它不需要（位置由 showAnchoredCard 自己夹住）。
    final Rect? anchor = _rectOfHeaderMoreButton();
    showAnchoredCard<void>(
      context,
      anchor:
          anchor ??
          Rect.fromLTWH(MediaQuery.sizeOf(context).width - 56, 56, 46, 46),
      width: 196,
      preferAbove: false,
      cardPadding: const EdgeInsets.symmetric(vertical: 4),
      builder: (BuildContext ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _moreRow(
            s,
            icon: Icons.account_tree_outlined,
            label: '工具调用',
            onTap: () {
              Navigator.of(ctx).pop();
              _showToolCallsSheet();
            },
          ),
          _moreRow(
            s,
            icon: widget.settings.autoApproveAll
                ? Icons.priority_high_rounded
                : Icons.shield_outlined,
            iconColor: widget.settings.autoApproveAll ? AppColors.danger : null,
            label: widget.settings.autoApproveAll ? '全部权限已放行' : '全部权限：逐次确认',
            onTap: () {
              Navigator.of(ctx).pop();
              _showToolStatus();
            },
          ),
        ],
      ),
    );
  }

  /// 右上角小卡片里的一行：图标 + 文字，整行可点。
  ///
  /// 不直接用 `ListTile`：它自带 56 的固定行高和 Material 的左右留白，
  /// 放在 196 宽的小卡片里会显得又空又高。这里压到 38 左右，读起来是
  /// "小卡片里的一行"。
  Widget _moreRow(
    AppSurface s, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 18, color: iconColor ?? s.text),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(size: 14, color: s.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final AppSurface s = AppSurface.of(context);
    // 顶栏只有内容；**背板**由外面那层 [_headerBackdrop] 画
    // （模糊 + 渐变，见它的注释）。这里只管布局。
    // 状态栏高度。竖屏 edgeToEdge 下它是一个真实的值（24~48，挖孔更高），
    // 横屏 immersiveSticky 下是 0。**只能从这里拿**，不能写死 ——
    // 见 [_headerGap]。
    final double statusInset = MediaQuery.of(context).padding.top;
    // 竖屏在状态栏下再留 [_headerGap]；横屏那一条由横向导航条自己分界，
    // 只留 2 像素的"别贴着屏幕边"。
    final double topGap = _isLandscape ? 2 : _headerGap;

    // 顶栏不再显示对话名（方案 A：只留两个圆按钮）。
    //
    // 代价说清楚：用户在这一屏看不到"这是哪个会话"。改名的入口在侧边
    // 抽屉的历史列表里，而抽屉第一项就是当前会话 —— 需要时一眼能找到。

    // ---- 头部**不是一块背景板** ----
    //
    // 原来这里是一条玻璃栏（`GlassBar` + 底部发丝线）：整块半透明面板压在
    // 屏幕顶端。现在改成"几个元素直接浮在内容上"：
    //
    //  · 没有背板、没有发丝线、没有模糊 —— 视觉上只有返回键、标题和两个图标；
    //  · 但**必须给一个底色**，而且必须是**不透明**的：头部用 `Stack` 压在
    //    消息列表**上面**（见 build），底色透明的话滚动时消息会从标题字里穿过，
    //    两条文字叠在一起比"有背板"难看得多。
    //
    // 所以这里的取舍是：用和页面完全同色的底 —— 它**在视觉上不存在**
    // （没有色块、没有边界），但功能上仍然把底下滚过去的内容挡住了。
    //
    // ---- 2026-10-16：滚动之后再加一层"模糊 + 加浓" ----
    //
    // 静止时那层同色底最干净（用户要的就是"没有背板"）。但一滚起来，
    // 消息是从标题字底下穿过去的 —— 同色底只是"盖住"，边界处那一条
    // 永远是硬切，而顶部压力最大（标题、状态点、三个图标都在那一行）。
    // 所以滚起来之后**再叠一层**：虚化的内容 + 加浓的底色 + 一条发丝线，
    // 标题立刻从背景里脱出来（"提高对比度"就是这个意思）。
    //
    // **只在滚动时出现**是关键：一直顶着一条毛玻璃栏，就等于把
    // 之前那块"背板"又请回来了。两个状态之间用同一段淡入淡出，
    // 不做位移（顶栏动位置比变色更容易被注意到）。
    // ---- 顶栏只有"两个圆"，没有背板 ----
    //
    // 之前这里有一层整宽底色（+ 滚动后的模糊层 + 一条发丝线）—— 那就是
    // 用户说的"底板"。现在全部删掉：内容直接从两个圆按钮**后面**穿过去，
    // 只有按钮本身有自己的圆形底。
    //
    // 代价：滚动时文字会从按钮旁边经过没被遮挡。这正是要的效果 ——
    // 顶栏不再是一条"栏"，而是浮在内容上的两个控件。
    return Padding(
      // 顶端 = 系统状态栏高度 + [_headerGap]（竖屏）。
      //
      // **不要再"压紧"这个值**：这一行的点按区是 38，而状态栏下沿
      // 往下 8 像素之内都属于下拉通知栏的手势热区 —— 压到 2 的时候
      // 标题既是"字贴着系统栏"，那一排图标也几乎点不动。
      //
      // 底部原来是 2：那一栏只有"图标 38 + 上下 2"那么高，
      // 看上去是一条被压扁的塑料条，标题字几乎贴到下面的消息列表。
      // 给到 10 —— 顶栏是**页面级**元素，它需要一点自己的留白，
      // 否则永远像"还没排完版"。
      // 左边距和右边距**必须相等**：8/4 时左边按钮离屏幕边 8、
      // 右边按钮离边 4+8(SizedBox)=12，一眼看出歪。
      padding: EdgeInsets.fromLTRB(14, statusInset + topGap, 8, 8),
      child: Row(
        children: <Widget>[
          // ---- 左：会话标题 ----
          //
          // 参考图里顶栏是"一行标题 + 右侧两个图标"，没有任何胶囊/圆底。
          // 标题就是当前会话名字，点它打开侧边栏（历史列表在那里）——
          // 一个**看不见边界**的入口，和参考图一致。
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
              child: Text(
                widget.conversations.current?.title ?? '新对话',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // ---- 颜色从 `muted` 提到 `text` ----
                //
                // 原来是次要文字的灰。问题出在标题本身很短（"新对话"三个字）
                // 而顶栏背后又是页面同色底 —— 灰字在这个位置读起来像
                // "禁用"或者"还没加载完"（用户原话："颜色浓一点，不要太淡"）。
                //
                // 它是这一屏的**身份**（我在哪个会话里），不是注释；
                // 用主文字色 + w500，和下面正文同一个墨色，但比正文略重。
                style: AppFonts.body(
                  size: 15,
                  weight: FontWeight.w500,
                  color: s.text,
                  height: 1.3,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // ---- 右：新建 + 更多（**都是裸图标**，没有圆形底） ----
          //
          // 参考图的右上角就是两个淡淡的字形。做成裸图标之后顶栏真的
          // 变成"内容浮在页面上"，而不是一条挂着两颗按钮的栏。
          _headerPlainIcon(
            icon: Icons.add_rounded,
            tooltip: '新建聊天',
            onTap: () => widget.conversations.createNew(),
          ),
          _headerPlainIcon(
            key: const ValueKey<String>('chat.moreButton'),
            // 三个点：和"更多"语义一致，也比时钟更像一个菜单入口。
            icon: Icons.more_horiz_rounded,
            tooltip: '工具调用与权限',
            onTap: _showHeaderMore,
          ),
        ],
      ),
    );
  }

  /// 顶栏右侧的**裸图标**按钮：只有命中区，没有底色、没有描边。
  ///
  /// 命中区仍是 40×40（图标 21 直接用点不中），只是不再画出来 ——
  /// 这正是参考图里"顶栏只有几个字形"的样子。
  Widget _headerPlainIcon({
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final AppSurface s = AppSurface.of(context);
    return Tooltip(
      key: key,
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(child: Icon(icon, size: 21, color: s.muted)),
        ),
      ),
    );
  }

  // Shizuku 状态点暂时没有放回顶栏（方案 A 只留两个圆按钮）。
  // 保留实现：它是判断"权限服务活着没有"的唯一可视信号，后面要么挪进
  // 「更多」那个 sheet，要么放进抽屉 —— 删掉会丢掉这段逻辑。
  // ignore: unused_element
  Widget _shizukuDot() {
    final ShizukuService z = widget.shizuku;
    final bool ok = z.ready;

    // 未授权只是「部分功能缺失」，用橙色而不是红色，
    // 完全没装 Shizuku 才用中性灰 —— 都不该让用户以为应用坏了。
    final Color color = ok
        ? AppColors.success
        : z.supported
        ? AppColors.warning
        : AppColors.neutral;

    final String label = ok
        ? '系统权限已就绪，可以执行命令、管理应用、读写文件'
        : z.supported
        ? '尚未授予系统操作权限 · 点击去授权。\n未授权时联网、识图、普通对话仍可正常使用'
        : '未检测到 Shizuku。需要它才能执行系统命令等操作';

    return StatusDot(
      color: color,
      glow: ok,
      tooltip: label,
      onTap: () {
        if (!ok && z.supported) {
          _requestShizuku();
        } else {
          _snack(label.replaceAll('\n', ' '));
        }
      },
    );
  }

  Future<void> _requestShizuku() async {
    await widget.shizuku.requestPermission();
    if (mounted) _snack('已发起授权请求，请在系统弹窗中允许');
  }

  Widget _messageList(
    Conversation conv, {
    double topInset = 0,
    double bottomInset = 0,
  }) {
    // 静默回合（互动面板的每一次点击）也留在会话里喂上下文，
    // 但**不画出来** —— 否则聊天会被「【互动面板·实时】…」刷屏。
    final List<int> visible = <int>[
      for (int i = 0; i < conv.messages.length; i++)
        if (!conv.messages[i].hidden) i,
    ];
    if (visible.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
        child: _emptyState(),
      );
    }

    // 极简过程挂在哪里：**最后一条用户气泡之后**。
    // 这一格正好是「用户气泡下边、AI 原文顶部左边」，而且滚动时它跟着
    // 这次任务走，不会像输入框上方的浮条那样挡住正文。
    int lastUserIndex = -1;
    for (final int i in visible) {
      if (conv.messages[i].role == Role.user) lastUserIndex = i;
    }

    // ---- 全部工具调用：整场对话合计成一行（见 ToolFoldAllRow）----
    //
    // 汇总行的位置取**第一次用工具的那条回复之后**：那一行代表的就是
    // "从这里开始它一直在调工具"，和原来"每条回复下面的工具行"读起来
    // 是同一条线，只是被压成了一行。
    final bool collapse = widget.settings.collapseToolSteps;
    // 极简过程：整场对话的工具汇总行也不出现 —— 那一行和"只留结论"
    // 是互相矛盾的（它本身就是一条会动的过程信息）。
    final bool minimal = widget.settings.minimalProgress;
    final List<ToolInvocation> allTools = <ToolInvocation>[
      for (final int i in visible) ...conv.messages[i].tools,
    ];
    final bool showFoldRow = collapse && !minimal && allTools.isNotEmpty;
    int firstToolIdx = -1;
    if (showFoldRow) {
      for (final int i in visible) {
        if (conv.messages[i].tools.isNotEmpty) {
          firstToolIdx = i;
          break;
        }
      }
    }
    // 合上时每条消息都不画工具过程 —— 它们已经在上面那一行里了。
    final bool hideMsgTools = showFoldRow && _toolsFolded;

    final Widget foldRow = ToolFoldAllRow(
      total: allTools.length,
      failed: allTools
          .where(
            (ToolInvocation t) =>
                t.status == InvocationStatus.failed ||
                t.status == InvocationStatus.rejected,
          )
          .length,
      running: allTools
          .where((ToolInvocation t) => t.status == InvocationStatus.running)
          .length,
      folded: _toolsFolded,
      onTap: () => setState(() => _toolsFolded = !_toolsFolded),
    );

    final Widget list = ListView.builder(
      controller: _scroll,
      // 上下内边距 = 两条栏的实测高度。列表本身铺满整个屏幕，
      // 靠 padding 让内容从栏下方开始 —— 这样滚动时消息会**从栏下面穿过**。
      // 首次布局时测量值还是 0，会闪一下，但下一帧就修正了。
      // 左右 20：正文要留出边距，16 在手机上偏窄 ——
      // 一行 20 多个汉字贴着屏边，读起来像"填满了"。
      // 上下多给 4/6：最后一条消息离输入框远一点，视觉上不再"被吸进去"。
      padding: EdgeInsets.fromLTRB(20, topInset + 8, 20, bottomInset + 20),
      // 最后多一格：整场对话末尾的署名（见 AiSignature）。
      // 只在**已经有 AI 回复**时给那一格 —— 一条 AI 回复都没有的新对话
      // 没有"AI 生成的内容"可署名。
      itemCount: visible.length + (_hasAssistantReply(conv) ? 1 : 0),
      itemBuilder: (BuildContext context, int i) {
        if (i == visible.length) return const AiSignature();
        final int index = visible[i];
        final ChatMessage m = conv.messages[index];
        final AppSurface s = AppSurface.of(context);

        // ---- 内容没变的消息：直接复用上一次的 widget 实例 ----
        //
        // 这是"带公式/长文本就卡"的真正解法。
        //
        // 页面是整页 `setState`：流式输出时每 50~160ms 重建一次整棵树。
        // 就算 Markdown 解析有缓存、公式 Widget 实例也能复用，**外层的
        // Column 仍然是新建的** —— 子树会被重新挂载，于是每个公式都要
        // 重新布局一遍（TeX 布局是最贵的一步），屏幕上十来个公式就是
        // 肉眼可见的卡顿。
        //
        // Flutter 的 `updateChild` 里有一条短路：如果新旧 widget
        // `identical`，整棵子树**跳过更新**。所以只要把"输入没变"的那条
        // 消息的 widget 实例留着复用，它下面的公式、代码块、图片全都
        // 不会重排。
        //
        // 签名必须覆盖所有影响渲染的输入；拿不准就宁可多算一次重建。
        final String sig = <String>[
          m.id,
          '${m.content.length}:${m.content.hashCode}',
          '${m.reasoning.length}:${m.reasoning.hashCode}',
          '${m.pending}',
          m.error ?? '',
          '${m.attachments.length}',
          '${m.tools.length}',
          m.tools.isEmpty ? '' : m.tools.last.status.name,
          '${m.marks.length}',
          m.quote?.text ?? '',
          // 变量库引用：有它时气泡画成"已存入变量库"卡片而不是普通文本，
          // 漏了在签名里就会出现"同一条消息一会儿是卡片一会儿是长文"。
          m.varRefs.join(','),
          '${m.hidden}',
          '$collapse|$minimal|$hideMsgTools|${s.isDark}|${AppFonts.scale}',
          '${_enteringBubbles.contains(m.id)}',
        ].join('|');

        final String cacheKey = '$index#$sig';
        final Widget? cached = _msgCache[cacheKey];
        if (cached != null) {
          final AppSurface s2 = AppSurface.of(context);
          final bool showProcessHere = minimal && index == lastUserIndex;
          if (!showProcessHere && index != firstToolIdx) return cached;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              cached,
              if (showProcessHere) _minimalProcessRow(s2),
              if (index == firstToolIdx) foldRow,
            ],
          );
        }

        final Widget view = KeyedSubtree(
          // 引用跳转靠这个 key 找到"那条消息现在在屏幕上的哪儿"
          // （见 _jumpToQuote：用 ensureVisible 而不是估算偏移量）。
          key: _keyFor(index),
          child: MessageView(
            message: m,
            onOpenLink: _openLink,
            // 长按选中 → 引用 / 标记 / 取消标记（两种消息都支持）
            onQuote: _quoteFrom,
            onMark: _markOn,
            onUnmark: _unmarkOn,
            // 长按消息 → 「重新生成 / 修改」（见 MarkdownView 的选区菜单）
            onRegenerate: _regenerateFrom,
            onEdit: _editFrom,
            onDelete: _deleteMessage,
            animateIn: _enteringBubbles.contains(m.id),
            onBubbleAnimated: () => _bubbleEntered(m.id),
            // 点消息上的引用条 → 跳回原文
            onTapQuote: (MessageQuote q) => _jumpToQuote(conv, q),
            // 「性能 → 工具步骤过程」：收成一行还是逐步平铺
            collapseToolSteps: collapse,
            // 「性能 → 极简过程」：思考和工具合成一句状态，不给展开入口
            minimalProgress: minimal,
            // 整场对话的工具调用已经汇总成一行时，这里不再画第二遍
            showToolSteps: !hideMsgTools,
          ),
        );
        // 缓存实例（上限 200 条：一屏几十条，够覆盖来回翻动）。
        _msgCache[cacheKey] = view;
        if (_msgCache.length > 200) _msgCache.clear();

        final bool showProcessHere = minimal && index == lastUserIndex;
        if (!showProcessHere && index != firstToolIdx) return view;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            view,
            if (showProcessHere) _minimalProcessRow(s),
            if (index == firstToolIdx) foldRow,
          ],
        );
      },
    );

    // ---- 不再用 ShaderMask 做两端淡出 ----
    //
    // 之前这里返回的是 `ShaderMask(blendMode: dstIn, child: list)`：整屏消息
    // 每帧被压成一个离屏图层，再按渐变改 alpha。代价随**内容长度**线性上涨
    // （答案越长，这层越大），而且它会把这个子树重新合成一遍 ——
    // 外层刚加的 `RepaintBoundary` 因此完全失效。表现就是"文本一长就卡"。
    //
    // 底部的淡出其实**输入区自己已经做了**：`_composer` 里那层
    // `Positioned.fill` 的渐变就是从透明到页底色，正好盖在输入框上沿。
    // 顶部按现行设计是"完全透明、内容直接从标题后面滚过去"，本来就不该有
    // 一层渐隐。所以这层 ShaderMask 是**纯重复开销**，删掉后观感不变。
    return list;
  }

  Future<void> _openLink(String url) async {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      _snack('无法打开链接：$url');
    }
  }

  /// 空白对话页上**只有一句问候**。
  ///
  /// ## 为什么把"可以让我做什么"那几张卡片删了
  ///
  /// 那四张卡片看起来是在教用户怎么用，实际上每次开一条新对话都要先
  /// 跨过一屏**示例话术**，而开新对话的人几乎总是已经知道自己要说什么。
  /// 示例只在"第一次打开、完全不知道能干什么"那一次有价值，之后每次
  /// 都是一层要划过去的噪音（用户的原话：只留早上好/中午好/晚上好）。
  ///
  /// 权限提示也不再挂在这里：头部那个状态点就是它的入口 —— 橙色 =
  /// 没授权，点一下直接请求。它比一张卡片更近，也不需要占正文的地方。
  Widget _emptyState() {
    final AppSurface s = AppSurface.of(context);
    // ---- 空态**必须能滚** ----
    //
    // 这段问候语本身只有两行，但它坐在"整块 body 减掉输入区"的那块空间里。
    // 键盘一弹、输入框又长到五行，剩下的高度可以只有 38 —— 而这段内容是
    // 82，`Center` 会照旧按自然高度排版，于是 RenderFlex 直接溢出 44，
    // 屏幕上出现黄黑斜纹。这不是理论值，是量出来的。
    //
    // `SingleChildScrollView` + `ConstrainedBox(minHeight: 视口)` 是
    // "居中，但装不下时能滚"的标准写法：空间够的时候 `Center` 生效、
    // 位置和以前一模一样；空间不够的时候它退化成一块可滚区域，
    // 问候语随正文一起被推上去，而不是把布局撑破。
    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints c) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Center(
              child: Padding(
                // 左右 32、底部再往上抬 48：空状态不是上边距撑着的一行字，
                // 而是整屏的中心。手机上手自然停在屏幕中部，句子也该在那里。
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      Greeting.line(),
                      textAlign: TextAlign.center,
                      style: AppFonts.body(
                        size: 30,
                        weight: FontWeight.w600,
                        color: s.text,
                        height: 1.3,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 一句"上哪儿去"的引子。光有问候语那一屏太空了
                    // （用户的原话），而这里又不该再摆一屏示例卡片 ——
                    // 一行小字把"接下来该你说话"说清楚就够。
                    Text(
                      '直接说你要做什么',
                      textAlign: TextAlign.center,
                      style: AppFonts.body(
                        size: 15,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 输入区那一块**模糊玻璃**：状态行 + 输入框 + 工具条都在它里面。
  ///
  /// ## 为什么要模糊（2026-10-16）
  ///
  /// 原来这块是**不透明**的 `s.surface`，而且内容在它上沿就已经淡没了
  /// （见 `_messageList` 的 ShaderMask）。两者叠在一起的效果是：内容滚到
  /// 输入区就"没了" —— 用户看不出下面还有东西，也看不出输入框是浮在
  /// 对话之上的。改成毛玻璃之后，滚过去的内容在它下面**模糊着继续走**，
  /// 玻璃的"厚度"自己就出来了。
  ///
  /// ## 为什么状态行也搬进玻璃里
  ///
  /// 它们原来在玻璃**上面**、背后是透明的消息列表 —— 那正是"字叠字"的来源
  /// （内容滚到状态行背后时两条字叠在一起）。现在整块输入区（正在抓网页 /
  /// Termux running / 待发附件 / 引用条 / 输入框 / 工具条）都在同一块玻璃上，
  /// 只有一种表面、一种边框。
  ///
  /// 边框仍然用 `ShapeDecoration` + side 画在**最上层**：先模糊、再描边，
  /// 圆角处才不会被裁掉一半（`Border.all` 在非整数宽度下还会粗细不匀）。
  /// 输入区那层玻璃。
  ///
  /// ## Android 17 的模糊玻璃
  ///
  /// 这一版是 **iOS 的薄玻璃**（`UIBlurEffect` 那一档）：
  ///  · 真实背景模糊（`BackdropFilter`），sigma 20 —— 消息滚到下面时是糊的；
  ///  · 半透明的系统底色填充（不是实心白板，能看见底下内容的明暗）；
  ///  · 一条发丝线勾边，没有白色高光、没有暖色投影。
  ///
  /// sigma 从 32 降到 20：32 是"磨砂板"的强度，背后什么都看不清；
  /// iOS 的栏是**薄薄一层**，底下的内容还在动、还认得出形状。
  ///
  /// ## 模糊保留，但只保留"看得见"的那一处
  ///
  /// 输入框背后是滚动的正文，所以这里的模糊是**有内容的**，必须留下。
  /// 之前为了压掉打字卡顿把它整个关掉了，等于把设计语言也一起删了 ——
  /// 那是过度优化，已改回。
  ///
  /// 真正省下来的在别处（见 [BlurSurface]）：82 张卡片坐在纯色底上，
  /// 它们那层模糊本来就没有东西可糊，看不见却最费 GPU。
  ///
  /// sigma 从 18 提到 32，同时把填充透明度降到 0.42（暗色 0.34）：
  /// 只加模糊会显得像一块磨砂板，只降透明度又会让背后文字直接透出来、
  /// 和输入框里的字打架。两个一起调，才是"糊着但看得见底下在动"。
  Widget _composerGlass(
    AppSurface s, {
    required Widget child,
    double radius = AppRadius.input,
  }) {
    // ---- 输入区是**毛玻璃** ----
    //
    // 用户要的同时是三件事，只有毛玻璃能同时满足：
    //  · 正文要能**滚到输入框底下**（背板不能是实心墙）；
    //  · 滚过去的内容要被**糊掉**，不能在框里读出字来；
    //  · 框本身仍然要是一块清楚的圆角面板。
    //
    // 实心填充做不到前两条；纯半透明做不到第二条（字直接透上来）。
    // 所以是 `clip → blur → 半透明填充` 三层：
    //  · `ClipRRect`：模糊只作用在圆角以内，不然四角会糊成方的；
    //  · `BackdropFilter(sigma 20)`：把背后已经画好的正文抹平；
    //  · 填充 0.72 / 0.78：在糊掉的底上再压一层，保证框里的字对比度够。
    //
    // 外层的 `Container` 只负责描边和投影（它们要画在裁剪外面），
    // 填充交给里面那层 —— 否则圆角边缘会有一圈"实色出界"。
    return Container(
      key: _composerGlassKey,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        // ---- 淡灰描边：让输入框**从页面里浮出来** ----
        //
        // 只靠底色是不够的：`chipBg` 和页面底只差两三个色阶，在一片灰
        // 里框的边界是"糊"的。一圈 1px 的发丝线把边界钉住，但要用
        // `s.border`（描边专用的那一档），不能用文字/分隔线那种更深的灰 ——
        // 输入框是**一直摆在那**的控件，描边抢眼就成了"未填完的表单"。
        border: Border.all(color: s.border, width: 1),
        // ---- 极轻的投影：只负责"悬着"，不负责"抬高" ----
        //
        // 0 偏移 + 3 模糊 + 4% 黑：在浅色下只是让下边缘比上边缘略深
        // 一点点，看起来像"贴着纸面浮起一层"；深色下 4% 黑几乎看不见，
        // 所以不用换色 —— 深色的层次由描边负责。
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        // 内层比外层小一圈：刚好让描边不被填充盖住。
        borderRadius: BorderRadius.circular(radius - 1),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: ColoredBox(
            // 0.78（浅）/ 0.70（深）：浅色底本来就淡，压得太狠就成了实心；
            // 深色反过来，透太多背后那行字会浮上来。两档都量过字压在上面
            // 仍然清楚。
            color: s.chipBg.withValues(alpha: s.isDark ? 0.70 : 0.78),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    final AppSurface s = AppSurface.of(context);
    // 键盘高度（没弹起时是 0）。这一行也会让 [_composer] 在键盘升降时重建。
    final double kb = MediaQuery.viewInsetsOf(context).bottom;

    return Stack(
      children: <Widget>[
        // ---- 底部渐变 ----
        //
        // 消息列表是**铺满整屏**的，从输入区后面穿过去（那是玻璃模糊
        // 需要的）。问题是：最后一条消息会一直滚到屏幕最底、贴着边缘，
        // 读起来像"被切掉了"。
        //
        // 铺一层从透明到页面底色的渐变，内容就有了"淡出"的收尾，
        // 而输入框本身不需要额外加背板 —— 渐变自己就是那块背板。
        //
        // 高度**就是输入区的实际高度**（Stack 按非定位子项定尺寸），
        // 所以它永远跟着输入区走，不会出现"渐变比输入框短一截"。
        //
        // ⚠️ **渐变必须一直铺到屏幕最下沿**，不能像以前那样在
        // `padding.bottom` 处截断。截断之后，系统手势条（小白条）那一段
        // 是裸的 —— 滚动的正文会从它后面露出来，白条上压着字。
        // 现在整条安全区都被这层不透明底色盖住：输入框仍然停在小白条
        // 上方，但白条后面是纯底色，不是文字。
        // ---- 输入区背板：**上透下实**的渐变 ----
        //
        // 用户要的是"正文内容可以显示到输入框下面" —— 滚上来的消息要从
        // 输入框**底下**经过（被框糊掉），而不是把框当成一堵墙。
        //
        // ⚠️ 这里**没有背板**，是故意的。
        //
        // 之前试过两种：整块实底（正文透不上来，等于钉了一层墙纸）和
        // 四段渐变（正文在模型那一行背后隐约可见）。用户要的是第三种：
        // **正文可以滚到输入框下面、被框糊掉，但不会跑到框下面**。
        //
        // 也就是说：模糊由 `_composerGlass` 的 BackdropFilter 负责，
        // 而"框下面"（模型那一行 + 手势条）仍然是不透明的页面底色 ——
        // 那块底色长在 `_composerFooter` 自己身上，见那里的注释。
        // 这里再铺一层就会把"框底下"也一起盖住，模糊就白做了。
        Padding(
          // ---- 左右**不缩进**，让底栏通栏 ----
          //
          // 以前这里写的是 12/12，缩进由这一层统一给。问题是
          // [_composerFooter] 的实底长在这一层**里面**，只盖到中间那条
          // 388 宽的区域 —— 左右各剩 12px 是透的，正文从那两条竖缝里
          // 露出来（用户报的"有一点文字露出来了"就是它们）。
          //
          // 现在缩进下放到各个子项（玻璃、`@` 面板、附件条自己加），
          // 底栏则可以真正铺满整幅宽度，正文到它的上沿就被截断。
          //
          // ---- 键盘弹起时**补 8 的底边距** ----
          //
          // 底排（模型那一行）在打字时是收起的，而它的下边距里含了
          // 手势条安全区。键盘一起来，输入框就直接贴到键盘顶沿上 ——
          // 用户的原话是"输入框贴太近输入法了"。这里补 8，让框和键盘
          // 之间留一道缝。
          padding: EdgeInsets.fromLTRB(0, 6, 0, kb > 0 ? 8 : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // ---- `@` 补全面板：浮在输入框上方的**另一张卡** ----
              //
              // 它以前长在 `_composerBody` 里，也就是和输入框**共用同一块玻璃**：
              // 同样的圆角、同样的描边，中间没有一点断开 —— 读起来就是"输入框
              // 被拉高了一段"，而不是"上面弹出来一个候选列表"。要让它像一张
              // 独立浮着的卡，唯一的办法是把挂载点挪到玻璃外面来，见
              // [_mentionCard]。
              //
              // 挪出来还顺带修掉两件事：
              //  · 它不再是 [_composerGlass] 的子树，`_morph` 那 260ms 的形变
              //    （宽度/高度/圆角一起插值）不会把它一起缩放，也不会被收缩到
              //    42 的盒子裁掉 —— 以前打字打到一半往回收，面板会跟着抖一下；
              //  · `_bodyH` 里不再混进面板的高度。面板一开一关，正文自然高度
              //    原来是**突变**的，收起动画会照那个数补间，于是"忽然跳一下"。
              //
              // ⚠️ 用 `Flexible` 而不是普通子项，这是"不许把输入框顶出屏幕"
              // 那条铁律的真正兑现：面板拿到的是**这根 Column 减掉输入框等
              // 固定高度之后剩下的空间**，不够高就在面板内部滚（[ListView] 本来
              // 就能滚），而不是靠一个按整块屏幕估出来的上限去祈祷它够。
              if (_mention != null)
                Flexible(
                  child: Padding(
                    // 左右 12：缩进从外层挪到这里（见上面 `padding` 的注释）。
                    padding: EdgeInsets.fromLTRB(12, 0, 12, _mentionGap),
                    child: _mentionCard(s),
                  ),
                ),
              // ---- 待发的图片/文件：**挂在输入框外面** ----
              //
              // 用户的原话是"插入的文件和图片，统一放在输入框外面挂着，
              // 不要挤在输入框里面"。所以它不进那块玻璃，而是单独一条浮在
              // 输入框上方 —— 和消息列表同色底，看着就是"贴在上面的几个卡片"。
              //
              // 这样做还有个实际好处：那 66×66 的缩略图 + 右上角的删除角标
              // 本来就不该被玻璃边框圈住（角标必然要压线），挂在外面之后
              // 角标怎么放都干净。
              if (_pendingCwt.isNotEmpty) _cwtStrip(s),
              if (_suggestions.isNotEmpty || _suggesting) _suggestBar(s),
              if (_pending.isNotEmpty) _pendingStrip(s),
              // 输入框：**固定展开**，不再有"缩成一颗圆"的形态。
              //
              // 这里原来是一整段形变动画（宽/高/圆角共用 `_morph`，下滑跟手
              // 压缩、点小图标收起）。用户要求关掉它：输入框就是输入框，
              // 长按是把文字选出来处理，而不是把盒子收起来。
              Padding(
                // 左右 12：缩进从外层挪到这里（见上面 `padding` 的注释）。
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: LayoutBuilder(
                  builder: (BuildContext ctx, BoxConstraints c) {
                    final double avail = c.maxWidth;
                    return SizedBox(
                      width: avail,
                      child: _composerGlass(
                        s,
                        radius: AppRadius.input,
                        child: SizedBox(
                          width: avail,
                          child: _composerBody(s),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // ---- 框外下面一行：模型 + 附件 / 语音 ----
              //
              // 参考图里这一行在输入框外面、和输入框同宽：
              // 左边是模型名 + 强度（`✳ Fable 5.1 Low`），右边是几个图标。
              // 放进框内会把输入宽度压窄，而且它们都是"发消息前的准备"，
              // 和"我要说的话"不是同一件事。
              //
              // **不要再往这里加提示小字**：试过一版"输入 @ 可指向文件、
              // skill…"，放在框和这一行之间 —— 用户看了一版就要求删掉。
              // 那一行字每一屏都在，但只在第一次用时有用，长期看就是噪声。
              //
              // ---- 打字时整行**消失** ----
              //
              // 输入法一起来（`viewInsets.bottom > 0`），这一行就收起来，
              // 只留输入框。理由很实际：键盘吃掉半屏之后，多出来那一行
              // 40 多像素纯粹是挤掉了正文；而"选模型 / 加附件 / 语音"
              // 这三件事没有一件是在**打字过程中**要点的。
              //
              // 用 `MediaQuery.viewInsetsOf(context)` 而不是自己去听
              // 键盘事件：它会让这个 widget 在 inset 变化时重建，键盘
              // 一升一降正好一次，不需要额外的状态字段。
              //
              // ---- 收/放**必须带过渡** ----
              //
              // 之前是裸的 `if (kb == 0) footer()`：键盘一收，这一行
              // 在**同一帧**里凭空出现 —— 而输入框还在回到原位，
              // 于是看到"下面那一行闪了一下"。
              //
              // `AnimatedSize` 让它按高度长出来（从 0 到实际高度），
              // 160ms，和键盘收起的动画大致同长；`alignment: topCenter`
              // 保证它向下生长时上沿不动，输入框不会被顶得跳一下。
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: kb == 0
                    ? _composerFooter(s)
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 输入框**下面**那一行：模型（左）+ 附件 / 语音（右）。
  ///
  /// 全部是**裸图标**：参考图里这一行没有任何圆形底、没有描边，
  /// 只有淡灰的字形 —— 和顶栏同一种语言。
  Widget _composerFooter(AppSurface s) {
    // ---- 这一行**自带实底**：内容到这里为止 ----
    //
    // 用户的要求是"正文可以滚到输入框下面，被框糊掉，但不会跑到框下面"。
    // 后半句就落在这块底色上：模型那一行（以及它下面的手势条）是不透明的
    // 页面底色，滚动的正文在这里被截断 —— 从框的下沿开始就看不到了。
    //
    // 而输入框本身是毛玻璃（见 [_composerGlass]），所以"框底下那一段"
    // 仍然有正文经过、只是被糊成一片色块。两者合起来才是用户要的效果：
    // 模糊看得见，字看不见。
    return ColoredBox(
      color: s.pageBg,
      child: Padding(
        // ---- 左右边距是**按输入框里的文字**对齐的 ----
        //
        // 输入框的外边距是 12，里面文字再缩进 8 + 14 = 22 —— 也就是说
        // 框里第一个字的左边线在 `12 + 22 = 34`。这一行要"看起来和上面
        // 那块面板同一条竖线"，所以 14 + 模型按钮的 8 = 22，
        // 加上外面的 12，正好也是 34。
        //
        // 之前是 6 + 8 = 14（外面 12 → 26），整行比框里的字缩进少了 8，
        // 放大看就是"下面这行没对齐"。
        //
        // 右边 4：最后那颗麦克风图标离框的右边缘留一点，和左边不对称 ——
        // 左边要对齐的是**文字**（22 缩进），右边要对齐的是**圆角**（8 缩进），
        // 两个基准本来就不是一个数。
        //
        // 上边距 2 → 8：这一行和输入框之间原来只有 2px，模型名像"粘"在
        // 框的下沿上。用户要的是"往下移一点" —— 8 让那一行浮在框下面，
        // 和框之间留出一条呼吸缝，同时仍然属于输入区（不是列表的一部分）。
        // 上 8 → 4：整条输入区要往下压，这一行自己的上留白是最后一块
        // 能省的高度（框和它之间 4 仍然分得开，不至于粘成一坨）。
        //
        // **下边距 = 手势条高度**：安全区原来在外层 `Padding` 上，那段
        // 留白是透明的、在实底外面 —— 正文会从最底沿那几像素里透出来。
        // 挪到这里之后，留白长在不透明底色里面，滚动的正文被它截断。
        padding: EdgeInsets.fromLTRB(
          14,
          4,
          10,
          MediaQuery.of(context).padding.bottom,
        ),
        child: Row(
          children: <Widget>[
            _modelButton(s),
            const Spacer(),
            _attachIcon(s),
            _voiceIcon(s),
          ],
        ),
      ),
    );
  }

  /// 有没有工具正在跑（浏览器 / 终端）。
  ///
  /// 顶栏「更多」里的「工具与权限」详情按它说清"现在在忙什么"。
  bool get toolBusy =>
      WebViewLoader.activity.value.isNotEmpty || TerminalSession.instance.busy;

  /// 收起态那个圆点了之后：详情 + 关掉"全部放行"。
  ///
  /// 用户的原话是"点击可以查看详情和关闭同意所有权限" —— 这两件事
  /// 合成一个面板。放一起是有道理的：**看见**它一路在跑什么，
  /// 和**决定**要不要继续放行，本来就是同一个决定的两面。
  Future<void> _showToolStatus() async {
    final AppSurface s = AppSurface.of(context);
    final String browser = WebViewLoader.activity.value;
    final bool term = TerminalSession.instance.busy;

    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          '工具与权限',
          style: AppFonts.body(
            size: 16.5,
            weight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '· 浏览器：${browser.isEmpty ? '没在用' : browser}',
              style: AppFonts.body(size: 13, color: s.text, height: 1.6),
            ),
            Text(
              '· 终端：${term ? '正在跑 ${TerminalSession.instance.runningLabel}' : '没在用'}',
              style: AppFonts.body(size: 13, color: s.text, height: 1.6),
            ),
            Text(
              '· 全部放行：${widget.settings.autoApproveAll ? '**开着**（不再问你）' : '关着'}',
              style: AppFonts.body(size: 13, color: s.text, height: 1.6),
            ),
            if (browser.isNotEmpty || term) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                term && browser.isNotEmpty
                    ? '两边都在忙：先进哪个页由你点的那一下决定。'
                    : (term ? '点下面的「看终端」进那一页。' : '点下面的「看浏览器」进那一页。'),
                style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          if (browser.isNotEmpty || term)
            GlassButton(
              label: term && browser.isNotEmpty
                  ? '看哪个'
                  : (term ? '看终端' : '看浏览器'),
              onTap: () {
                Navigator.of(ctx).pop();
                if (term && browser.isNotEmpty) {
                  _pickBusyTarget();
                } else if (term) {
                  openTerminal(context);
                } else {
                  BrowserPage.open(
                    context,
                    url:
                        WebViewLoader.liveUrl ??
                        browserHomeUrl(widget.settings.searchEngine),
                  );
                }
              },
            ),
          if (widget.settings.autoApproveAll)
            GlassButton(
              label: '暂停全部放行',
              danger: true,
              onTap: () {
                Navigator.of(ctx).pop();
                _pauseAutoApprove();
              },
            ),
          if (!widget.settings.autoApproveAll)
            GlassButton(
              label: '全部放行',
              danger: true,
              onTap: () {
                Navigator.of(ctx).pop();
                _enableAutoApprove();
              },
            ),
          GlassButton(label: '关闭', onTap: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
  }

  Future<void> _enableAutoApprove() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('允许全部工具运行？'),
        content: Text(
          '打开后，所有工具调用都不再逐次确认，'
          '包括删除数据、执行 shell 命令等危险操作。'
          '输入框旁边的红色感叹号会一直提示，随时可以点它暂停。',
          style: AppFonts.body(size: 13, height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('全部放行', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.settings.update(() => widget.settings.autoApproveAll = true);
    if (mounted) setState(() {});
  }

  /// `@` 引用补全面板 —— **一张独立的、浮在输入框上方的卡片**。
  ///
  /// 调用点在 [_composer] 的 Column 里，**不在** [_composerBody] 里。
  /// 这一点是这张卡的全部要点：挂在正文里时，它和输入框共用 [_composerGlass]
  /// 的圆角与描边，所以不管怎么调内边距都还是"一整块"。
  ///
  /// ## 为什么工具和插件放在同一个列表里
  ///
  /// 用户的心智是"我要引用那个东西"，而不是"我要引用一个插件还是一个工具"。
  /// 让他先选类别等于多一次点击，而那个区别只有实现上才重要。
  /// 所以一个列表，用图标标出类别（文件夹 = 工具，拼图 = 插件）。
  ///
  /// ## 为什么最多 6 条
  ///
  /// 面板长在输入框上面，条数一多就把输入框顶出屏幕 ——
  /// 而补全时用户最需要看着的恰恰是自己打的东西。
  /// 超过 6 条就靠继续打字收窄。
  ///
  /// ## 高度：两道闸
  ///
  /// 外层 `Flexible` 给的是"输入区剩下的全部高度"，那是**硬上限**；
  /// 这里再按屏幕高度压一个"大约 5 条"的软上限 —— 大屏上不让它铺掉半屏，
  /// 小屏/横屏上真正起作用的仍然是外层那个剩余高度。
  Widget _mentionCard(AppSurface s) {
    final MentionKind? kind = _mention?.kind;
    final String q = (_mention?.query ?? '').toLowerCase();

    final List<({Mention mention, String title, String desc})> items =
        <({Mention mention, String title, String desc})>[];

    if (kind != MentionKind.plugin) {
      for (final FolderTool t in FolderToolStore.instance.enabled) {
        // 搜索也覆盖备注和说明 —— 用户很可能只记得"那个能合并 PDF 的"，
        // 而不记得文件夹叫什么。只按 id 和标题匹配会让他以为没这个工具。
        if (q.isNotEmpty &&
            !t.id.toLowerCase().contains(q) &&
            !t.title.toLowerCase().contains(q) &&
            !t.description.toLowerCase().contains(q) &&
            !t.noteLine.toLowerCase().contains(q)) {
          continue;
        }
        items.add((
          mention: Mention(kind: MentionKind.tool, id: t.id),
          title: t.title,
          // ---- 优先显示**备注**（intro.md）----
          //
          // `description` 是写给模型看的（"这个工具能做什么"），
          // 而备注是写给人看的（"哪来的、有什么坑"）。在 `@` 面板里
          // 做选择的是人，所以先给备注。
          //
          // 备注为空（老工具没写）时退回 description，再退到 id ——
          // 三层兜底保证这一行**永远有内容**：空着一行会让列表
          // 看起来像没加载出来。
          desc: t.noteLine.isNotEmpty
              ? t.noteLine
              : (t.description.isNotEmpty ? t.description : '工具 · ${t.id}'),
        ));
      }
    }
    if (kind != MentionKind.tool) {
      for (final CustomPlugin p in widget.plugins.plugins) {
        if (!p.enabled) continue;
        if (q.isNotEmpty &&
            !p.name.toLowerCase().contains(q) &&
            !p.title.toLowerCase().contains(q)) {
          continue;
        }
        items.add((
          mention: Mention(kind: MentionKind.plugin, id: p.name),
          title: p.title,
          desc: p.description.isEmpty ? '插件 · ${p.name}' : p.description,
        ));
      }
    }

    if (items.isEmpty) {
      // 空态也套同一个壳。以前它是一行灰字直接飘在玻璃上 —— 换了形状之后，
      // 从"没结果"到"有结果"会像一块区域凭空长出来。
      return _mentionCardFrame(
        s,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Text(
            '没有匹配的工具或插件。\n'
            '工具在「设置 → 工具」里建，插件在「设置 → 插件」里建。',
            style: AppFonts.body(size: 11.5, color: s.muted, height: 1.5),
          ),
        ),
      );
    }

    return _mentionCardFrame(
      s,
      // ---- 必须能滚动 ----
      //
      // 原来是一个 `Column` + `take(6)`，看起来"6 条不会超"。但那是错的：
      //  · 横屏时可用高度只有一半，6 条直接顶穿输入框；
      //  · 字号调大（设置里能调到 130%）后每条变高，同样会溢出；
      //  · 键盘弹起时可用高度再减一半。
      //
      // 溢出在这个位置的表现很糟：不是被裁掉（那还能忍），而是
      // **整块输入区布局报错**、输入框位置乱跳。
      //
      // 所以是"有上限的滚动列表"：高度按可用空间自适应，超过就在面板内部
      // 滑动 —— 不会把输入框顶出屏幕，也不会溢出。
      //
      // 这里这个上限只是**软闸**（大屏上不让它铺掉半个屏幕，约 5 条）；
      // 真正的硬闸是 [_composer] 里那个 `Flexible`：它给的剩余高度可能比
      // 这个数小得多（横屏 + 键盘弹起），那时以小的为准（`ConstrainedBox`
      // 会取两者的最小值）。
      maxHeight: (MediaQuery.of(context).size.height * 0.32).clamp(96.0, 240.0),
      child: Scrollbar(
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: items.length,
          itemBuilder: (BuildContext _, int i) {
            final ({Mention mention, String title, String desc}) it = items[i];
            return InkWell(
              onTap: () => _applyMention(it.mention),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: <Widget>[
                    // 工具用**它自己的图标**（文件夹里的 `tool.icon`），
                    // 没有才退回文件夹字形。
                    //
                    // 这里要再查一次 store：`Mention` 只带 id，不带文件夹内容。
                    // 查不到的唯一可能是"这个工具刚被删、面板还没重建"，
                    // 那时给字形比给空白强。
                    //
                    // 尺寸统一走 `kToolIconSize`：同一个工具在列表页和
                    // `@` 面板里长得不一样，会让人以为是两个不同的东西。
                    if (it.mention.kind == MentionKind.tool &&
                        FolderToolStore.instance.byId(it.mention.id) != null)
                      ToolIcon(
                        tool: FolderToolStore.instance.byId(it.mention.id)!,
                        color: AppColors.accent,
                      )
                    else
                      Icon(
                        it.mention.kind == MentionKind.tool
                            ? Icons.folder_outlined
                            : Icons.extension_outlined,
                        size: kToolIconSize,
                        color: AppColors.accent,
                      ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            it.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(
                              size: 13,
                              weight: FontWeight.w600,
                              color: s.text,
                            ),
                          ),
                          Text(
                            it.desc,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(size: 11, color: s.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 面板的**卡片壳**：圆角、底色、描边，外加一层给水波纹用的透明 `Material`。
  ///
  /// 圆角只有 [AppRadius.card] 一处定义：以前这里是 `AppRadius.field`，
  /// 和输入框/列表项同族，面板看起来像"又一个小控件"；卡片这一档（16）
  /// 才撑得起"浮在输入区上方"的位置。
  ///
  /// [maxHeight] 为空表示不设上限（空态那两行字不需要）。
  Widget _mentionCardFrame(
    AppSurface s, {
    required Widget child,
    double? maxHeight,
  }) {
    final BorderRadius r = BorderRadius.circular(AppRadius.card);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight ?? double.infinity),
      child: Container(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: r,
          border: Border.all(color: s.border, width: 0.8),
        ),
        // 水波纹得**裁在圆角里**：`Material` 自己不裁边，点第一行时那圈
        // 墨水会溢到卡片圆角外面，看起来像描边被啃掉一口。
        child: ClipRRect(
          borderRadius: r,
          // 面板现在挂在那块玻璃**外面**，背后没有现成的 `Material` ——
          // 少了这一层，`InkWell` 的按下反馈根本画不出来（点击有效、
          // 但没有任何回馈）。`transparency` 不画底色：底色已经由上面那层
          // `decoration` 给了，再画一层会把圆角的抗锯齿糊掉。
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }

  /// 把选中的引用写回输入框。
  ///
  /// 做法是**整段替换**那个 `@fragment`，而不是在光标处插入 ——
  /// 用户已经打了 `@tool:xx`，再插一个会变成 `@tool:xx@tool:yy`，
  /// 两个标记都会被解析，行为很诡异。
  void _applyMention(Mention m) {
    final String text = _input.text;
    final int cursor = _input.selection.baseOffset >= 0
        ? _input.selection.baseOffset
        : text.length;
    final String before = text.substring(0, cursor);
    final int at = before.lastIndexOf('@');

    final String token = '${m.token} ';
    final int start = at >= 0 ? at : text.length;
    final String updated =
        before.substring(0, start) + token + text.substring(cursor);

    _input.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    // 引用插在光标处 —— 如果这段话已经有好几屏，插完得让人看见插在哪儿。
    _revealInputCaret();
    setState(() => _mention = null);
    _inputFocus.requestFocus();
  }

  /// 输入区展开态的正文（输入框 + 工具条 + 上面那几行状态）。
  ///
  /// ⚠️ 这棵子树会被**建好几份**（展开、压缩中、收起态的离屏测量各一份，
  /// 见 [_composer] 里那个 `_morph`）。所以这里只放"必须和玻璃一起动"的
  /// 东西 —— 别再把 `@` 面板塞回来：那是上面一张独立的卡（[_mentionCard]），
  /// 塞进来的话会被复制成四份列表，顺手把 `_bodyH` 的测量也搅乱。
  Widget _composerBody(AppSurface s) {
    final bool hasContent =
        _input.text.trim().isNotEmpty ||
        _pending.isNotEmpty ||
        _pendingCwt.isNotEmpty;

    // ---- 输入框上方现在**有没有状态行** ----
    //
    // 有状态行时，那块玻璃的高度是"状态行 + 输入框 + 工具条"三者相加 ——
    // 而三者各自的上下留白是**为了单独出现时好看**定的，叠在一起就变成了
    // 一坨空白（用户的原话："调用行太高了，空出很多位置"）。
    //
    // 所以状态行在的时候，把"状态行 → 输入文字"这段间距收掉一档：
    // 上面那几行自己的上边距减半、输入框的上内边距从 10 收到 4。
    // **没有状态行时一切照旧** —— 那是最常见的样子，不该被这次改动碰到。
    //
    // ⚠️ 「浏览器/终端在忙」**不算**状态行（2026-10-16）：那一行已经
    // 不画了，还算进去的话，跑任务时输入框会莫名其妙地贴紧上方空白。
    // ⚠️ 待发附件**不算**状态行：它挂在玻璃**外面**（见 [_pendingStrip]），
    // 玻璃里面的留白不该因为它而变。
    final bool hasStatusRow = _activeModelChatless;

    // 一整块圆角盒子，里面"上输入、下工具条"。
    //
    // 原来输入框和两侧按钮是并排三个控件（46 / 自适应 / 46），
    // 一行里塞了三种圆角语义；而且模型切换得离开对话去设置页。
    // 收进一个盒子之后：
    //   · 视觉上就是一个整块，和消息列表分得干净；
    //   · 拇指够得到的下半屏里，"写"和"发/换模型"都在同一处，
    //     不用在窄屏上跟两个 46 的圆按钮抢中间的宽度。
    // 圆角 20 是**外框**的曲率，里面每个控件各自是小圆角/胶囊 ——
    // 内半径小于外半径，嵌套看起来才是"装进去的"而不是"贴上去的"。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // `@` 引用补全**不在这里** —— 它已经挪到玻璃外面，是输入区上方
        // 一张独立的卡（[_composer] → [_mentionCard]）。
        // 位置仍然是"输入框上方、不盖住它"：补全时用户要一边看自己打了
        // 一半的名字、一边挑，盖上去就什么都看不见了。
        // 「正在抓取网页内容…」这一行随「从网上」入口一起删除 ——
        // 面板里已经没有抓取入口，这个状态永远不会为真。
        // ---- 「浏览器正在使用 / Termux Running」这一行**不再显示** ----
        //
        // 用户要的：输入框上方只留输入框本身。
        //
        // 信息没有丢，只是换了地方：手机端那颗常驻指示圆已经撤掉，
        // 换成顶栏「更多」里的「工具与权限」详情；消息流里的工具卡片
        // 本来就在说"这一步在干什么"，而那一行是**每一屏都常驻**的 ——
        // 它占的是输入框的位置。
        // 当前模型不能对话时，在输入框**上方**先说清楚。
        //
        // 放在这里而不是等他发出去再报错：这个错误用户完全无法自救 ——
        // 服务端只说 "not supported on chat completions endpoint"，
        // 他不知道自己选错了模型。提前一行提示能省掉一整轮困惑。
        if (_activeModelChatless) _chatlessBanner(s),
        Padding(
          // 玻璃的底色和描边**不在这里**：整块输入区（连状态行一起）
          // 共用外面那一层 `_composerGlass` 的玻璃。这里只留内边距。
          //
          // `top` 在"上面有状态行"时收到 0：那点空白加上输入框自己的上内边距
          // 就是 16 的空白，和状态行之间看起来像隔了一堵墙。
          // 上下 3：整块玻璃的高度 = 这里 ×2 + 行高，而行高由"文字那侧"
          // 决定（`TextField` 实际能到 50 —— 内边距加行盒，比两边 42 的圆
          // 和它 48 的点击区都高）。4 的时候总高 58，3 才是 56 ——
          // 56 就是加高之前的高度（量过），也是用户要的"收成原来的高度"。
          // 上下 4（不是 3）：输入框那一行现在是**48**（和两边那颗圆的
          // 点击区同高），4 + 48 + 4 = 56 —— 正好是用户要的"原来的高度"。
          // 四边**统一 8**：圆按钮整体内缩，四周都留出空隙。
          //
          // 用户要的是"在内部、留出空隙"，不是贴着圆角走 —— 之前试过
          // 贴边（4），圆压在弧线上显得局促。8 让两颗圆从玻璃边缘退开，
          // 上下左右间距一致，视觉上才是一块面板里"装着"两个按钮。
          // 上下 4（6 → 4）：框内那一行 36 高，4+36+4 = 44 —— 再收 8。
          // 用户连着说"高度低一点""往下压一点"，这块内边距是最直接的
          // 可调项：它只影响玻璃的厚度，不动字的位置（字的居中由
          // [_inputField] 的 `_inputPadV` + `textAlignVertical` 负责）。
          // 左右仍是 8。
          padding: EdgeInsets.fromLTRB(8, hasStatusRow ? 0 : 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 待发送的引用条：在输入框**上方**，紧挨着输入框。
              // 位置是有讲究的 —— 它和输入框是一体的（"这段话要跟着
              // 你这条消息一起发出去"），所以要贴着，不能飘在别处。
              if (_pendingQuote != null) _quoteBar(s),
              if (_pendingResearch) _researchTag(s),
              // ---- 按参考图：**框里只有文字 + 发送键** ----
              //
              // 参考图里输入框是一整块圆角面板，框内右侧一枚小小的发送/停止；
              // 模型、附件、语音这些"发消息前的准备"，全在**框外下面一行**。
              //
              // 这样分的好处很直接：框内只有"我要说的话"和"发出去"，
              // 视线不需要在几个圆之间跳跃；而框外那一行是低频操作，
              // 排在它自己的行里，不占输入宽度。
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    // **居中**，不是 `end`。
                    //
                    // 用 `end` 时那颗 36 的圆会贴着行的下沿：圆上方空
                    // 4（40-36）、下方 0，再加面板自身的 6，就成了
                    // "上 10 / 下 6" —— 放大看圆明显偏低。居中之后
                    // 上下各 2，圆真正和文字在同一条中线上。
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      // 文字区：至少 36（和两边的图标同高，见 [_inputField]）。
                      //
                      // 40 → 36：用户说"输入框的高度低一点"。整条输入区
                      // 的高度由这一行决定（36 + 上下内边距），降 4 之后
                      // 屏幕底部能多露出小半行正文。
                      Expanded(
                        child: ConstrainedBox(
                          // 高度和 `_inputField` 里的 `_inputRowHeight`
                          // 是**同一个数**：那边按它算上下留白，两边一起
                          // 才能保证"自然高度正好填满"，不留余量给外层。
                          constraints: const BoxConstraints(
                            minHeight: _inputRowHeight,
                          ),
                          child: _inputField(s, hasStatusRow: hasStatusRow),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // 发送 / 停止：和文字同一条中线，不再单独补底边距。
                      _trailingCircle(s, hasContent),
                    ],
                  ),
                  // ---- 「已存入变量库 · 点击查看」 ----
                  //
                  // 输入框里那段长文本已经换成占位标记（见
                  // [_maybeStashLongInput]），这一行是它的注脚：告诉用户
                  // "内容没丢，在这里" + "点一下能看全文"。
                  if (_varChipName != null) _varHintRow(s),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 框外那一行的**裸图标按钮**：只有命中区和字形，没有圆底。
  ///
  /// 参考图里输入框下面那一排就是这样 —— 淡灰色的字形直接浮在页面上。
  Widget _plainIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color? color,
  }) {
    final AppSurface s = AppSurface.of(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 17,
        child: SizedBox(
          // 34：和「模型名」那一行文字的高度**同一档**。
          //
          // 之前是 40 —— 那一行比左边的文字高出一截，整行被图标撑高，
          // 模型名看起来就"沉"在下面。34 让两边中线和行高都对上，
          // 字形也收到 20（40 的盒子里放 21 时，图标显得比文字粗一档）。
          width: 34,
          height: 34,
          child: Center(
            child: Icon(icon, size: 20, color: color ?? s.muted),
          ),
        ),
      ),
    );
  }

  /// 附件入口（框外那一行）。
  Widget _attachIcon(AppSurface s) {
    final bool enabled = !_busyFor(widget.conversations.current ?? _conv);
    return _plainIcon(
      icon: Icons.add_rounded,
      tooltip: '发送图片或文件',
      onTap: enabled ? _showAttachMenu : null,
      color: enabled ? s.muted : s.muted.withValues(alpha: 0.45),
    );
  }

  /// 语音入口（框外那一行）。正在听时变红 —— 那是唯一需要"显眼"的状态。
  Widget _voiceIcon(AppSurface s) {
    return ValueListenableBuilder<bool>(
      valueListenable: VoiceInput.listening,
      builder: (BuildContext context, bool listening, Widget? _) {
        final bool canUse = !_busyFor(widget.conversations.current ?? _conv);
        return _plainIcon(
          icon: listening ? Icons.stop_rounded : Icons.mic_none_rounded,
          tooltip: listening ? '停止识别' : '语音输入',
          onTap: canUse ? _toggleVoice : null,
          color: listening ? AppColors.danger : s.muted,
        );
      },
    );
  }

  /// **当前这条会话**是不是在跑。
  ///
  /// 所有"看得见"的判断（发送/停止、附件、模型选择器）都该用这个，
  /// 而不是裸的 `_busy`：否则切走之后新会话会继承上一条的运行状态。
  ///
  /// **`_busyConvId == null` 不再当作"全都忙"**。
  ///
  /// 原来的写法是 `_busy && (_busyConvId == null || _busyConvId == c.id)`：
  /// 只要那个字段因为任何原因变成 null（中断、异常路径、计时器回调里
  /// 提前清空），**所有会话**都会显示成"正在跑" —— 用户看到的就是
  /// "A 在跑，B 的按钮也是停止、模型选择器点不动"。
  ///
  /// 现在改成严格相等：不知道是哪个会话在跑，就当谁都没在跑。
  /// 代价是极端路径下当前会话会短暂显示成发送键，点一下会被 `_busy`
  /// 拦住（动作层仍然互斥），比"整片界面变灰"好得多。
  bool _busyFor(Conversation c) =>
      _busyConvIds.contains(c.id) && !_silentConvIds.contains(c.id);

  /// 这条会话**有没有回合在跑**（包括静默的实时互动回合）。
  ///
  /// 与 [_busyFor] 的区别：静默回合不该让发送键变成停止键、也不该
  /// 让聊天区出现"正在思考"，但它仍然占用 agent —— 用户这时发消息
  /// 必须排队/拒绝，否则两个 runner 会同时写同一条会话。
  bool _running(String convId) => _busyConvIds.contains(convId);

  /// 输入框右边那颗圆：**语音输入**。
  ///
  /// 按用户要求：平时是黑底（在米白界面上是一颗明确的"说话"按钮），
  /// 点一下进入识别就变成红色 —— 红色是"正在录"的唯一信号，
  /// 不需要再额外弹一层提示。图标同时从麦克风变成方块（停止）。
  ///
  /// 认的是 [VoiceInput.listening] 而不是本地 bool：识别可能因为
  /// 超时 / 出错 / 用户松手在原生侧自己结束，界面必须跟着回去，
  /// 不能靠某一次 `stop()` 的返回值。

  /// 语音识别：开始 / 停止。
  Future<void> _toggleVoice() async {
    if (VoiceInput.listening.value) {
      await VoiceInput.stop();
      return;
    }
    if (!await VoiceInput.available()) {
      _toast('这台设备没有可用的语音识别服务');
      return;
    }
    // 已经打了字再开语音：识别结果接在后面，而不是把原稿冲掉。
    _voiceBase = _input.text.trimRight();
    _inputFocus.requestFocus();
    await VoiceInput.start(
      onPartial: (String t) => _applyVoice(t),
      onFinal: (String t) => _applyVoice(t),
      onError: (String m) {
        // 权限类错误给一条"去设置"的出口：有些 ROM 的授权回调不可靠，
        // 用户只能在系统页里确认一次。
        if (m.contains('权限')) {
          _toast(m, actionLabel: '去设置', action: VoiceInput.openSettings);
        } else {
          _toast(m);
        }
      },
    );
  }

  /// 把识别到的一段话拼进输入框（保留开录之前已经打好的字）。
  void _applyVoice(String text) {
    final String t = text.trim();
    if (t.isEmpty) return;
    final String base = _voiceBase;
    final String merged = base.isEmpty
        ? t
        : RegExp(r'[，。！？,.!?]$').hasMatch(base)
        ? '$base$t'
        : '$base $t';
    _input.value = TextEditingValue(
      text: merged,
      selection: TextSelection.collapsed(offset: merged.length),
    );
    // 语音结果接在末尾：这段话可能已经很长了，光标得跟着下去。
    _revealInputCaret();
  }

  void _toast(String message, {String? actionLabel, VoidCallback? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          // 带操作时多留一会儿，否则按钮还没点到就消失了。
          duration: Duration(seconds: action == null ? 3 : 8),
          action: action == null || actionLabel == null
              ? null
              : SnackBarAction(label: actionLabel, onPressed: action),
        ),
      );
  }

  /// 输入框右边那一颗：发送（忙的时候是停止）。
  Widget _trailingCircle(AppSurface s, bool hasContent) {
    // `current` 是可空的：理论上没有会话时也不该崩在这里，
    // 那种情况下按"不在跑"处理 —— 发送键至少是能用的。
    final Conversation? cur = widget.conversations.current;
    if (cur == null || !_busyFor(cur)) {
      return _sendButton(s, hasContent);
    }
    // ---- 停止：一个**圆角正方形** ----
    //
    // 以前是 `IconButton.filledTonal` + `stop_rounded`，也就是一个灰色圆
    // 里嵌一个方形。用户要的是反过来：**形状本身**就是那个方块 ——
    // 圆角方形直接表示"停止"，里面不再放图标。
    //
    // 这样和左边的回车键（一个字形、没有底）形成对比：**能发**时是一个
    // 安静的图标，**正在跑**时是一块实心的色块 —— 状态一眼可辨，
    // 也不需要在 36px 里塞两个互相打架的形状。
    return Tooltip(
      message: '停止',
      child: InkResponse(
        onTap: _stop,
        radius: 18,
        child: SizedBox(
          width: _circleInRow,
          height: _circleInRow,
          child: Center(
            child: Container(
              // 18 → 14：再小一档。
              //
              // 用的是**文字色**（浅色下 `#1C1C1E`，深色下 `#EDEDED`），
              // 不是强调蓝。用户明确要"黑色的、小一点的"：停止是一个
              // **中断**动作，不该和"选中/进行中"共用那抹蓝。
              // 深色主题下不能真给黑（黑块在深灰底上看不见），
              // 所以跟的是 `s.text` —— 两套主题里都是"最实的那个墨色"。
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: s.text,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 程序化写入输入框之后，把光标（也就是刚写进去的那一截）滚进视野。
  ///
  /// ## 为什么需要这个
  ///
  /// `EditableText` 只会在**用户输入**时做这件事。源码里那行注释写得很直白：
  ///
  /// > Programmatic changes to `textEditingValue` do not trigger the behavior
  /// > even if the text field is focused.
  ///
  /// 而代码里往输入框塞字的路径很多 —— 引用片段（[_applyMention]）、语音
  /// 识别结果、从历史里"放回/修改"、变量库展开、取消发送后的还原。
  /// 它们全都是直接赋值，于是出现同一个症状：内容有好几屏，**滚动位置却
  /// 停在 0**，用户只看到开头五行，后面一大块不显示文字。
  ///
  /// 实测（`max=910` / `pixels=0`）确认过这一点，不是推测。
  ///
  /// 做法：拿到底层 [EditableTextState]，让它自己 `bringIntoView` ——
  /// 那是 Flutter 内部用的同一条路（算光标矩形 → 换算成滚动偏移），
  /// 比我们按行高乘行数去估要准，也不依赖字体度量。
  ///
  /// 必须放在**帧后**：写入到这一帧的排版之间还差一次 layout，
  /// 这时候量到的光标矩形还是旧文本的。`pumpAndSettle` 之前会正好跑一次。
  void _revealInputCaret() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final EditableTextState? st = _editableStateOfInput();
      if (st == null) return;
      // 用 controller 的 selection 而不是 `st.textEditingValue`：两边
      // 理论上一致，但 controller 才是我们刚写的那份，不会因为一次
      // 尚未同步的 rebuild 拿到旧值。
      final int offset = _input.selection.baseOffset >= 0
          ? _input.selection.baseOffset
          : _input.text.length;
      st.bringIntoView(TextPosition(offset: offset));
    });
  }

  /// 找输入框底层的 [EditableTextState]。
  ///
  /// 往上走而不是往下找：`FocusNode.context` 指向的是 `EditableText`
  /// 内部那个 `Focus` widget，而 `EditableTextState` 是它的**祖先**。
  /// 往下扫会一个都碰不到 —— 这不是风格问题，是层级方向反了就失效。
  EditableTextState? _editableStateOfInput() {
    EditableTextState? found;
    _inputFocus.context?.visitAncestorElements((Element el) {
      if (el is StatefulElement && el.state is EditableTextState) {
        found = el.state as EditableTextState;
        return false;
      }
      return true;
    });
    return found;
  }

  /// 输入框里那一行的**自然高度**（逻辑像素）。
  ///
  /// 字号 15 × 行高 1.5 × 全局行距 1.14 —— 三个因子都来自主题，
  /// 不是写死的数：用户把字号调到 1.4×，这里跟着变。
  static double get _inputLineBox => 15 * 1.5 * AppFonts.lineHeight * AppFonts.scale;

  /// 输入框上下留白：**按行盒算**，让自然高度正好等于 [_inputRowHeight]。
  ///
  /// ## 为什么不能给固定值
  ///
  /// 上一版写的是 `vertical: 4` + `textAlignVertical: center`，
  /// 想靠装饰器把余量居中。问题是：[TextField] 的自然高度是
  /// `行盒 + 上下内边距`，4+25.6+4 = 33.6，比外框的 36 矮 2.4 ——
  /// 这 2.4 是**外层 ConstrainedBox 补的**，补完之后文字在 36 里
  /// 并不居中（少的那一截只加在下面）。于是空输入时提示字略偏上，
  /// 一写字、或者换行之后行盒变了，整块又跟着跳 —— 用户看到的就是
  /// "输入的时候文字会向上飘"。
  ///
  /// 现在把这一截自己补上：留白 = (目标高度 - 行盒) / 2，
  /// 自然高度**恒等于** 36，外层那块 `minHeight` 再也补不到东西，
  /// 文字的位置就和字体度量、字号设置都无关了。
  static const double _inputRowHeight = 36;

  static double get _inputPadV {
    final double pad = (_inputRowHeight - _inputLineBox) / 2;
    // 下限 2：字号调到很大（行盒超过 36）时不能算出负数，
    // 那时框会自然长高，外层 Row 也会跟着，不需要强行压回 36。
    return pad < 2 ? 2 : pad;
  }

  Widget _inputField(AppSurface s, {required bool hasStatusRow}) {
    return TextField(
      controller: _input,
      // ---- 长按选词：系统菜单 + 全屏模式 ----
      //
      // 不再劫持长按（以前用 Listener + 500ms 定时器，长按直接被我们
      // 拿走，选词/复制/粘贴全都没了）。现在长按是 TextField 自己的
      // 选词，工具条由 `contextMenuBuilder` 补上一项「全屏模式」，
      // 其余「复制」「粘贴」「全选」保持系统原生行为。
      contextMenuBuilder: (BuildContext ctx, EditableTextState state) {
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: <ContextMenuButtonItem>[
            ContextMenuButtonItem(
              label: '全屏模式',
              onPressed: () {
                state.hideToolbar();
                _openFullscreenInput();
              },
            ),
            ...state.contextMenuButtonItems,
          ],
        );
      },
      focusNode: _inputFocus,
      // 内部的滚动条由我们自己拿着，见 [_inputScroll] 和 [_revealInputCaret]。
      scrollController: _inputScroll,
      minLines: 1,
      maxLines: 5,
      // ---- 纵向居中不靠算内边距，靠这一行 ----
      //
      // 输入框的实际高度是外层给的 `minHeight: 36`，而一行字的行盒
      // 只有 25 左右 —— 多出来的 10 像素由谁分配、分在哪边，由这个属性决定。
      // 默认是 `start`（多行输入框的默认值：字贴着顶部），单行时看起来
      // 就是"字偏上、和右边的回车键不在一条线上"。
      //
      // `center` 让装饰器**按内容实际的宽高**把字摆在中间，和字体度量无关。
      textAlignVertical: TextAlignVertical.center,
      textInputAction: TextInputAction.newline,
      keyboardType: TextInputType.multiline,
      // `even` 不能省：见上面这段注释和 `_inputStyle`。
      style: _inputStyle(s),
      // 关键：没有这个 onChanged，输入时不会重建，
      // 发送按钮会一直停在「禁用」状态 —— 表现为必须先关掉
      // 输入法（触发一次 MediaQuery 重建）才点得动。
      onChanged: (_) {
        // ---- 长文本 → 立刻存进变量库、输入框换成占位标记 ----
        //
        // 放在 `setState` **之前**：换完文本再重算引用片段，否则
        // `_mention` 会按旧的（几万字的）文本算一次，白跑一遍解析。
        _maybeStashLongInput();
        setState(() {
          // 每次改动都重算一次引用片段。
          // 读一次 selection 是因为 onChanged 之后它可能已经被
          // 输入法挪动，延后读会拿到错的位置。
          _mention = MentionParser.activeFragment(
            _input.text,
            _input.selection.baseOffset >= 0
                ? _input.selection.baseOffset
                : _input.text.length,
          );
        });
        _scheduleSuggestions();
      },
      // 输入框自己**不再画底色和描边**：外框已经给了。
      // 两层描边叠在一起，圆角处会出现一条不均匀的双线。
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        // ---- 上下留白是**常数**，居中交给 `textAlignVertical` ----
        //
        // 以前这里是 `(36 - 行盒) / 2 - 1.75`：一个依赖"行盒正好
        // 1.71em"的算式，再减掉一个量出来的经验值。它在测试字体下
        // 分毫不差，但真机上换了系统中文字体、或者用户把字号调大，
        // 上升/下降的比例一变，算出来的留白就不再对称 —— 表现就是
        // 用户说的"文字没有上下对齐"。
        //
        // 现在：`_inputPadV`（4）只是一个呼吸量，剩下的高度由
        // `textAlignVertical: center` 在**上下等分**。这种做法不依赖
        // 任何字体度量，行盒多大都能居中。
        //
        // 左右各 14：输入框不再是"两边各一颗圆"的结构，文字直接贴着
        // 玻璃边缘会显得没排完版（用户的原话："输入内容四个字太靠左"）。
        // 14 和卡片的内边距同一档，和上面那排按钮的左边线也对得上。
        // 这里**不能写 `const`**：`_inputPadV` 是按字号算出来的 getter，
        // 不是编译期常量。
        contentPadding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: _inputPadV,
        ),
        // ---- 框内只留**短提示** ----
        //
        // 原来这里是整句"说说要改什么。输入 @ 可指向文件、skill、某个时刻
        // 或当前会话"：一行放不下，只能 `hintMaxLines: 1` 硬截成
        // "说说要改什么。输入 @ 可指向文…"。截断的提示比没有提示更糟 ——
        // 它看起来像界面出了 bug。
        //
        // 现在框内只留"说说要改什么"。后半句（@ 能指向什么）**不再显示**：
        // 试过放在框下面一行，用户看了一版就要求删掉 —— 那句话每一屏都在，
        // 却只在第一次用时有用。@ 面板本身在打出 @ 的那一刻就会告诉用户
        // 它能指向什么，比常驻一行说明更及时。
        //
        // 短提示仍然保留 `hintText` 而不是纯装饰文字：它是这个输入框在
        // 无障碍树里的**名字**，删了之后读屏软件只会念"文本输入框"。
        hintText: '说说要改什么',
        hintMaxLines: 1,
        // 占位符必须和正文用同一套行盒，否则一打字
        // "输入内容"就往上跳一下（差的是 leading 的分布）。
        hintStyle: _inputStyle(s).copyWith(color: s.muted),
      ),
    );
  }

  /// 输入框正文的样式。
  ///
  /// ## 为什么 `leadingDistribution` 必须显式写成 `even`
  ///
  /// 行高 1.5（再乘全局 1.14 = 1.71）比字本身高出一截，多出来的那部分
  /// 叫 leading。Flutter 默认把它按字体上/下度量的比例分（`proportional`），
  /// 而这个字体上沿约 1.16em、下沿约 0.31em —— leading 里八成落在了字的**上面**。
  ///
  /// 结果就是：`contentPadding` 上下算得再对称（见 [_inputPadV]），
  /// 汉字在行盒里仍然偏下。dpr=3 逐像素量过：单行 `好的` 的墨迹中线比
  /// 两边那两颗圆的中线低 1.83 像素 —— 就是用户说的"输入的字和按钮没对齐"。
  ///
  /// `even` 把 leading 上下各分一半：同一个输入框里再量，墨迹中线比圆的中线
  /// **高 0.17** 像素（即对齐，剩下的偏差小于半个像素）。而且它和字号无关：
  /// 字号滑杆怎么动，行盒都是自洽的。
  /// 用 `Transform.translate` 去补才是错的 —— 那个偏移量得跟着字号走。
  static TextStyle _inputStyle(AppSurface s) => AppFonts.body(
    size: 15,
    color: s.text,
    height: 1.5,
  ).copyWith(leadingDistribution: TextLeadingDistribution.even);

  /// 输入框收到长文本时，把全文存进变量库，框里只留一个占位标记。
  ///
  /// 触发条件（缺一不可）：
  ///  · 文本长度超过 [kVarBankAutoStoreChars]；
  ///  · 当前不是"已经只剩占位标记"的状态（否则会反复存）；
  ///  · 时间上不是连续流式输入 —— 见下面 [kVarBankStashCooldown] 的说明。
  ///
  /// 为什么要有冷却：用户在输入法里**快速打字**时，`onChanged` 会连续触发。
  /// 每超过一次阈值就存一次，会生成一串 `var1`/`var2`/`var3`…… 而它们
  /// 只是同一段内容的中间态。冷却期内不再重复存，等用户停下来才处理。
  void _maybeStashLongInput() {
    final String text = _input.text;

    // 已经存过：只在占位标记被删掉时清理状态。
    final String? name = _varChipName;
    if (name != null) {
      final String token = varChipToken(name);
      if (!text.contains(token)) {
        // 占位标记被删了（用户按退格删到它 / 全选重打）。
        // 变量**不删** —— 用户可能只是不想这一段，再退格一次才删变量。
        _varChipName = null;
      } else {
        return;
      }
    }

    if (text.length <= kVarBankAutoStoreChars) return;
    // 已经把整段文本变成占位标记了，别再存。
    if (text.contains(kVarBankChipToken)) return;

    final DateTime now = DateTime.now();
    if (_lastStashAt != null &&
        now.difference(_lastStashAt!) < kVarBankStashCooldown) {
      return;
    }
    _lastStashAt = now;

    final VarBankStore bank = VarBankStore.instance;
    final String fresh = freshVarName(bank);
    if (bank.set(fresh, text, note: _previewNote(text)) != null) return;

    _varChipName = fresh;
    final String token = varChipToken(fresh);
    // 换掉输入框内容，把光标放到标记之后 —— 用户接着打字就是"在引用后面补话"。
    _input.value = TextEditingValue(
      text: token,
      selection: TextSelection.collapsed(offset: token.length),
    );
  }

  /// 上一次存库的时间。给 [_maybeStashLongInput] 的冷却用。
  DateTime? _lastStashAt;

  /// 存库冷却：这么短时间内不重复触发。
  ///
  /// 600ms 是"打字停顿"的量级：比它短的两次 onChanged 属于同一段连续输入，
  /// 只该在最开始处理一次；比它长的说明用户停了手，再粘一次新内容应当重新存。
  static const Duration kVarBankStashCooldown = Duration(milliseconds: 600);

  /// 当前选中的模型能不能用来对话。
  ///
  /// 有些模型（`gpt-image-2` / `dall-e-3` / `stable-diffusion-*`）**只提供
  /// 生图接口**，没有 `/chat/completions`。拿它们发消息会直接失败，
  /// 而服务端的报错完全没告诉用户该怎么做 —— 他只是在输入框里打了句话。
  bool get _activeModelChatless {
    final ModelProfile? p = widget.settings.activeProfile;
    return p != null && p.usable && !p.chat;
  }

  /// 「这个模型不能对话」的确认框。返回 true = 用户想去换模型。
  Future<bool> _confirmChatless() async {
    final ModelProfile p = widget.settings.activeProfile!;
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          '这个模型不能对话',
          style: AppFonts.body(size: 16, weight: FontWeight.w600, height: 1.3),
        ),
        content: Text(
          '「${p.displayName}」（${p.model}）是**仅生图**模型，'
          '它只提供 `/images/generations`，没有对话接口。\n\n'
          '发出去会被服务端拒绝，报错是 '
          '“not supported on chat completions endpoint”。',
          style: AppFonts.body(size: 13.5, height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('换个模型'),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  /// 「这个模型不能对话」的提示条。
  ///
  /// 夹在输入框**上方**、同属那块玻璃。只在这一种情况下出现：
  /// 当前模型只提供生图接口（`/images/generations`），没有对话接口。
  Widget _chatlessBanner(AppSurface s) {
    final ModelProfile p = widget.settings.activeProfile!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 17, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '「${p.displayName}」是**仅生图**模型，没有对话接口。'
              '在这里发消息会被服务端拒绝。'
              '想聊天请在下面换一个模型；想画图就直接说"画一张"。',
              style: AppFonts.body(
                size: 12,
                color: AppColors.warning,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 输入框的焦点节点。
  ///
  /// 只用来做一件事：拿到焦点的瞬间去取一次输入建议
  /// （见 [_onInputFocus]）。长按选词不走它 —— 那是 `TextField` 自己的事。
  final FocusNode _inputFocus = FocusNode();

  /// **待发送的引用**。
  ///
  /// 用户在消息里长按选中 → 「引用并回复」之后，这段话先挂在这里，
  /// 输入框上方显示一条引用条；发送时它跟着用户消息一起落库
  /// （见 `ChatMessage.quote`），同时在**原文那条消息**上留一道虚线锚点。
  MessageQuote? _pendingQuote;

  /// 输入框里挂着的「深入研究」标签（【+】→ 深度研究 设的）。
  ///
  /// 按设计稿：深入研究不跳新页，而是在原聊天里引用、在输入框显示
  /// 蓝色标签；下一条消息发出时，它会被当作研究请求发送，标签随即清掉。
  bool _pendingResearch = false;

  /// 待发送的引用**在原文留下的那道虚线锚点**（消息 + 标记本身）。
  ///
  /// 存下来是为了**取消引用时能精确删掉它** —— 只存文本的话，
  /// 取消之后那道虚线还留在消息上（用户报的就是这个）。
  (ChatMessage, TextMark)? _quoteAnchor;

  /// 每条消息的 GlobalKey，用于引用跳转的精确滚动。
  ///
  /// 用**消息索引**做 key 而不是消息 id：引用跳转拿到的是索引，
  /// 两边用同一套编号最省事；消息增删时整张表跟着重建。
  final Map<int, GlobalKey> _messageKeys = <int, GlobalKey>{};

  GlobalKey _keyFor(int index) =>
      _messageKeys.putIfAbsent(index, () => GlobalKey());

  /// 「重新生成」：把这条 AI 回复**和它之后的全部内容**删掉，再用同一条
  /// 用户消息重跑一遍。
  ///
  /// ## 为什么之后的内容也要删
  ///
  /// 重新生成等于"这一段还没发生"。只删那一条、把后续消息留在原地的活，
  /// 后面的回答就建立在一段已经不存在的上下文上了 —— 用户看到的是
  /// "生成了一条新的，但后面几条还引用着旧的"，那比不给这个功能更糟。
  ///
  /// ## 为什么不是原地重写那一条
  ///
  /// `AgentRunner` 是"往会话里追加"的，没有"替换某条"的入口。
  /// 硬要替换就得给它加一个模式，而那会让并发/中断那套逻辑多一个分支 ——
  /// 删掉重发复用同一条路径，行为可预测。
  Future<void> _regenerateFrom(ChatMessage from) async {
    final Conversation? conv = widget.conversations.current;
    if (conv == null || _busyFor(conv)) return;

    final int i = conv.messages.indexOf(from);
    if (i < 0) return;

    // 往前找最近的一条用户消息：重新生成的是**那一条的回答**。
    int u = i - 1;
    while (u >= 0 && conv.messages[u].role != Role.user) {
      u--;
    }
    if (u < 0) {
      _snack('这条之前没有用户消息，无法重新生成');
      return;
    }

    final String text = conv.messages[u].content;
    final List<Attachment> atts = conv.messages[u].attachments;

    setState(() {
      conv.messages.removeRange(u, conv.messages.length);
      // 把原话和附件放回待发区，走**和"发送"完全同一条路** ——
      // 包括描述改进、工具确认、中断这些都由那条路负责。
      _pending
        ..clear()
        ..addAll(atts);
    });
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _revealInputCaret();
    widget.conversations.touch(conv);
    if (mounted) await _send();
  }

  /// 「修改」：把这条用户消息放回输入框，改完自己再发。
  ///
  /// 和「重新生成」共用"从这条开始截断"的语义：改完之后发出去的是一条
  /// **新的**消息，原来的那条和它的回答都已经被删掉了 —— 否则会话里会
  /// 同时存在"改之前的问法和回答"与"改之后的问题"，模型会看糊涂。
  void _editFrom(ChatMessage from) {
    final Conversation? conv = widget.conversations.current;
    if (conv == null || _busyFor(conv)) return;

    final int i = conv.messages.indexOf(from);
    if (i < 0) return;

    final String text = from.content;
    final List<Attachment> atts = from.attachments;

    setState(() {
      conv.messages.removeRange(i, conv.messages.length);
      _pending
        ..clear()
        ..addAll(atts);
    });
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _revealInputCaret();
    widget.conversations.touch(conv);
    _inputFocus.requestFocus();
    _snack('已放回输入框，改完直接发送');
  }

  /// 「删除」：**只从最新一段开始删**，而且整段一起删。
  ///
  /// 一段 = 最后一条用户消息 + 它后面所有 AI 回复/工具过程。用户看到的是
  /// 「气泡和 AI 文本一起消失」，而不是留下一条没有上下文的孤儿回答。
  /// 删完这一段后，上一段自然成为“最新”，可以继续删 —— 所以连续删除就是
  /// 从后往前回退，不会从中间掏空对话。
  ///
  /// 运行中禁止删除：此刻 agent 还在往列表里追加，突然抽掉一段会让后面的
  /// 引用/工具状态对不上。等这一轮结束再删。
  Future<void> _deleteMessage(ChatMessage from) async {
    final Conversation? conv = widget.conversations.current;
    if (conv == null) return;
    if (_busyFor(conv)) {
      _snack('正在执行，等这一轮结束再删除');
      return;
    }

    // 最新一段的起点：最后一条可见用户消息；整场没有用户消息时退回最后一条
    // 可见消息。
    int start = -1;
    for (int i = conv.messages.length - 1; i >= 0; i--) {
      final ChatMessage m = conv.messages[i];
      if (!m.hidden && m.role == Role.user) {
        start = i;
        break;
      }
    }
    if (start < 0) {
      for (int i = conv.messages.length - 1; i >= 0; i--) {
        if (!conv.messages[i].hidden) {
          start = i;
          break;
        }
      }
    }
    if (start < 0) return;

    final int tapped = conv.messages.indexOf(from);
    if (tapped < start) {
      _snack('只能从最新的一段开始删除');
      return;
    }

    final String raw = conv.messages[start].content.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final String preview = raw.length > 80 ? raw.substring(0, 80) : raw;
    final int count = conv.messages.length - start;

    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除最新一段对话？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '会把最新这段的用户消息和 AI 回复一起删除（共 $count 条），'
              '删除后无法恢复。',
              style: AppFonts.body(size: 13, height: 1.5),
            ),
            if (preview.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                preview,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                  size: 12.5,
                  color: AppSurface.of(ctx).muted,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除这段', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    setState(() {
      conv.messages.removeRange(start, conv.messages.length);
      // 索引变了，引用跳转用的 key 表必须重建；否则下一次 ensureVisible
      // 会拿着旧索引去找一条已经不存在的消息。
      _messageKeys.clear();
      if (_quoteAnchor != null && !conv.messages.contains(_quoteAnchor!.$1)) {
        _quoteAnchor = null;
        _pendingQuote = null;
      }
      if (conv.messages.isEmpty) {
        conv.title = Conversation.defaultTitle;
      }
    });
    widget.conversations.touch(conv);
    widget.conversations.unawaitedSave();
    _snack('已删除最新一段');
  }

  /// 长按选中 → 「引用并回复」。
  void _quoteFrom(ChatMessage from, String selected) {
    final String t = selected.trim();
    if (t.isEmpty) return;
    final int occ = _occurrenceFor(_renderedTextOf(from.content), t, selected);
    setState(() {
      _pendingQuote = MessageQuote(text: t);
      // 顺手在原文留一道**虚线锚点** —— 这样回头翻记录能看出
      // "这句话被人接过"。用和引用同一个底色，视觉上能对上号。
      //
      // 锚点要记住它是哪条消息的哪一处，**取消引用时才好删掉** ——
      // 早先只存了文本，取消引用后那道虚线就永远留着了
      // （用户报的"引用后取消下划线还在"）。
      final TextMark anchor = TextMark(
        text: t,
        kind: MarkKind.quote,
        color: MarkColor.blue,
        occurrence: occ,
      );
      _quoteAnchor = (from, anchor);
      if (!from.marks.any((TextMark m) => m.samePlaceAs(anchor))) {
        from.marks.add(anchor);
      }
    });
    widget.conversations.save();
    _inputFocus.requestFocus();
  }

  /// 取消待发送的引用，**同时把原文那道虚线锚点也撤掉**。
  ///
  /// 只清 `_pendingQuote` 是不够的：锚点是实打实写进消息数据里的，
  /// 留着它界面上就永远有一道"这句话被引用过"的虚线，
  /// 可实际上引用已经取消了。
  void _cancelQuote() {
    final (ChatMessage, TextMark)? a = _quoteAnchor;
    setState(() {
      _pendingQuote = null;
      _quoteAnchor = null;
      if (a != null) {
        a.$1.marks.removeWhere((TextMark m) => m.samePlaceAs(a.$2));
      }
    });
    widget.conversations.save();
  }

  /// 长按选中 → 某个底色的「标记」。
  void _markOn(ChatMessage on, String selected, MarkColor color) {
    final String t = selected.trim();
    if (t.isEmpty) return;

    // **出现次序只能在完整原文上算。**
    //
    // 渲染器是按"块"工作的（一个段落一个 Text.rich），它不知道用户选的
    // 是全文第几个「的」—— 所以这里算的是**整条消息**的次序。
    //
    // ⚠️ 但基准必须是 `_renderedTextOf`（渲染后的正文），**不是 `on.content`**：
    // 原文里带着 markdown 语法（`**`、`- `、`[文字](url)`），
    // 链接地址里的字会让计数整体错位 —— 标记就"飘到其他地方的相同字"上。
    final int occ = _occurrenceFor(_renderedTextOf(on.content), t, selected);

    setState(() {
      // 同一处重复标记时**覆盖颜色**，不新增一条 ——
      // 判据是"文本 + 次序 + 种类"，不含颜色（见 TextMark.samePlaceAs）。
      final TextMark place = TextMark(
        text: t,
        kind: MarkKind.mark,
        occurrence: occ,
      );
      on.marks.removeWhere((TextMark m) => m.samePlaceAs(place));
      on.marks.add(place.copyWith(color: color));
    });
    widget.conversations.save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已标记。长按选中同一段可以换色，或选「取消标记」。'),
          duration: Duration(milliseconds: 1800),
        ),
      );
    }
  }

  /// 长按选中 → 「取消标记」。
  ///
  /// 按**选中的文字 + 出现次序**去找标记，找不到就如实说 ——
  /// 与其静默失败（用户以为取消了、其实还在），不如给一句话。
  void _unmarkOn(ChatMessage on, String selected) {
    final String t = selected.trim();
    if (t.isEmpty) return;
    final int occ = _occurrenceFor(_renderedTextOf(on.content), t, selected);

    final int before = on.marks.length;
    setState(() {
      on.marks.removeWhere(
        (TextMark m) =>
            m.text == t && m.occurrence == occ && m.kind == MarkKind.mark,
      );
    });
    widget.conversations.save();

    if (!mounted) return;
    final bool removed = on.marks.length < before;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(removed ? '已取消标记' : '这一段没有标记'),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  /// 消息**渲染之后**的正文（去掉 markdown 语法）。
  ///
  /// 标记的"第几次出现"必须对着这份文本算 —— 渲染器数的就是它。
  /// 拿 `message.content`（原文）算的话，`[文档](https://x.com/的)` 里那个
  /// **藏在链接地址里的字**也会被算进去，而渲染结果里根本没有它 ——
  /// 计数整体错位，标记就"飘到其他地方的相同字"上。
  String _renderedTextOf(String content) {
    try {
      return MarkdownView.plainTextOf(content, AppSurface.of(context));
    } catch (_) {
      // 解析出问题就退回原文：计数可能偏，但不能因此崩掉、也不能标都标不上。
      return content;
    }
  }

  /// 选中的片段是全文里**第几次**出现。
  ///
  /// [raw] 是**没有 trim 过的原选区** —— 优先用它在 content 里定位，
  /// 这样算出来的次序和渲染时看到的完全一致。
  /// （拿 trim 过的串去找，前面恰好也有同样文字时会错位。）
  static int _occurrenceFor(String content, String trimmed, String raw) {
    final int at = raw.isEmpty ? -1 : content.indexOf(raw);
    final String probe = at >= 0 ? raw : trimmed;
    final int from = at >= 0 ? at : content.indexOf(trimmed);
    if (from < 0) return 0;
    int occ = 0;
    int i = 0;
    while (true) {
      final int k = content.indexOf(probe, i);
      if (k < 0 || k >= from) break;
      occ++;
      i = k + probe.length;
    }
    return occ;
  }

  /// 点一下消息上的引用条 → 滚到被引用那段的原文。
  ///
  /// 用**消息的 GlobalKey + ensureVisible**，而不是"按平均高度估算
  /// 一个偏移量再 animateTo"。
  ///
  /// 估算那套完全不可用：消息高度差得很远（一行文字 vs 一张表格），
  /// 原来按 160px 一条猜，长会话里能偏出好几屏 ——
  /// 用户看到的就是"点了引用什么都没发生"（虽然确实滚了，只是滚错地方）。
  /// `ensureVisible` 由框架按**真实布局**计算，永远准。
  void _jumpToQuote(Conversation conv, MessageQuote quote) {
    final String needle = quote.text.trim();
    if (needle.isEmpty) return;
    final int idx = conv.messages.indexWhere(
      (ChatMessage m) => m.content.contains(needle),
    );
    if (idx < 0) return;

    final GlobalKey? key = _messageKeys[idx];
    final BuildContext? ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
        // 对齐到**靠近顶部**：引用要看的是那句话的上下文，
        // 居中的话上面那段会被挡在顶栏后面。
        alignment: 0.15,
      );
      return;
    }
    // 那条消息还没被构建出来（在屏幕外很远，ListView 没建它）。
    // 这时没法 ensureVisible —— 先粗滚到附近让它进入构建范围，
    // 等这次滚动动画结束、它真的建出来了，再做一次精确滚动。
    final int reversed = conv.messages.length - 1 - idx;
    final double rough = (reversed * 200.0).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll
        .animateTo(
          rough,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        )
        .then((_) => _fineScrollTo(key));
  }

  /// 粗滚之后再精确定位一次。
  ///
  /// 单独一个 async 方法是为了让 `mounted` 检查和 context 的使用
  /// **落在同一个同步段里** —— 写在 `.then()` 里的话 linter 会报
  /// `use_build_context_synchronously`（它看不穿那个闭包）。
  Future<void> _fineScrollTo(GlobalKey? key) async {
    if (!mounted) return;
    final BuildContext? ctx = key?.currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 200),
      alignment: 0.15,
    );
  }

  /// 输入框上方那条**引用条**（待发送的引用）。
  ///
  /// 和消息上的引用卡片刻意用**同一套视觉**（左侧竖线 + 平面文字）：
  /// 两处说的是同一件事（"我要回应这段话"），长得不一样会让人以为是
  /// 两种东西。
  /// 输入框上方的蓝色「深入研究」标签。点 × 可以取消。
  /// 输入框下面那行小字：长文本已存进变量库，点一下看全文。
  ///
  /// ## 为什么是"输入框下面"而不是塞进输入框
  ///
  /// 输入框里只有一行占位标记（"[已存入变量库 · var1]"），它需要一个
  /// **额外的入口**指向内容 —— 用户点了才能看到自己存了什么、也才能确认
  /// "我要发的是这一段"。这一行就是那个入口。
  ///
  /// 用 12 号字、`muted` 色：它是注脚，不是操作按钮，不该和正文抢注意力。
  Widget _varHintRow(AppSurface s) {
    final String name = _varChipName!;
    final Variable? v = VarBankStore.instance.get(name);
    final String size = v == null
        ? '（变量已删除）'
        : '${v.lines} 行 · ${humanBytes(v.bytes)}';
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 2, bottom: 1),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: _showVarChipContent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.inventory_2_outlined, size: 12, color: s.muted),
                const SizedBox(width: 5),
                Text(
                  '已存入变量库 · $name · $size',
                  style: AppFonts.body(size: 12, color: s.muted, height: 1.3),
                ),
                const SizedBox(width: 6),
                Text(
                  '点击查看',
                  style: AppFonts.body(
                    size: 12,
                    color: AppColors.accent,
                    weight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 弹出：这条被存进变量库的内容，以及"改用纯文本发"的出口。
  Future<void> _showVarChipContent() async {
    final String? name = _varChipName;
    if (name == null) return;
    final Variable? v = VarBankStore.instance.get(name);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return AlertDialog(
          title: Text(
            '已存入变量库：$name',
            style: AppFonts.body(
              size: 16,
              weight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                v?.text ?? '（变量已删除）',
                style: AppFonts.body(size: 13.5, height: 1.6, color: s.text),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _expandVarChipToText();
              },
              child: const Text('取回全文'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// 把输入框里的占位标记换回**变量全文**（占位标记消失，变量不删）。
  ///
  /// 这是"我想直接改这段文字"的出口：有时候用户就是要在原文上改几笔，
  /// 而不是引用它。
  void _expandVarChipToText() {
    final String? name = _varChipName;
    if (name == null) return;
    final Variable? v = VarBankStore.instance.get(name);
    if (v == null) return;
    final String token = varChipToken(name);
    final String body = _input.text;
    final String next = body.contains(token)
        ? body.replaceAll(token, v.text)
        : v.text;
    setState(() {
      _varChipName = null;
      _input.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });
    // 展开变量库 = 把那一大段原文换回输入框，光标在末尾，得跟下去。
    _revealInputCaret();
  }

  Widget _researchTag(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
          decoration: BoxDecoration(
            color: AppColors.research.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(
              color: AppColors.research.withValues(alpha: 0.45),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.travel_explore_rounded,
                size: 14,
                color: AppColors.research,
              ),
              const SizedBox(width: 5),
              Text(
                '深入研究',
                style: AppFonts.body(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: AppColors.research,
                ),
              ),
              const SizedBox(width: 2),
              InkWell(
                onTap: () => setState(() => _pendingResearch = false),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: AppColors.research,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quoteBar(AppSurface s) {
    final MessageQuote q = _pendingQuote!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 3, 2, 3),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: q.color.background(
                dark: Theme.of(context).brightness == Brightness.dark,
              ),
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.format_quote_rounded, size: 13, color: s.muted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                q.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 12.2, color: s.muted, height: 1.45),
              ),
            ),
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              tooltip: '取消引用',
              icon: Icon(Icons.close_rounded, color: s.muted),
              // 用 _cancelQuote 而不是只清 _pendingQuote ——
              // 那道虚线锚点也要一起撤掉（见 _cancelQuote 的注释）
              onPressed: _cancelQuote,
            ),
          ],
        ),
      ),
    );
  }

  /// 返回 true 表示用户在全屏页点了「完成并发送」——那时直接走 [_send]。
  Future<void> _openFullscreenInput() async {
    // 先收起键盘再推页面：不然键盘会因为输入焦点转移而闪一下，
    // 全屏页里那个 TextField 自己会重新拉起它。
    FocusScope.of(context).unfocus();
    final bool send = await FullscreenInputPage.open(
      context,
      controller: _input,
    );
    if (!mounted) return;
    setState(() {});
    if (send) await _send();
  }

  // ---- 那两个行盒常量（`_chipStrut` / `_chipHeightBehavior`）到这儿为止 ----
  //
  // 它们是给**旧的那颗模型胶囊**调的：那一行里同时有中文模型名和拉丁的
  // 思考深度，两种字体 ascent/descent 不一样，必须把行盒钉死才对得齐。
  //
  // 现在模型选择器收进了收起态那一行，里面只有**一段文字 + 一个图标** ——
  // 没有混排就没有对不齐的问题，而钉死的行盒（13pt 的 strut 套 12.5pt 的字）
  // 反而把多出来的行距全堆在字上面，看着就是"文字比图标高"。
  // 所以两个常量一起删掉：Row 默认居中，两者自然在同一条中线上。

  // ---- 「浏览器正在使用 / Termux Running」那一行 2026-10-16 撤掉了 ----
  //
  // 它原来是"浏览器一行、终端一行"，后来合成一行贴在输入框上方。
  // 现在整行都不画了：那一块位置属于输入框，而"谁在忙"这件事由收起态
  // 右边那颗指示圆表达（有工具在跑就换成浏览器 / 终端 / 闪电图标并上色，
  // 点开是「工具与权限」详情，见 [_composerCollapsedRest]）。
  //
  // [_pickBusyTarget] 留着：详情面板里"两边都在忙"时还是用它问一句。

  Future<void> _pickBusyTarget() async {
    final AppSurface s = AppSurface.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Text(
                '现在两边都在忙',
                style: AppFonts.body(
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: s.muted,
                ),
              ),
            ),
            ListTile(
              leading: Icon(
                Icons.public_rounded,
                size: 20,
                color: AppColors.accent,
              ),
              title: Text(
                '看浏览器那一页',
                style: AppFonts.body(size: 14.5, color: s.text),
              ),
              subtitle: Text(
                WebViewLoader.activity.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 11.5, color: s.muted),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                BrowserPage.open(
                  context,
                  url:
                      WebViewLoader.liveUrl ??
                      browserHomeUrl(widget.settings.searchEngine),
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.terminal_rounded,
                size: 20,
                color: AppColors.accent,
              ),
              title: Text(
                '看正在跑的命令',
                style: AppFonts.body(size: 14.5, color: s.text),
              ),
              subtitle: Text(
                TerminalSession.instance.runningLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.code(size: 11.5, color: s.muted),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                openTerminal(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 待发的图片/文件：**挂在输入框外面**的一条。
  ///
  /// ## 为什么不塞进输入框里
  ///
  /// 用户的原话："插入的文件和图片，统一放在输入框外面挂着，不要挤在
  /// 输入框里面。"
  ///
  /// 这也确实更合理 —— 它和输入框不是一回事：输入框是"我现在要写的字"，
  /// 而这几张是"已经挂在消息上、等着跟它一起发出去的东西"。
  /// 挂在外面之后：
  ///  · 输入框本身**高度恒定**，不会因为贴了几张图就长高一截；
  ///  · 缩略图右上角那个删除角标本来就必须压线，挂在外面之后
  ///    怎么放都不会被玻璃边框圈住。
  Widget _pendingStrip(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: SizedBox(
        // 一颗小胶囊的高度：缩略图 28 + 上下 5，和下面模型那一行同一档。
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pending.length,
          separatorBuilder: (BuildContext _, int _) => const SizedBox(width: 6),
          itemBuilder: (BuildContext context, int i) =>
              _pendingChip(s, _pending[i], i),
        ),
      ),
    );
  }

  /// 一个待发附件：**一只小框装缩略图 + 文件名**。
  ///
  /// ## 为什么从 66×66 的方块改成一条小胶囊
  ///
  /// 之前每张图占 66×66，十个附件就是一整条几乎顶到屏幕宽的缩略图墙 ——
  /// 它会顶掉正文两三行，而且用户要的信息其实只有两个：
  /// "选的是哪几个"和"要不要删掉一个"。整张缩略图墙对这两件事都过度。
  ///
  /// 现在是一枚 38 高的胶囊：左边 28 的缩略图（图片是图本身，文件是
  /// 一个类型图标），右边一行文件名，末尾一颗很小的 ×。十个并排也就
  /// 两行正文的高度，而且每个都能一眼认出来。
  Widget _pendingChip(AppSurface s, Attachment a, int i) {
    return AttachmentChip(
      attachment: a,
      onTap: a.isImage
          ? () => showImageViewer(context, path: a.path, title: a.name)
          : null,
      onRemove: () => setState(() => _pending.removeAt(i)),
    );
  }

  /// 输入框右边的**模型按钮**：点开先选思考强度，顶部一行进模型列表。
  ///
  /// ## 为什么把两个旋钮放在同一处
  ///
  /// "用哪个模型"和"想多深"是同一个决定的两种颗粒度：换模型常常就是
  /// 想换强度（便宜的模型配低强度、贵的配高强度）。分两处的话，
  /// 用户每次都要先去 A 看一眼、再去 B 点一下。
  ///
  /// 所以第一层只露**强度**（四档，图标一眼能分），最上面一行
  /// 「选择模型」才是第二层 —— 那件事更重（会换掉整个后端和 key），
  /// 不该和日常调档混在一排。
  Widget _modelButton(AppSurface s) {
    final ModelProfile? p = widget.settings.activeProfile;
    // 参考图里这一处是**裸文字**：「✳ Fable 5.1 Low」——
    // 厂商图标 + 模型名 + 思考深度，没有胶囊底、没有描边。
    //
    // 图标是**厂商**的（Claude / GPT / Gemini…），不是思考档位：
    // 用户在这一行认的是"现在用的是谁家的模型"，档位是附带的第二个信息。
    // 档位用文字跟在名字后面（`Low` / `Deep` / `Max`），比一个抽象图形
    // 更容易读懂 —— 参考图里也是这么写的。
    // ---- 显示的是**档案名**（用户自己起的）----
    //
    // 之前显示 `p.model`（API 里的真实模型名，`deepseek-v4-flash` 这种），
    // 理由是"一眼知道用的是哪个模型"。用户要的正好相反：他要看到
    // **自己起的那个名字**（"日常主力"）—— 那是他自己建立的心智标签，
    // 比一串带版本号的英文更认得出"我现在在用哪一个"。
    //
    // 档案名是必填的（新建时就有），`p.model` 只影响调用参数，不该露在界面上。
    final String name = (p == null) ? '选模型' : p.displayName;
    final int level = modelEffortLevel(widget.settings);
    final String effort = effortTagOf(widget.settings);
    return Pressable(
      key: const ValueKey<String>('chat.modelButton'),
      onTap: _showModelMenu,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // ---- 图标是**思考档位**，不是厂商 ----
            //
            // 用过一版厂商图标（Claude 的星芒、GPT 的六边形…），问题是
            // 这一行真正要回答的是"这条消息想多深"，而厂商在右上的模型
            // 菜单里已经写了一行字。图标跟档位走，一眼就能看出当前是
            // 闪电 / 积木 / 土星，不用去读后面那个 `Deep`。
            //
            // 「关闭思考」没有档位图标（见 [_effortGlyph]），用一个空心圈
            // 占位：这个位置不能塌，否则整行会往左挪 23px 跳一下。
            SizedBox(
              width: 16,
              height: 16,
              child: Center(
                child:
                    _effortGlyph(level, size: 16, color: s.muted) ??
                    Icon(
                      Icons.circle_outlined,
                      size: 12,
                      color: s.muted.withValues(alpha: 0.55),
                    ),
              ),
            ),
            const SizedBox(width: 7),
            // ---- 模型名深、档位浅 ----
            //
            // 深浅两级把"叫什么"和"想多深"分开：名字是主信息（`s.text`），
            // 档位是附注（`s.muted`）。之前两者同色，读起来是一长串。
            //
            // 不再需要 `Transform.translate` 上提：Inter 的字形在
            // `leadingDistribution: even` 下已经居中，实测墨迹中线和
            // 左边图标差不到 1px。
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 132),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // 行高钉死 1.2：和右边那截深度文字**共用同一条基线**。
                    // 不钉的话两边各自按字体度量算行盒，放大之后能差半个像素。
                    style: AppFonts.body(
                      size: 12.5,
                      weight: FontWeight.w500,
                      color: s.text,
                      height: 1.2,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                if (effort.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 5),
                  Text(
                    effort,
                    style: AppFonts.body(
                      size: 12.5,
                      color: s.muted,
                      height: 1.2,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 四档强度各自的图标。
  ///
  /// 用形状而不是文字："低/中/高"三个字在 11 号字下几乎分不出，
  /// 而闪电 / 积木 / 土星 的轮廓差得很开。
  ///
  /// **「关闭思考」没有图标**（用户要求）：它不是一个"档位"，而是"不思考"，
  /// 和另外三个并排放一个图标反而误导。返回 null，调用点直接不画。
  ///
  /// 三档的对应关系（用户指定）：
  ///  · 低 → **闪电**（一下就过，想得最少）；
  ///  · 中 → **弯月**（半亮半暗，想了一半）；
  ///  · 高 → **土星**（带星环，想得最远）。
  ///
  /// 「中」最早是 `psychology_alt_outlined`（一个脑袋，16px 下糊成一团），
  /// 后来试过积木（三块方块，太碎）。现在是**弯月**：一个挖掉一轮的圆，
  /// 形状上和闪电（折线）、土星（环）都分得开，而且"半明半暗"本身就是
  /// "中等"最直白的读法。
  ///
  /// 「高」用**带星环的土星**而不是地球：地球读起来像"联网/全球"，
  /// 土星才是"想得更远"的那层意思；Material 也没有土星，同样自己画。
  static Widget? _effortGlyph(int level, {double size = 18, Color? color}) {
    final Color c = color ?? const Color(0xFF000000);
    switch (level) {
      case 0:
        return null;
      case 1:
        return Icon(Icons.bolt_rounded, size: size, color: c);
      case 2:
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _CrescentPainter(c)),
        );
      default:
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _SaturnPainter(c)),
        );
    }
  }

  static String _effortLabel(int level) => switch (level) {
    0 => '关闭思考',
    1 => '低',
    2 => '中',
    _ => '高',
  };

  /// 模型按钮的菜单：**第一层只调思考深度**。
  ///
  /// 两层结构（用户要求）：
  ///  · 点输入框里的模型按钮 → 只有四档思考深度 + 底部一行「模型设置」；
  ///  · 点「模型设置」→ 另一张卡，列出模型（deepseek / anthropic…）。
  ///
  /// 为什么拆开："用哪个模型"和"想多深"颗粒度差太多。换模型会换掉
  /// 整个后端和 key，是低频的重操作；调档是每一句话都可能改的高频动作。
  /// 塞进同一张卡时，调一次档要先跨过一串模型名。
  ///
  /// 卡片锚在**输入区**上（不是按钮上），所以永远贴着输入框上沿，
  /// 输入框变高也不会跑到别处去。
  Future<void> _showModelMenu() async {
    final int current = modelEffortLevel(widget.settings);

    // 第一层：**只有思考深度**。锚点用整块输入区，卡片贴着输入框上沿。
    //
    // 模型列表是另一张卡（点卡片底部那行「模型设置」才出来）：
    // 调档是"这句话怎么想"，换模型是"换掉整个后端和 key"，
    // 混在同一张卡里，每次调档都要先跨过一串模型名。
    final String? action = await showAnchoredCard<String>(
      context,
      anchorBuilder: () => _rectOfComposer() ?? _fallbackComposerAnchor(),
      width: 224,
      gap: 6,
      align: CardAlign.left,
      cardPadding: const EdgeInsets.symmetric(vertical: 4),
      builder: (BuildContext ctx) =>
          _effortPanel(ctx, AppSurface.of(ctx), current),
    );
    if (!mounted || action == null) return;

    if (action == 'model') {
      await _showModelCard();
      return;
    }
    if (action.startsWith('effort:')) {
      final int level = int.tryParse(action.substring(7)) ?? current;
      applyEffortLevel(widget.settings, level);
      if (mounted) setState(() {});
    }
  }

  /// 第二层：模型卡片。只列模型，点一行直接切过去。
  ///
  /// 「管理」才是完整设置（新增 / 编辑 / 删 key），那件事重得多，
  /// 放进 `showModelPicker`，不在这张小卡片里展开。
  Future<void> _showModelCard() async {
    final String? action = await showAnchoredCard<String>(
      context,
      anchorBuilder: () => _rectOfComposer() ?? _fallbackComposerAnchor(),
      width: 224,
      gap: 6,
      align: CardAlign.left,
      cardPadding: const EdgeInsets.symmetric(vertical: 4),
      builder: (BuildContext ctx) => _modelPanel(ctx, AppSurface.of(ctx)),
    );
    if (!mounted || action == null) return;

    if (action == 'manage') {
      final String? picked = await showModelPicker(
        context,
        settings: widget.settings,
        anchorBuilder: () => _rectOfComposer() ?? _fallbackComposerAnchor(),
        align: CardAlign.left,
      );
      if (picked != null) widget.settings.selectProfile(picked);
      if (mounted) setState(() {});
      return;
    }
    if (action.startsWith('profile:')) {
      widget.settings.selectProfile(action.substring(8));
      if (mounted) setState(() {});
    }
  }

  /// 思考深度卡片的**本体**。
  ///
  /// 结构：
  /// ```
  /// 思考深度
  /// ⚡ 关闭思考        ✓
  /// ⚡ 低
  /// 🧠 中
  /// 🌐 高
  /// ─────────────────
  /// ⚙ 模型设置   deepseek  ›
  /// ```
  ///
  /// ⚠️ 这里**不要再包一层 `SurfaceCard`**：`showAnchoredCard` 已经给了
  /// 一张卡片。里面再套一张，两张卡的圆角对不齐，外层的玻璃就会在
  /// 上下圆角那里露出一个"罩子"。
  Widget _effortPanel(BuildContext ctx, AppSurface s, int current) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
          child: Text(
            '思考深度',
            style: AppFonts.body(
              size: 11.5,
              weight: FontWeight.w600,
              color: s.muted,
              letterSpacing: 0.4,
            ),
          ),
        ),
        for (int i = 0; i < 4; i++)
          _panelRow(
            s,
            leading: _effortGlyph(
              i,
              color: i == current ? AppColors.accent : s.muted,
            ),
            label: _effortLabel(i),
            selected: i == current,
            onTap: () => Navigator.of(ctx).pop('effort:$i'),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Divider(height: 0.8, thickness: 0.8, color: s.border),
        ),
        _panelRow(
          s,
          leading: Icon(Icons.tune_rounded, size: 18, color: s.muted),
          label: '模型设置',
          value: widget.settings.activeProfile?.displayName,
          trailingChevron: true,
          onTap: () => Navigator.of(ctx).pop('model'),
        ),
      ],
    );
  }

  /// 小卡片里的一行：图标 + 文字 +（可选）当前值 / 勾选 / 右箭头。
  ///
  /// 行高 38：这是两百来宽的小卡片，行高再大就变回"半屏菜单"了。
  ///
  /// [leading] 为 null 时**不占位**：「关闭思考」那一行本来就没有图标。
  Widget _panelRow(
    AppSurface s, {
    required Widget? leading,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
    String? value,
    bool trailingChevron = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 14,
                    weight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? AppColors.accent : s.text,
                  ),
                ),
              ),
              if (value != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 84),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(size: 11.5, color: s.muted),
                  ),
                ),
              if (selected)
                Icon(Icons.check_rounded, size: 16, color: AppColors.accent),
              if (trailingChevron)
                Icon(Icons.chevron_right_rounded, size: 18, color: s.muted),
            ],
          ),
        ),
      ),
    );
  }

  /// 模型卡片的**本体**：一张米白小卡片，不是黑块。
  ///
  /// ## 结构（按用户草图）
  ///
  /// ```
  /// 模型设置                    管理
  /// ─────────────────────────
  /// deepseek                  ✓
  /// anthropic
  /// ```
  ///
  /// 模型名直接用档案的 `displayName` —— 用户看到的就是他在
  /// 设置里给那条配置起的名字，不需要再翻译一层。
  Widget _modelPanel(BuildContext ctx, AppSurface s) {
    final String? activeId = widget.settings.activeProfile?.id;
    // 隐藏的模型**不在这里出现**：输入框旁那条路径（思考深度 → 模型设置）
    // 和「管理」里的完整选择器必须是同一套规则，否则用户会看到
    // "这处藏了、那处还在"。
    final List<ModelProfile> profiles = <ModelProfile>[
      for (final ModelProfile p in widget.settings.profiles)
        if (!widget.settings.isProfileHidden(p.id) || p.id == activeId) p,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // ---- 标题行 ----
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 4, 2),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '模型设置',
                  style: AppFonts.body(
                    size: 14,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.2,
                  ),
                ),
              ),
              InkWell(
                onTap: () => Navigator.of(ctx).pop('manage'),
                borderRadius: BorderRadius.circular(AppRadius.field),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    '管理',
                    style: AppFonts.body(
                      size: 12,
                      weight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Divider(height: 0.8, thickness: 0.8, color: s.border),
        ),
        // ---- 模型列表 ----
        if (profiles.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
            child: Text(
              '还没有模型，点右上角「管理」添加一个。',
              style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
            ),
          )
        else
          for (final ModelProfile p in profiles)
            _panelRow(
              s,
              // 模型列表里统一用**AI 图标**。
              //
              // 之前给每一行画了厂商图标（Claude 的星芒、GPT 的六边形…）。
              // 用户要求换回同一个 AI 图标：这张卡里每一行都已经是
              // **用户自己起的名字**，图标再按厂商分家，反而让人以为
              // 不同行是"不同种类的东西"。一个统一的字形说明"这都是一类
              // 东西：可选的 AI"，区分靠名字。
              leading: Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: p.id == activeId ? AppColors.accent : s.muted,
              ),
              label: p.displayName,
              selected: p.id == activeId,
              onTap: () => Navigator.of(ctx).pop('profile:${p.id}'),
            ),
      ],
    );
  }

  /// 发送键：**回车图标，没有底色**。
  ///
  /// 用户要的是"不要圆形背景，图标是回车键，没有输入淡色、输入了深色"。
  ///
  /// 这个改动和 [_composerGlass] 的描边是一套的：输入框自己已经是一块
  /// 有边界的面板，里面再放一颗实心圆就是"面板里嵌了一个按钮"。
  /// 图标**直接浮在面板上**，和输入的文字同一种语言 —— 框里只有
  /// "我要说的话"和"回车发出去"，没有第二个形状。
  ///
  /// ## 两档颜色就是两档状态
  ///
  ///  · 空：`muted` + 45% 透明 —— 淡到一个**看着就不该点**的程度；
  ///  · 有内容：`s.text`（不是强调色）—— 深色的字形，安静但确定。
  ///
  /// 为什么不用强调色：强调色在这个界面里留给"选中/进行中"（勾选、
  /// 正在跑）。发送是一个**过渡动作**，不是状态。深色的回车读起来是
  /// "敲一下就发"，而不是"一个需要被注意的按钮"。
  Widget _sendButton(AppSurface s, bool hasContent) {
    return IconButton(
      icon: const Icon(Icons.keyboard_return_rounded),
      iconSize: 21,
      tooltip: hasContent ? '发送' : '先输入内容',
      onPressed: hasContent ? _send : null,
      style: IconButton.styleFrom(
        // 没有底色、没有描边 —— 按下时也只有 `InkResponse` 自带的
        // 那一圈涟漪，不改变平常的样子。
        backgroundColor: Colors.transparent,
        foregroundColor: hasContent ? s.text : s.muted.withValues(alpha: 0.45),
        disabledForegroundColor: s.muted.withValues(alpha: 0.45),
        // 和左边「+」「麦克风」一样 36 的方形盒：这一行三颗的
        // 中线、右边缘才对得上。
        minimumSize: Size.square(_circleInRow),
        // 别让 48 的 tapTarget 把布局尺寸撑大（见原注释：多出来的
        // 透明边会让右边缘和上一版对不齐）。
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// 「高」档的图标：**带星环的土星**。
///
/// Material 里没有土星，`Icons.public` 是地球 —— 它读起来更像"联网/全球"，
/// 而不是"想得深"。这里画一个：一颗实心圆 + 一圈斜着的椭圆环，
/// 环的下半段压在星球前面（有被遮挡的感觉），上半段藏在后面。
///
/// 尺寸跟着调用方给的 `size` 走，描边按比例缩放，所以在 15px 的按钮里
/// 和 18px 的菜单里都清楚。
class _SaturnPainter extends CustomPainter {
  const _SaturnPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double r = size.width * 0.28;
    final Rect ringRect = Rect.fromCenter(
      center: Offset.zero,
      width: size.width * 0.96,
      height: size.height * 0.40,
    );
    final Paint ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.09
      ..strokeCap = StrokeCap.round;
    final Paint planet = Paint()..color = color;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-0.38);

    // 环的后半段（先画，会被星球盖住）
    canvas.drawArc(ringRect, 3.14159, 3.14159, false, ring);
    // 星球
    canvas.drawCircle(Offset.zero, r, planet);
    // 环的前半段（压在星球下沿，形成"穿过"的感觉）
    canvas.drawArc(ringRect, 0, 3.14159, false, ring);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SaturnPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 「中」档的图标：**三块积木**（下面两块并排，上面一块居中）。
///
/// **弯月**：一个实心圆，挖掉一个偏右上的圆。
///
/// 为什么是弯月：
///  · 上一版是积木（三块小方块），16px 下三块之间的缝只剩 1px，
///    远看像一颗脏点；
///  · 弯月是一个**单一的大形状**，缩到 14px 轮廓仍然清楚；
///  · 语义上也最直白 —— "半明半暗"就是"想了一半"，和闪电（一下过）、
///    土星（想到天外）正好三档递进。
///
/// 挖掉的那个圆偏右上（而不是正右）：这样月亮的开口朝上，形态是
/// "上弦月"，和土星那圈斜环在视觉上不会撞。
class _CrescentPainter extends CustomPainter {
  const _CrescentPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Offset c = Offset(size.width / 2, size.height / 2);
    // 半径 0.42 → **0.34**：上一版月牙几乎顶满了整个方框（上下左右各剩
    // 1px），和旁边的文字摆在一起显得"胖"，而且 16px 的盒子里它是唯一
    // 一个铺满的图形 —— 闪电是字形（自带内边距）、土星只占地 0.56。
    //
    // 0.34 之后四周留出约 2.5px，三档图标在同一行上的"视觉重量"才对得上。
    final double r = s * 0.34;

    final Path disc = Path()
      ..addOval(Rect.fromCircle(center: c, radius: r));
    // 挖掉的圆：中心偏右（0.55r）偏上（-0.30r），半径 0.86r。
    //
    // 这几个比例决定"月牙有多粗"：挖的圆越靠右、越小，月牙越宽；
    // 太宽就成了满月，太窄在 14px 下会断成一根细线。
    final Path bite = Path()
      ..addOval(
        Rect.fromCircle(
          center: c + Offset(r * 0.55, -r * 0.30),
          radius: r * 0.86,
        ),
      );

    canvas.drawPath(
      Path.combine(PathOperation.difference, disc, bite),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _CrescentPainter oldDelegate) =>
      oldDelegate.color != color;
}

///
/// 只用"红色圆"还不够 —— 静止的红色和"禁用"在色觉上很接近。
/// 加一个持续呼吸的圆点，用户一眼就知道"它在听"，也知道再点一下会停。
class _RecordingGlyph extends StatefulWidget {
  const _RecordingGlyph();

  @override
  State<_RecordingGlyph> createState() => _RecordingGlyphState();
}

class _RecordingGlyphState extends State<_RecordingGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FadeTransition(
          opacity: Tween<double>(
            begin: 0.25,
            end: 1,
          ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
          child: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 3),
        const Icon(Icons.stop_rounded, size: 14, color: Colors.white),
      ],
    );
  }
}
