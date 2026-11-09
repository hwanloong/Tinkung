import 'package:dsh_agent/core/think_tags.dart';
import 'package:dsh_agent/ui/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

/// 两个"内容长错地方"的 bug 的回归。
///
///  1. 有些模型/中转站把思维链**直接写在正文里**、包一层 `…`
///     —— 用户看到一整段思考混在回答里，开头那个标签还挂在第一行。
///  2. 正文里的**裸链接**（`https://…`）没被识别成链接，点不了、
///     也没法从样式上看出它是个地址。
void main() {
  // 标签用**拼**的：直接写字面量会被各种"清理 HTML"的环节吃掉
  // （这个测试的第一版就是这么丢掉闭合标签、变成空转的）。
  // 也不用 `+` 拼字面量 —— 那会触发 `prefer_adjacent_string_concatenation`。
  final String closeThink = <String>['<', '/thi', 'nk>'].join();

  group('思考标签拆分', () {
    test('成对标签：内容进思考，正文只剩回答', () {
      final ThinkSplit r = splitThinkTags('<think>先看电量，再清缓存。</think>好的，我来处理。');
      expect(r.content, '好的，我来处理。');
      expect(r.reasoning, '先看电量，再清缓存。');
    });

    test('只给开标签（流式/被吞闭合）：后面全部算思考', () {
      final ThinkSplit r = splitThinkTags('<think>正在推演，还没想完…');
      expect(r.content, '');
      expect(r.reasoning, contains('正在推演'));
    });

    test('只给闭标签（中转站吃掉开标签）：前面那段算思考', () {
      final String t = '先这样再那样。$closeThink好的，答案是 42。';
      final ThinkSplit r = splitThinkTags(t);
      expect(r.content, '好的，答案是 42。');
      expect(r.reasoning, '先这样再那样。');
    });

    test('多段思考按顺序拼起来，标签本身从正文消失', () {
      final ThinkSplit r = splitThinkTags(
        '<think>第一段</think>回答一<thinking>第二段</thinking>回答二',
      );
      expect(r.content, '回答一回答二');
      expect(r.reasoning, contains('第一段'));
      expect(r.reasoning, contains('第二段'));
      expect(r.content, isNot(contains('<')));
    });

    test('没有标签时**一个字都不改**（别把普通正文搞坏）', () {
      const String t = '普通回答，里面有 <div> 这种标签也不该被动。';
      final ThinkSplit r = splitThinkTags(t);
      expect(r.content, t);
      expect(r.reasoning, isEmpty);
    });

    test('只剩标签的垃圾会被清掉', () {
      final ThinkSplit r = splitThinkTags(closeThink);
      expect(r.content, '');
      expect(r.reasoning, isEmpty);
    });
  });

  group('markdown 链接', () {
    test('地址里带括号（维基那种）也要认成链接', () {
      // 以前这一条整体匹配失败，正文里原样显示
      // `[Foo](https://en.wikipedia.org/wiki/Foo_(bar))`。
      const String t = '[Foo](https://en.wikipedia.org/wiki/Foo_(bar)) 之后';
      expect(inlineLinkTargets(t), <String>[
        'https://en.wikipedia.org/wiki/Foo_(bar)',
      ]);
    });
  });

  group('裸链接末尾标点', () {
    test('句号/逗号不进链接（否则点进去 404）', () {
      expect(trimUrlTail('https://a.com/x。'), 'https://a.com/x');
      expect(trimUrlTail('https://a.com/x,'), 'https://a.com/x');
      expect(trimUrlTail('https://a.com/x！'), 'https://a.com/x');
    });

    test('包围用的右括号剥掉，成对的括号留着', () {
      expect(trimUrlTail('https://a.com/x)'), 'https://a.com/x');
      expect(
        trimUrlTail('https://a.com/wiki/Foo_(bar)'),
        'https://a.com/wiki/Foo_(bar)',
        reason: '括号是地址的一部分，剥掉就 404 了',
      );
    });

    test('查询串一个字都不动', () {
      expect(trimUrlTail('https://a.com/s?q=1&b=2'), 'https://a.com/s?q=1&b=2');
    });
  });
}
