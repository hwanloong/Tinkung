import 'dart:io';


import 'app_info.dart';
import 'models.dart';

/// 一轮的时间线：模型思考、工具执行、以及它们之间的空洞。
///
/// ## 为什么需要"空洞"这个量
///
/// 用户问"为什么这次回答这么慢"时，能看到的往往只有"思考 3 秒"和
/// "工具 2 秒"。但**一整个回合可能要 40 秒** —— 中间那些既没在思考、
/// 也没在跑工具的时间去哪了？
///
/// 真实的成分有这些：等首字（建连 + 排队 + 模型 prefill）、工具确认框
/// 等用户点、工具结果回填之后的下一轮请求。这些时间不归任何一步，
/// 但它们往往才是大头。不算出来，报告里就会写"3 秒 + 2 秒 = 40 秒"，
/// 谁看了都不知道该改什么。
class TurnTiming {
  const TurnTiming({
    required this.index,
    required this.startedAt,
    required this.finishedAt,
    required this.thinkingMs,
    required this.toolMs,
    required this.reasoningLevel,
    required this.toolCalls,
    required this.pendingMs,
  });

  /// 第几轮（1 起算）。一次"发送"里可能有多轮：模型 → 工具 → 模型 → …
  final int index;

  final DateTime startedAt;
  final DateTime finishedAt;

  /// 模型思考耗时（`reasoning_content` 从首片到正文首片）。
  final int thinkingMs;

  /// 这一轮里所有工具执行时间之和。
  final int toolMs;

  /// 这一轮里"既不在思考、也不在跑工具"的时间。
  final int pendingMs;

  final String reasoningLevel;

  /// 这一轮调用了哪些工具（名字 + 各自耗时 + 状态）。
  final List<({String name, int ms, String status})> toolCalls;

  int get totalMs => finishedAt.difference(startedAt).inMilliseconds;

  bool get hasWork => thinkingMs > 0 || toolMs > 0 || toolCalls.isNotEmpty;
}

/// 一次「发送」的完整耗时报告。
class TimingReport {
  const TimingReport({
    required this.conversationTitle,
    required this.model,
    required this.turns,
    required this.generatedAt,
    this.note = '',
  });

  final String conversationTitle;
  final String model;
  final List<TurnTiming> turns;
  final DateTime generatedAt;

  /// 报告里要附的一句说明（比如"这次数据来自估算"）。
  final String note;

  int get totalMs =>
      turns.fold<int>(0, (int s, TurnTiming t) => s + t.totalMs);

  int get thinkingMs =>
      turns.fold<int>(0, (int s, TurnTiming t) => s + t.thinkingMs);

  int get toolMs => turns.fold<int>(0, (int s, TurnTiming t) => s + t.toolMs);

  int get pendingMs =>
      turns.fold<int>(0, (int s, TurnTiming t) => s + t.pendingMs);

  int get toolCallCount =>
      turns.fold<int>(0, (int s, TurnTiming t) => s + t.toolCalls.length);

  bool get isEmpty => turns.isEmpty;
}

/// 把一次对话整理成逐轮时间线。
///
/// ## 口径（写进 log 里，方便对账）
///
/// · **一轮** = 一条 assistant 消息。多轮工具调用时会有好几条，
///   它们合起来才是一次"发送"。
/// · **思考** = `ChatMessage.reasoningMs`，从收到第一个 reasoning 分片
///   到第一个正文分片。不含建连排队。
/// · **工具** = 每个 `ToolInvocation` 的 `finishedAt - startedAt`。
///   并行执行的几个工具会**分别计入**，所以 `toolMs` 在这一轮里
///   可能大于这一轮的墙钟时间 —— 那是正常的，log 里会标出来。
/// · **等待** = 这一轮墙钟 - 思考 - 串行工具时间。它包含首字延迟、
///   确认框等待、以及下一轮请求的准备。
TimingReport buildTimingReport(
  Conversation conv, {
  required String model,
}) {
  final List<TurnTiming> turns = <TurnTiming>[];
  int index = 0;

  for (final ChatMessage m in conv.messages) {
    if (m.role != Role.assistant || m.hidden) continue;
    // 完全空的消息不算一轮：那是建了占位但没等到内容的情况，
    // 算进来会让"平均每轮耗时"失真。
    if (m.content.trim().isEmpty && m.tools.isEmpty && m.reasoningMs == 0) {
      continue;
    }
    index++;

    final List<({String name, int ms, String status})> calls =
        <({String name, int ms, String status})>[
      for (final ToolInvocation t in m.tools)
        (
          name: t.name,
          ms: t.elapsed?.inMilliseconds ?? 0,
          status: t.status.name,
        ),
    ];

    int toolMs = 0;
    for (final ({String name, int ms, String status}) c in calls) {
      toolMs += c.ms;
    }

    // 墙钟：这条消息创建 → 它最后一个动作结束。
    //
    // 为什么用"最后一个工具结束"而不是"消息被保存的时刻"：消息在流式
    // 过程中就建好了，`createdAt` 是开始时间；而它什么时候"算完"，
    // 取最后完成的那个工具最准。没有工具时就用思考耗时兜住。
    DateTime end = m.createdAt;
    for (final ToolInvocation t in m.tools) {
      final DateTime? f = t.finishedAt;
      if (f != null && f.isAfter(end)) end = f;
    }
    if (m.reasoningMs > 0) {
      final DateTime guess = m.createdAt.add(
        Duration(milliseconds: m.reasoningMs),
      );
      if (guess.isAfter(end)) end = guess;
    }

    final int wall = end.difference(m.createdAt).inMilliseconds;
    final int pending = wall - m.reasoningMs - toolMs;

    turns.add(
      TurnTiming(
        index: index,
        startedAt: m.createdAt,
        finishedAt: end,
        thinkingMs: m.reasoningMs,
        toolMs: toolMs,
        // 负数说明并行工具把它撑大了，钳到 0：一个负数只会让人以为算错了。
        pendingMs: pending < 0 ? 0 : pending,
        reasoningLevel: m.reasoningLevel,
        toolCalls: calls,
      ),
    );
  }

  return TimingReport(
    conversationTitle: conv.title.trim().isEmpty ? '未命名对话' : conv.title,
    model: model,
    turns: turns,
    generatedAt: DateTime.now(),
  );
}

/// 把报告渲染成**纯文本 log**。
///
/// 为什么是纯文本而不是 JSON 或 CSV：用户拿到它是要**贴给我看**的。
/// JSON 在一段聊天里没法读，CSV 在手机上打开是一团横线。纯文本
/// 谁都能读、能直接粘进任何一个输入框，而且 diff 起来也正常。
String renderTimingLog(TimingReport r) {
  final StringBuffer sb = StringBuffer();

  sb.writeln('===== $kAppName 耗时报告 =====');
  sb.writeln('版本    : $kAppVersionLabel');
  sb.writeln('时间    : ${_stamp(r.generatedAt)}');
  sb.writeln('对话    : ${r.conversationTitle}');
  sb.writeln('模型    : ${r.model.isEmpty ? '（未记录）' : r.model}');

  if (r.isEmpty) {
    sb.writeln();
    sb.writeln('这条对话里没有可以统计的回合。');
    sb.writeln('（只有真实产生过回复的回合才会被记录，空占位不算。）');
    return sb.toString();
  }

  sb.writeln();
  sb.writeln('----- 汇总 -----');
  sb.writeln('回合数      : ${r.turns.length}');
  sb.writeln('总耗时      : ${_ms(r.totalMs)}');
  sb.writeln(
    '模型思考    : ${_ms(r.thinkingMs)}'
    '${_pct(r.thinkingMs, r.totalMs)}',
  );
  sb.writeln(
    '工具执行    : ${_ms(r.toolMs)}'
    '${_pct(r.toolMs, r.totalMs)}',
  );
  sb.writeln(
    '其它等待    : ${_ms(r.pendingMs)}'
    '${_pct(r.pendingMs, r.totalMs)}',
  );
  sb.writeln('工具调用次数: ${r.toolCallCount}');

  sb.writeln();
  sb.writeln('----- 逐轮 -----');
  sb.writeln(
    '回合  开始       总耗时     思考       工具       等待       深度',
  );
  for (final TurnTiming t in r.turns) {
    sb.writeln(
      '${t.index.toString().padLeft(4)}  '
      '${_clock(t.startedAt)}  '
      '${_ms(t.totalMs).padLeft(9)}  '
      '${_ms(t.thinkingMs).padLeft(9)}  '
      '${_ms(t.toolMs).padLeft(9)}  '
      '${_ms(t.pendingMs).padLeft(9)}  '
      '${t.reasoningLevel.isEmpty ? '-' : t.reasoningLevel}',
    );
    for (final ({String name, int ms, String status}) c in t.toolCalls) {
      sb.writeln(
        '        · ${c.name.padRight(14)} ${_ms(c.ms).padLeft(9)}  ${c.status}',
      );
    }
  }

  // ---- 读法说明 ----
  //
  // 没有这段的话，一份全是数字的 log 交到别人手里只能靠猜。
  sb.writeln();
  sb.writeln('----- 怎么读这份 log -----');
  sb.writeln(
    '· 「其它等待」= 总耗时 - 思考 - 工具。它主要是首字延迟（建连、排队、',
  );
  sb.writeln(
    '  模型 prefill）和工具确认框等用户点的时间。这一项很大时，慢的不是',
  );
  sb.writeln('  模型思考，也不是工具。');
  sb.writeln(
    '· 并行执行的几个工具会分别计入「工具」，所以单轮的工具时间可能',
  );
  sb.writeln('  大于那一轮的墙钟时间。串行调用没有这个问题。');
  sb.writeln(
    '· 「思考」不含建连和排队，只算真正在出 reasoning_content 的那段。',
  );
  sb.writeln(
    '· 时间是**单调**的（取消息创建时间到最后一步结束），跨设备对时可能',
  );
  sb.writeln('  有几毫秒偏差。');
  if (r.note.trim().isNotEmpty) {
    sb.writeln();
    sb.writeln('备注：${r.note}');
  }

  return sb.toString();
}

/// 保存到文件，返回路径。失败时抛异常，由调用方决定怎么提示。
Future<String> saveTimingLog(
  TimingReport report,
  Directory dir, {
  String name = '',
}) async {
  await dir.create(recursive: true);
  final String safeName = (name.trim().isEmpty ? report.conversationTitle : name)
      // 文件名里的斜杠/冒号在 Windows 上不合法，而这份文件会同步到电脑
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .trim();
  final String base = safeName.isEmpty ? 'timing' : safeName;
  final String path =
      '${dir.path}/timing_${_fileStamp(report.generatedAt)}_$base.txt';
  await File(path).writeAsString(renderTimingLog(report));
  return path;
}

// ---------------------------------------------------------------- 格式化

String _ms(int v) {
  if (v <= 0) return '0';
  if (v < 1000) return '${v}ms';
  if (v < 10000) return '${(v / 1000).toStringAsFixed(2)}s';
  if (v < 60000) return '${(v / 1000).toStringAsFixed(1)}s';
  final int m = v ~/ 60000;
  final int s = (v % 60000) ~/ 1000;
  return '${m}m${s.toString().padLeft(2, '0')}s';
}

String _pct(int part, int total) {
  if (total <= 0) return '';
  return '  (${(part * 100 / total).toStringAsFixed(1)}%)';
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_clock(t)}';

String _fileStamp(DateTime t) =>
    '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

String _two(int v) => v.toString().padLeft(2, '0');
