// 四个系统层工具的实际行为。
//
// 这些用例刻意**不 mock 文件系统**：对象池的价值全在"真的按范围读、
// 真的只回摘要"上，用 mock 验证等于验证自己写的假设。
// 唯一被绕开的是 `sheller` 的命令执行（要平台通道），
// 那一部分只验"参数怎么拼"和"风险怎么判"。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/obj_store.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/resolver.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/plugins/plugin.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/obj_tools.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个够用的 ToolContext：这几个工具只用得到 `workDir`。
ToolContext _ctx(Settings settings, String workDir) => ToolContext(
  settings: settings,
  shizuku: ShizukuService(),
  conversation: Conversation(id: 'c', title: 't'),
  workDir: workDir,
  searchApiKey: '',
  visionBaseUrl: '',
  visionApiKey: '',
  visionModel: '',
  mainApiKey: '',
  mainBaseUrl: '',
  mainModel: '',
  modelSeesImages: false,
  modelGeneratesImages: false,
  imageGen: null,
  searchEngine: 'bing',
  webSearchMode: 'auto',
  selfHostedSearchUrl: '',
  notes: NoteStore(File('unused-notes.json')),
  tasks: TaskStore(File('unused-tasks.json')),
  plugins: PluginStore(File('unused-plugins.json')),
);

void main() {
  late Directory tmp;
  late Settings settings;
  late ToolContext ctx;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dsh_objtools');
    await ObjStore.configure(Directory('${tmp.path}/spill'));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = await Settings.load();
    ctx = _ctx(settings, tmp.path);
  });

  tearDown(() async {
    ObjStore.instance.clear();
    ObjStore.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> writeFile(String name, String content) async {
    final File f = File('${tmp.path}/$name');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  group('filesearch', () {
    test('按通配找文件，结果里带大小和下一页游标', () async {
      for (int i = 0; i < 5; i++) {
        await writeFile('logs/app$i.log', 'line' * 100);
      }
      await writeFile('logs/other.txt', 'x');

      final String out = await const FileSearchTool().run(
        ctx,
        <String, dynamic>{'root': tmp.path, 'pattern': '*.log'},
      );

      expect(out, contains('app0.log'));
      expect(out, isNot(contains('other.txt')), reason: '模式就是要筛掉不匹配的');
      expect(out, contains('找到 5 项'));
    });

    test('超过一页时给游标，按游标能翻到下一页', () async {
      for (int i = 0; i < 12; i++) {
        await writeFile('many/f$i.txt', 'x');
      }

      final String page1 = await const FileSearchTool().run(
        ctx,
        <String, dynamic>{'root': tmp.path, 'pattern': '*.txt', 'limit': 5},
      );
      expect(page1, contains('第 1–5 项'));

      final RegExpMatch? m = RegExp(r'cursor="([^"]+)"').firstMatch(page1);
      expect(m, isNotNull, reason: '还有下一页就必须给游标');

      final String page2 = await const FileSearchTool().run(
        ctx,
        <String, dynamic>{
          'root': tmp.path,
          'pattern': '*.txt',
          'limit': 5,
          'cursor': m!.group(1)!,
        },
      );
      expect(page2, contains('第 6–10 项'));

      // 两页的文件名不能重叠 —— 游标要是没生效，这里会重复
      final Set<String> names1 = RegExp(r'f(\d+)\.txt').allMatches(page1)
          .map((RegExpMatch e) => e.group(1)!)
          .toSet();
      final Set<String> names2 = RegExp(r'f(\d+)\.txt').allMatches(page2)
          .map((RegExpMatch e) => e.group(1)!)
          .toSet();
      expect(names1.intersection(names2), isEmpty, reason: '翻页不能重复给同一批');
    });

    test('目录不存在时说清怎么办，而不是一句"失败"', () async {
      final String out = await const FileSearchTool().run(
        ctx,
        <String, dynamic>{'root': '${tmp.path}/nope'},
      );
      expect(out, contains('目录不存在'));
      expect(out, contains('/sdcard'), reason: '要给一个可执行的下一步');
    });

    test('默认跳过 .git / node_modules', () async {
      await writeFile('.git/config', 'x');
      await writeFile('node_modules/pkg/index.js', 'x');
      await writeFile('src/main.py', 'x');

      final String out = await const FileSearchTool().run(
        ctx,
        <String, dynamic>{'root': tmp.path, 'pattern': '*', 'max_depth': 5},
      );
      expect(out, contains('main.py'));
      expect(out, isNot(contains('node_modules')));
    });  });

  group('reader', () {
    test('默认只给摘要，不给正文', () async {
      final File f = await writeFile(
        'big.md',
        '# 标题\n${List<String>.generate(3000, (int i) => '正文第 $i 行').join('\n')}',
      );

      final String out = await const ReaderTool().run(
        ctx,
        <String, dynamic>{'target': f.path},
      );

      expect(out, contains('共'), reason: '要有行数');
      expect(out, contains('标题'));
      expect(out.length, lessThan(4000));
      expect(out.contains('正文第 2000 行'), isFalse, reason: '摘要里不该有中段正文');
    });

    test('mode=raw 加 range 只返回那几行', () async {
      final File f = await writeFile(
        'seg.txt',
        List<String>.generate(100, (int i) => 'row $i').join('\n'),
      );

      final String out = await const ReaderTool().run(
        ctx,
        <String, dynamic>{
          'target': f.path,
          'mode': 'raw',
          'range': <String, dynamic>{'start': 10, 'end': 12},
        },
      );
      expect(out, contains('row 9\nrow 10\nrow 11'));
      expect(out, isNot(contains('row 50')));
      expect(out, contains('共 100 行'), reason: '要告诉它总长度,好判断还剩多少');
    });

    test('mode=grep 返回命中行，不返回整个文件', () async {
      final File f = await writeFile(
        'app.log',
        List<String>.generate(5000, (int i) => i == 1234 ? 'FATAL: boom' : 'noise $i')
            .join('\n'),
      );

      final String out = await const ReaderTool().run(
        ctx,
        <String, dynamic>{
          'target': f.path,
          'mode': 'grep',
          'grep': <String, dynamic>{'pattern': 'FATAL'},
        },
      );
      expect(out, contains('FATAL: boom'));
      expect(out, contains('第 1235 行'));
      expect(out.length, lessThan(2000));
    });

    test('op=write 覆盖写，然后能读回来', () async {
      final File f = File('${tmp.path}/out.txt');
      final String w = await const ReaderTool().run(
        ctx,
        <String, dynamic>{
          'op': 'write',
          'target': f.path,
          'content': '写进去的内容\n第二行',
        },
      );
      expect(w, contains('已写入'));
      expect(await f.readAsString(), '写进去的内容\n第二行');
    });

    test('dry_run 不真的落盘', () async {
      final File f = File('${tmp.path}/dry.txt');
      final String w = await const ReaderTool().run(
        ctx,
        <String, dynamic>{
          'op': 'write',
          'target': f.path,
          'content': '不该出现',
          'dry_run': true,
        },
      );
      expect(w, contains('没有真的写'));
      expect(await f.exists(), isFalse);
    });

    test('写的内容里引用超限时拒绝执行，不写入摘要', () async {
      final File big = await writeFile('src.txt', List<String>.generate(30000, (int i) => 'x$i').join('\n'));
      final Obj o = await ObjStore.instance.putFile(big.path);
      final File dest = File('${tmp.path}/dest.txt');

      final String w = await const ReaderTool().run(
        ctx,
        <String, dynamic>{
          'op': 'write',
          'target': dest.path,
          'content': '{{${o.uri}}}',
        },
      );

      expect(w, contains('没有执行'));
      expect(await dest.exists(), isFalse, reason: '宁可失败，也不能把摘要当成正文写进用户的文件');
    });

    test('找不到文件时给出定位建议', () async {
      final String out = await const ReaderTool().run(
        ctx,
        <String, dynamic>{'target': '${tmp.path}/missing.txt'},
      );
      expect(out, contains('找不到'));
      expect(out, contains('filesearch'));
    });
  });

  group('geter', () {
    test('define 文件后返回句柄，list 能看到它', () async {
      final File f = await writeFile('doc.md', '文档内容');
      final String out = await const GeterTool().run(
        ctx,
        <String, dynamic>{'op': 'define', 'name': 'doc', 'source': f.path},
      );
      expect(out, contains('obj://doc'));

      final String list = await const GeterTool().run(
        ctx,
        <String, dynamic>{'op': 'list'},
      );
      expect(list, contains('obj://doc'));
    });

    test('ref 的 full 在超限时拒绝，并指向 reader', () async {
      final File f = await writeFile('huge.bin.txt', 'y' * 200000);
      final Obj o = await ObjStore.instance.putFile(f.path, id: 'huge');

      final String out = await const GeterTool().run(
        ctx,
        <String, dynamic>{'op': 'ref', 'name': o.uri, 'as': 'full'},
      );
      expect(out, contains('超过'));
      expect(out, contains('reader'), reason: '拒绝之后要给一条可行的路');
    });

    test('ref 的 path 解析成真实路径', () async {
      final File f = await writeFile('p.txt', 'x');
      final Obj o = await ObjStore.instance.putFile(f.path, id: 'pp');
      final String out = await const GeterTool().run(
        ctx,
        <String, dynamic>{'op': 'ref', 'name': o.uri, 'as': 'path'},
      );
      expect(out.trim(), f.path);
    });

    test('pin 住的对象不能被 drop', () async {
      await ObjStore.instance.putText('留着', id: 'keep', pinned: true);
      final String out = await const GeterTool().run(
        ctx,
        <String, dynamic>{'op': 'drop', 'name': 'keep'},
      );
      expect(out, contains('pin'));
      expect(ObjStore.instance.lookup('keep'), isNotNull);
    });
  });

  group('sheller 的安全面', () {
    test('脚本按 shell 规则判风险', () {
      final RiskAssessment safe = const ShellerTool().riskFor(
        <String, dynamic>{'lang': 'sh', 'script': 'ls -la /sdcard'},
      );
      expect(safe.level, RiskLevel.safe);

      final RiskAssessment dangerous = const ShellerTool().riskFor(
        <String, dynamic>{'lang': 'sh', 'script': 'rm -rf /sdcard/Download'},
      );
      expect(dangerous.level, RiskLevel.dangerous);
    });

    test('py 脚本复用 Python 那套分级（不另写一份）', () {
      final RiskAssessment r = const ShellerTool().riskFor(
        <String, dynamic>{
          'lang': 'py',
          'script': 'import shutil\nshutil.rmtree("/sdcard/x")',
        },
      );
      expect(r.level, RiskLevel.dangerous);
    });

    test('参数里的 path:// 会被换成真实路径，而不是原文', () async {
      final File f = await writeFile('arg.txt', '文件内容不该进命令行');
      final Obj o = await ObjStore.instance.putFile(f.path, id: 'arg');

      // 直接调解析函数：真跑命令要平台通道，而这里要验的是"拼出来的是什么"
      final String resolved = await resolvePathArg('path://${o.uri}');
      expect(resolved, f.path);
      expect(resolved.contains('文件内容'), isFalse, reason: '命令行里只能出现路径');
    });

    test('两种前缀叠在一起（path://obj://a）也认', () async {
      final File f = await writeFile('arg2.txt', 'x');
      final Obj o = await ObjStore.instance.putFile(f.path, id: 'arg2');
      expect(await resolvePathArg('path://${o.uri}'), f.path);
    });
  });
}
