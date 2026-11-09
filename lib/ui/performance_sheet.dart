import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/metrics.dart';
import '../core/models.dart';
import '../core/platform_files.dart';
import '../core/store.dart';
import '../core/timing_report.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'ios_switch.dart';
import 'tool_line.dart';
import 'widgets.dart';

/// 性能面板：缓存命中 / token 用量 / 上下文占用。
///
/// 有一条必须守住的底线：**实测值和估算值要分开显示**。
/// token 只有 API 真的返回了 `usage` 才是准的，否则只能用本地经验规则估。
/// 把估算值伪装成实测值，用户拿去对账就会发现对不上，
/// 那时候他不会再信任面板上的任何数字。
Future<void> showPerformanceSheet(
  BuildContext context, {
  required Settings settings,
  int contextTokens = 0,
  Conversation? conversation,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext ctx) => _PerformanceSheet(
      settings: settings,
      contextTokens: contextTokens,
      conversation: conversation,
    ),
  );
}

/// 独立面板的外壳：把手 + 标题。
///
/// 内容本身在 [PerformanceBody] —— 对话页「+」里的「性能工具」标签页直接
/// 复用它，不需要再套一层把手（那里已经在一个面板里了）。
class _PerformanceSheet extends StatelessWidget {
  const _PerformanceSheet({
    required this.settings,
    required this.contextTokens,
    this.conversation,
  });

  final Settings settings;
  final int contextTokens;
  final Conversation? conversation;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Container(
      constraints: BoxConstraints(
        // 让出状态栏：内容变长时标题会和时间/电量叠在一起。
        maxHeight: sheetMaxHeight(context, 0.85),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 12),
            child: Column(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.border,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '性能',
                  style: AppFonts.body(
                    size: 17,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: PerformanceBody(
              settings: settings,
              contextTokens: contextTokens,
              conversation: conversation,
            ),
          ),
        ],
      ),
    );
  }
}

/// 性能面板的**内容**。两个入口共用：
///
/// · 设置里的「性能」→ `showPerformanceSheet`（外面套一层把手 + 标题）
/// · 对话页「+」→「性能工具」标签页（已经在一个面板里了，不要再套一层）
///
/// 抽成公共组件而不是复制一份：这两个入口显示的是**同一批数字**，
/// 复制之后迟早会长得不一样 —— 而"两处的数字对不上"是最伤信任的。
class PerformanceBody extends StatefulWidget {
  const PerformanceBody({
    super.key,
    required this.settings,
    this.contextTokens = 0,
    this.conversation,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 24),
  });

  final Settings settings;
  final int contextTokens;

  /// 要列出工具调用明细的对话。为 null 时那一段显示一句说明而不是空白 ——
  /// 「面板在但没内容」最容易让人以为统计坏了。
  final Conversation? conversation;

  final EdgeInsetsGeometry padding;

  @override
  State<PerformanceBody> createState() => _PerformanceBodyState();
}

class _PerformanceBodyState extends State<PerformanceBody> {
  /// 性能页 / 工具调用页的左右分页。
  ///
  /// 为什么把工具调用**挪成单独一页**，而不是留在性能页里那一小节：
  ///
  /// 它是**表格**（时间 / 工具 / 内容，一行一次调用），而性能页通篇是
  /// 指标卡片。两种排版对宽度的要求差一个量级 —— 挤在同一屏里，
  /// 要么表格被压成几行小字（时间、工具名各占一列之后就只剩几十像素
  /// 给"内容"），要么把卡片冲散。分页之后每页都能用满整屏。
  ///
  /// 用**左滑**切换：这是"同一个东西的下一层细节"，滑一下比翻菜单快。
  final PageController _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    AppMetrics.instance.removeListener(_onChange);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    AppMetrics.instance.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    // 开发者选项打开时多出第三页「耗时明细」。
    //
    // 为什么放在同一排页签里而不是另开一个面板：它是**同一次排障**的
    // 一部分（缓存/token 看代价，工具调用看做了什么，耗时看时间花在哪），
    // 分开两个入口只会让人来回跳。
    final bool dev = widget.settings.developerMode;
    final int pages = dev ? 3 : 2;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _pageTabs(s, pages),
        Flexible(
          child: PageView(
            controller: _pages,
            onPageChanged: (int i) => setState(() => _page = i),
            children: <Widget>[
              _metricsPage(s),
              _toolCallPage(s),
              if (dev) _timingPage(s),
            ],
          ),
        ),
      ],
    );
  }

  /// 顶部那几个页签。既是**指示**（现在在哪一页），也是**入口** ——
  /// 不是每个人都会想到去左滑；滑和点两条路都得通。
  Widget _pageTabs(AppSurface s, int count) {
    Widget tab(String label, int index) {
      final bool on = _page == index;
      return Pressable(
        onTap: () => _pages.animateToPage(
          index,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          child: Text(
            label,
            style: AppFonts.body(
              size: 12.5,
              weight: on ? FontWeight.w600 : FontWeight.w500,
              color: on ? AppColors.accent : s.muted,
              height: 1.3,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        widget.padding is EdgeInsets ? (widget.padding as EdgeInsets).top : 0,
      ),
      child: Row(
        children: <Widget>[
          tab('性能', 0),
          const SizedBox(width: 4),
          tab('工具调用', 1),
          if (count >= 3) ...<Widget>[
            const SizedBox(width: 4),
            tab('耗时明细', 2),
          ],
        ],
      ),
    );
  }

  Widget _metricsPage(AppSurface s) {
    final AppMetrics m = AppMetrics.instance;
    return ListView(
      padding: widget.padding,
      children: <Widget>[
        // ---------------- 缓存 ----------------
        _section(s, '搜索缓存'),
        _metricGrid(
          s,
          <Widget>[
            _metricCard(
              s,
              icon: Icons.bolt_rounded,
              title: '命中率',
              value: m.cacheHitRate == null
                  ? '—'
                  : '${(m.cacheHitRate! * 100).toStringAsFixed(0)}%',
              desc: m.searchCacheTotal == 0
                  ? '还没有搜索过'
                  : '命中 ${m.searchCacheHits} / 未命中 ${m.searchCacheMisses}',
              accent: m.cacheHitRate != null && m.cacheHitRate! > 0.3,
            ),

            // ---- 模型缓存（服务端） ----
            //
            // 这和搜索缓存是**两件事**：搜索缓存是我们自己跳过
            // 一次网络请求；模型缓存是服务端复用相同的提示词前缀，
            // 命中部分的 token 便宜得多。DeepSeek 会在 usage 里回
            // `prompt_cache_hit_tokens`，很多中转站不回 —— 所以
            // "查不出来"时必须说清是服务端没给，而不是算不出。
            _metricCard(
              s,
              icon: Icons.cached_rounded,
              title: '模型缓存',
              value: m.promptCacheHitRate == null
                  ? '—'
                  : '${(m.promptCacheHitRate! * 100).toStringAsFixed(0)}%',
              desc: m.promptCacheHitRate == null
                  ? '服务端未返回明细'
                  : '命中 ${AppMetrics.humanCount(m.promptCacheHitTokens)} tokens',
              accent:
                  m.promptCacheHitRate != null && m.promptCacheHitRate! > 0.3,
            ),
          ],
        ),

        // ---------------- token ----------------
        _section(s, 'Token 用量（本次运行）'),
        _metricGrid(
          s,
          <Widget>[
            _metricCard(
              s,
              icon: Icons.data_usage_rounded,
              title: '总计',
              value: AppMetrics.humanCount(m.totalTokens),
              desc: '调用 ${m.callCount} 次',
            ),
            _metricCard(
              s,
              icon: Icons.call_received_rounded,
              title: '输入',
              value: AppMetrics.humanCount(m.promptTokens),
              desc: '提示词 + 工具输出',
            ),
            _metricCard(
              s,
              icon: Icons.call_made_rounded,
              title: '输出',
              value: AppMetrics.humanCount(m.completionTokens),
              desc: m.reasoningTokens > 0
                  ? '含思维链 ${AppMetrics.humanCount(m.reasoningTokens)}'
                  : '模型生成的正文',
            ),
            _metricCard(
              s,
              icon: Icons.join_full_rounded,
              title: '缓存命中',
              value: AppMetrics.humanCount(m.promptCacheHitTokens),
              desc: '服务端复用的前缀',
            ),
          ],
        ),

        // 实测 / 估算的区分，这是整个面板最需要说清楚的一点
        if (m.callCount > 0)
          SurfaceCard(
            margin: const EdgeInsets.only(bottom: 9),
            color: m.hasMeasuredUsage
                ? AppColors.success.withValues(alpha: 0.08)
                : AppColors.warning.withValues(alpha: 0.10),
            borderColor:
                (m.hasMeasuredUsage ? AppColors.success : AppColors.warning)
                    .withValues(alpha: 0.30),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  m.hasMeasuredUsage
                      ? Icons.verified_rounded
                      : Icons.info_outline_rounded,
                  size: 16,
                  color: m.hasMeasuredUsage
                      ? AppColors.success
                      : AppColors.warning,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: mdText(
                    m.hasMeasuredUsage
                        ? '其中 ${m.measuredCalls} 次是服务端实测值'
                              '${m.estimatedCalls > 0 ? '，${m.estimatedCalls} 次为本地估算' : ''}。'
                        : '服务端没有返回 usage，以下全部是**本地估算**：'
                              '按「中文约 1 token/字、其余约 1 token/4 字符」估算，'
                              '只能用于感知量级，不能当作计费依据。',
                    style: AppFonts.body(
                      size: 12.3,
                      color: s.text,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),

        // ---------------- 上下文 ----------------
        _contextCard(s, m),

        // 工具调用明细**移到第二页**（左滑，或点上面的「工具调用」）：
        // 它是要按列对齐着看的表格，塞在这一列卡片里既看不全、
        // 也把指标卡片冲散了。见 [_toolCallPage]。

        // ---------------- 工具步骤过程 ----------------
        //
        // 放在「性能」里而不是「界面」：它不改变外观，改变的是
        // **一轮对话里有多少行是给过程而不是给结论的** ——
        // 这直接影响"扫一眼能找到结果吗"，是信息密度问题。
        _section(s, '工具步骤过程'),
        _toggleRow(
          s,
          icon: Icons.unfold_less_rounded,
          title: '折叠成一行',
          subtitle: widget.settings.collapseToolSteps
              ? '多步工具调用收成「执行了 N 步」，点开看细节。'
              : '每一步都平铺成一行，调试时能一眼扫完整个调用链。',
          value: widget.settings.collapseToolSteps,
          onChanged: (bool v) =>
              widget.settings.update(() => widget.settings.collapseToolSteps = v),
        ),

        const SizedBox(height: 8),
        // ---------------- 极简过程 ----------------
        //
        // 和上面那张是**两档**，不是同一根滑杆上的两个刻度：
        //  · 折叠：一行摘要，点得开；
        //  · 极简：一行状态，点不开，跑完连这行都没有。
        //
        // 单独放一张卡是因为选它的人要的是「别让我看见过程」，
        // 把两件事塞进一句话里说，反而两边都说不清。
        _toggleRow(
          s,
          icon: Icons.visibility_off_outlined,
          title: '极简过程',
          subtitle: widget.settings.minimalProgress
              ? '只留一行状态字，点开才是全部历史工具调用和文件修改。'
              : '过程和细节都照常显示。',
          value: widget.settings.minimalProgress,
          onChanged: (bool v) => widget.settings.update(
            () => widget.settings.minimalProgress = v,
          ),
        ),

        const SizedBox(height: 14),
        Center(
          child: GlassButton(
            label: '重置统计',
            icon: Icons.restart_alt_rounded,
            fontSize: 13,
            onTap: () => AppMetrics.instance.reset(),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '统计只保存在本次运行内，应用退出后清零',
            style: AppFonts.body(size: 11.5, color: s.muted),
          ),
        ),
      ],
    );
  }

  /// 这一页要列的工具调用（**时间倒序**）。
  ///
  /// 倒序的理由没变：排障时人先看"刚刚发生了什么"。正序读一遍十几步的
  /// 清单得先滑到底 —— 那正是最不想做的动作。
  List<ToolInvocation> _allInvocations() {
    final Conversation? conv = widget.conversation;
    if (conv == null) return <ToolInvocation>[];
    final List<ToolInvocation> all = <ToolInvocation>[
      for (final ChatMessage m in conv.messages) ...m.tools,
    ];
    return all.reversed.toList();
  }

  /// ---- 耗时明细（只在开发者选项打开时出现）----
  ///
  /// 把一条对话里**每一轮**的模型思考、工具执行、以及"其它等待"全列出来。
  ///
  /// ## 为什么要单列"其它等待"
  ///
  /// 用户问"为什么这次这么慢"时，能看到通常只有"思考 3 秒 / 工具 2 秒"，
  /// 但整个回合可能是 40 秒 —— 差额是首字延迟、确认框等用户点、
  /// 下一轮请求的准备。找不到这个差额，任何人都不知道该改哪里。
  Widget _timingPage(AppSurface s) {
    final Conversation? conv = widget.conversation;
    if (conv == null) {
      return ListView(
        padding: widget.padding,
        children: <Widget>[
          SurfaceCard(
            child: Text(
              '这个入口看不到对话内容。从**对话页**右上角的「性能」进来，'
              '就能看到这条对话每一轮的耗时明细。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
            ),
          ),
        ],
      );
    }

    final TimingReport report = buildTimingReport(
      conv,
      model: widget.settings.model,
    );

    if (report.isEmpty) {
      return ListView(
        padding: widget.padding,
        children: <Widget>[
          SurfaceCard(
            child: Text(
              '这条对话还没有可统计的回合。\n'
              '（只有真实产生过回复的回合才会被记录。）',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: widget.padding,
      children: <Widget>[
        // ---- 汇总 ----
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${report.turns.length} 轮 · 总耗时 ${_fmtMs(report.totalMs)}',
                style: AppFonts.body(
                  size: 13.5,
                  weight: FontWeight.w600,
                  color: s.text,
                ),
              ),
              const SizedBox(height: 8),
              _timingBar(
                s,
                _Ratio(
                  thinking: report.thinkingMs,
                  tool: report.toolMs,
                  pending: report.pendingMs,
                ),
              ),
              const SizedBox(height: 9),
              _timingLegend(
                s,
                color: AppColors.accent,
                label: '模型思考',
                value: report.thinkingMs,
                total: report.totalMs,
              ),
              _timingLegend(
                s,
                color: AppColors.success,
                label: '工具执行',
                value: report.toolMs,
                total: report.totalMs,
              ),
              _timingLegend(
                s,
                color: AppColors.warning,
                label: '其它等待',
                value: report.pendingMs,
                total: report.totalMs,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // ---- 导出 ----
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _exportTiming(report, save: false),
                icon: const Icon(Icons.content_copy_rounded, size: 16),
                label: const Text('复制 log'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => _exportTiming(report, save: true),
                icon: const Icon(Icons.save_alt_rounded, size: 16),
                label: const Text('导出文件'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ---- 逐轮 ----
        _section(s, '逐轮明细'),
        for (final TurnTiming t in report.turns)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SurfaceCard(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '第 ${t.index} 轮',
                        style: AppFonts.body(
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: s.text,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _clockText(t.startedAt),
                        style: AppFonts.code(size: 10.8, color: s.muted),
                      ),
                      const Spacer(),
                      Text(
                        _fmtMs(t.totalMs),
                        style: AppFonts.body(
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: s.text,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _timingBar(s, _Ratio.of(t)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    children: <Widget>[
                      _chip(s, '思考 ${_fmtMs(t.thinkingMs)}', AppColors.accent),
                      _chip(s, '工具 ${_fmtMs(t.toolMs)}', AppColors.success),
                      if (t.pendingMs > 0)
                        _chip(
                          s,
                          '等待 ${_fmtMs(t.pendingMs)}',
                          AppColors.warning,
                        ),
                      if (t.reasoningLevel.isNotEmpty)
                        _chip(s, t.reasoningLevel, s.muted),
                    ],
                  ),
                  if (t.toolCalls.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    for (final ({String name, int ms, String status}) c
                        in t.toolCalls)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: <Widget>[
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                c.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppFonts.code(
                                  size: 11,
                                  color: s.muted,
                                ),
                              ),
                            ),
                            Text(
                              c.status == 'failed' ? '失败' : _fmtMs(c.ms),
                              style: AppFonts.body(
                                size: 11,
                                color: c.status == 'failed'
                                    ? AppColors.danger
                                    : s.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text(
          '「其它等待」= 总耗时 − 思考 − 工具。它主要是首字延迟和确认框'
          '等你点的时间，不是模型在思考。并行执行的工具会分别计入工具时间，'
          '所以单轮的工具时间可能大于那一轮的总耗时。',
          style: AppFonts.body(size: 11, color: s.muted, height: 1.55),
        ),
      ],
    );
  }

  /// 一条堆叠比例条：思考 / 工具 / 等待 三段。
  ///
  /// 为什么不用三个进度环或三张卡：**比例**是这个页面上唯一的空间信息，
  /// 而比例只有在同一条轴线上并排才看得出来。三张卡各有各的刻度，
  /// 读起来要来回换算。
  Widget _timingBar(AppSurface s, _Ratio r) {
    final int total = r.total <= 0 ? 1 : r.total;
    return ClipRRect(
      // 6 高的条，圆角取全圆：半圆端头看起来才是「一根条」，
      // 而不是一个被裁掉角的矩形。
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: SizedBox(
        height: 6,
        child: Row(
          children: <Widget>[
            if (r.thinking > 0)
              Expanded(
                flex: (r.thinking * 1000 ~/ total).clamp(1, 1000),
                child: ColoredBox(color: AppColors.accent),
              ),
            if (r.tool > 0)
              Expanded(
                flex: (r.tool * 1000 ~/ total).clamp(1, 1000),
                child: ColoredBox(color: AppColors.success),
              ),
            if (r.pending > 0)
              Expanded(
                flex: (r.pending * 1000 ~/ total).clamp(1, 1000),
                child: ColoredBox(color: AppColors.warning),
              ),
          ],
        ),
      ),
    );
  }

  Widget _timingLegend(
    AppSurface s, {
    required Color color,
    required String label,
    required int value,
    required int total,
  }) {
    final String pct = total <= 0
        ? ''
        : '${(value * 100 / total).toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(label, style: AppFonts.body(size: 12, color: s.text)),
          const Spacer(),
          Text(
            '${_fmtMs(value)}${pct.isEmpty ? '' : '  $pct'}',
            style: AppFonts.body(size: 11.5, color: s.muted),
          ),
        ],
      ),
    );
  }

  Widget _chip(AppSurface s, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(text, style: AppFonts.body(size: 11, color: s.muted)),
      ],
    );
  }

  /// 导出：复制到剪贴板，或存成 .txt 并提示路径。
  ///
  /// 两条路都要有，因为它们对应两种完全不同的场景：
  /// · 复制 —— 用户就在聊天里，直接粘给我看，一步到位；
  /// · 存文件 —— 要给对方/留档，或者内容太长粘不下（几千轮的对话）。
  Future<void> _exportTiming(
    TimingReport report, {
    required bool save,
  }) async {
    final String text = renderTimingLog(report);
    if (!save) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已复制到剪贴板，可以直接粘贴'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }

    try {
      final Directory dir = await getTemporaryDirectory();
      final String path = await saveTimingLog(report, dir);
      // 再调一次系统「保存」，让它真的进到用户能找到的「下载」目录。
      //
      // 只写进临时目录是不够的：那个路径用户在任何文件管理器里都看不到，
      // 提示"已保存到 /data/user/0/.../cache"等于没保存成功。
      final String? err = await PlatformFiles.save(
        path,
        name: path.split(RegExp(r'[/\\]')).last,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              err == null ? '已保存到「下载」目录' : '文件已生成，但导出失败：$err',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
    }
  }

  /// 工具调用表：**时间 / 工具 / 内容**三列。  ///
  /// 为什么是表格而不是卡片清单：卡片每行只能放三样东西，而且每张卡
  /// 自己带内边距 —— 十几步之后一屏只能看三四条。排障要看的是
  /// "哪一步失败、前后两步是什么"，那需要**竖着对齐**地扫（时间一列、
  /// 工具一列），所以列宽必须固定：时间 62、工具 84，剩下的全给内容。
  Widget _toolCallPage(AppSurface s) {
    final List<ToolInvocation> all = _allInvocations();
    if (all.isEmpty) {
      return ListView(
        padding: widget.padding,
        children: <Widget>[
          SurfaceCard(
            child: Text(
              widget.conversation == null
                  ? '这个入口看不到对话内容。从**对话页**右上角的「性能」进来，'
                        '就能看到这条对话里每一次工具调用的时间和结果。'
                  : '这次对话还没有调用过工具。',
              style: AppFonts.body(size: 12.2, color: s.muted, height: 1.5),
            ),
          ),
        ],
      );
    }

    // 整张表收进一个圆角卡片：表头和行共用同一条外框，
    // 行与行之间只有一条发丝分隔线 —— 和 [ToolCallTable] 一致。
    return Padding(
      padding: widget.padding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          decoration: BoxDecoration(
            color: s.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: s.border, width: 0.6),
          ),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            // 表头一行 + 每条一次
            itemCount: all.length + 1,
            itemBuilder: (BuildContext _, int i) {
              if (i == 0) return _toolTableHead(s, all.length);
              return _toolRow(s, all[i - 1], last: i == all.length);
            },
          ),
        ),
      ),
    );
  }

  /// 表头。列宽必须和 [_toolRow] 里逐字一致 —— 两处各写一遍是唯一
  /// 容易出错的地方，所以宽度都从这两个常量来。
  static const double _colTime = 62;
  static const double _colTool = 84;

  Widget _toolTableHead(AppSurface s, int total) {
    Widget cell(String t, double? w) => SizedBox(
      width: w,
      child: Text(
        t,
        style: AppFonts.body(
          size: 11.5,
          weight: FontWeight.w600,
          color: s.muted,
          height: 1.3,
        ),
      ),
    );
    // 表头用 chipBg 铺一条：和 diff 面板的行号栏、列表分组标题同一档，
    // 让"这一行是列名"不需要靠猜。
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      decoration: BoxDecoration(
        color: s.chipBg,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.card),
        ),
      ),
      child: Row(
        children: <Widget>[
          cell('时间', _colTime),
          cell('工具', _colTool),
          Expanded(child: cell('内容（共 $total 次）', null)),
        ],
      ),
    );
  }

  /// 表格里的一行：**时间 / 工具 / 内容**。点开看完整参数和结果。
  Widget _toolRow(AppSurface s, ToolInvocation inv, {bool last = false}) {
    final (IconData icon, String label) = ToolDisplay.of(inv.name);
    final _RowState state = _rowStateOf(inv.status);
    final String content = _argSummary(inv);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showToolDetail(inv),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: state.tint,
            border: last
                ? null
                : Border(bottom: BorderSide(color: s.border, width: 0.6)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: _colTime,
                child: Text(
                  _clockText(inv.startedAt),
                  style: AppFonts.code(size: 10.8, color: s.muted),
                ),
              ),
              SizedBox(
                width: _colTool,
                child: Row(
                  children: <Widget>[
                    Icon(icon, size: 13, color: s.muted),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 12,
                          color: s.text,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  content.isEmpty ? '（没有参数）' : content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(size: 11.8, color: s.text, height: 1.4),
                ),
              ),
              const SizedBox(width: 6),
              // 状态用一个小圆点：一列对下来，哪一步失败一眼就能找到，
              // 不用读文字。颜色全部来自语义色 —— 混进一个强调橙
              // 会让"正在跑"和"点得动的地方"看起来是同一个意思。
              StatusDot(
                color: state.color,
                size: 8,
                glow: state.glow,
                tooltip: _stateLabel(inv),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _stateLabel(ToolInvocation inv) => switch (inv.status) {
    InvocationStatus.failed => '失败',
    InvocationStatus.rejected => '用户拒绝',
    InvocationStatus.running => '进行中',
    InvocationStatus.awaitingConfirm => '等确认',
    InvocationStatus.success => '成功',
  };

  /// 状态的「色 + 极淡底」。
  ///
  /// 底色压得很低（7%~12%）：十几行的表格每行铺一层明显的色，
  /// 整页会变成色块拼贴，反而更难扫。颜色只用来托住那一列小圆点。
  static _RowState _rowStateOf(InvocationStatus status) {
    switch (status) {
      case InvocationStatus.success:
        return _RowState(AppColors.success, AppColors.success, 0.06);
      case InvocationStatus.failed:
        return _RowState(AppColors.danger, AppColors.danger, 0.09);
      case InvocationStatus.rejected:
        return _RowState(AppColors.danger, AppColors.danger, 0.06);
      case InvocationStatus.running:
        return _RowState(AppColors.warning, AppColors.warning, 0.10, glow: true);
      case InvocationStatus.awaitingConfirm:
        return _RowState(AppColors.warning, AppColors.warning, 0.12);
    }
  }

  /// 点一行 → 完整参数 + 结果（复用原来那张卡的排版）。
  Future<void> _showToolDetail(ToolInvocation inv) async {
    final AppSurface s = AppSurface.of(context);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(6, 14, 6, 0),
        content: SingleChildScrollView(child: _toolCallCard(s, inv)),
        actions: <Widget>[
          GlassButton(label: '关闭', onTap: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
  }

  Widget _toolCallCard(AppSurface s, ToolInvocation inv) {
    final (IconData icon, String label) = ToolDisplay.of(inv.name);
    final bool failed = inv.status == InvocationStatus.failed;
    final bool rejected = inv.status == InvocationStatus.rejected;
    final Duration? took = inv.elapsed;

    final Color stateColor = failed
        ? AppColors.danger
        : (rejected ? AppColors.warning : AppColors.success);

    final String summary = _argSummary(inv);
    final String output = (inv.output ?? '').trim();

    return SurfaceCard(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 15, color: s.muted),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppFonts.body(
                  size: 12.8,
                  weight: FontWeight.w600,
                  color: s.text,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _clockText(inv.startedAt),
                style: AppFonts.code(size: 11, color: s.muted),
              ),
              const Spacer(),
              if (took != null)
                Text(
                  '${(took.inMilliseconds / 1000).toStringAsFixed(1)}s',
                  style: AppFonts.body(size: 11, color: s.muted),
                ),
              const SizedBox(width: 8),
              Icon(
                failed
                    ? Icons.error_outline_rounded
                    : (rejected
                          ? Icons.block_rounded
                          : Icons.check_circle_outline_rounded),
                size: 14,
                color: stateColor,
              ),
            ],
          ),
          if (summary.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: s.codeBg,
                borderRadius: BorderRadius.circular(AppRadius.code),
              ),
              child: Text(
                summary,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.code(size: 11.2, color: s.text, height: 1.45),
              ),
            ),
          ],
          if (output.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            ToolOutputText(text: output),
          ],
        ],
      ),
    );
  }

  /// 参数摘要。命令类工具给 `command`，检索类给 `query`，文件类给 `path`，
  /// 其余给压过空白的 JSON —— 完整 JSON 会占掉半屏，
  /// 而这里要看的是"它想干什么"，不是"参数长什么样"。
  static String _argSummary(ToolInvocation inv) {
    for (final String k in <String>['command', 'query', 'path', 'url']) {
      final String v = inv.args[k]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v.replaceAll(RegExp(r'\s+'), ' ');
    }
    final String raw = inv.argumentsJson.trim();
    if (raw.isEmpty || raw == '{}') return '';
    return raw.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// `HH:mm:ss`。拿不到时间戳时给"—" —— **不能编一个"现在"**，
  /// 那会让老记录看起来像刚刚发生的。
  static String _clockText(DateTime? t) {
    if (t == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _contextCard(AppSurface s, AppMetrics m) {
    // 两个口径取**较大的那个**：
    //  · `contextTokens` = 页面按消息正文算的粗估（不含系统提示词、工具表）；
    //  · `m.lastContextTokens` = 上一次请求实际发出去的 prompt 用量
    //    （含系统提示词 / 记忆 / 工具 schema / 工具输出）。
    // 只看前者会明显低估，用户会以为"还有一半空间"，其实下一轮就该压缩了。
    final int tokens = widget.contextTokens > m.lastContextTokens
        ? widget.contextTokens
        : m.lastContextTokens;
    // 上下文窗口以**模型档案里声明的**为准（见 Settings.contextLimit）：
    // 按模型名猜只在这个字段没填时才兜底，否则中转站里的模型会全猜成 128K。
    final int limit = widget.settings.contextLimit;
    final double ratio = limit <= 0 ? 0 : (tokens / limit).clamp(0.0, 1.0);

    final Color barColor = ratio > 0.8
        ? AppColors.danger
        : ratio > 0.5
        ? AppColors.warning
        : AppColors.accent;

    return SurfaceCard(
      // 上面不再有分组标题（标题已并进卡片），这里自己留出组间距。
      margin: const EdgeInsets.only(top: 10, bottom: 9),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.memory_rounded, size: 16, color: s.muted),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '上下文占用',
                      style: AppFonts.body(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: s.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.settings.model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.code(size: 11.5, color: s.muted),
                    ),
                  ],
                ),
              ),
              // 百分比放在**最显眼的位置**：它是这一块唯一一个
              // "一眼就知道该不该开新会话"的数字，token 数只作依据。
              // 字号和指标卡的大数字同一档（22/w600），这样性能页
              // 从头到尾只有一种"重点数字"的规格。
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    limit <= 0 ? '—' : '${(ratio * 100).toStringAsFixed(1)}%',
                    style: AppFonts.body(
                      size: 22,
                      weight: FontWeight.w600,
                      color: barColor,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    limit <= 0
                        ? ''
                        : '${AppMetrics.humanCount(tokens)} / '
                              '${AppMetrics.humanCount(limit)}',
                    style: AppFonts.code(size: 10.5, color: s.muted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: limit <= 0 ? 0 : ratio,
              minHeight: 6,
              backgroundColor: s.border,
              color: barColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tokens == 0
                ? '还没有发送过消息。'
                : '${ratio > 0.8 ? '接近上限，建议开新会话。' : ''}'
                      '（含系统提示词、工具表和工具输出；按文本长度估算）',
            style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _section(AppSurface s, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        title,
        style: AppFonts.body(
          size: 11.5,
          weight: FontWeight.w600,
          color: s.muted,
          height: 1.2,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  /// 列表式开关行：图标块 + 标题 + 副信息 + 右侧开关。
  ///
  /// 和存储 / 插件 / MCP 三页的列表行同一套规格。整行可点（`onTap`
  /// 和开关本身的 `onChanged` 是同一个动作），这样不必精确戳到那个开关。
  Widget _toggleRow(
    AppSurface s, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      // `ListTile`/`InkWell` 的水波纹画在最近的 Material 上，
      // SurfaceCard 是带底色的装饰盒 —— 不垫一层就没有反馈。
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => onChanged(!value),
          borderRadius: BorderRadius.circular(AppRadius.field),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.code),
                ),
                child: Icon(icon, size: 18, color: AppColors.accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: AppFonts.body(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: s.text,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              IosSwitch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }

  /// 两列网格。
  ///
  /// 一屏性能数字，原来是**一列卡片、每张一整行**：数字挤在右端，
  /// 左半边永远是空的 —— 那是把一个数字当段落排版。改成两列之后，
  /// 同一屏能放下四张，而且数字之间可以横向比较。
  ///
  /// 每两张一组用 [IntrinsicHeight]：同一行的两张卡等高，
  /// 副标题长短不一时底边不会一高一低。总数是奇数时最后一张
  /// 靠左、右边留空 —— 不拉伸成整行，否则它会比同组的高一倍。
  Widget _metricGrid(AppSurface s, List<Widget> tiles) {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < tiles.length; i += 2) {
      final Widget left = tiles[i];
      final Widget right = i + 1 < tiles.length ? tiles[i + 1] : const SizedBox();
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: left),
              const SizedBox(width: 8),
              Expanded(child: right),
            ],
          ),
        ),
      );
      if (i + 2 < tiles.length) rows.add(const SizedBox(height: 8));
    }
    return Column(children: rows);
  }

  /// 一张指标卡：图标 + 标签一行，大数字，下面一行副信息。
  ///
  /// 值的字号是 22：两列之后每张卡约 160 宽，22 的数字能保持
  /// "扫一眼抓重点"，再大就该换行了（`12.3M` 这种值最宽）。
  Widget _metricCard(
    AppSurface s, {
    required IconData icon,
    required String title,
    required String value,
    required String desc,
    bool accent = false,
  }) {
    final Color tone = accent ? AppColors.success : s.text;
    return SurfaceCard(
      radius: AppRadius.card,
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: (accent ? AppColors.success : AppColors.accent)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.code - 4),
                ),
                child: Icon(
                  icon,
                  size: 13,
                  color: accent ? AppColors.success : AppColors.accent,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 11.5,
                    weight: FontWeight.w500,
                    color: s.muted,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.body(
              size: 22,
              weight: FontWeight.w600,
              color: tone,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            desc,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.body(size: 11.5, color: s.muted, height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// 工具行的一档状态样式：圆点色 + 整行底色。
class _RowState {
  _RowState(this.color, Color base, double alpha, {this.glow = false})
    : tint = base.withValues(alpha: alpha);

  final Color color;
  final Color tint;
  final bool glow;
}

/// 三段时间的比例，给堆叠条用。
class _Ratio {
  const _Ratio({
    required this.thinking,
    required this.tool,
    required this.pending,
  });

  factory _Ratio.of(TurnTiming t) => _Ratio(
    thinking: t.thinkingMs,
    tool: t.toolMs,
    pending: t.pendingMs,
  );

  final int thinking;
  final int tool;
  final int pending;

  /// 用三段之和而不是墙钟：并行工具会让墙钟小于各段之和，
  /// 那时用墙钟当分母，三段加起来会超过 100%（条会溢出）。
  int get total => thinking + tool + pending;
}

/// 毫秒 → 人话。和 `timing_report.dart` 里那份刻意分开：
/// 那一份是写进 log 的（要稳定的纯文本），这一份是界面上的（可以更短）。
String _fmtMs(int v) {
  if (v <= 0) return '0';
  if (v < 1000) return '${v}ms';
  if (v < 10000) return '${(v / 1000).toStringAsFixed(2)}s';
  if (v < 60000) return '${(v / 1000).toStringAsFixed(1)}s';
  final int m = v ~/ 60000;
  final int s = (v % 60000) ~/ 1000;
  return '${m}m${s.toString().padLeft(2, '0')}s';
}

/// 一条工具调用的输出，默认只露 5 行。
///
/// 为什么不直接全文铺开：一次 `run_shell` 的输出可能是几十行日志，
/// 三条就能把面板撑到底 —— 而"清单"的价值在于**一眼扫完**。
/// 需要细看时点一下展开，那时占满屏幕是合理的。
class ToolOutputText extends StatefulWidget {
  const ToolOutputText({super.key, required this.text});

  final String text;

  @override
  State<ToolOutputText> createState() => _ToolOutputTextState();
}

class _ToolOutputTextState extends State<ToolOutputText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.text,
          maxLines: _open ? null : 5,
          overflow: _open ? TextOverflow.visible : TextOverflow.ellipsis,
          style: AppFonts.code(size: 11.2, color: s.muted, height: 1.5),
        ),
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _open ? '收起' : '展开全部',
                  style: AppFonts.body(size: 11.5, color: AppColors.accent),
                ),
                Icon(
                  _open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 15,
                  color: AppColors.accent,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
