// 工具的 `intro.md`（备注）与 `tool.md`（做法）的分工。
//
// 两者都是工具文件夹里的主文件，但**读者不同**：
//  · tool.md 给模型看 → 会被注入上下文；
//  · intro.md 给用户看 → 不进上下文。
//
// 搞混的后果很具体：备注被塞进 tool.md 就会每轮占上下文、
// 还可能被模型当成指令；反过来命令细节摆在备注里，人看着很乱。
//
// 文件后半段还有一组**图标**的测试（`tool.icon`）—— 同属"工具文件夹里
// 有固定名字的文件"这条约定：名字对了就生效，名字/内容不对就**安静地**
// 退回默认样子，而不是报错或者让界面看起来坏掉。
import 'dart:convert';
import 'dart:io';

import 'package:dsh_agent/core/folder_tool.dart';
import 'package:dsh_agent/ui/tools_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh_tools_');
    await FolderToolStore.instance.configure(root);
  });

  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('intro.md 被读进 intro，且不出现在附件清单里', () async {
    final Directory d = Directory('${root.path}/demo')..createSync();
    File('${d.path}/tool.md')
        .writeAsStringSync('---\ntitle: 演示\ndescription: 演示用\n---\n1. 做这个\n');
    File('${d.path}/intro.md').writeAsStringSync('这是备注：它来自某次需求。\n');

    await FolderToolStore.instance.load();
    final FolderTool t = FolderToolStore.instance.byId('demo')!;

    expect(t.title, '演示');
    expect(t.body, contains('做这个'));
    expect(t.intro, contains('这是备注'));
    // intro.md 不该被当成普通附件，否则文件列表里会出现两次
    expect(t.files, isNot(contains('intro.md')));
  });

  test('没有 intro.md 也能正常加载（老工具/没写备注）', () async {
    final Directory d = Directory('${root.path}/bare')..createSync();
    File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 裸工具\n---\n步骤\n');
    await FolderToolStore.instance.load();
    final FolderTool t = FolderToolStore.instance.byId('bare')!;
    expect(t.intro, isEmpty);
  });

  test('filesOf 把两个主文件排在最前', () async {
    final Directory d = Directory('${root.path}/order')..createSync();
    File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 排序\n---\n');
    File('${d.path}/intro.md').writeAsStringSync('备注\n');
    File('${d.path}/z_script.sh').writeAsStringSync('echo\n');
    File('${d.path}/a_note.txt').writeAsStringSync('x\n');
    await FolderToolStore.instance.load();

    final FolderTool t = FolderToolStore.instance.byId('order')!;
    final List<String> files = FolderToolStore.instance.filesOf(t);

    expect(files.first, FolderToolStore.manifestName);
    expect(files[1], FolderToolStore.introName);
    // 其余按名字排
    expect(files.sublist(2), <String>['a_note.txt', 'z_script.sh']);
  });

  test('ensureIntro 会创建带模板的 intro.md', () async {
    final Directory d = Directory('${root.path}/made')..createSync();
    File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 新建\n---\n');
    await FolderToolStore.instance.load();
    final FolderTool t = FolderToolStore.instance.byId('made')!;
    expect(t.intro, isEmpty);

    await FolderToolStore.instance.ensureIntro(t);
    expect(File('${d.path}/intro.md').existsSync(), isTrue);
    // 重新扫过之后 intro 应该读到了模板内容
    expect(FolderToolStore.instance.byId('made')!.intro, isNotEmpty);
  });

  test('noteLine：跳过标题和 HTML 注释，取第一行真内容', () {
    final FolderTool t = FolderTool(
      id: 'x',
      title: 'x',
      folderPath: '/tmp/x',
      intro: '''
# 合并 PDF · 备注

<!--
  这个文件是给你自己看的，模型不会读它。
-->

## 它从哪来

需求原话是"能合并 PDF"。
''',
    );
    // 标题（# 和 ##）和注释块都要被跳过，落到正文第一句
    expect(t.noteLine, '需求原话是"能合并 PDF"。');
    expect(t.noteLine.contains('<!--'), isFalse);
    expect(t.noteLine.startsWith('#'), isFalse);
  });

  test('noteLine：备注为空时返回空串（由调用方回退）', () {
    final FolderTool t = FolderTool(id: 'x', title: 'x', folderPath: '/tmp/x');
    expect(t.noteLine, isEmpty);
  });

  test('noteLine：整篇只有注释时返回空串', () {
    final FolderTool t = FolderTool(
      id: 'x',
      title: 'x',
      folderPath: '/tmp/x',
      intro: '# 标题\n\n<!-- 只有注释 -->\n',
    );
    expect(t.noteLine, isEmpty);
  });

  test('noteLine 会把换行折成单行', () {
    final FolderTool t = FolderTool(
      id: 'x',
      title: 'x',
      folderPath: '/tmp/x',
      intro: '第一行   有   很多空格\n第二行',
    );
    expect(t.noteLine, '第一行 有 很多空格');
  });

  test('setTitle 只改 title，其它 frontmatter 键保留', () async {
    final Directory d = Directory('${root.path}/ren')..createSync();
    File('${d.path}/tool.md').writeAsStringSync(
      '---\nname: ren\ntitle: 老名字\ndescription: 说明\nversion: 3\nenabled: true\n---\n正文\n',
    );
    await FolderToolStore.instance.load();
    // 先确认读出来的确实是老名字（否则下面的断言就证明不了"改了"）
    expect(FolderToolStore.instance.byId('ren')!.title, '老名字');

    final String? err = await FolderToolStore.instance.setTitle('ren', '新名字');
    expect(err, isNull);

    final FolderTool after = FolderToolStore.instance.byId('ren')!;
    expect(after.title, '新名字');
    // 其它键不能被顺手抹掉 —— 那是"改个名字丢了配置"
    expect(after.description, '说明');
    expect(after.version, 3);
    expect(after.enabled, isTrue);
    expect(after.body.trim(), '正文');
  });

  test('renameId 改文件夹名，并按新 id 能查到', () async {
    final Directory d = Directory('${root.path}/old_id')..createSync();
    File('${d.path}/tool.md')
        .writeAsStringSync('---\nname: old_id\ntitle: 老\n---\n正文\n');
    await FolderToolStore.instance.load();
    expect(FolderToolStore.instance.byId('old_id'), isNotNull);

    final String? err = await FolderToolStore.instance.renameId(
      'old_id',
      'new_id',
    );
    expect(err, isNull);

    expect(FolderToolStore.instance.byId('old_id'), isNull);
    final FolderTool t = FolderToolStore.instance.byId('new_id')!;
    expect(t.title, '老'); // 标题不受影响
    // 目录真的换了名
    expect(Directory('${root.path}/new_id').existsSync(), isTrue);
    expect(Directory('${root.path}/old_id').existsSync(), isFalse);
  });

  test('renameId 拒绝非法标识和重名', () async {
    for (final String id in <String>['a', 'b']) {
      final Directory d = Directory('${root.path}/$id')..createSync();
      File('${d.path}/tool.md').writeAsStringSync('---\ntitle: $id\n---\n');
    }
    await FolderToolStore.instance.load();

    // 非法字符（会变成文件夹名）
    expect(
      await FolderToolStore.instance.renameId('a', '带 空格'),
      contains('只能用'),
    );
    // 重名
    expect(await FolderToolStore.instance.renameId('a', 'b'), contains('已经有'));
    // 非法输入不该产生副作用
    expect(FolderToolStore.instance.byId('a'), isNotNull);
  });

  test('newTitle 为空会被拒（不允许改出无名工具）', () async {
    final Directory d = Directory('${root.path}/nt')..createSync();
    File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 有名字\n---\n');
    await FolderToolStore.instance.load();
    expect(
      await FolderToolStore.instance.setTitle('nt', '   '),
      contains('不能为空'),
    );
    expect(FolderToolStore.instance.byId('nt')!.title, '有名字');
  });

  test('writeFile 能写 intro.md，写路径越界会被拒', () async {
    final Directory d = Directory('${root.path}/w')..createSync();
    File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 写\n---\n');
    await FolderToolStore.instance.load();
    final FolderTool t = FolderToolStore.instance.byId('w')!;

    await FolderToolStore.instance.writeFile(t, 'intro.md', '新备注');
    expect(FolderToolStore.instance.byId('w')!.intro, '新备注');

    // 沙箱：不能跳出工具文件夹
    expect(
      () => FolderToolStore.instance.writeFile(t, '../../notes.json', '坏'),
      throwsA(isA<Exception>()),
    );
  });

  // ------------------------------------------------------------------
  // 图标渲染
  //
  // 这一组的失败方式**全在界面上**：`tool.icon` 里放了坏字节，列表里
  // 冒出一个红叉、或者整页崩掉。用户只是往文件夹里放了个文件，
  // 不该有这个后果 —— 所以"读不出来就退回默认字形"是**必需路径**，
  // 不是防御性冗余：认内容不认扩展名，意味着任意坏字节都能进来。
  // ------------------------------------------------------------------
  group('ToolIcon 渲染', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

    testWidgets('没有图标时渲染默认字形，盒子正好 kToolIconSize', (tester) async {
      final FolderTool t = FolderTool(
        id: 'a',
        title: 'A',
        folderPath: root.path,
      );
      await tester.pumpWidget(host(ToolIcon(tool: t)));

      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      // 尺寸必须和 kToolIconSize 一致：列表行高全靠这个盒子稳住
      expect(
        tester.getSize(find.byType(ToolIcon)),
        const Size(kToolIconSize, kToolIconSize),
      );
      expect(
        tester.getSize(find.byIcon(Icons.folder_outlined)),
        const Size(kToolIconSize, kToolIconSize),
      );
    });

    testWidgets('坏图标（不是图片的字节）静默退回默认字形，不抛异常', (tester) async {
      final File f = File('${root.path}/broken.bin')
        ..writeAsBytesSync(<int>[0x00, 0xFF, 0x13, 0x37, 0x00]);
      final FolderTool t = FolderTool(
        id: 'b',
        title: 'B',
        folderPath: root.path,
        iconPath: f.path,
      );

      // 真实 IO + 解码：必须在 runAsync 里跑，否则解码永远不推进
      await tester.runAsync(() async {
        await tester.pumpWidget(host(ToolIcon(tool: t)));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      // 有图标（虽然坏了）时盒子尺寸也不变 —— 否则行会抖
      expect(
        tester.getSize(find.byType(ToolIcon)),
        const Size(kToolIconSize, kToolIconSize),
      );
    });

    testWidgets('图标文件被删掉了也不崩（路径还记着）', (tester) async {
      final FolderTool t = FolderTool(
        id: 'c',
        title: 'C',
        folderPath: root.path,
        iconPath: '${root.path}/已经没有了.png',
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(host(ToolIcon(tool: t)));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    });

    testWidgets('能解码的图片真的显示出来（不是默认字形）', (tester) async {
      // 1x1 的 PNG（真空图，用来证明"有图标时走图片分支"）。
      final List<int> png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJ'
        'cEhZcwAADsMAAA7DAcdvqGQAAAALSURBVBhXY2AAAgAA'
        'BQABqtXIUQAAAABJRU5ErkJggg==',
      );
      final File f = File('${root.path}/tool.icon')..writeAsBytesSync(png);
      final FolderTool t = FolderTool(
        id: 'd',
        title: 'D',
        folderPath: root.path,
        iconPath: f.path,
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(host(ToolIcon(tool: t)));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.folder_outlined), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(
        tester.getSize(find.byType(ToolIcon)),
        const Size(kToolIconSize, kToolIconSize),
      );
    });
  });
}
