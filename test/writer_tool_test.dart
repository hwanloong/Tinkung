// writer：按段改文件。
//
// 这个工具的风险不在"能不能改"，而在**改错地方**和**改坏文件**。
// 所以用例集中在这几条上：
//  · 出现多次时拒绝执行（而不是猜一处改掉）；
//  · 找不到原文时给出可执行的下一步；
//  · 改完内容确实变了，其余部分一字不动；
//  · 覆盖之前留了备份。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/plugins/plugin.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:dsh_agent/tools/writer_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  late ToolContext ctx;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dsh_writer');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ctx = _ctx(await Settings.load(), tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> write(String name, String content) async {
    final File f = File('${tmp.path}/$name');
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  group('replace', () {
    test('只改命中处，其余内容一字不动', () async {
      final File f = await write(
        'a.md',
        '# 标题\n\n第一段。\n\n第二段要改这里。\n\n第三段。\n',
      );

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'old': '第二段要改这里。',
        'new': '第二段已经改好了。',
      });

      expect(out, contains('已修改'));

      final String after = await f.readAsString();
      expect(after, contains('第二段已经改好了。'));
      expect(after, isNot(contains('第二段要改这里。')));
      // 前后也必须原样在
      expect(after, startsWith('# 标题\n\n第一段。\n\n'));
      expect(after, endsWith('\n\n第三段。\n'));
    });

    test('原文出现多次时拒绝执行，一个字节都不改', () async {
      final String content = 'x = 1\n\n中间\n\nx = 1\n';
      final File f = await write('dup.py', content);

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'old': 'x = 1',
        'new': 'x = 2',
      });

      expect(out, contains('出现了 2 次'));
      expect(out, contains('没有动文件'));
      expect(out, contains('line'), reason: '要告诉它怎么修，而不是只说不行');
      expect(await f.readAsString(), content, reason: '有歧义就绝不能猜一处改掉');
    });

    test('给了 line 之后能消歧', () async {
      final File f = await write('dup2.py', 'x = 1\n\n中间\n\nx = 1\n');

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'old': 'x = 1',
        'new': 'x = 2',
        'line': 5,
      });

      expect(out, contains('已修改'));
      final String after = await f.readAsString();
      // 第 5 行那个被改了，第 1 行那个没动
      expect(after, startsWith('x = 1'));
      expect(after, endsWith('x = 2\n'));
    });

    test('找不到原文时说清可能的原因', () async {
      final File f = await write('nope.md', '内容\n');

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'old': '这段不存在',
        'new': 'x',
      });

      expect(out, contains('找不到这段原文'));
      expect(out, contains('reader'), reason: '要指回去看原样');
      expect(await f.readAsString(), '内容\n');
    });

    test('替换前后相同时不写盘', () async {
      final File f = await write('same.md', 'abc\n');
      final DateTime before = (await f.stat()).modified;

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'old': 'abc',
        'new': 'abc',
      });

      expect(out, contains('没有写盘'));
      expect((await f.stat()).modified, before);
    });
  });

  group('insert / delete', () {
    test('insert 在指定行之后插入', () async {
      final File f = await write('ins.txt', '一\n二\n三\n');

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'op': 'insert',
        'after': 1,
        'new': '插进来的',
      });

      expect(out, contains('插入 1 行'));
      expect(await f.readAsString(), '一\n插进来的\n二\n三\n');
    });

    test('delete 只删命中那一段', () async {
      final File f = await write('del.txt', '保留A\n要删掉这行\n保留B\n');

      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'op': 'delete',
        'old': '要删掉这行\n',
      });

      expect(out, contains('已删除'));
      expect(await f.readAsString(), '保留A\n保留B\n');
    });
  });

  group('新建与备份', () {
    test('文件不存在且没给 create 时拒绝', () async {
      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': '${tmp.path}/new.md',
        'old': 'x',
        'new': 'y',
      });
      expect(out, contains('文件不存在'));
      expect(out, contains('create=true'));
    });

    test('create=true 能新建（含中间目录）', () async {
      final String path = '${tmp.path}/a/b/c.md';
      final String out = await const WriterTool().run(ctx, <String, dynamic>{
        'path': path,
        'create': true,
        'new': '# 新文件\n',
      });
      expect(out, contains('已新建'));
      expect(await File(path).readAsString(), '# 新文件\n');
    });

    test('改文件之前留了备份，内容就是改动前的原文', () async {
      final File f = await write('backup.md', '原始内容\n');

      await const WriterTool().run(ctx, <String, dynamic>{
        'path': f.path,
        'old': '原始内容',
        'new': '新内容',
      });

      final Directory bakDir = Directory('${f.parent.path}/.dsh_backup');
      expect(await bakDir.exists(), isTrue, reason: '改坏了要能退回去');

      final List<File> baks = await bakDir
          .list()
          .where((FileSystemEntity e) => e is File)
          .cast<File>()
          .toList();
      expect(baks, hasLength(1));
      expect(await baks.first.readAsString(), '原始内容\n');
    });

    test('备份只保留最近几份，不会无限堆积', () async {
      final File f = await write('prune.md', 'v0\n');
      // 改很多次，每次内容都不同（否则会被"没有变化"挡住）
      for (int i = 1; i <= 6; i++) {
        await const WriterTool().run(ctx, <String, dynamic>{
          'path': f.path,
          'old': 'v${i - 1}\\n'.replaceAll('\\n', '\n'),
          'new': 'v$i\n',
        });
        // 时间戳精度只到秒，等待一下让文件名不同
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final Directory bakDir = Directory('${f.parent.path}/.dsh_backup');
      final List<File> baks = await bakDir
          .list()
          .where((FileSystemEntity e) => e is File)
          .cast<File>()
          .toList();
      expect(
        baks.length,
        lessThanOrEqualTo(WriterTool.backupKeep),
        reason: '备份是误操作恢复，不是版本管理，不该无限增长',
      );
    });
  });

  group('风险分级', () {
    test('改文件要确认，新建也要确认', () {
      final RiskAssessment edit = const WriterTool().riskFor(
        <String, dynamic>{'path': '/sdcard/a.md', 'op': 'replace'},
      );
      expect(edit.level, RiskLevel.caution);

      final RiskAssessment create = const WriterTool().riskFor(
        <String, dynamic>{'path': '/sdcard/a.md', 'create': true},
      );
      expect(create.level, RiskLevel.caution);
    });
  });
}
