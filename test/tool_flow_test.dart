// 工具链的两条硬约束：
//
//  1. **较早轮次的工具输出必须有预算**。工具自己截到 8k~12k，可一次任务
//     会调十几次，而每一轮请求都要把整段历史重发一遍 —— 10 次 × 12k
//     等于还没作答就先把上下文花掉一半。坏掉时没有任何报错，只是
//     "越到后面越慢、越容易超上下文"，是最难归因的那类回归。
//
//  2. **同一轮里参数完全相同的只读调用只跑一次**。模型偶尔会并行吐两条
//     一模一样的调用，两次结果必然相同，却要多等一次网络、多付一份 token。
//
// 这里钉的都是"格式/行为"，不依赖真实模型或真实工具。
import 'dart:io';

import 'package:dsh_agent/ai/agent.dart';
import 'package:dsh_agent/core/learning.dart';
import 'package:dsh_agent/core/memory.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/rules.dart';
import 'package:flutter_test/flutter_test.dart';

ToolInvocation _inv(
  String id,
  String name,
  String args,
  String output, {
  InvocationStatus status = InvocationStatus.success,
}) => ToolInvocation(
  id: id,
  name: name,
  argumentsJson: args,
  args: <String, dynamic>{},
  risk: RiskAssessment.safe,
  status: status,
  output: output,
);

ChatMessage _assistantWith(ToolInvocation inv) => ChatMessage(
  id: 'a_${inv.id}',
  role: Role.assistant,
  content: '先查一下',
  tools: <ToolInvocation>[inv],
);

void main() {
  setUpAll(() async {
    // buildApiMessages 会读这几个单例（main() 里正常也会配）。
    final Directory tmp = await Directory.systemTemp.createTemp('dsh_flow');
    await MemoryStore.configure(File('${tmp.path}/memory.json'));
    await RuleStore.configure(File('${tmp.path}/rules.json'));
    await LearningStore.configure(File('${tmp.path}/learning.json'));
  });

  group('较早工具输出的预算', () {
    test('超过上限的会被截断，并说明"要全文就重新调一次"', () {
      final String long = 'x' * (kOldToolOutputLimit + 500);
      final String out = budgetToolOutput(long);

      expect(out.length, lessThan(long.length));
      expect(out, contains('较早的工具输出'), reason: '必须说清这是早前的结果，否则模型会以为文件真的只有这么长');
      expect(out, contains('重新调用一次'), reason: '给了截断，就要给"拿回全文"的路，不然模型只能干瞪眼');
      expect(
        out,
        contains('${long.length}'),
        reason: '原文多长要写出来 —— 模型据此判断值不值得重取',
      );
    });

    test('没超上限的原样返回（不要凭空加尾注）', () {
      const String short = '就一行输出';
      expect(budgetToolOutput(short), short);
    });

    test('刚好等于上限时不动', () {
      final String exact = 'y' * kOldToolOutputLimit;
      expect(budgetToolOutput(exact), exact);
    });
  });

  group('buildApiMessages 里的预算只作用于较早轮次', () {
    test('上一轮全文、更早一轮被压', () async {
      final String older = 'A' * 5000;
      final String latest = 'B' * 5000;

      final Conversation conv = Conversation(
        id: 'c1',
        title: 't',
        messages: <ChatMessage>[
          ChatMessage(id: 'u1', role: Role.user, content: '查两件事'),
          _assistantWith(_inv('t1', 'web', '{"q":"a"}', older)),
          ChatMessage(id: 'u2', role: Role.user, content: '继续'),
          _assistantWith(_inv('t2', 'web', '{"q":"b"}', latest)),
        ],
      );

      final List<Map<String, dynamic>> msgs = await buildApiMessages(
        conv,
        shizukuReady: false,
      );

      final List<Map<String, dynamic>> toolMsgs = msgs
          .where((Map<String, dynamic> m) => m['role'] == 'tool')
          .toList();
      expect(toolMsgs, hasLength(2), reason: '两条 tool 消息都要在，配对不能少');

      final String first = toolMsgs[0]['content'] as String;
      final String second = toolMsgs[1]['content'] as String;

      expect(
        first.length,
        lessThan(older.length),
        reason: '更早那一轮是"已经用过"的结果，必须让位给上下文',
      );
      expect(first, contains('较早的工具输出'));
      expect(second, latest, reason: '最后一轮正是模型要作答的依据，一个字都不能少');
    });

    test('被拒绝的调用仍然是那句固定说明（不参与预算）', () async {
      final Conversation conv = Conversation(
        id: 'c2',
        title: 't',
        messages: <ChatMessage>[
          ChatMessage(id: 'u1', role: Role.user, content: '删掉它'),
          _assistantWith(
            _inv(
              't1',
              'file_write',
              '{}',
              '',
              status: InvocationStatus.rejected,
            ),
          ),
          ChatMessage(id: 'u2', role: Role.user, content: '算了'),
          _assistantWith(_inv('t2', 'web', '{}', 'ok')),
        ],
      );

      final List<Map<String, dynamic>> msgs = await buildApiMessages(
        conv,
        shizukuReady: false,
      );
      final List<Map<String, dynamic>> toolMsgs = msgs
          .where((Map<String, dynamic> m) => m['role'] == 'tool')
          .toList();

      expect(toolMsgs.first['content'], '用户拒绝执行该操作，命令没有运行。');
    });
  });

  group('同一轮里的重复只读调用', () {
    test('参数完全相同的两条只留一条执行', () {
      final ToolInvocation a = _inv('a', 'read_file', '{"path":"/x.txt"}', '');
      final ToolInvocation b = _inv('b', 'read_file', '{"path":"/x.txt"}', '');

      final (
        List<ToolInvocation> unique,
        Map<ToolInvocation, ToolInvocation> dups,
      ) = dedupeReadOnly(<ToolInvocation>[
        a,
        b,
      ]);

      expect(unique, <ToolInvocation>[a]);
      expect(dups, hasLength(1));
      expect(dups[b], same(a), reason: '重复项要指回**第一次**那次，结果从它抄');
    });

    test('参数不同（哪怕只差一个字符）都保留', () {
      final ToolInvocation a = _inv('a', 'read_file', '{"path":"/x.txt"}', '');
      final ToolInvocation b = _inv('b', 'read_file', '{"path":"/y.txt"}', '');

      final (List<ToolInvocation> unique, _) = dedupeReadOnly(<ToolInvocation>[
        a,
        b,
      ]);

      expect(unique, hasLength(2));
    });

    test('工具名不同、参数相同也不算重复', () {
      final ToolInvocation a = _inv('a', 'read_file', '{"p":1}', '');
      final ToolInvocation b = _inv('b', 'web', '{"p":1}', '');

      final (List<ToolInvocation> unique, _) = dedupeReadOnly(<ToolInvocation>[
        a,
        b,
      ]);

      expect(unique, hasLength(2));
    });

    test('空列表安全', () {
      final (
        List<ToolInvocation> unique,
        Map<ToolInvocation, ToolInvocation> dups,
      ) = dedupeReadOnly(
        <ToolInvocation>[],
      );
      expect(unique, isEmpty);
      expect(dups, isEmpty);
    });
  });

  group('工具兜底时限', () {
    test('默认 10 分钟，超时文案要说清"可能还在后台跑"', () {
      const ToolTimeout t = ToolTimeout('拼图', Duration(minutes: 10));
      expect(t.toString(), contains('10 分钟'));
      expect(
        t.toString(),
        contains('后台'),
        reason: '最危险的是用户以为没执行、又让模型跑一遍同一条写操作',
      );
    });
  });

  group('工具参数解析（parseToolArgs）', () {
    test('正常 JSON 对象直接解析', () {
      final (Map<String, dynamic> args, String? err) = parseToolArgs(
        '{"path":"/a.txt","n":2}',
      );
      expect(err, isNull);
      expect(args['path'], '/a.txt');
      expect(args['n'], 2);
    });

    test('尾部逗号自动修复（模型最常见的语法错误）', () {
      final (Map<String, dynamic> args, String? err) = parseToolArgs(
        '{"a": 1, "b": [2, 3,],}',
      );
      expect(err, isNull, reason: '修得好就不该报错，省掉一整轮重来');
      expect(args['a'], 1);
      expect(args['b'], <int>[2, 3]);
    });

    test('字符串内容里的 ",}" 不能被误伤', () {
      final (Map<String, dynamic> args, String? err) = parseToolArgs(
        '{"t": "a,}",}',
      );
      expect(err, isNull);
      expect(args['t'], 'a,}', reason: '修复只能动字符串之外的逗号');
    });

    test('能解析但不是对象 → 明确报错', () {
      final (_, String? err) = parseToolArgs('[1,2,3]');
      expect(err, isNotNull);
      expect(err, contains('JSON 对象'));
    });

    test('彻底坏掉的 JSON：报错要写清"怎么办"', () {
      final (Map<String, dynamic> args, String? err) = parseToolArgs('{bad');
      expect(args, isEmpty);
      expect(err, contains('不是合法的 JSON'));
      expect(err, contains('重新发起调用'), reason: '错误是给模型看的：不给下一步，它只会把坏 JSON 原样重发');
    });
  });

  group('未知工具的报错', () {
    test('必须附可用名单，模型下一轮才挑得对', () {
      final String out = unknownToolOutput('fly_to_moon', <String>[
        'web',
        'python',
      ]);
      expect(out, contains('fly_to_moon'));
      expect(out, contains('web'));
      expect(out, contains('python'));
      expect(out, contains('不要编造'));
    });
  });

  group('ImageDataCache（一次任务内的图片缓存）', () {
    test('同一文件第二次走缓存；内容变了自动重读', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('dsh_imgc');
      final File f = File('${tmp.path}/a.png');
      await f.writeAsBytes(<int>[1, 2, 3]);
      final Attachment a = Attachment(
        kind: AttachmentKind.image,
        path: f.path,
        name: 'a.png',
      );

      final ImageDataCache cache = ImageDataCache();
      final String? u1 = await cache.dataUrlFor(a);
      final String? u2 = await cache.dataUrlFor(a);

      expect(u1, isNotNull);
      expect(u1, startsWith('data:image/png;base64,'));
      expect(u2, u1);
      expect(cache.hits, 1, reason: '第二次必须命中缓存，不能再读盘编码一次');

      // 内容变了（尺寸跟着变）必须重读，不能拿旧图。
      await f.writeAsBytes(<int>[9, 8, 7, 6, 5]);
      final String? u3 = await cache.dataUrlFor(a);
      expect(u3, isNot(u1));
    });

    test('不存在的文件返回 null', () async {
      final ImageDataCache cache = ImageDataCache();
      final String? url = await cache.dataUrlFor(
        Attachment(
          kind: AttachmentKind.image,
          path: 'C:/不存在的/图.png',
          name: 'x.png',
        ),
      );
      expect(url, isNull);
    });
  });
}
