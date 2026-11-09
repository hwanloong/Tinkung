// 文件差异跟踪对新工具（reader / sheller）的适配。
//
// 两个方向的回归都要挡住：
//  · **该跟踪的没跟踪**：用 `reader` 写文件时如果不出差异卡片，
//    用户就失去了"AI 改了我哪个文件"的可回看性 —— 而这是这个应用
//    最核心的信任机制之一；
//  · **不该跟踪的跟踪了**：读一次文件就拍一次全文件快照，等于把
//    `reader` 的"别读整份"彻底抵消掉，而且是**每次读都付**。
import 'dart:io';

import 'package:dsh_agent/core/file_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('什么算"可能写文件"', () {
    test('reader 的读操作不跟踪', () {
      expect(
        FileChangeTracker.tracks('reader', <String, dynamic>{
          'target': '/sdcard/a.txt',
        }),
        isFalse,
        reason: '读一次就拍一次快照，等于把整个文件读两遍',
      );
      expect(
        FileChangeTracker.tracks('reader', <String, dynamic>{
          'op': 'read',
          'target': '/sdcard/a.txt',
        }),
        isFalse,
      );
    });

    test('reader 的写操作跟踪', () {
      expect(
        FileChangeTracker.tracks('reader', <String, dynamic>{
          'op': 'write',
          'target': '/sdcard/a.txt',
        }),
        isTrue,
      );
    });

    test('sheller 跟踪（它能写任何东西）', () {
      expect(FileChangeTracker.tracks('sheller', <String, dynamic>{}), isTrue);
    });

    test('filesearch / geter 不跟踪（它们只读）', () {
      expect(FileChangeTracker.tracks('filesearch', <String, dynamic>{}), isFalse);
      expect(FileChangeTracker.tracks('geter', <String, dynamic>{}), isFalse);
    });
  });

  group('从参数里认路径', () {
    test('reader 的 target 是路径时被认出来', () {
      final List<String> paths = FileChangeTracker.candidatePaths(
        'reader',
        <String, dynamic>{'op': 'write', 'target': '/sdcard/Download/a.md'},
      );
      expect(paths, contains('/sdcard/Download/a.md'));
    });

    test('reader 的 target 是句柄时不会被当成路径', () {
      final List<String> paths = FileChangeTracker.candidatePaths(
        'reader',
        <String, dynamic>{'op': 'write', 'target': 'obj://a'},
      );
      expect(paths, isEmpty, reason: '句柄不是文件系统上的路径');
    });

    test('index.json 这种不带文本扩展名的也要认（写出去的是文本）', () {
      // `/project/data/index.json` 里 json 已经在 _looksTextPath 的名单里，
      // 这里验的是"路径提取不依赖引号"
      final List<String> paths = FileChangeTracker.candidatePaths(
        'reader',
        <String, dynamic>{'target': '/project/data/index.json'},
      );
      expect(paths, contains('/project/data/index.json'));
    });
  });

  group('端到端：写文件后差异能算出来', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dsh_diff');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('旧内容被替换时能算出删除和新增', () async {
      final File f = File('${tmp.path}/note.md');
      await f.writeAsString('第一行\n第二行\n第三行\n');

      final FileChangeSnapshot? snap = await FileChangeTracker.snapshot(
        'reader',
        <String, dynamic>{'op': 'write', 'target': f.path},
      );
      expect(snap, isNotNull, reason: '写文件的调用必须能回看差异');

      await f.writeAsString('第一行\n改过的第二行\n第三行\n');
      final List<FileChange> changes = await snap!.changes();

      expect(changes, hasLength(1));
      expect(changes.first.additions, 1);
      expect(changes.first.deletions, 1);
    });
  });
}
