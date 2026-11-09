// AI 标记原文：找位置这件事的边界。
//
// 这里最容易错的是**计数基准**：创建标记时算的"第几次出现"必须和渲染器数的
// 是同一份文本。拿 markdown 原文去数的话，`[文档](https://x.com/的)` 里
// 藏在链接地址里的那个字会被算进去，标记就飘到同一文字的另一处 ——
// 用户在真机上报过两次的就是这个。
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/tools/mark_tool.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _msg(Role role, String content) =>
    ChatMessage(id: 'm${content.hashCode}', role: role, content: content);

void main() {
  test('默认找最近一条含这段文字的消息', () {
    final List<ChatMessage> msgs = <ChatMessage>[
      _msg(Role.user, '帮我看看那个文件'),
      _msg(Role.assistant, '文件里有三处问题。'),
      _msg(Role.user, '再检查一遍那个文件'),
    ];
    final hit = MarkTool.locate(msgs, '那个文件');
    expect(hit, isNotNull);
    expect(hit!.message.role, Role.user, reason: '最近的命中是最后那条用户消息');
  });

  test('on: assistant 只在 AI 回复里找', () {
    final List<ChatMessage> msgs = <ChatMessage>[
      _msg(Role.user, '重点是什么'),
      _msg(Role.assistant, '重点在第三段：注意超时。'),
    ];
    expect(
      MarkTool.locate(msgs, '重点', on: 'assistant')!.message.role,
      Role.assistant,
    );
    expect(MarkTool.locate(msgs, '第三段', on: 'user'), isNull);
  });

  test('计数基准是渲染后的正文：链接地址里的字不算', () {
    final List<ChatMessage> msgs = <ChatMessage>[
      _msg(Role.assistant, '看这个 [文档](https://x.com/的) 然后 的 这个字'),
    ];
    // 渲染后「的」只出现一次（链接地址里那个不存在）→ 第 0 次
    final hit = MarkTool.locate(msgs, '的');
    expect(hit, isNotNull);
    expect(hit!.occurrence, 0);

    // 拿原文数会是 1（地址里那次排在前面）—— 那正是标记飘走的原因
    expect('的'.allMatches(msgs.first.content).length, 2);
  });

  test('同一条消息里出现多次：默认第一处，可指定第几处', () {
    final List<ChatMessage> msgs = <ChatMessage>[_msg(Role.assistant, '的 的 的')];
    expect(MarkTool.locate(msgs, '的')!.occurrence, 0);
    expect(MarkTool.locate(msgs, '的', occurrence: 2)!.occurrence, 2);
    // 要第 4 处 → 这一条里没有这么多 → 找不到（不硬标第 1 处）
    expect(MarkTool.locate(msgs, '的', occurrence: 3), isNull);
  });

  test('找不到就返回 null（不猜、不标别处）', () {
    final List<ChatMessage> msgs = <ChatMessage>[
      _msg(Role.assistant, '今天晴，10 到 24 度。'),
    ];
    expect(MarkTool.locate(msgs, '明天有雨'), isNull);
    expect(MarkTool.locate(msgs, '   '), isNull);
  });
}
