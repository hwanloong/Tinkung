// 工具调用的**严格校验**：
//
//  1. 合法 JSON ≠ 合法调用。缺必填 / 类型不对 / 枚举越界必须在弹确认框
//     **之前**判失败 —— 让用户确认一个注定失败的调用是白打扰。
//  2. 「同一条调用」的判定必须按**语义**（排序后的参数），不能按原始 JSON
//     原文，否则模型换个 key 顺序就能绕过去重和失败熔断。
import 'package:dsh_agent/tools/validate_args.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validateToolArgs：缺必填', () {
    const Map<String, dynamic> schema = <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'code': <String, dynamic>{'type': 'string'},
        'reset': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['code'],
    };

    test('缺必填 → 失败，并点名是哪个字段', () {
      final ToolArgsCheck c = validateToolArgs('python', schema, <String, dynamic>{});
      expect(c.ok, isFalse);
      expect(c.message, contains('code'));
      expect(c.message, contains('必填'));
      // 错误是给模型看的：要告诉它下一步怎么做，否则只会原样重发
      expect(c.message, contains('重新发起调用'));
    });

    test('给了必填就通过', () {
      final ToolArgsCheck c = validateToolArgs('python', schema, <String, dynamic>{
        'code': 'print(1)',
      });
      expect(c.ok, isTrue);
    });

    test('显式 null 按"没给"处理（模型常见输出）', () {
      final ToolArgsCheck c = validateToolArgs('python', schema, <String, dynamic>{
        'code': null,
      });
      expect(c.ok, isFalse);
      expect(c.message, contains('code'));
    });
  });

  group('validateToolArgs：类型与枚举', () {
    const Map<String, dynamic> schema = <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'action': <String, dynamic>{
          'type': 'string',
          'enum': <String>['list', 'read', 'write'],
        },
        'limit': <String, dynamic>{'type': 'integer'},
        'ratio': <String, dynamic>{'type': 'number'},
        'tags': <String, dynamic>{'type': 'array'},
        'options': <String, dynamic>{'type': 'object'},
        'dry': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['action'],
    };

    test('枚举越界 → 失败，且列出允许值', () {
      final ToolArgsCheck c = validateToolArgs('tool', schema, <String, dynamic>{
        'action': 'delete',
      });
      expect(c.ok, isFalse);
      expect(c.message, contains('action'));
      expect(c.message, contains('list'));
      expect(c.message, contains('delete'), reason: '要告诉模型它实际给了什么');
    });

    test('类型不对 → 失败，并说明期望类型', () {
      final ToolArgsCheck c = validateToolArgs('tool', schema, <String, dynamic>{
        'action': 'list',
        'limit': 'ten',
      });
      expect(c.ok, isFalse);
      expect(c.message, contains('limit'));
      expect(c.message, contains('integer'));
    });

    test('整数也接受 number，整数形式的 double 也接受 integer', () {
      expect(
        validateToolArgs('tool', schema, <String, dynamic>{
          'action': 'list',
          'ratio': 3,
        }).ok,
        isTrue,
      );
      expect(
        validateToolArgs('tool', schema, <String, dynamic>{
          'action': 'list',
          'limit': 5.0,
        }).ok,
        isTrue,
      );
    });

    test('数组 / 对象 / 布尔按声明校验', () {
      expect(
        validateToolArgs('tool', schema, <String, dynamic>{
          'action': 'list',
          'tags': 'a,b',
        }).ok,
        isFalse,
        reason: '字符串不能当数组 —— 工具里的 listVal 兜底不该靠类型校验来放过',
      );
      expect(
        validateToolArgs('tool', schema, <String, dynamic>{
          'action': 'list',
          'options': <String, dynamic>{'a': 1},
          'dry': true,
          'tags': <String>['a'],
        }).ok,
        isTrue,
      );
    });

    test('未知字段不拒绝：模型多带一个 purpose 不该让调用失败', () {
      expect(
        validateToolArgs('tool', schema, <String, dynamic>{
          'action': 'list',
          'purpose': '看看有什么',
        }).ok,
        isTrue,
      );
    });

    test('schema 没写 required / type 时一律放行（宁可漏检）', () {
      const Map<String, dynamic> loose = <String, dynamic>{'type': 'object'};
      expect(validateToolArgs('x', loose, <String, dynamic>{'anything': 1}).ok, isTrue);
    });
  });

  group('canonicalToolKey：同一条调用只有一个键', () {
    test('key 顺序不同仍是同一个键', () {
      final String a = canonicalToolKey('reader', <String, dynamic>{
        'path': '/a.txt',
        'mode': 'raw',
      });
      final String b = canonicalToolKey('reader', <String, dynamic>{
        'mode': 'raw',
        'path': '/a.txt',
      });
      expect(a, b);
    });

    test('参数值不同则是不同的键', () {
      expect(
        canonicalToolKey('reader', <String, dynamic>{'path': '/a.txt'}),
        isNot(canonicalToolKey('reader', <String, dynamic>{'path': '/b.txt'})),
      );
    });

    test('工具名不同则是不同的键', () {
      expect(
        canonicalToolKey('web', <String, dynamic>{'q': 'x'}),
        isNot(canonicalToolKey('reader', <String, dynamic>{'q': 'x'})),
      );
    });

    test('解析失败时退回原文，但把空白差异抹平', () {
      final String a = canonicalToolKey(
        'writer',
        <String, dynamic>{},
        raw: '{bad',
      );
      final String b = canonicalToolKey(
        'writer',
        <String, dynamic>{},
        raw: '  {bad  ',
      );
      expect(a, b, reason: '一模一样的坏 JSON 必须能被熔断认出来');
      expect(a, contains('{bad'));
    });

    test('空参数稳定成 {}', () {
      expect(
        canonicalToolKey('x', <String, dynamic>{}),
        canonicalToolKey('x', <String, dynamic>{}, raw: '{}'),
      );
    });
  });
}
