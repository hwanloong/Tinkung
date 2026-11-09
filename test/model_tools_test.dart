// 「工具能力挂在模型档案上」的测试。
//
// 为什么值得测：这块有两个容易搞错的地方 ——
//  1. `tools` 为 **null** 和为空 **列表** 语义不同（"没配过" vs "全关了"），
//     写错会导致"用户关掉生图后重启又自己开了"；
//  2. 老存档里有个更旧的 `image: true` 字段，必须迁成 `generate_image`，
//     否则**本来能画图的模型升级上来突然画不了** —— 这种回归很难被发现。
import 'dart:convert';

import 'package:dsh_agent/core/model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tools：null 和空列表不是一回事', () {
    test('没配过（null）跟随默认', () {
      final ModelProfile p = ModelProfile(id: '1', name: '', model: 'x');
      expect(p.tools, isNull);
      expect(p.enabledTools, ModelProfile.defaultTools);
      expect(p.hasTool(kImageGenTool), isTrue);
    });

    test('空列表 = 用户明确全关了 —— 不能回退到默认', () {
      final ModelProfile p = ModelProfile(
        id: '1',
        name: '',
        model: 'x',
        tools: <String>[],
      );
      expect(p.enabledTools, isEmpty);
      expect(p.hasTool(kImageGenTool), isFalse);
    });

    test('setTool 关掉之后不再是 null，而且真的关了', () {
      final ModelProfile p = ModelProfile(id: '1', name: '', model: 'x');
      p.setTool(kImageGenTool, false);
      expect(p.tools, isNotNull, reason: '关掉要记成"用户的选择"，不是"没配过"');
      expect(
        p.hasTool(kImageGenTool),
        isFalse,
        reason:
            '关掉生图之后 hasTool 必须为 false —— '
            '这是"用户关了它"和"没配过"唯一能观察到的区别',
      );
    });

    test('生图工具默认开启', () {
      final ModelProfile p = ModelProfile(id: '1', name: '', model: 'x');
      expect(p.hasTool(kImageGenTool), isTrue);
    });

    test('setTool 重复开启不会重复添加', () {
      final ModelProfile p = ModelProfile(
        id: '1',
        name: '',
        model: 'x',
        tools: <String>[],
      );
      p.setTool(kImageGenTool, true);
      p.setTool(kImageGenTool, true);
      expect(p.enabledTools, <String>[kImageGenTool]);
    });
  });

  group('存档往返', () {
    test('tools: null 和 [] 存下来要能区分', () {
      final String raw = ModelProfile.encodeList(<ModelProfile>[
        ModelProfile(id: 'a', name: '', model: 'x'),
        ModelProfile(id: 'b', name: '', model: 'y', tools: <String>[]),
      ]);
      final List<ModelProfile> back = ModelProfile.decodeList(raw);
      expect(back[0].tools, isNull);
      expect(back[0].hasTool(kImageGenTool), isTrue);
      expect(back[1].tools, isEmpty);
      expect(back[1].hasTool(kImageGenTool), isFalse);
    });
  });

  group('老存档迁移', () {
    ModelProfile fromLegacy(String json) =>
        ModelProfile.fromJson(jsonDecode(json) as Map<String, dynamic>);

    test('老的 image: true → 开启 generate_image', () {
      // 这是**升级路径上最容易悄悄坏掉的一环**：不迁的话，
      // 本来能画图的模型升级之后突然画不了了。
      final ModelProfile p = fromLegacy(
        '{"id":"a","model":"dall-e-3","image":true}',
      );
      expect(p.hasTool(kImageGenTool), isTrue);
    });

    test('老的 image: false → 保留成"用户关了"，不回退到默认', () {
      final ModelProfile p = fromLegacy(
        '{"id":"a","model":"deepseek-flash","image":false}',
      );
      expect(p.tools, <String>[]);
      expect(p.hasTool(kImageGenTool), isFalse);
    });

    test('两者都没有 → null（跟随默认）', () {
      final ModelProfile p = fromLegacy('{"id":"a","model":"x"}');
      expect(p.tools, isNull);
    });

    test('已经有 tools 时以它为准，忽略残留的 image 字段', () {
      final ModelProfile p = fromLegacy(
        '{"id":"a","model":"x","tools":[],"image":true}',
      );
      expect(p.tools, isEmpty, reason: '新字段优先，别被老字段盖回去');
      expect(p.hasTool(kImageGenTool), isFalse);
    });
  });

  group('copyWith', () {
    test('不传 tools 时保留原值', () {
      final ModelProfile p = ModelProfile(
        id: 'a',
        name: '',
        model: 'x',
        tools: <String>[kImageGenTool],
      );
      expect(p.copyWith(model: 'y').tools, <String>[kImageGenTool]);
    });

    test('可以改成空列表', () {
      final ModelProfile p = ModelProfile(id: 'a', name: '', model: 'x');
      expect(p.copyWith(tools: <String>[]).tools, isEmpty);
    });
  });
}
