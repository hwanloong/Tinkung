// 「描述改进」的护栏测试。
//
// 为什么重点测这两个纯函数：这个功能是**用模型改写用户输入**，
// 风险不在"改得不够好"，而在"改出了用户没说的东西"或者"改写失败反而
// 让消息发不出去"。所以真正要钉住的是**拒绝条件**：
//  · 模型答非所问（输出一段解释而不是改写结果）→ 必须拒绝；
//  · 模型加了一堆用户没提的要求（长度暴涨）→ 必须拒绝；
//  · 模型原样抄回 → 没必要占字段，也拒绝。
//
// 这些条件一旦放宽，坏掉的不是"改写质量"，而是**用户的原意**。
import 'package:dsh_agent/ai/prompt_improver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractImproved：从返回体里取改写结果', () {
    String body(String content) =>
        '{"choices":[{"message":{"role":"assistant","content":'
        '${_json(content)}}}]}';

    test('正常返回能取到', () {
      expect(
        PromptImprover.extractImproved(
          body('请读取 /sdcard/a.txt 的内容并总结要点'),
          '帮我看看那个文件',
        ),
        '请读取 /sdcard/a.txt 的内容并总结要点',
      );
    });

    test('去掉代码围栏', () {
      // 用 `~` 占位再替换成反引号：直接在字符串里写三反引号要塞一堆
      // 转义，读起来完全看不出是什么。
      const String fence = '~~~';
      final String content = '$fence\n改进后的句子\n$fence'.replaceAll('~', '`');
      final String b =
          '{"choices":[{"message":{"content":'
          '${_json(content)}}}]}';
      expect(PromptImprover.extractImproved(b, '原来那句话'), '改进后的句子');
    });

    test('去掉整段外面的引号', () {
      expect(
        PromptImprover.extractImproved(body('“请把标题改成蓝色”'), '标题改一下'),
        '请把标题改成蓝色',
      );
      expect(
        PromptImprover.extractImproved(body('「查看电池电量」'), '看看电量'),
        '查看电池电量',
      );
    });

    test('去掉"改写后："这类前缀', () {
      expect(
        PromptImprover.extractImproved(body('改写后：查看当前电量并汇报'), '看看电量'),
        '查看当前电量并汇报',
      );
    });

    test('结构不对时返回 null，不抛异常', () {
      expect(PromptImprover.extractImproved('not json', 'x'), isNull);
      expect(PromptImprover.extractImproved('{}', 'x'), isNull);
      expect(PromptImprover.extractImproved('{"choices":[]}', 'x'), isNull);
      expect(
        PromptImprover.extractImproved('{"choices":[{"message":{}}]}', 'x'),
        isNull,
      );
    });
  });

  group('isSane：拒绝不该发出去的改写', () {
    test('正常改写放行', () {
      expect(
        PromptImprover.isSane('读取 /sdcard/a.txt 并总结要点', '帮我看看那个文件'),
        isTrue,
      );
    });

    test('空结果拒绝', () {
      expect(PromptImprover.isSane('', '原话'), isFalse);
      expect(PromptImprover.isSane('   ', '原话'), isFalse);
    });

    test('**开始解释"不需要改写"时拒绝**', () {
      // 这是最常见的失败模式：模型不听指令，回一段评论。
      // 直接发出去的话，主模型会把这段评论当成任务的一部分。
      for (final String t in <String>[
        '这句话已经很明确了，不需要改写。',
        '无需改写，原话就很好。',
        '作为改写助手，我需要更多信息。',
        '抱歉，我无法完成这个请求。',
      ]) {
        expect(
          PromptImprover.isSane(t, '帮我看看那个文件'),
          isFalse,
          reason: '应该拒绝：$t',
        );
      }
    });

    test('**长度暴涨时拒绝**（模型开始写小作文 / 加需求）', () {
      final String original = '看看电量';
      final String bloated = '请执行以下步骤：' * 20;
      expect(PromptImprover.isSane(bloated, original), isFalse);
    });

    test('合理范围内的加长放行', () {
      // "帮我看看那个文件" → 补全指代之后长一些是**正常且有价值**的
      expect(
        PromptImprover.isSane('请查看工作目录下最新的那个日志文件，把报错行找出来', '帮我看看那个文件'),
        isTrue,
      );
    });

    test('原样抄回时拒绝（等于没改进）', () {
      expect(PromptImprover.isSane('看看电量', '看看电量'), isFalse);
      // 只差空白也算抄回
      expect(PromptImprover.isSane('看 看 电 量', '看看电量'), isFalse);
    });
  });

  group('系统提示词', () {
    test('明确禁止新增需求、禁止执行', () {
      // 这两条一旦从提示词里掉了，这个功能就会开始"自作主张"。
      // 用测试钉住它们，防止以后改文案时被顺手删掉。
      expect(PromptImprover.systemPrompt, contains('不要新增'));
      expect(PromptImprover.systemPrompt, contains('不要执行'));
      expect(PromptImprover.systemPrompt, contains('原样返回'));
    });
  });

  group('promptFor：档位与自定义要求', () {
    test('三个档位写法不同，但底线规则一个都不能丢', () {
      final String low = PromptImprover.promptFor('low', '');
      final String mid = PromptImprover.promptFor('medium', '');
      final String high = PromptImprover.promptFor('high', '');

      for (final String p in <String>[low, mid, high]) {
        // 换档位只该改"能改多少"，不该把安全底线一起换掉 ——
        // "不要新增用户没提的需求"是最容易被违背、也最伤信任的一条。
        expect(p, contains('不要新增'), reason: '底线规则必须一直在');
        expect(p, contains('只输出改写后的那一句话'));
      }

      expect(low, contains('最小改动'));
      expect(mid, contains('中等'));
      expect(high, contains('完整任务描述'));
      expect(low == high, isFalse, reason: '两档的提示词必须真的不一样');
    });

    test('默认（不认识的档位值）走中等：宁可保守，不要放开手脚', () {
      // 存档里出现空串/旧值时不能落到"高"档 —— 那会突然开始替用户加内容。
      expect(PromptImprover.promptFor('', ''), contains('中等'));
      expect(PromptImprover.promptFor('whatever', ''), contains('中等'));
    });

    test('自定义要求追加在最后，而且标明优先级最高', () {
      final String p = PromptImprover.promptFor('medium', '把所有代词换成具体的名字');
      expect(p, contains('把所有代词换成具体的名字'));
      expect(p, contains('优先级最高'));
      // 越靠后的指令对模型影响越大 —— 用户自己的要求必须压在内置规则之后。
      expect(p.indexOf('把所有代词换成具体的名字'), greaterThan(p.indexOf('改写力度')));
    });

    test('自定义要求是空白时不留一个空的"用户要求"段', () {
      expect(
        PromptImprover.promptFor('medium', '   '),
        isNot(contains('用户本人')),
      );
      expect(
        PromptImprover.promptFor('high', '\n\t '),
        isNot(contains('用户本人')),
      );
    });
  });

  group('长度上限的档位余量', () {
    test('高档位放宽上限（结构化改写本来就比原话长得多）', () {
      final String original = '把那个文件改一下';
      // 一段"高档次下很正常"的改写：比原话长得多（原话只有 8 个字）。
      const String block =
          '目标：修改那个文件的配置项。\n'
          '约束：不动其它字段和缩进风格。\n'
          '产出：一份改好的文件，以及改了哪几行的说明。\n'
          '待确认：具体是哪个文件、要改成什么值。';
      final String rewritten = '$block\n$block\n$block';

      // 默认余量按中等档位定的：这段话超过原话 4 倍，会被当成"它在解释"。
      expect(PromptImprover.isSane(rewritten, original), isFalse);
      // 高档次给了额外余量，同一段话就应当被接受。
      expect(PromptImprover.isSane(rewritten, original, slack: 800), isTrue);
    });
  });
}

/// 极简 JSON 字符串转义（测试里手拼 JSON 用）。
String _json(String s) {
  final StringBuffer b = StringBuffer('"');
  for (final int c in s.runes) {
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x60:
        b.write(r'\u0060');
      default:
        b.writeCharCode(c);
    }
  }
  return '$b"';
}
