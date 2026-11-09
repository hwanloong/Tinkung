import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_agent/core/varbank.dart';

/// 变量库的纯逻辑测试。
///
/// 不碰磁盘（`VarBankStore.instance` 在没配置时就是纯内存的），
/// 所以这些用例又快又不会互相污染。
void main() {
  setUp(VarBankStore.resetForTest);

  group('名字校验', () {
    test('接受字母、数字、下划线、汉字', () {
      expect(VarBankStore.isValidName('plan'), isTrue);
      expect(VarBankStore.isValidName('方案'), isTrue);
      expect(VarBankStore.isValidName('a_1'), isTrue);
      expect(VarBankStore.isValidName('需求v2'), isTrue);
    });

    test('拒绝空、数字开头、带空格和标点', () {
      expect(VarBankStore.isValidName(''), isFalse);
      expect(VarBankStore.isValidName('1abc'), isFalse);
      expect(VarBankStore.isValidName('a b'), isFalse);
      expect(VarBankStore.isValidName('a-b'), isFalse);
      expect(VarBankStore.isValidName('a.b'), isFalse);
    });
  });

  group('存取', () {
    test('存进去能按名字取回', () {
      final VarBankStore s = VarBankStore.instance;
      expect(s.set('方案', '第一行\n第二行'), isNull);
      expect(s.get('方案')?.text, '第一行\n第二行');
      expect(s.get('方案')?.lines, 2);
    });

    test('同名默认不覆盖，显式 overwrite 才覆盖', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('x', 'old');
      expect(s.set('x', 'new'), isNotNull);
      expect(s.get('x')?.text, 'old');
      expect(s.set('x', 'new', overwrite: true), isNull);
      expect(s.get('x')?.text, 'new');
    });

    test('超过单条上限会被拒绝', () {
      final VarBankStore s = VarBankStore.instance;
      final String huge = 'a' * (VarBankStore.maxVarChars + 1);
      expect(s.set('big', huge), isNotNull);
    });
  });

  group('展开', () {
    test('裸引用展开成全文', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('方案', 'A\nB\nC');
      expect(s.expand('看这个：{{方案}}'), '看这个：A\nB\nC');
    });

    test('按行取范围', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('v', 'l1\nl2\nl3\nl4');
      expect(s.expand('{{v:2-3}}').trim(), 'l2\nl3');
    });

    test('按字符取范围（c 后缀）', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('v', 'abcdefghij');
      expect(s.expand('{{v:0-5c}}'), 'abcde');
    });

    test('认不出的引用原样保留', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('方案', 'X');
      // 变量不存在 → 不动；普通花括号 → 不动
      expect(s.expand('{{不存在}}'), '{{不存在}}');
      expect(s.expand('代码 {{a: b}} 结束'), '代码 {{a: b}} 结束');
    });

    test('展开不递归', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('a', '{{b}}');
      s.set('b', 'B');
      // a 的内容里写着 {{b}}，展开 a 之后**不再**继续展开 b
      expect(s.expand('{{a}}'), '{{b}}');
    });

    test('范围越界不抛异常', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('v', 'only one line');
      expect(s.expand('{{v:100-200}}'), '');
    });
  });

  group('删除与搜索', () {
    test('drop 之后取不到', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('temp', 'x');
      expect(s.drop('temp'), isTrue);
      expect(s.get('temp'), isNull);
    });

    test('search 同时匹配名字和正文', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('alpha', '苹果');
      s.set('beta', '香蕉');
      expect(s.search('alpha').length, 1);
      expect(s.search('香蕉').length, 1);
    });
  });

  group('提示词', () {
    test('空库不产生段落', () {
      expect(VarBankStore.instance.toPromptSection(), '');
    });

    test('有变量时只列名字不注入正文', () {
      final VarBankStore s = VarBankStore.instance;
      s.set('方案', 'SECRET_BODY_CONTENT');
      final String section = s.toPromptSection();
      expect(section, contains('{{方案}}'));
      // 正文不该出现在提示词里 —— 那是每轮都要付的成本
      expect(section, isNot(contains('SECRET_BODY_CONTENT')));
    });
  });
}
