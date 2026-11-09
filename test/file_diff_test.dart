// 「修改文件」的行级差异。
//
// 这几个用例钉住三件用户能直接看到的事：
//  · 哪一行是删除（红）、哪一行是新增（绿）；
//  · 每行左边显示的是**原行号**还是**新行号**；
//  · 长文件里没变的大段内容会被折叠，不会把面板撑满。
import 'dart:io';

import 'package:dsh_agent/core/file_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileDiff', () {
    test('替换一行：删除和新增各自带正确的行号', () {
      final FileChange? c = FileDiff.compute(
        '/sdcard/a.txt',
        '第一行\n旧内容\n第三行\n',
        '第一行\n新内容\n第三行\n',
      );
      expect(c, isNotNull);
      expect(c!.additions, 1);
      expect(c.deletions, 1);

      final DiffLine removed = c.lines.firstWhere(
        (DiffLine l) => l.kind == DiffKind.removed,
      );
      final DiffLine added = c.lines.firstWhere(
        (DiffLine l) => l.kind == DiffKind.added,
      );
      expect(removed.text, '旧内容');
      expect(removed.oldLine, 2);
      expect(removed.newLine, isNull);
      expect(added.text, '新内容');
      expect(added.newLine, 2);
      expect(added.oldLine, isNull);
    });

    test('只添加：原行号为空，新行号连续', () {
      final FileChange? c = FileDiff.compute(
        '/sdcard/a.md',
        '# 标题\n',
        '# 标题\n\n新增一段\n',
      );
      expect(c, isNotNull);
      expect(c!.additions, 2);
      expect(c.deletions, 0);
      final List<DiffLine> added = c.lines
          .where((DiffLine l) => l.kind == DiffKind.added)
          .toList();
      expect(added.map((DiffLine l) => l.newLine), <int>[2, 3]);
      expect(added.every((DiffLine l) => l.oldLine == null), isTrue);
    });

    test('新建文件：整份内容都是新增', () {
      final FileChange? c = FileDiff.compute(
        '/sdcard/new.py',
        '',
        'a = 1\nb = 2\n',
        beforeMissing: true,
      );
      expect(c, isNotNull);
      expect(c!.isNew, isTrue);
      expect(c.additions, 2);
      expect(c.deletions, 0);
      expect(c.lines.first.kind, DiffKind.added);
    });

    test('内容相同：不产生一份空差异', () {
      expect(FileDiff.compute('/sdcard/a.txt', '一样\n', '一样\n'), isNull);
    });

    test('长文件里没变的大段内容折叠成跳过行', () {
      final String before = <String>[for (int i = 0; i < 40; i++) 'line $i']
          .join('\n');
      final String after = '$before\n新增最后一行';
      final FileChange? c = FileDiff.compute('/sdcard/a.txt', before, after);
      expect(c, isNotNull);
      expect(
        c!.lines.any((DiffLine l) => l.kind == DiffKind.skip),
        isTrue,
        reason: '前 40 行没变，不该原样铺满整个面板',
      );
    });

    test('JSON 往返后行号和类型不丢', () {
      final FileChange c = FileDiff.compute(
        '/sdcard/a.txt',
        'a\nb\n',
        'a\nc\n',
      )!;
      final FileChange back = FileChange.fromJson(c.toJson());
      expect(back.path, c.path);
      expect(back.additions, c.additions);
      expect(back.deletions, c.deletions);
      expect(back.lines.length, c.lines.length);
      expect(back.lines.last.kind, c.lines.last.kind);
      expect(back.lines.last.newLine, c.lines.last.newLine);
    });
  });

  test('快照能把 /shared 显示路径映射到真实文件', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('dsh_map');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final File file = File('${tmp.path}/报告.txt');
    await file.writeAsString('旧内容\n');

    final FileChangeSnapshot snap = FileChangeSnapshot(
      candidates: <String>['/shared/报告.txt'],
      before: <String, String>{file.path: '旧内容\n'},
      existedBefore: <String>{file.path},
      resolved: <String, String>{'/shared/报告.txt': file.path},
    );
    await file.writeAsString('新内容\n');
    final List<FileChange> changes = await snap.changes();
    expect(changes, hasLength(1));
    expect(changes.first.path, '/shared/报告.txt', reason: '差异要挂在用户看到的路径上');
    expect(changes.first.additions, 1);
    expect(changes.first.deletions, 1);
  });

  group('FileChangeTracker', () {
    test('file_op write：执行前后读出修改行', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('dsh_diff');
      addTearDown(() => tmp.delete(recursive: true));
      final File file = File('${tmp.path}/note.txt');
      await file.writeAsString('第一行\n旧内容\n第三行\n');

      final FileChangeSnapshot? snap = await FileChangeTracker.snapshot(
        'file_op',
        <String, dynamic>{'action': 'write', 'path': file.path},
      );
      expect(snap, isNotNull);

      await file.writeAsString('第一行\n新内容\n第三行\n');
      final List<FileChange> changes = await snap!.changes();
      expect(changes, hasLength(1));
      expect(changes.first.path, FileChange.normalizePath(file.path));
      expect(changes.first.additions, 1);
      expect(changes.first.deletions, 1);
    });

    test('只读工具不拍快照', () async {
      expect(
        FileChangeTracker.tracks('file_op', <String, dynamic>{
          'action': 'read',
        }),
        isFalse,
      );
      expect(
        FileChangeTracker.tracks('python', <String, dynamic>{'code': '1+1'}),
        isFalse,
        reason: '只读 Python 不该为不存在的修改去读文件',
      );
      expect(
        FileChangeTracker.tracks('python', <String, dynamic>{
          'code': "open('/sdcard/a.txt', 'w').write('x')",
        }),
        isTrue,
      );
    });

    test('从 Python 代码里认出绝对路径，不把接口路径当文件', () {
      final List<String> paths = FileChangeTracker.candidatePaths(
        'python',
        <String, dynamic>{
          'code':
              "open('/sdcard/Download/方案.txt', 'w').write('x')\n"
              "requests.get('https://api.example.com/v1/models')",
        },
      );
      expect(paths, contains('/sdcard/Download/方案.txt'));
      expect(paths.any((String p) => p.contains('/v1/models')), isFalse);
    });
  });
}
