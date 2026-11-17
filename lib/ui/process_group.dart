import 'package:flutter/material.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import '../tools/chat_alarm_tool.dart';
import 'shimmer.dart';
import 'tool_line.dart';
import 'tool_steps.dart';
import 'working_pulse.dart';

/// 卡片里工具行的图标补偿（逻辑像素，正数 = 向下）。
///
/// ## 为什么不能直接用 [toolIconNudge]
///
/// 那张表是给 `ToolLine` 量的：标签走**正文字体**（13 / 1.35）。卡片里的
/// 工具名换成了**等宽字体**（12.2 / 1.45），两套字体的 ascent/descent 不同，
/// 同一个标签的墨迹在行盒里的落点能差到 1.7 —— 直接套用会让图标明显偏高
/// （`Shell`、`python`）或偏低（`改文件`）。
///
/// 这里的数是在真实的 [ToolRow] + 代码字体下，按 [ToolDisplay] 的**真实
/// 图标 + 真实标签**逐个量出来的（图标墨迹包围盒中心 ↔ 文字墨迹包围盒
/// 中心）。没量到的工具（插件 / 自定义名，标签是裸英文）兜底 0.6：
/// 那类名字下伸部多，需要比中文标签多一点。
const Map<String, double> _kCardNudge = <String, double>{
  'linux': 0,
  'python': 0.8,
  'file_op': 0.2,
  'filesearch': 1.5,
  'reader': 0.2,
  'writer': -0.8,
  'sheller': 0.2,
  'geter': 0.2,
  'web': 0.3,
  'browser': 0.3,
  'read_image': 0.3,
  'generate_image': -0.8,
  'open_file': 0.2,
  'get_location': 0.2,
  'notes': 0,
  'tasks': 0.5,
  'memory': 0.2,
  'recall': 1.7,
  'rules': -0.5,
  'interact': -0.5,
  'change_think': 0.5,
  'knowledge': -0.5,
  'learn': 0.2,
  'plugin': 0,
  'tool': 0.3,
  'pc': 0.2,
  'workspace': 0.5,
  'request_unlock': 0.5,
  'notify_user': 0,
  'model_manager': 0,
  'mark': 0.2,
};

double _cardNudge(String toolName) => _kCardNudge[toolName] ?? 0.6;

/// 一轮任务的**全部过程**，收成一张小列表。
///
/// ## 为什么是"列表"而不是一行摘要
///
/// `AgentRunner` 每发起一次带工具调用的请求就往会话里追加一条独立的
/// assistant 消息：模型先说一句「我先查一下…」，调工具，再说下一句，
/// 再调工具……最后一条不带工具的消息才是给用户的**答复**。
///
/// 以前这里只留一行「已完成 · 12 步」，用户得点开才知道它在干什么。
/// 现在直接把**最新几条**摊开来（图标 / 工具名 / 参数摘要 / 状态），
/// 正在跑的那条置顶加粗；更早的记录点「更多历史」进「工具调用」表。
///
/// 列表只取最近 [kRecentRows] 条：一屏里能看完全部过程行时，
/// 正文反而被推下去了 —— 用户要的是"此刻在干嘛"，不是完整审计日志。
///
/// ## 框只在**真的有工具调用**时才出现
///
/// 模型先想、想完才调工具。纯思考那段如果也立一个框，框里只有一行
/// "工作中"，既没有信息、又比正文更抢眼（用户会以为自己漏看了什么）。
/// 所以没工具时只留一行提示（和普通思考卡一致），第一次调用出现后
/// 框才跟着出现 —— 框的含义很明确：这里有一串工具调用。
///
/// ## 为什么没有背景板
///
/// 过程行是正文之前的铺垫，不是内容。灰底 + 描边会让每一轮都像
/// 一张卡片压在聊天里；现在只保留一圈很淡的外框，行本身是透明底，
/// 文字用**等宽字体**（工具名 / 参数本来就是代码），比正文更暗一档，
/// 扫过去不会抢正文。
class ProcessGroup extends StatefulWidget {
  const ProcessGroup({
    super.key,
    required this.turns,
    this.finalTurn,
    this.onMoreHistory,
  });

  /// 过程轮（带工具调用、或正文为空的 assistant 消息），按发生顺序。
  final List<ChatMessage> turns;

  /// 紧随其后的最终答复。
  ///
  /// **只借它的思维链**：最后一轮模型也可能先想再答，那段思考同样属于
  /// 过程，不该在正文上方再占一行。正文仍然在外面正常显示。
  final ChatMessage? finalTurn;

  /// 点「更多历史」时打开完整的「工具调用」表。
  final VoidCallback? onMoreHistory;

  @override
  State<ProcessGroup> createState() => _ProcessGroupState();
}

/// 列表里最多摊开几条工具调用。多出来的走「更多历史」。
const int kRecentRows = 3;

class _ProcessGroupState extends State<ProcessGroup> {
  /// 完整过程（中间说的话 / 思维链 / 逐步命令）默认收起。
  /// 只有点列表头才展开 —— 主视图永远只有那几条最新调用。
  bool _open = false;

  /// 整轮的工具调用，按发生顺序。
  ///
  /// `chat_alarm` 不进过程列表：它的产物是正文下面那条风险告示，
  /// 在这里再列一行等于同一件事说两遍。
  List<ToolInvocation> get _tools => <ToolInvocation>[
    for (final ChatMessage m in widget.turns)
      for (final ToolInvocation t in m.tools)
        if (t.name != ChatAlarmTool.toolName) t,
  ];

  static List<ToolInvocation> _toolsOf(ChatMessage m) => m.tools
      .where((ToolInvocation t) => t.name != ChatAlarmTool.toolName)
      .toList();

  bool get _running =>
      widget.turns.any((ChatMessage m) => m.pending) ||
      _tools.any((ToolInvocation t) => t.status == InvocationStatus.running);

  int get _failed => _tools
      .where(
        (ToolInvocation t) =>
            t.status == InvocationStatus.failed ||
            t.status == InvocationStatus.rejected,
      )
      .length;

  /// 当前正在跑的那一步（并行时有多个，取最后加进来的那个）。
  ToolInvocation? get _current {
    final List<ToolInvocation> tools = _tools;
    for (int i = tools.length - 1; i >= 0; i--) {
      if (tools[i].status == InvocationStatus.running) return tools[i];
    }
    return null;
  }

  int get _thinkingMs =>
      widget.turns.fold<int>(
        0,
        (int sum, ChatMessage m) => sum + m.reasoningMs,
      ) +
      (widget.finalTurn?.reasoningMs ?? 0);

  /// 这一组里有没有**还在想**的消息（pending 且还没出正文）。
  bool get _thinking => widget.turns.any(
    (ChatMessage m) => m.pending && m.content.trim().isEmpty,
  );

  /// 有没有可展开的思维链：过程轮自己的，加上最后答复那条的。
  bool get _hasReasoning =>
      widget.turns.any((ChatMessage m) => m.reasoning.trim().isNotEmpty) ||
      (widget.finalTurn?.reasoning.trim().isNotEmpty ?? false);

  /// 整组的思维链，按发生顺序拼起来。
  String get _allReasoning => <String>[
    for (final ChatMessage m in widget.turns)
      if (m.reasoning.trim().isNotEmpty) m.reasoning.trim(),
    if ((widget.finalTurn?.reasoning ?? '').trim().isNotEmpty)
      widget.finalTurn!.reasoning.trim(),
  ].join('\n\n');

  /// 毫秒 → 人话。和工具组、思考卡保持同一套措辞。
  static String? _humanMs(int ms) {
    if (ms < 1000) return null;
    final double sec = ms / 1000.0;
    if (sec < 60) {
      return '${sec.toStringAsFixed(sec < 10 ? 1 : 0)} 秒';
    }
    final int m = ms ~/ 60000;
    final int r = (ms % 60000) ~/ 1000;
    return r == 0 ? '$m 分' : '$m 分 $r 秒';
  }

  /// 运行中按 `createdAt` 现算，配合聊天页流式重建，秒数会自己往上走。
  String _liveSeconds() {
    if (widget.turns.isEmpty) return '刚刚';
    final int ms = DateTime.now()
        .difference(widget.turns.first.createdAt)
        .inMilliseconds;
    if (ms < 1000) return '刚刚';
    final int s = ms ~/ 1000;
    return s < 60 ? '$s 秒' : '${s ~/ 60} 分 ${s % 60} 秒';
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    if (widget.turns.isEmpty) return const SizedBox.shrink();

    final List<ToolInvocation> tools = _tools;
    final bool running = _running;
    final ToolInvocation? current = _current;

    // ---- 还没有工具调用：不立框，只显示"思考" ----
    //
    // 框本身是"这里有一串工具调用"的信号。模型还在想的时候把它先立起来，
    // 用户看到的是一个空框，比一行字更让人怀疑"是不是卡住了"。
    // 所以这一段只画思考行；等第一次调用出现，思考会**挪进框里**
    // （见下面的 [_thinkingLine]），不会在框外再多一行。
    if (tools.isEmpty) {
      if (!running && !_hasReasoning) return const SizedBox.shrink();
      return _thinkingOnly(context, s);
    }

    // 最新几条，新的在上面；正在跑的那条已经在标题里了，不再重复列。
    final List<ToolInvocation> recent = tools.reversed
        .where((ToolInvocation t) => current == null || !identical(t, current))
        .take(kRecentRows)
        .toList();

    // 思考行只在**整轮已经结束**时出现，作为"想过什么"的回顾。
    //
    // 跑的时候不要再挂第二行状态：标题已经在说「正在运行：Shell」/
    // 「工作中 · 12 秒」，下面再来一行「思考中…」等于同一件事说两遍
    // （用户原话："第一行显示正在运行的内容，不要第一第二行都显示"）。
    final bool showThinking =
        !running && (_thinking || _hasReasoning || _thinkingMs > 0);

    return Padding(
      // 离上面的用户气泡远一点、离下面的正文近一点。
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: s.border, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(s, running: running, current: current),
            // 思考并进同一张卡片：它和这些工具调用属于同一次"想 + 做"。
            if (showThinking) _thinkingLine(s),
            for (final ToolInvocation inv in recent) _toolRow(s, inv),
            if (widget.onMoreHistory != null) _moreRow(s),
            if (_open) _expanded(context, s),
          ],
        ),
      ),
    );
  }

  /// 纯思考阶段（**还没有工具调用**）：只有一个可展开的思考行，没有外框。
  ///
  /// 观感和普通消息上的思考卡一致：呼吸的心理学图标、会走的秒数；
  /// 想完了把秒数留成"已思考 X"，点一下能读那段思维链。
  Widget _thinkingOnly(BuildContext context, AppSurface s) {
    final String? ms = _humanMs(_thinkingMs);
    final String label = _thinking ? '思考中…' : (ms == null ? '思考' : '已思考 $ms');
    final Widget text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppFonts.body(size: 12.2, color: s.muted, height: 1.35),
    );

    return Padding(
      // 和框同一个上边距：从"思考"过渡到"出现工具框"时不会跳一下。
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _hasReasoning ? () => setState(() => _open = !_open) : null,
            // ---- 这一行**不加任何水平内距** ----
            //
            // 想完之后这条消息会变成普通回复，「思考」由 `_ThinkingCard` 画
            // （widgets.dart），那张行**贴着列表左边缘**起步（图标 x=0，
            // 文字 x=22）。这里原来带了 `horizontal: 12`，于是同一个位置在
            // 「思考中…」和「已思考 …」之间会横向跳 12 像素 —— 用户看到的就是
            // 两行没对齐。
            //
            // 所以这里和它**逐像素一致**：无内距、`iconGap: 7`、图标补偿查
            // 同一张表、展开区同样缩进 22。两个状态切换时只有文字内容在变。
            child: ToolRow(
              iconGap: 7,
              iconNudge: toolIconNudge(Icons.psychology_outlined),
              icon: _thinking
                  ? WorkingPulse(
                      size: 15,
                      icon: Icons.psychology_outlined,
                      color: s.muted,
                    )
                  : Icon(Icons.psychology_outlined, size: 15, color: s.muted),
              trailing: _hasReasoning
                  ? AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 17,
                        color: s.muted,
                      ),
                    )
                  : null,
              child: _thinking
                  ? ShimmerMask(
                      base: s.muted,
                      highlight: Color.lerp(s.muted, AppColors.accent, 0.55)!,
                      child: text,
                    )
                  : text,
            ),
          ),
          if (_open && _hasReasoning)
            Padding(
              // 和 `_ThinkingCard` 一致：展开块缩进 = 图标 15 + 间隔 7。
              padding: const EdgeInsets.only(left: 22, top: 4),
              child: _reasoningBox(s, _allReasoning),
            ),
        ],
      ),
    );
  }

  /// 卡片里的思考行：一行摘要，点一下展开完整思维链。
  ///
  /// 它和工具行挤在同一张卡里，是用户要的"想 + 做放在一起" ——
  /// 但仍然只占一行，不会把正文推下去。
  Widget _thinkingLine(AppSurface s) {
    final String? ms = _humanMs(_thinkingMs);
    final String label = _thinking ? '思考中…' : (ms == null ? '思考' : '思考 $ms');

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _hasReasoning ? () => setState(() => _open = !_open) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        // 和标题行、工具行共用 [ToolRow]：图标槽 15、间隔 8，
        // 三行文字的左边缘因此落在同一条竖线上。
        child: ToolRow(
          iconGap: 8,
          iconNudge: 0,
          icon: _thinking
              ? WorkingPulse(
                  size: 15,
                  icon: Icons.psychology_outlined,
                  color: s.muted,
                )
              : Icon(Icons.psychology_outlined, size: 15, color: s.muted),
          trailing: _hasReasoning
              ? Icon(
                  Icons.expand_more_rounded,
                  size: 15,
                  color: s.muted.withValues(alpha: 0.7),
                )
              : null,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.body(
              size: 11.8,
              color: s.text.withValues(alpha: 0.6),
              height: 1.35,
            ),
          ),
        ),
      ),
    );
  }

  /// 标题行：正在跑什么；没有在跑时是整轮的统计。
  ///
  /// 这一行同时是「展开完整过程」的开关（默认收起）——
  /// 中间说的话和思维链仍然能回看，只是不占着主列表的位置。
  Widget _header(
    AppSurface s, {
    required bool running,
    required ToolInvocation? current,
  }) {
    final (IconData icon, String currentLabel) = current == null
        ? (Icons.psychology_outlined, '')
        : ToolDisplay.of(current.name);
    final IconData headIcon = running
        ? icon
        : (_failed > 0
              ? Icons.error_outline_rounded
              : Icons.check_circle_outline_rounded);
    final Color headColor = _failed > 0 ? AppColors.danger : s.muted;

    final String text;
    if (running && current != null) {
      text = '正在运行：$currentLabel';
    } else if (running) {
      text = '工作中 · ${_liveSeconds()}';
    } else {
      // 思考时长不再塞进这一行 —— 它有自己的那一行（[_thinkingLine]），
      // 两个地方都写一遍只会让标题越拉越长。
      text = '工具调用 · 共 ${_tools.length} 次';
    }

    return InkWell(
      onTap: () => setState(() => _open = !_open),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 5, 8, 5),
        // 和下面的思考行、工具行同一套 [ToolRow]：图标槽宽、间隔、
        // 文字起点都由它决定 —— 列对齐是布局保证的，不是手调出来的。
        child: ToolRow(
          iconGap: 8,
          // 正在跑的时候图标就是那个工具自己的，按它的标签查表；
          // 静止态是勾/叉 + 中文统计，码字的墨迹在行盒里居中，补 0。
          iconNudge: running && current != null ? _cardNudge(current.name) : 0,
          icon: running
              ? WorkingPulse(size: 15, icon: headIcon, color: s.muted)
              : Icon(headIcon, size: 15, color: headColor),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (running)
                Text(
                  '执行中',
                  style: AppFonts.body(
                    size: 10.6,
                    weight: FontWeight.w600,
                    color: s.muted,
                    height: 1.3,
                  ),
                ),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 17,
                  color: s.muted.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 等宽字体：标题里那半句是工具名，和下面几行同一个字形。
            style: AppFonts.code(
              size: 12.5,
              weight: FontWeight.w600,
              color: _failed > 0 ? AppColors.danger : s.text,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }

  /// 一条历史工具调用：图标 / 工具名 / 参数摘要 / 状态。
  ///
  /// 名字和参数是**代码**（命令、路径、正则），所以整行走等宽字体；
  /// 颜色也比正文更暗一档（`muted` 读起来太淡，像被禁用了一样）。
  /// 状态标签是给人看的词，仍然是正文字体 —— 中文在等宽族里会回退。
  Widget _toolRow(AppSurface s, ToolInvocation inv) {
    final (IconData icon, String label) = ToolDisplay.of(inv.name);
    final _StateStyle state = _stateOf(inv.status);
    final String summary = toolCallSummary(inv);
    final bool hasSummary =
        summary.isNotEmpty && summary != '（无参数）' && summary != label;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      // 工具名 + 摘要放进 [ToolRow] 的内容槽里，图标槽宽度和标题/思考行
      // 完全一致 —— 三行文字才在同一条竖线上。
      child: ToolRow(
        iconGap: 8,
        iconNudge: _cardNudge(inv.name),
        icon: Icon(icon, size: 15, color: state.color),
        trailing: Text(
          state.label,
          maxLines: 1,
          style: AppFonts.body(
            size: 10.6,
            weight: FontWeight.w600,
            color: state.color,
            height: 1.3,
          ),
        ),
        child: Row(
          children: <Widget>[
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.code(
                size: 12.2,
                weight: FontWeight.w500,
                color: s.text,
                height: 1.45,
              ),
            ),
            if (hasSummary) ...<Widget>[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.code(
                    size: 11.4,
                    // 正文色降一点透明度：比 muted 深，又比工具名浅。
                    color: s.text.withValues(alpha: 0.72),
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 底部那行「更多历史」：进完整的「工具调用」表。
  ///
  /// 左边空出图标槽的宽度（15 + 8）：它虽然没有图标，但文字仍然要落在
  /// 上面几行文字的那条竖线上 —— 否则整张卡里会有两个左边缘（用户原话：
  /// "没有对齐，两个文字"）。
  Widget _moreRow(AppSurface s) {
    return InkWell(
      onTap: widget.onMoreHistory,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12 + 15 + 8, 6, 10, 7),
        child: Row(
          children: <Widget>[
            Text(
              '更多历史',
              style: AppFonts.body(size: 11.8, color: s.muted, height: 1.35),
            ),
            const Spacer(),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: s.muted.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  static _StateStyle _stateOf(InvocationStatus status) {
    switch (status) {
      case InvocationStatus.success:
        return _StateStyle('完成', AppColors.success);
      case InvocationStatus.failed:
        return _StateStyle('失败', AppColors.danger);
      case InvocationStatus.rejected:
        return _StateStyle('已拒绝', AppColors.danger);
      case InvocationStatus.running:
        return _StateStyle('执行中', AppColors.accent);
      case InvocationStatus.awaitingConfirm:
        return _StateStyle('等待确认', AppColors.warning);
    }
  }

  Widget _expanded(BuildContext context, AppSurface s) {
    final List<Widget> blocks = <Widget>[];

    for (final ChatMessage m in widget.turns) {
      final String said = m.content.trim();
      if (said.isNotEmpty) {
        blocks.add(_processText(s, said));
      }
      final String thought = m.reasoning.trim();
      if (thought.isNotEmpty) blocks.add(_reasoning(s, thought));
      final List<ToolInvocation> tools = _toolsOf(m);
      if (tools.isNotEmpty) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ToolStepGroup(tools: tools, collapse: false),
          ),
        );
      }
    }

    // 最后一轮的思考也在这里，正文上方不再单独挂一张思考卡。
    final String? lastThought = widget.finalTurn?.reasoning.trim();
    if (lastThought != null && lastThought.isNotEmpty) {
      blocks.add(_reasoning(s, lastThought));
    }

    if (blocks.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: ConstrainedBox(
        // 一轮长任务的中间话可能几千字：硬上限 + 内部滚动，
        // 不能让一次「展开」把整页聊天顶走。
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height * 0.45).clamp(
            180.0,
            420.0,
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: blocks,
          ),
        ),
      ),
    );
  }

  /// 模型在两次工具调用之间说的话。它属于过程，但用户排查时要用，
  /// 所以保留成可选中的浅色正文 —— 不套卡片、不抢视觉层级。
  Widget _processText(AppSurface s, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: SelectionArea(
      child: Text(
        text,
        style: AppFonts.body(size: 13, color: s.muted, height: 1.55),
      ),
    ),
  );

  Widget _reasoning(AppSurface s, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.psychology_outlined, size: 13, color: s.muted),
            const SizedBox(width: 5),
            Text('思考', style: AppFonts.body(size: 11.5, color: s.muted)),
          ],
        ),
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: s.codeBg,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          child: SelectionArea(
            child: Text(
              text,
              style: AppFonts.read(size: 12.2, color: s.muted, height: 1.65),
            ),
          ),
        ),
      ],
    ),
  );

  /// 纯思考阶段展开的思维链：一块浅底、可选中、可滚动的文字。
  ///
  /// 和展开整轮过程时的那一块（[_reasoning]）观感一致，只是不带
  /// 「思考」小标题 —— 外面那一行已经写了，重复一次只是多占一行。
  Widget _reasoningBox(AppSurface s, String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
    decoration: BoxDecoration(
      color: s.codeBg,
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    child: SelectionArea(
      child: Text(
        text,
        style: AppFonts.read(size: 12.2, color: s.muted, height: 1.65),
      ),
    ),
  );
}

class _StateStyle {
  const _StateStyle(this.label, this.color);

  final String label;
  final Color color;
}
