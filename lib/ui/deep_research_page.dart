import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/agent.dart';
import '../core/background.dart';
import '../core/models.dart';
import '../core/overlay.dart';
import '../core/productivity.dart';
import '../core/store.dart';
import '../plugins/plugin.dart';
import '../shizuku/shizuku_service.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../tools/android_tools.dart';
import '../tools/browser_tool.dart';
import '../tools/extra_tools.dart';
import '../mcp/mcp_store.dart';
import '../tools/knowledge_tool.dart';
import '../tools/learning_tool.dart';
import '../tools/mcp_tool.dart';
import '../tools/memory_tool.dart';
import '../tools/model_tool.dart';
import '../tools/productivity_tools.dart';
import '../tools/python_tool.dart';
import '../tools/rule_tool.dart';
import '../tools/tool.dart';
import 'widgets.dart';

/// 「深入探究」页：给一个题目，跑一条**多轮检索 + 交叉验证**的链，
/// 产出一份带出处的 markdown 报告。
///
/// ## 它和聊天页的区别不是"更长的提示词"
///
/// 聊天页的默认姿态是"一问一答"：模型答完就停。探究要的是反过来 ——
/// 先拆问题、再分头查、然后**回头怀疑自己查到的东西**（来源是否一致、
/// 有没有时间上过期的说法），最后才落笔。
///
/// 所以这里做三件事：
///  · 用一段专门的探究指令**替换**聊天的默认姿态（见 [_researchPrompt]）；
///  · 题目和结果**不塞进会话历史** —— 探究产出的是"一份报告"，
///    混进日常对话列表里只会把那个列表变成垃圾桶；
///  · 报告可以一键存成笔记，因为它的形态本来就是一篇长文。
class DeepResearchPage extends StatefulWidget {
  const DeepResearchPage({
    super.key,
    required this.settings,
    required this.shizuku,
    required this.workDir,
    required this.notes,
    required this.tasks,
    required this.plugins,
  });

  final Settings settings;
  final ShizukuService shizuku;
  final String workDir;
  final NoteStore notes;
  final TaskStore tasks;
  final PluginStore plugins;

  @override
  State<DeepResearchPage> createState() => _DeepResearchPageState();
}

class _DeepResearchPageState extends State<DeepResearchPage> {
  final TextEditingController _topic = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// 本次探究的会话。**不进 [ConversationStore]**，理由见类注释。
  late final Conversation _conv;

  AgentRunner? _runner;
  bool _busy = false;
  String _activity = '正在规划';

  /// 历史题目（只存题目，不存报告 —— 报告在会话里，"再来一次"比翻旧报告常见）
  List<_Topic> _history = <_Topic>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _conv = Conversation(id: 'deep_only', title: '深入探究');
    _loadHistory();
  }

  @override
  void dispose() {
    _runner?.abort();
    _topic.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String raw = p.getString('researchTopics') ?? '[]';
      final dynamic data = jsonDecode(raw);
      final List<_Topic> list = <_Topic>[];
      if (data is List) {
        for (final dynamic e in data) {
          if (e is Map) {
            list.add(_Topic.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      if (mounted) {
        setState(() {
          _history = list;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _rememberTopic(String topic) async {
    _history.removeWhere((_Topic t) => t.title == topic);
    _history.insert(0, _Topic(title: topic, at: DateTime.now()));
    if (_history.length > 20) _history.removeRange(20, _history.length);
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
        'researchTopics',
        jsonEncode(_history.map((_Topic t) => t.toJson()).toList()),
      );
    } catch (_) {
      // 写不进去不影响这次探究本身
    }
  }

  /// 探究指令。
  ///
  /// 刻意写得"流程化"而不是"请你深入研究"：后者模型只会把一段常识
  /// 排成小标题。真正决定质量的是**要求它去查、要求它交叉验证、
  /// 要求它把不确定的东西标出来**。
  static String _researchPrompt(String topic) =>
      '''
请对下面这个题目做一次深入探究，最后给我一份可以直接存档的报告。

题目：$topic

要求（按顺序做，不要跳步）：

1. **先拆解**：把这个题目拆成 3–6 个必须先回答的子问题，写出来。
2. **逐个检索**：每个子问题都去查资料。至少换 2 组不同的关键词，
   优先找一手来源（官方文档、原始论文、标准、财报、法规原文），
   其次才是有署名的二手报道。不要只依赖一次搜索的结果。
3. **交叉验证**：同一个事实至少要有两个独立来源。如果来源之间说法
   不一致，**把这个分歧写出来**，而不是挑一个看起来顺眼的。
4. **标注时间**：明确哪些结论有时效性（版本号、价格、政策、排名），
   并写出你查到的信息对应的日期。
5. **区分事实与推测**：你查到的（有出处）和你推断的（无出处）
   要分开写，不要把推测写成事实。
6. **诚实标注缺口**：没能查证的部分，直接写"未能查证"，并说明
   你试过哪些方向。不要用常识填补空白。

报告结构：

## 结论
三到五句话直接回答题目本身。先给答案，不要铺垫。

## 关键发现
分点，每点一句话结论 + 一句依据。重要的数字要写出具体值。

## 分歧与不确定
查到的矛盾之处、以及你判断依据不足的地方。

## 来源
列成清单，每条给标题 + 网址。只列你真的用到的。

如果题目本身有歧义（比如"最好的"取决于评价标准），
在开头用一句话说明你按哪个理解来回答。
''';

  ToolRegistry _buildRegistry() {
    final ToolRegistry r = ToolRegistry();

    // 探究的**核心能力是联网**，所以联网工具无条件注册；
    // shell 类工具只在 Shizuku 就绪时给，否则模型会反复调用然后拿到
    // 一堆"无法执行"，白白烧掉轮次。
    r.registerAll(<AgentTool>[
      const WebTool(),
      const BrowserTool(),
      const NotesTool(),
      const TasksTool(),
      const PythonTool(),
      const MemoryTool(),
      const RuleTool(),
      const LearnTool(),
      const KnowledgeTool(),
      const ModelManagerTool(),
    ]);

    // MCP 工具：同样来自用户配置的远程服务器（缓存的那一份）。
    for (final McpServer server
        in McpStore.maybeInstance?.enabledServers ?? const <McpServer>[]) {
      for (final McpToolInfo info in server.tools) {
        if (r.byName(info.exposedName) != null) continue;
        r.register(McpTool(server: server, info: info));
      }
    }

    if (widget.shizuku.ready) {
      r.registerAll(<AgentTool>[const ShellTool(), const FileTool()]);
    }

    for (final PluginTool t in widget.plugins.enabledTools()) {
      if (r.byName(t.name) != null) continue;
      if (!widget.shizuku.ready && t.plugin.kind == PluginKind.shell) continue;
      r.register(t);
    }

    final List<String>? allow = widget.settings.activeProfile?.toolAllowlist;
    if (allow != null) {
      r.retainWhere((AgentTool t) => allow.contains(t.name));
    }

    return r;
  }

  Future<void> _start([String? preset]) async {
    final String topic = (preset ?? _topic.text).trim();
    if (topic.isEmpty || _busy) return;

    if (!widget.settings.configured) {
      _snack('还没有可用的模型，先去「模型」里绑一个');
      return;
    }

    _topic.text = topic;
    _conv.messages
      ..clear()
      ..add(
        ChatMessage(
          id: 'u_deep_${DateTime.now().microsecondsSinceEpoch}',
          role: Role.user,
          content: _researchPrompt(topic),
        ),
      );

    setState(() {
      _busy = true;
      _activity = '正在规划';
    });
    await _rememberTopic(topic);
    _scrollToEnd();

    final AgentRunner runner = AgentRunner(
      settings: widget.settings,
      shizuku: widget.shizuku,
      registry: _buildRegistry(),
      workDir: widget.workDir,
      notes: widget.notes,
      tasks: widget.tasks,
      plugins: widget.plugins,
    );
    _runner = runner;
    await BackgroundService.instance.start('正在深入探究');

    try {
      await runner.run(
        conversation: _conv,
        onUpdate: () {
          if (!mounted) return;
          setState(() => _activity = _describe(_conv));
          _scrollToEnd();
        },
        onConfirm: (ToolInvocation inv) async {
          if (!mounted) return ConfirmDecision.deny;
          // 和聊天页同一套：用调用当时记下的名字/摘要，不重建注册表。
          final String title = inv.title.isEmpty ? inv.name : inv.title;
          final String command = inv.summary.isNotEmpty
              ? inv.summary
              : (inv.args['command']?.toString() ?? inv.argumentsJson);

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
          _conv.messages.add(
            ChatMessage(
              id: 'e_${DateTime.now().microsecondsSinceEpoch}',
              role: Role.assistant,
              error: e.toString(),
            ),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activity = '已完成';
        });
      }
      _runner = null;
      await BackgroundService.instance.stop();
      await OverlayService.dismissActivity();
    }
  }

  void _stop() {
    _runner?.abort();
    _runner = null;
    setState(() => _busy = false);
  }

  /// 从会话里读出"现在在干什么"，给进度行用。
  static String _describe(Conversation conv) {
    if (conv.messages.isEmpty) return '正在规划';
    final ChatMessage last = conv.messages.last;
    if (last.tools.isNotEmpty) {
      for (final ToolInvocation t in last.tools) {
        switch (t.status) {
          case InvocationStatus.running:
            return '正在执行：${t.name}';
          case InvocationStatus.awaitingConfirm:
            return '等待你确认：${t.name}';
          default:
            break;
        }
      }
    }
    if (last.pending) return '正在写报告';
    return '正在思考';
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 把最后一条有正文的助手消息存成笔记。
  Future<void> _saveAsNote() async {
    ChatMessage? report;
    for (final ChatMessage m in _conv.messages.reversed) {
      if (m.role == Role.assistant && m.content.trim().isNotEmpty) {
        report = m;
        break;
      }
    }
    if (report == null) {
      _snack('还没有可保存的报告');
      return;
    }

    final String topic = _topic.text.trim();
    final Note n = widget.notes.create(
      title: topic.isEmpty ? '探究报告' : topic,
      body: report.content,
      tags: <String>['深入探究'],
    );
    widget.notes.touch(n);
    if (!mounted) return;
    _snack('已存到笔记：${n.title}');
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final double topInset = MediaQuery.of(context).padding.top;
    final bool hasReport = _conv.messages.any(
      (ChatMessage m) =>
          m.role == Role.assistant && m.content.trim().isNotEmpty,
    );

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          GlassBar(
            hairlineBottom: true,
            padding: EdgeInsets.fromLTRB(6, topInset + 8, 12, 10),
            child: Row(
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Text(
                    '深入探究',
                    style: AppFonts.body(
                      size: 19,
                      weight: FontWeight.w600,
                      color: s.text,
                      height: 1.2,
                    ),
                  ),
                ),
                if (hasReport && !_busy)
                  IconButton(
                    icon: const Icon(Icons.save_alt_rounded),
                    tooltip: '存成笔记',
                    onPressed: _saveAsNote,
                  ),
              ],
            ),
          ),
          Expanded(child: _conv.messages.isEmpty ? _intro(s) : _reportView(s)),
          // 活动状态：**一行**。它替代了原来那种"提示条 + 转圈 + 按钮"
          // 的三件套 —— 探究过程中屏幕的主人是报告，状态只需要说明
          // "还在动、现在在干嘛"，多占一行都是抢版面。
          if (_busy) _activityBar(s),
        ],
      ),
    );
  }

  Widget _activityBar(AppSurface s) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: s.surface,
        border: Border(top: BorderSide(color: s.border, width: 0.6)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _activity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(
                size: 12.5,
                color: s.muted,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GlassButton(
            label: '停止',
            fontSize: 12.5,
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
            onTap: _stop,
          ),
        ],
      ),
    );
  }

  /// 还没开始时：输入题目 + 历史题目。
  Widget _intro(AppSurface s) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
      children: <Widget>[
        Text(
          '给我一个题目',
          style: AppFonts.body(
            size: 22,
            weight: FontWeight.w600,
            color: s.text,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '它会先拆问题，再分头检索、交叉验证，最后给一份带出处的报告。'
          '过程比聊天慢，产出可以直接存成笔记。',
          style: AppFonts.body(size: 13, color: s.muted, height: 1.6),
        ),
        const SizedBox(height: 16),
        // 输入区：和聊天页的输入框同一档圆角（AppRadius.card）。
        // 这里刻意不用 ChatPage 的胶囊 —— 那是多行输入配圆形按钮的
        // 规格，而这一页只有一个"发送"。
        Card(
          color: s.surface,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(color: s.border),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _topic,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    style: AppFonts.body(size: 15, color: s.text, height: 1.5),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      hintText: '例如：AGP 9 对 Flutter 插件构建链的影响',
                      hintStyle: AppFonts.body(
                        size: 14.5,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.arrow_upward_rounded),
                  tooltip: '开始探究',
                  onPressed: () => _start(),
                ),
              ],
            ),
          ),
        ),
        if (_loaded && _history.isNotEmpty) ...<Widget>[
          const SizedBox(height: 22),
          Text(
            '探究过的题目',
            style: AppFonts.body(
              size: 11.5,
              weight: FontWeight.w600,
              color: s.muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final _Topic t in _history)
                ActionChip(
                  label: Text(
                    t.title.length > 22
                        ? t.title.substring(0, 22)
                        : t.title,
                  ),
                  onPressed: _busy ? null : () => _start(t.title),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _reportView(AppSurface s) {
    // ---- 第一条用户消息**不渲染** ----
    //
    // 那条消息的内容是 `_researchPrompt()` 生成的一大段指令
    // （拆解题目 / 逐个检索 / 交叉验证 / 报告结构…），几百字。
    // 把它显示在最上面有两个坏处：
    //   · 用户看到的是一屏"要求"，而不是"我开始干活了"；
    //   · 它把真正的产出（进度、报告）挤到屏幕下方，得往下翻才看得到。
    //
    // 所以从第 1 条开始渲染，并在上面用一行状态替代它。
    // **只跳过这一条**：它是本页自己造出来的，不是用户写的；
    // 后面任何消息都照常显示。
    final List<ChatMessage> show = _conv.messages.isEmpty
        ? <ChatMessage>[]
        : _conv.messages.sublist(1);
    final String topic = _topic.text.trim();

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 26),
      itemCount: show.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) return _topicHeader(s, topic);
        return MessageView(message: show[i - 1]);
      },
    );
  }

  /// 顶部的题目行 —— 替代被隐藏的那段指令。
  ///
  /// 它承担的是"我在探究什么"这个身份信息：页面标题只写着「深入探究」，
  /// 而用户可能同时开着好几个题目。
  Widget _topicHeader(AppSurface s, String topic) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.code - 4),
            ),
            child: Icon(
              Icons.travel_explore_rounded,
              size: 15,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              topic.isEmpty ? '深入探究' : topic,
              style: AppFonts.body(
                size: 14.5,
                weight: FontWeight.w600,
                color: s.text,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条探究历史（只存题目和时间）。
class _Topic {
  _Topic({required this.title, required this.at});

  final String title;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    'at': at.toIso8601String(),
  };

  static _Topic fromJson(Map<String, dynamic> j) => _Topic(
    title: j['title']?.toString() ?? '',
    at: DateTime.tryParse(j['at']?.toString() ?? '') ?? DateTime.now(),
  );
}
