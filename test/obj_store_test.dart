// 对象池 + 引用解析。
//
// 这一组的核心断言都是**上下文成本**：句柄化之后，模型看到的东西
// 必须从"整份内容"缩成"摘要 + 句柄"。所以每个用例都在检查
// "返回了多少字符"、"有没有真的把全文漏出来"。
//
// 另一半是**不破坏既有行为**：认不出的引用要原样留着（正文里提到
// `@某人` 不能被当成对象）、展开只做一层（防递归炸弹）、
// 超限要降级成摘要而不是截半截。
import 'dart:io';

import 'package:dsh_agent/core/obj_store.dart';
import 'package:dsh_agent/core/resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dsh_obj');
    await ObjStore.configure(Directory('${tmp.path}/spill'));
  });

  tearDown(() async {
    ObjStore.instance.clear();
    ObjStore.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> write(String name, String content) async {
    final File f = File('${tmp.path}/$name');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f.path;
  }

  group('短文本走内存、长文本落盘', () {
    test('64KB 以内留在内存，超过就落盘', () async {
      final Obj small = await ObjStore.instance.putText('短内容');
      expect(small.inline, isNotNull, reason: '短文本没必要碰磁盘');
      expect(small.source, isNull);

      final String big = 'x' * (ObjStore.inlineLimit + 10);
      final Obj large = await ObjStore.instance.putText(big);
      expect(large.source, isNotNull, reason: '大文本必须落盘，否则一次引用就多一份常驻内存');
      expect(large.inline, isNull);
      expect(await File(large.source!).length(), greaterThan(0));
    });

    test('落盘的对象照样能按行读回来', () async {
      final String content = List<String>.generate(500, (int i) => '行 $i').join('\n');
      final Obj o = await ObjStore.instance.putText(content);
      final String seg = await ObjStore.instance.readRange(o, start: 101, end: 103);
      expect(seg, '行 100\n行 101\n行 102');
    });
  });

  group('摘要不泄漏正文', () {
    test('大文件的摘要远小于原文，且带行数和句柄', () async {
      final String content = List<String>.generate(
        8000,
        (int i) => '第 $i 行：一些很长的正文内容，用来把文件撑大 ${'填充' * 10}',
      ).join('\n');
      final String path = await write('big.txt', content);
      final Obj o = await ObjStore.instance.putFile(path);

      final String s = await ObjStore.instance.summary(o);

      expect(s.length, lessThan(4000), reason: '摘要必须足够小，否则等于又搬了一遍全文');
      expect(s, contains('8000 行'), reason: '行数是模型决定 range 的唯一依据');
      expect(s, contains(o.uri));
      expect(s, contains('第 0 行'), reason: '开头几行要给,否则模型不知道这是什么文件');
      expect(
        s.contains('第 4000 行'),
        isFalse,
        reason: '正文中段绝不该出现在摘要里',
      );
    });

    test('行数把末行没有换行的文件也算对', () async {
      final String path = await write('no-newline.txt', 'a\nb\nc');
      final Obj o = await ObjStore.instance.putFile(path);
      expect(await ObjStore.instance.lineCount(o), 3);
    });
  });

  group('按范围读只读那一段', () {
    test('取中间 3 行不影响其余内容', () async {
      final String content = List<String>.generate(10000, (int i) => 'L$i').join('\n');
      final String path = await write('mid.txt', content);
      final Obj o = await ObjStore.instance.putFile(path);

      final String seg = await ObjStore.instance.readRange(o, start: 5000, end: 5002);
      expect(seg, 'L4999\nL5000\nL5001');
    });

    test('超出末尾时返回空串而不是异常', () async {
      final String path = await write('short.txt', 'one\ntwo');
      final Obj o = await ObjStore.instance.putFile(path);
      expect(await ObjStore.instance.readRange(o, start: 900, end: 901), '');
    });
  });

  group('grep', () {
    test('命中行带行号和上下文', () async {
      final String path = await write(
        'log.txt',
        'a\nb\nERROR: bad thing\nd\ne',
      );
      final Obj o = await ObjStore.instance.putFile(path);
      final List<GrepHit> hits = await ObjStore.instance.grep(
        o,
        'ERROR',
        context: 1,
      );

      expect(hits, hasLength(1));
      expect(hits.first.line, 3);
      expect(hits.first.text, contains('ERROR'));
      expect(hits.first.before, <String>['b']);
    });

    test('相邻命中并成一条，输出不会变成原文', () async {
      final String path = await write(
        'dense.txt',
        'x\nerr1\nerr2\nerr3\nerr4\ny',
      );
      final Obj o = await ObjStore.instance.putFile(path);
      final List<GrepHit> hits = await ObjStore.instance.grep(
        o,
        'err',
        context: 1,
      );

      expect(hits.length, lessThan(4), reason: '连着的命中要合并，否则和读全文没区别');
      expect(
        hits.map((GrepHit h) => h.text).join(),
        contains('err4'),
        reason: '合并之后后面那几行仍然要能看到',
      );
    });

    test('正则写错时按纯文本处理，不抛异常', () async {
      final String path = await write('weird.txt', 'a[b\nc');
      final Obj o = await ObjStore.instance.putFile(path);
      final List<GrepHit> hits = await ObjStore.instance.grep(o, 'a[b');
      expect(hits, hasLength(1));
    });
  });

  group('引用解析', () {
    test('小对象展开成全文', () async {
      final Obj o = await ObjStore.instance.putText('完整内容');
      final Resolved r = await Resolver.resolve(
        '前缀 {{${o.uri}}} 后缀',
        mode: ResolveMode.render,
      );
      expect(r.text, '前缀 完整内容 后缀');
      expect(r.truncated, isFalse);
    });

    test('大对象不带范围时降级成摘要，并说明原因', () async {
      final String path = await write('huge.txt', 'X' * 200000);
      final Obj o = await ObjStore.instance.putFile(path);

      final Resolved r = await Resolver.resolve(
        '{{${o.uri}}}',
        mode: ResolveMode.render,
      );

      expect(r.truncated, isTrue);
      expect(r.text.length, lessThan(6000), reason: '降级之后必须真的小');
      expect(r.warnings.join(), contains('摘要'), reason: '必须告诉模型它拿到的是摘要不是正文');
    });

    test('带行范围时只展开那几行', () async {
      final String path = await write('ranged.txt', List<String>.generate(300, (int i) => 'v$i').join('\n'));
      final Obj o = await ObjStore.instance.putFile(path);

      final Resolved r = await Resolver.resolve(
        '{{${o.uri}:10-12}}',
        mode: ResolveMode.render,
      );
      expect(r.text, 'v9\nv10\nv11');
    });

    test('path:// 解析成真实路径，不展开内容', () async {
      final String path = await write('p.txt', '内容不该出现在这里');
      final Obj o = await ObjStore.instance.putFile(path);

      final Resolved r = await Resolver.resolveOne(
        'path://${o.uri}',
        mode: ResolveMode.path,
      );
      expect(r.text, path);
      expect(r.text.contains('内容不该'), isFalse);
    });

    test('认不出的 @ 原样留着（正文里的 @某人 不能被吃掉）', () async {
      final Resolved r = await Resolver.resolve(
        '我跟 @zhangsan 说了',
        mode: ResolveMode.render,
      );
      expect(r.text, '我跟 @zhangsan 说了');
    });

    test('展开只做一层，文件里的占位符不会被二次展开', () async {
      final Obj inner = await ObjStore.instance.putText('内部机密');
      final Obj outer = await ObjStore.instance.putText(
        '文件里写着 {{${inner.uri}}} 这几个字',
      );

      final Resolved r = await Resolver.resolve(
        '{{${outer.uri}}}',
        mode: ResolveMode.render,
      );
      expect(r.text, contains(inner.uri), reason: '第二层必须留着原样，否则就是递归炸弹');
      expect(r.text.contains('内部机密'), isFalse);
    });

    test('引用不存在的对象时给出可读的说明', () async {
      final Resolved r = await Resolver.resolve(
        '{{obj://nope}}',
        mode: ResolveMode.render,
      );
      expect(r.text, '');
      expect(r.warnings.join(), contains('找不到'));
    });
  });

  group('输出超限转句柄', () {
    test('小于阈值原样返回', () async {
      final Resolved r = await packOutput('短输出');
      expect(r.text, '短输出');
      expect(r.truncated, isFalse);
    });

    test('超过阈值只给开头 + 句柄，并说明总数', () async {
      final String big = 'A' * 20000;
      final Resolved r = await packOutput(big);

      expect(r.truncated, isTrue);
      expect(r.text.length, lessThan(big.length));
      expect(r.text, contains('20000'), reason: '要写清原文多长，模型才知道值不值得回取');
      expect(r.text, contains('obj://'));
    });
  });

  group('生命周期', () {
    test('drop 之后查不到', () async {
      final Obj o = await ObjStore.instance.putText('临时');
      ObjStore.instance.drop(o.id);
      expect(ObjStore.instance.lookup(o.uri), isNull);
    });

    test('pin 住的对象不被 LRU 挤掉', () async {
      final Obj pinned = await ObjStore.instance.putText('要留着的', id: 'keep', pinned: true);
      for (int i = 0; i < ObjStore.maxObjects + 5; i++) {
        await ObjStore.instance.putText('临时 $i');
      }
      expect(ObjStore.instance.lookup(pinned.uri), isNotNull, reason: 'pin 就是"别动它"的意思');
    });

    test('查找时接受 obj:// / out:// / @ / 裸名 四种写法', () async {
      final Obj o = await ObjStore.instance.putText('x', id: 'zz');
      for (final String ref in <String>['zz', '@zz', 'obj://zz', 'out://zz']) {
        expect(ObjStore.instance.lookup(ref)?.id, o.id, reason: '写法不该成为失败原因');
      }
    });
  });
}
