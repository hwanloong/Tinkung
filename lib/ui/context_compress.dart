import 'package:flutter/material.dart';

import '../ai/deepseek.dart';
import '../core/metrics.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'widgets.dart';

/// 上下文压缩：把老消息换成一个摘要，腾出空间。
///
/// ## 为什么需要它
///
/// 多轮工具调用会飞快地把上下文吃掉 —— 一次网页抓取就是几千 token，
/// 一个复杂任务里模型可能调十几次工具。而**用户不会自己去算**还剩多少，
/// 等到 API 报"超出上下文"时，界面上只会出现一句莫名其妙的错误，
/// 前面聊的内容也没了（不同服务商的处理不一样，有的直接报错，
/// 有的**静默截断**开头 —— 后者更糟，模型会突然"忘记"用户说过什么）。
///
/// 所以做两件事：
///  · 用量到阈值时**主动问**要不要压缩（见 [CompressPrompt]）；
///  · 压缩本身是**有损但可控**的：老消息 → 一段摘要，
///    最近几轮原样保留。用户能看见摘要，也能撤销（不建议删原消息）。
///
/// ## 为什么保留最近几轮而不是全压
///
/// 摘要必然丢细节，而**最近的对话正是细节最要紧的地方** ——
/// 用户上一句说"不要用中文"，压没了下一轮就会翻车。
/// 所以保留尾部，只压中段。
class ContextCompressor {
  const ContextCompressor._();

  /// 保留尾部多少条消息不动。
  ///
  /// 8 条 ≈ 最近两三轮问答（含工具调用产生的消息）。
  /// 太少会在多工具任务里把"刚才在干什么"压掉；太多则省不下多少空间。
  static const int keepTail = 8;

  /// 触发提示的阈值：用量超过上下文的这个比例就弹。
  ///
  /// 0.85 而不是 0.95：留出一次完整往返的余量 ——
  /// 提示是**在**一轮结束**后**弹的，而用户点"压缩"到模型开始回答之间
  /// 还会有新的输入。等到 95% 再弹，那一次就已经溢出了。
  static const double warnRatio = 0.85;

  /// 估算一段会话占多少 token。
  static int estimate(Conversation conv) {
    int sum = 0;
    for (final ChatMessage m in conv.messages) {
      sum += AppMetrics.estimate(m.content);
      sum += AppMetrics.estimate(m.reasoning);
      for (final ToolInvocation t in m.tools) {
        sum += AppMetrics.estimate(t.output ?? '');
      }
    }
    return sum;
  }

  /// 把会话渲染成一段纯文本，喂给模型做摘要。
  ///
  /// **截断得很狠**（每条 1200 字符）：摘要请求本身也要花 token，
  /// 把要压的内容原样再发一遍，等于"为了省空间先花掉同等空间" ——
  /// 在最需要它的场景（上下文快满）下这恰恰会失败。
  ///
  /// 所以这里做的是**抽样式压缩**：长内容只取开头，靠模型的概括能力
  /// 而不是靠把原文全带上。
  static String render(Conversation conv) {
    final StringBuffer sb = StringBuffer();
    for (final ChatMessage m in conv.messages) {
      final String role = switch (m.role) {
        Role.user => '用户',
        Role.assistant => '助手',
        Role.tool => '工具',
        Role.system => '系统',
      };
      final String text = m.content.trim();
      if (text.isEmpty && m.tools.isEmpty) continue;

      sb.writeln('【$role】');
      if (text.isNotEmpty) {
        sb.writeln(text.length > 1200 ? text.substring(0, 1200) : text);
      }
      // 工具调用只记名字和结果开头 —— 完整输出往往是整页网页，
      // 带上它会让这次摘要请求本身超限。
      for (final ToolInvocation t in m.tools) {
        final String out = (t.output ?? '').trim();
        sb.writeln(
          '· 调用工具 ${t.name}'
          '${out.isEmpty ? '' : '：${out.length > 300 ? out.substring(0, 300) : out}'}',
        );
      }
      sb.writeln();
    }
    return sb.toString();
  }

  /// 让模型把 [conv] 里"中段"的消息压成一段摘要。
  ///
  /// 返回摘要文本；失败抛 [ApiException]（调用方负责提示）。
  static Future<String> summarize({
    required Conversation conv,
    required Settings settings,
    required int keepTailCount,
    void Function(String chunk)? onProgress,
  }) async {
    final int head = conv.messages.length - keepTailCount;
    if (head <= 0) {
      throw ApiException('这个会话太短，没有可压缩的内容');
    }

    final List<ChatMessage> middle = conv.messages.sublist(0, head);
    final StringBuffer body = StringBuffer();
    for (final ChatMessage m in middle) {
      final String role = switch (m.role) {
        Role.user => '用户',
        Role.assistant => '助手',
        Role.tool => '工具',
        Role.system => '系统',
      };
      final String text = m.content.trim();
      if (text.isNotEmpty) {
        body.writeln(
          '【$role】'
          '${text.length > 1200 ? '${text.substring(0, 1200)}…' : text}',
        );
      }
      for (final ToolInvocation t in m.tools) {
        final String out = (t.output ?? '').trim();
        body.writeln(
          '· 工具 ${t.name}'
          '${out.isEmpty ? '' : '：${out.length > 300 ? out.substring(0, 300) : out}'}',
        );
      }
    }

    final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'system',
        'content':
            '你是对话摘要器。把用户和助手的对话压缩成一份**能替代原文**的摘要。'
            '要求：\n'
            '1. 保留所有**事实性信息**：文件名、路径、命令、数字、报错原文、'
            '用户明确提出的偏好和约束。\n'
            '2. 保留"做过什么、结果如何"，尤其是**失败过什么** —— '
            '否则后面的轮次会重复踩同一个坑。\n'
            '3. 用条目而不是长段落。\n'
            '4. 不要评价、不要补充原文没有的内容、不要写"以上是摘要"。\n'
            '5. 直接输出摘要正文。',
      },
      <String, dynamic>{'role': 'user', 'content': '请压缩下面这段对话：\n\n$body'},
    ];

    final DeepSeekClient client = DeepSeekClient(settings);
    final AssistantTurn turn = await client.chat(
      messages: messages,
      onText: onProgress,
    );
    final String summary = turn.content.trim();
    if (summary.isEmpty) {
      throw ApiException('模型没有返回摘要内容');
    }
    return summary;
  }

  /// 把摘要**替换进**会话：删掉中段，在开头插入一条摘要消息。
  ///
  /// 摘要放在**最前面**（`Role.assistant`）：
  /// · 放最前 = 时间顺序正确，模型读到它就知道"这是之前发生的事"；
  /// · 用 assistant 而不是 system：system 会被各家服务端的提示词
  ///   优先级规则特殊对待，而这里只是一段历史内容的替身。
  static void apply(Conversation conv, String summary, int keepTailCount) {
    final int head = conv.messages.length - keepTailCount;
    if (head <= 0) return;

    final List<ChatMessage> tail = conv.messages.sublist(head);
    conv.messages
      ..clear()
      ..add(
        ChatMessage(
          id: 'summary_${DateTime.now().microsecondsSinceEpoch}',
          role: Role.assistant,
          content:
              '（以下是本次对话较早部分的摘要，用于节省上下文；'
              '原文已从上下文中移除，但历史记录里仍能看到）\n\n$summary',
        ),
      )
      ..addAll(tail);
  }
}

/// 压缩前的确认面板。
///
/// 做成面板而不是 AlertDialog：里面要放**摘要预览**（可能好几百字），
/// 弹窗在窄屏上会被压得很矮、内容得来回滚，而用户需要的是
/// "扫一眼摘要，确认它没丢关键信息，再决定"。
class CompressPrompt extends StatefulWidget {
  const CompressPrompt({
    super.key,
    required this.conversation,
    required this.settings,
  });

  final Conversation conversation;
  final Settings settings;

  /// 返回 true 表示用户确认压缩（并且压缩已经落到 [conversation] 上）。
  static Future<bool> show(
    BuildContext context, {
    required Conversation conversation,
    required Settings settings,
  }) async {
    final bool? ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (BuildContext _) =>
          CompressPrompt(conversation: conversation, settings: settings),
    );
    return ok ?? false;
  }

  @override
  State<CompressPrompt> createState() => _CompressPromptState();
}

class _CompressPromptState extends State<CompressPrompt> {
  bool _running = false;
  String? _summary;
  String? _error;

  int get _before => ContextCompressor.estimate(widget.conversation);

  int get _after {
    final String? s = _summary;
    if (s == null) return _before;
    // 估算压缩后的大小：摘要 + 保留的尾部
    final int keep =
        widget.conversation.messages.length >= ContextCompressor.keepTail
        ? widget.conversation.messages.length - ContextCompressor.keepTail
        : 0;
    int tail = 0;
    for (final ChatMessage m in widget.conversation.messages.sublist(keep)) {
      tail += AppMetrics.estimate(m.content);
      for (final ToolInvocation t in m.tools) {
        tail += AppMetrics.estimate(t.output ?? '');
      }
    }
    return AppMetrics.estimate(s) + tail;
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final String summary = await ContextCompressor.summarize(
        conv: widget.conversation,
        settings: widget.settings,
        keepTailCount: ContextCompressor.keepTail,
      );
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _running = false;
      });
    }
  }

  void _accept() {
    final String? s = _summary;
    if (s == null) return;
    ContextCompressor.apply(widget.conversation, s, ContextCompressor.keepTail);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final int limit = widget.settings.contextLimit;
    final int before = _before;
    final int after = _after;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // 摘要预览可能很长。用 sheetMaxHeight 让出状态栏 ——
        // 这个面板的标题（"上下文快满了"）正好是最需要看清的一行。
        constraints: BoxConstraints(maxHeight: sheetMaxHeight(context, 0.85)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: <Widget>[
                  // 和存储 / 插件 / MCP 的列表行同一个图标块规格。
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.code),
                    ),
                    child: Icon(
                      Icons.compress_rounded,
                      size: 18,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '上下文快满了',
                          style: AppFonts.body(
                            size: 17,
                            weight: FontWeight.w600,
                            color: s.text,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '已用约 ${_k(before)} / ${_k(limit)} token'
                          '（${(before / limit * 100).clamp(0, 999).toStringAsFixed(0)}%）',
                          style: AppFonts.code(size: 11.5, color: s.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '继续聊下去会被服务端截断或直接报错 —— '
                  '**截断更麻烦**：模型会突然"忘记"你前面说过什么。',
                  style: AppFonts.body(size: 12.5, color: s.muted, height: 1.55),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '压缩会把较早的对话交给模型总结成一段摘要，'
                      '最近 ${ContextCompressor.keepTail} 条消息原样保留。'
                      '原始记录**不会被删除** —— 往上翻仍然看得到。',
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.55,
                      ),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 14),
                      _box(
                        s,
                        border: AppColors.danger,
                        child: Text(
                          '压缩失败：$_error',
                          style: AppFonts.body(
                            size: 12.4,
                            color: s.text,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                    if (_summary != null) ...<Widget>[
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Text(
                            '摘要预览',
                            style: AppFonts.body(
                              size: 12.5,
                              weight: FontWeight.w600,
                              color: s.text,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '约 ${_k(before)} → ${_k(after)} token',
                            style: AppFonts.code(
                              size: 11.5,
                              color: AppColors.success,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _box(
                        s,
                        child: Text(
                          _summary!,
                          style: AppFonts.body(
                            size: 12.6,
                            color: s.text,
                            height: 1.65,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '如果摘要里少了关键信息，可以点「重新生成」再试一次。'
                        '不接受的话选「稍后」，这一轮照常发出去（只是有被截断的风险）。',
                        style: AppFonts.body(
                          size: 11.4,
                          color: s.muted,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: <Widget>[
                  TextButton(
                    onPressed: _running
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('稍后'),
                  ),
                  const Spacer(),
                  if (_summary == null)
                    FilledButton.icon(
                      onPressed: _running ? null : _run,
                      icon: _running
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.compress_rounded, size: 18),
                      label: Text(_running ? '正在压缩' : '开始压缩'),
                    )
                  else ...<Widget>[
                    TextButton(
                      onPressed: _running ? null : _run,
                      child: const Text('重新生成'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: _accept,
                      child: const Text('用这份摘要'),
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

  /// 摘要预览 / 错误提示的底框。圆角、底色、描边都走 token，
  /// 和其余弹层里的卡片是同一套（见 [AppRadius.card]）。
  Widget _box(AppSurface s, {required Widget child, Color? border}) {
    // 统一用玻璃卡片。`border` 原来是给它染一层淡色（比如"保留/压缩"
    // 两种状态），玻璃的 tint 能承担同样的语义，所以直接传进去。
    return SizedBox(
      width: double.infinity,
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        radius: AppRadius.card,
        color: border?.withValues(alpha: s.isDark ? 0.10 : 0.06),
        child: child,
      ),
    );
  }

  /// token 数字的可读化：`12345` → `12.3k`。
  ///
  /// 精确到个位没有意义（本来就是估算），反而让用户以为很准。
  static String _k(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }
}
