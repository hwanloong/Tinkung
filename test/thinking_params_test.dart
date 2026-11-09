// 「思考参数」形状的测试。
//
// 为什么必须逐字测：`thinking` **不在 OpenAI 规范里**，是各家自己加的，
// 而服务端大多**严格校验** `type` —— 传错是直接 400 而不是忽略，
// 报错还只说"参数不合法"。
//
// 最典型的两个不兼容：
//   · DeepSeek  → {"type":"enabled"|"disabled"}
//   · Anthropic → **只认** {"type":"adaptive"}
//
// 所以这里把每种形状的**准确字段**断言出来，改动时如果手滑改了键名或取值，
// 测试会立刻红。
import 'package:dsh_agent/ai/deepseek.dart';
import 'package:dsh_agent/core/model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> build({
    required ThinkingStyle style,
    bool enabled = true,
    String effort = 'high',
    double temperature = 0.7,
  }) => DeepSeekClient.buildThinkingParams(
    style: style,
    enabled: enabled,
    effort: effort,
    temperature: temperature,
  );

  group('Anthropic：只认 adaptive', () {
    test('开启时只发 {"type":"adaptive"}', () {
      final Map<String, dynamic> p = build(style: ThinkingStyle.anthropic);
      expect(p['thinking'], <String, dynamic>{'type': 'adaptive'});
      // 绝不能混进 enabled —— 那正是被拒绝的那个值
      expect(p.toString(), isNot(contains('enabled')));
    });

    test('不发 reasoning_effort（Anthropic 用 budget_tokens，形状不同）', () {
      final Map<String, dynamic> p = build(
        style: ThinkingStyle.anthropic,
        effort: 'max',
      );
      expect(p.containsKey('reasoning_effort'), isFalse);
    });

    test('关闭思考时整个字段都不发（它没有 disabled 这个取值）', () {
      final Map<String, dynamic> p = build(
        style: ThinkingStyle.anthropic,
        enabled: false,
      );
      expect(p.containsKey('thinking'), isFalse);
      // 关掉之后温度就该生效
      expect(p['temperature'], 0.7);
    });
  });

  group('DeepSeek：enabled / disabled', () {
    test('开启时发 enabled + reasoning_effort，且不发温度', () {
      final Map<String, dynamic> p = build(
        style: ThinkingStyle.deepseek,
        effort: 'high',
      );
      expect(p['thinking'], <String, dynamic>{'type': 'enabled'});
      expect(p['reasoning_effort'], 'high');
      // 官方说明思考模式下 temperature「设置不报错但也不生效」，
      // 所以不发，免得造成"我调了温度"的误导
      expect(p.containsKey('temperature'), isFalse);
    });

    test('关闭时发 disabled + 温度', () {
      final Map<String, dynamic> p = build(
        style: ThinkingStyle.deepseek,
        enabled: false,
      );
      expect(p['thinking'], <String, dynamic>{'type': 'disabled'});
      expect(p['temperature'], 0.7);
      expect(p.containsKey('reasoning_effort'), isFalse);
    });

    test('强度为空时不发 reasoning_effort（避免服务端拒绝空串）', () {
      final Map<String, dynamic> p = build(
        style: ThinkingStyle.deepseek,
        effort: '  ',
      );
      expect(p.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('openAiLike：形状同 DeepSeek', () {
    test('开启发 enabled', () {
      expect(
        build(style: ThinkingStyle.openAiLike)['thinking'],
        <String, dynamic>{'type': 'enabled'},
      );
    });
  });

  group('effortOnly：免费网关用', () {
    test('只发 reasoning_effort，不发 thinking', () {
      final Map<String, dynamic> p = build(
        style: ThinkingStyle.effortOnly,
        effort: 'max',
      );
      expect(p.containsKey('thinking'), isFalse);
      expect(p['reasoning_effort'], 'max');
      expect(p['temperature'], 0.7);
    });

    test('关闭或强度为空时不下发空串', () {
      final Map<String, dynamic> off = build(
        style: ThinkingStyle.effortOnly,
        enabled: false,
      );
      expect(off.containsKey('reasoning_effort'), isFalse);
      final Map<String, dynamic> blank = build(
        style: ThinkingStyle.effortOnly,
        effort: '  ',
      );
      expect(blank.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('none：完全不发 thinking', () {
    test('任何情况下都没有 thinking 字段', () {
      for (final bool on in <bool>[true, false]) {
        final Map<String, dynamic> p = build(
          style: ThinkingStyle.none,
          enabled: on,
        );
        expect(
          p.containsKey('thinking'),
          isFalse,
          reason: 'enabled=$on 时也不该发 thinking',
        );
      }
    });

    test('温度照发 —— 对不认识这个字段的服务它就是普通采样温度', () {
      expect(build(style: ThinkingStyle.none)['temperature'], 0.7);
    });
  });

  group('存档兼容', () {
    test('id ↔ enum 往返一致', () {
      for (final ThinkingStyle s in ThinkingStyle.values) {
        expect(ThinkingStyleX.fromId(s.id), s);
      }
    });

    test('老数据没有这个字段时默认 DeepSeek', () {
      // 升级上来的档案基本都是 DeepSeek 后端
      expect(ThinkingStyleX.fromId(null), ThinkingStyle.deepseek);
      expect(ThinkingStyleX.fromId('没见过的值'), ThinkingStyle.deepseek);
    });

    test('uuid 之类的字符串不会把 id 和 index 搞混', () {
      // 用稳定字符串而不是 index 的原因：以后往中间插一项，
      // 老数据不会被指到错误的枚举上
      expect(ThinkingStyle.anthropic.id, 'anthropic');
      expect(ThinkingStyle.none.id, 'none');
    });
  });
}
