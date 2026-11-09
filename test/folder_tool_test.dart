// 文件夹工具（Tool）：frontmatter 解析、路径沙箱、以及 `@` 引用解析。
//
// 这三块的失败方式都是**静默**的：
//  · frontmatter 没解对 → 工具的描述/标题全空，提示词里那行索引变成
//    "`x`：" —— 模型根本不知道该不该用它；
//  · 路径不挡 `../` → 一次写操作就能改掉笔记库，不可逆；
//  · `@` 解析错 → 用户引用了工具但内容没注入，而界面上看起来"我明明 @ 了"。
//
// 后面新增的两组（导入外来文件 / tool.icon）失败方式同样是静默的：
//  · 导入越界 → 写到工具文件夹外面去，用户完全不知道；
//  · 图标认不出 → 界面一直显示默认文件夹图标，看起来像"这功能没做"。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_agent/core/folder_tool.dart';
import 'package:dsh_agent/core/mentions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tool.md 的 frontmatter', () {
    test('正常解析出元信息和正文', () {
      const String raw = '''
---
name: pdf_merge
title: 合并 PDF
description: 把多个 PDF 合成一个
when_to_use: 用户要合并 PDF 时
version: 2
enabled: true
---

# 步骤

1. 装 qpdf
2. 跑 qpdf --empty --pages
''';
      final FrontMatter fm = FrontMatter.parse(raw);
      expect(fm.meta['name'], 'pdf_merge');
      expect(fm.meta['title'], '合并 PDF');
      expect(fm.meta['version'], '2');
      expect(fm.body, contains('装 qpdf'));
      // 正文里不该还留着 ---
      expect(fm.body.startsWith('---'), isFalse);
    });

    test('没有 frontmatter 时整篇当正文（不吞内容）', () {
      final FrontMatter fm = FrontMatter.parse('# 就一段说明\n做这个那个');
      expect(fm.meta, isEmpty);
      expect(fm.body, contains('做这个那个'));
    });

    test('只有开头的 --- 没有收尾时，不把整篇当空正文', () {
      // 用户手写很容易漏收尾那一行。当成"空正文"是最难查的失败：
      // 工具出现在列表里，但模型读到的是空的。
      final FrontMatter fm = FrontMatter.parse('---\ntitle: x\n正文还在');
      expect(fm.body, isNotEmpty);
      expect(fm.body, contains('正文还在'));
    });

    test('值两边的引号会被去掉', () {
      final FrontMatter fm = FrontMatter.parse('---\ntitle: "带引号的标题"\n---\n正文');
      expect(fm.meta['title'], '带引号的标题');
    });

    test('中文值不会因为冒号被截断', () {
      final FrontMatter fm = FrontMatter.parse(
        '---\ndescription: 说明：这里有冒号\n---\n正文',
      );
      expect(fm.meta['description'], contains('这里有冒号'));
    });
  });

  group('@ 引用解析', () {
    test('解析 tool 和 plugin 两种', () {
      final List<Mention> ms = MentionParser.parse(
        '帮我看下 @tool:pdf_merge 和 @plugin:get_weather',
      );
      expect(ms.length, 2);
      expect(ms[0].kind, MentionKind.tool);
      expect(ms[0].id, 'pdf_merge');
      expect(ms[1].kind, MentionKind.plugin);
      expect(ms[1].id, 'get_weather');
    });

    test('不带前缀的 @ 不算引用（避免误吃"@某人"）', () {
      expect(MentionParser.parse('转告 @张三 一下'), isEmpty);
    });

    test('邮箱里的 @ 不算引用', () {
      expect(MentionParser.parse('发到 a@b.com'), isEmpty);
    });

    test('strip 去掉标记但保留其它文字', () {
      expect(MentionParser.strip('用 @tool:pdf_merge 合并这两个'), '用 合并这两个');
    });

    test('activeFragment：只在 @ 语境里返回', () {
      // 正在打前缀
      final f = MentionParser.activeFragment('看 @to', 5);
      expect(f, isNotNull);
      // 已经选了具体名字
      final g = MentionParser.activeFragment('@tool:pdf', 9);
      expect(g?.kind, MentionKind.tool);
      expect(g?.query, 'pdf');
    });

    test('activeFragment：@ 后面有空格就不再补全', () {
      expect(MentionParser.activeFragment('@tool:pdf_merge 合并', 20), isNull);
    });

    test('token 能原样再解析回来', () {
      const Mention m = Mention(kind: MentionKind.tool, id: 'x');
      expect(MentionParser.parse(m.token).single.id, 'x');
    });
  });

  // ------------------------------------------------------------------
  // 导入外来文件
  //
  // 这一组全部围绕"文件名是**外部给**的"这个事实：它可能带 `..`、
  // 可能是绝对路径、可能重名。任何一条漏掉，后果都是**写到别处去**
  // 或者**把用户原有的文件悄悄删掉**，而且事后很难发现。
  // ------------------------------------------------------------------
  group('导入外来文件', () {
    late Directory root;
    late FolderToolStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dsh_import_');
      store = FolderToolStore.instance;
      await store.configure(root);
      final Directory d = Directory('${root.path}/demo')..createSync();
      File('${d.path}/tool.md').writeAsStringSync('---\ntitle: 演示\n---\n步骤\n');
      await store.load();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    FolderTool tool() => store.byId('demo')!;

    test('按原始文件名原样写进去，字节不变', () async {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0x50,
        0x4b,
        0x03,
        0x04,
        0x00,
        0x01,
      ]);
      expect(await store.importBytes(tool(), 'pack.zip', bytes), isNull);

      final File f = File('${root.path}/demo/pack.zip');
      expect(f.existsSync(), isTrue);
      // 二进制必须一字节不差 —— 走文本通道写会把字节改坏
      expect(f.readAsBytesSync(), bytes);
      // 导入后要立刻重扫，否则界面和模型都还以为文件夹里没有它
      expect(store.byId('demo')!.files, contains('pack.zip'));
    });

    test('可以导到子目录（父目录自动建）', () async {
      expect(
        await store.importBytes(tool(), 'scripts/run.sh', Uint8List(3)),
        isNull,
      );
      expect(File('${root.path}/demo/scripts/run.sh').existsSync(), isTrue);
    });

    test('`..` 越界被拒，而且真的没写到外面去', () async {
      final String? err = await store.importBytes(
        tool(),
        '../escape.bin',
        Uint8List(4),
      );
      expect(err, contains('跳出'));
      // 关键：不能只是"报了个错"却已经把文件写出去
      expect(File('${root.path}/escape.bin').existsSync(), isFalse);
    });

    test('`a/../../b.bin` 这种绕一圈的越界也拒', () async {
      expect(
        await store.importBytes(tool(), 'a/../../b.bin', Uint8List(2)),
        contains('跳出'),
      );
      expect(File('${root.path}/b.bin').existsSync(), isFalse);
    });

    test('绝对路径和盘符路径被拒', () async {
      expect(
        await store.importBytes(tool(), '/data/data/x/evil.so', Uint8List(2)),
        contains('相对路径'),
      );
      expect(
        await store.importBytes(tool(), r'C:\Windows\evil.dll', Uint8List(2)),
        contains('相对路径'),
      );
    });

    test('反斜杠会被归一成路径分隔符，同样受沙箱约束', () async {
      expect(
        await store.importBytes(tool(), r'..\escape2.bin', Uint8List(2)),
        contains('跳出'),
      );
    });

    test('同名默认被拒，原内容不动；显式 overwrite 才替换', () async {
      final Uint8List first = Uint8List.fromList(<int>[1, 2, 3]);
      expect(await store.importBytes(tool(), 'a.bin', first), isNull);

      final Uint8List second = Uint8List.fromList(<int>[9, 9]);
      final String? err = await store.importBytes(tool(), 'a.bin', second);
      expect(err, contains('已经有'));
      // 拒绝必须是真的没动文件，而不是"报错但已经覆盖了"
      expect(File('${root.path}/demo/a.bin').readAsBytesSync(), first);

      expect(
        await store.importBytes(tool(), 'a.bin', second, overwrite: true),
        isNull,
      );
      expect(File('${root.path}/demo/a.bin').readAsBytesSync(), second);
    });

    test('超过上限被拒，且不留半个文件', () async {
      final Uint8List big = Uint8List(FolderToolStore.maxImportBytes + 1);
      expect(await store.importBytes(tool(), 'big.bin', big), contains('太大'));
      expect(File('${root.path}/demo/big.bin').existsSync(), isFalse);
    });

    test('hasFile 能先问一次同名（界面覆盖前用它）', () async {
      expect(store.hasFile(tool(), 'x.bin'), isFalse);
      await store.importBytes(tool(), 'x.bin', Uint8List(1));
      expect(store.hasFile(tool(), 'x.bin'), isTrue);
      // 越界路径不算"有这个文件"
      expect(store.hasFile(tool(), '../tool.md'), isFalse);
    });
  });

  // ------------------------------------------------------------------
  // tool.icon
  // ------------------------------------------------------------------
  group('工具图标 tool.icon', () {
    late Directory root;
    late FolderToolStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dsh_icon_');
      store = FolderToolStore.instance;
      await store.configure(root);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<FolderTool> makeTool(String id) async {
      final Directory d = Directory('${root.path}/$id')..createSync();
      File('${d.path}/tool.md').writeAsStringSync('---\ntitle: $id\n---\n');
      await store.load();
      return store.byId(id)!;
    }

    test('没有图标文件时 iconPath 为空（回退默认字形）', () async {
      final FolderTool t = await makeTool('plain');
      expect(t.hasIcon, isFalse);
      expect(t.iconPath, isEmpty);
    });

    test('恰好叫 tool.icon 就算图标（格式由内容决定）', () async {
      final FolderTool t = await makeTool('bare');
      File('${t.folderPath}/tool.icon').writeAsBytesSync(<int>[0x89, 0x50]);
      await store.load();
      final FolderTool after = store.byId('bare')!;
      expect(after.hasIcon, isTrue);
      expect(after.iconPath, endsWith('tool.icon'));
    });

    test('tool.icon.png 也认，大小写不敏感', () async {
      final FolderTool t = await makeTool('ext');
      File('${t.folderPath}/TOOL.ICON.PNG').writeAsBytesSync(<int>[1, 2]);
      await store.load();
      expect(store.byId('ext')!.hasIcon, isTrue);
    });

    test('tool.icon.webp / .jpg / .jpeg / .gif / .bmp 都认', () async {
      for (final String ext in <String>['webp', 'jpg', 'jpeg', 'gif', 'bmp']) {
        final String id = 'e_$ext';
        final FolderTool t = await makeTool(id);
        File('${t.folderPath}/tool.icon.$ext').writeAsBytesSync(<int>[1]);
        await store.load();
        expect(store.byId(id)!.hasIcon, isTrue, reason: '应该认 .$ext');
      }
    });

    test('tool.icon.svg 不认 —— 没有矢量解码器，认了也显示不出来', () async {
      final FolderTool t = await makeTool('vec');
      File('${t.folderPath}/tool.icon.svg').writeAsStringSync('<svg/>');
      await store.load();
      // 认了只会变成"图标放进去了但不显示"这种没法查的问题
      expect(store.byId('vec')!.hasIcon, isFalse);
    });

    test('其它名字的图片不算图标（比如 cover.png）', () async {
      final FolderTool t = await makeTool('other');
      File('${t.folderPath}/cover.png').writeAsBytesSync(<int>[1]);
      await store.load();
      expect(store.byId('other')!.hasIcon, isFalse);
    });

    test('子目录里的 tool.icon 不算 —— 图标只看第一层', () async {
      final FolderTool t = await makeTool('deep');
      Directory('${t.folderPath}/assets').createSync();
      File('${t.folderPath}/assets/tool.icon').writeAsBytesSync(<int>[1]);
      await store.load();
      expect(store.byId('deep')!.hasIcon, isFalse);
    });

    test('图标文件本身出现在文件清单里（用户能看见、能替换它）', () async {
      final FolderTool t = await makeTool('listed');
      File('${t.folderPath}/tool.icon').writeAsBytesSync(<int>[1]);
      await store.load();
      expect(store.filesOf(store.byId('listed')!), contains('tool.icon'));
    });

    test('用 importBytes 导入 tool.icon 后图标立刻生效', () async {
      final FolderTool t = await makeTool('viaimport');
      expect(t.hasIcon, isFalse);
      expect(
        await store.importBytes(
          t,
          'tool.icon',
          Uint8List.fromList(<int>[1, 2]),
        ),
        isNull,
      );
      // importBytes 内部会重扫，所以不用手动再 load
      expect(store.byId('viaimport')!.hasIcon, isTrue);
    });
  });

  // ------------------------------------------------------------------
  // 文本性判定
  //
  // 判错的代价不对称：把二进制当文本送进编辑器，用户按一次保存
  // 就把原文件覆盖成乱码了；把文本当二进制只是少一个编辑入口。
  // ------------------------------------------------------------------
  group('文本性判定（决定能不能进编辑器）', () {
    late Directory root;
    late FolderToolStore store;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dsh_stat_');
      store = FolderToolStore.instance;
      await store.configure(root);
      final Directory d = Directory('${root.path}/stat')..createSync();
      File('${d.path}/tool.md').writeAsStringSync('---\ntitle: stat\n---\n');
      await store.load();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    FolderTool tool() => store.byId('stat')!;

    Future<ToolFileStat> statOf(String name, List<int> bytes) async {
      File('${tool().folderPath}/$name').writeAsBytesSync(bytes);
      return store.statFile(tool(), name);
    }

    test('普通 UTF-8 文本 → 可编辑，大小正确', () async {
      // 注意用 utf8.encode 而不是 codeUnits：后者是 UTF-16 码元，
      // 中文会被截成一个字节，那样写出来本来就是坏 UTF-8。
      final List<int> bytes = utf8.encode('# 标题\n正文\n');
      final ToolFileStat st = await statOf('a.md', bytes);
      expect(st.isText, isTrue);
      expect(st.size, bytes.length);
      expect(st.exists, isTrue);
    });

    test('空文件 → 可编辑（在编辑器里写内容是正常操作）', () async {
      expect((await statOf('empty.txt', <int>[])).isText, isTrue);
    });

    test('PNG 文件头（含 NUL）→ 非文本', () async {
      const List<int> png = <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ];
      expect((await statOf('tool.icon', png)).isText, isFalse);
    });

    test('非法 UTF-8 字节 → 非文本（没有 NUL 也不行）', () async {
      // 0xFF 在任何 UTF-8 序列里都不合法；这条防的是"没有 NUL 就当文本"
      expect(
        (await statOf('weird.bin', <int>[0x41, 0xFF, 0x42])).isText,
        isFalse,
      );
    });

    test('GBK 中文被判成非文本 —— 故意的：乱码改完存回去等于毁文件', () async {
      // "中文" 的 GBK 编码，不是合法 UTF-8
      expect(
        (await statOf('gbk.txt', <int>[0xD6, 0xD0, 0xCE, 0xC4])).isText,
        isFalse,
      );
    });

    test('4KB 边界正好切在一个汉字中间时，仍判为文本', () async {
      // 4095 个 ASCII + 一个 3 字节汉字：前 4096 字节刚好把汉字切了一半。
      // 不做"砍掉末尾 3 字节"的话，一整篇正常中文会在这里被判成二进制。
      final List<int> bytes = <int>[
        ...List<int>.filled(4095, 0x61),
        0xE4, 0xB8, 0xAD, // '中' 的 UTF-8
        ...List<int>.filled(200, 0x62),
      ];
      expect((await statOf('big.md', bytes)).isText, isTrue);
    });

    test('文件不存在时不抛异常，返回 missing', () async {
      final ToolFileStat st = await store.statFile(tool(), 'nope.txt');
      expect(st.exists, isFalse);
      expect(st.size, -1);
    });

    test('批量 statFiles 覆盖全部给定文件', () async {
      await statOf('one.md', 'x'.codeUnits);
      await statOf('two.bin', <int>[0, 0, 0]);
      final Map<String, ToolFileStat> m = await store.statFiles(
        tool(),
        <String>['one.md', 'two.bin'],
      );
      expect(m['one.md']!.isText, isTrue);
      expect(m['two.bin']!.isText, isFalse);
    });
  });

  group('humanSize', () {
    test('三个量级都对', () {
      expect(FolderToolStore.humanSize(512), '512 B');
      expect(FolderToolStore.humanSize(2048), '2.0 KB');
      expect(FolderToolStore.humanSize(3 * 1024 * 1024), '3.0 MB');
      expect(FolderToolStore.humanSize(-1), '大小未知');
    });
  });
}
