// 耗时报告。
//
// 这份报告的唯一用途是"拿给看的人判断慢在哪"，所以用例盯的是
// **口径有没有说谎**：
//  · 三段（思考 / 工具 / 等待）加起来必须能解释总耗时；
//  · 并行工具时不能算出负数；
//  · 空回合不能被算进去（否则平均值失真）；
//  · log 里必须有"怎么读"的说明（否则一堆数字没人看得懂）。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/timing_report.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _assistant({
  required DateTime at,
  int reasoningMs = 0,
  List<ToolInvocation> tools = const <ToolInvocation>[],
  String content = '答好了',
  bool hidden = false,
}) {
  return ChatMessage(
    id: 'a${at.microsecondsSinceEpoch}',
    role: Role.assistant,
    content: content,
    reasoningMs: reasoningMs,
    createdAt: at,
    tools: tools,
    hidden: hidden,
  );
}

ToolInvocation _tool({
  required DateTime start,
  required int ms,
  String name = 'run_shell',
  InvocationStatus status = InvocationStatus.success,
}) => ToolInvocation(
  id: 't${start.microsecondsSinceEpoch}',
  name: name,
  argumentsJson: '{}',
  args: <String, dynamic>{},
  risk: RiskAssessment.safe,
  status: status,
  startedAt: start,
  finishedAt: start.add(Duration(milliseconds: ms)),
);

void main() {
  group('逐轮拆分', () {
    test('思考 + 工具 + 等待 = 总耗时', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      final Conversation conv = Conversation(
        id: 'c',
        title: '测试',
        messages: <ChatMessage>[
          ChatMessage(id: 'u', role: Role.user, content: '查一下', createdAt: t0),
          _assistant(
            at: t0,
            reasoningMs: 2000,
            tools: <ToolInvocation>[
              _tool(start: t0.add(const Duration(seconds: 2)), ms: 3000),
            ],
          ),
        ],
      );

      final TimingReport r = buildTimingReport(conv, model: 'm');
      expect(r.turns, hasLength(1));

      final TurnTiming t = r.turns.first;
      expect(t.thinkingMs, 2000);
      expect(t.toolMs, 3000);
      expect(t.totalMs, 5000, reason: '最后一步工具结束时就是这一轮的终点');
      expect(
        t.thinkingMs + t.toolMs + t.pendingMs,
        t.totalMs,
        reason: '三段必须能解释整个耗时，否则报告就是在糊弄',
      );
    });

    test('并行工具不会算出负的等待时间', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      // 两个工具同时跑 3 秒：墙钟 3 秒，但各自计 3 秒 → 相加 6 秒
      final Conversation conv = Conversation(
        id: 'c',
        title: 't',
        messages: <ChatMessage>[
          _assistant(
            at: t0,
            tools: <ToolInvocation>[
              _tool(start: t0, ms: 3000, name: 'web'),
              _tool(start: t0, ms: 3000, name: 'reader'),
            ],
          ),
        ],
      );

      final TurnTiming t = buildTimingReport(conv, model: 'm').turns.first;
      expect(t.toolMs, 6000, reason: '并行时各段的和不等于墙钟，这是正常的');
      expect(t.pendingMs, 0, reason: '负数只会让人以为算错了，钳到 0');
    });

    test('完全空的回合不算进去', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      final Conversation conv = Conversation(
        id: 'c',
        title: 't',
        messages: <ChatMessage>[
          ChatMessage(id: 'u', role: Role.user, content: 'hi', createdAt: t0),
          // 占位但什么都没等到的 assistant
          _assistant(at: t0, content: ''),
        ],
      );
      expect(buildTimingReport(conv, model: 'm').turns, isEmpty);
    });

    test('隐藏的静默回合不算进去（它们是互动面板的内部来回）', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      final Conversation conv = Conversation(
        id: 'c',
        title: 't',
        messages: <ChatMessage>[
          _assistant(at: t0, reasoningMs: 500, hidden: true),
        ],
      );
      expect(buildTimingReport(conv, model: 'm').turns, isEmpty);
    });

    test('失败的工具也计入时间，并保留状态', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      final Conversation conv = Conversation(
        id: 'c',
        title: 't',
        messages: <ChatMessage>[
          _assistant(
            at: t0,
            tools: <ToolInvocation>[
              _tool(
                start: t0,
                ms: 800,
                name: 'writer',
                status: InvocationStatus.failed,
              ),
            ],
          ),
        ],
      );
      final TurnTiming t = buildTimingReport(conv, model: 'm').turns.first;
      expect(t.toolCalls.first.status, 'failed');
      expect(t.toolMs, 800, reason: '失败也花了时间，不能从统计里抹掉');
    });
  });

  group('汇总', () {
    test('多轮累加', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      final Conversation conv = Conversation(
        id: 'c',
        title: 't',
        messages: <ChatMessage>[
          _assistant(at: t0, reasoningMs: 1000),
          _assistant(
            at: t0.add(const Duration(seconds: 5)),
            reasoningMs: 2000,
            tools: <ToolInvocation>[
              _tool(start: t0.add(const Duration(seconds: 7)), ms: 1000),
            ],
          ),
        ],
      );
      final TimingReport r = buildTimingReport(conv, model: 'm');
      expect(r.turns, hasLength(2));
      expect(r.thinkingMs, 3000);
      expect(r.toolMs, 1000);
      expect(r.toolCallCount, 1);
    });
  });

  group('log 文本', () {
    test('带汇总、逐轮、以及"怎么读"的说明', () {
      final DateTime t0 = DateTime(2026, 10, 26, 10, 0, 0);
      final Conversation conv = Conversation(
        id: 'c',
        title: '写周报',
        messages: <ChatMessage>[
          _assistant(
            at: t0,
            reasoningMs: 1200,
            tools: <ToolInvocation>[_tool(start: t0, ms: 400)],
          ),
        ],
      );

      final String log = renderTimingLog(
        buildTimingReport(conv, model: 'deepseek'),
      );

      expect(log, contains('耗时报告'));
      expect(log, contains('写周报'));
      expect(log, contains('deepseek'));
      expect(log, contains('模型思考'));
      expect(log, contains('其它等待'));
      expect(log, contains('逐轮'));
      expect(log, contains('怎么读'), reason: '没有读法的 log 只是一堆数字');
      expect(log, contains('并行'), reason: '并行会让工具时间超过墙钟，必须说清楚');
    });

    test('空对话也给出明确的说明，而不是一份空白', () {
      final Conversation conv = Conversation(id: 'c', title: '空');
      final String log = renderTimingLog(buildTimingReport(conv, model: 'm'));
      expect(log, contains('没有可以统计的回合'));
    });

    test('文件名里不能留斜杠冒号（要同步到电脑）', () async {
      final Directory dir = await Directory.systemTemp.createTemp('dsh_log');
      addTearDown(() => dir.delete(recursive: true));

      final TimingReport r = TimingReport(
        conversationTitle: '项目A/阶段:1',
        model: 'm',
        turns: const <TurnTiming>[],
        generatedAt: DateTime(2026, 10, 26, 10, 0, 0),
      );
      final String path = await saveTimingLog(r, dir);
      final String name = path.split(RegExp(r'[/\\]')).last;

      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(':')));
      expect(await File(path).exists(), isTrue);
    });
  });
}
