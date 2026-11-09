import 'dart:io';

import 'package:dsh_agent/core/storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 存储页「文件清单」的底层测试。
///
/// 为什么值得单测：这一层直接**删用户的文件**。列表分类错了，用户会以为
/// "删这些没问题"（把聊天附件当成截图的中间产物），删完发现历史消息全成破图；
/// 计数错了，用户会以为删干净了其实还剩一堆。分类、截断计数、真实删除数
/// 这三件事都必须在没有界面的情况下也能验证。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('priv_storage_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void write(String rel, int bytes) {
    final File f = File(
      '${root.path}${Platform.pathSeparator}'
      '${rel.replaceAll('/', Platform.pathSeparator)}',
    );
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 0));
  }

  group('StorageManager.listFiles', () {
    test('列出每个文件、分类正确、总数是扫描到的真实数量', () async {
      write('shot_20261016.png', 120);
      write('rec_20261016.mp4', 300);
      write('attachments/photo.jpg', 40);
      write('notes/plan.md', 10);

      final GenerateScan scan = await StorageManager.listFiles(root.path);

      expect(scan.total, 4);
      expect(scan.files.length, 4);
      expect(scan.capped, isFalse);

      final Map<String, String> kinds = <String, String>{
        for (final GeneratedFile f in scan.files) f.relPath: f.kind,
      };
      // 根目录下的 attachments/ 也要认出来 —— 这是之前会漏判的那条。
      expect(kinds['attachments/photo.jpg'], 'attachment');
      expect(kinds['shot_20261016.png'], 'capture');
      expect(kinds['rec_20261016.mp4'], 'capture');
      expect(kinds['notes/plan.md'], 'other');
    });

    test('相对路径保留子目录，不是只剩文件名', () async {
      write('notes/deep/plan.md', 10);
      final GenerateScan scan = await StorageManager.listFiles(root.path);
      expect(scan.files.single.relPath, 'notes/deep/plan.md');
      expect(scan.files.single.name, 'plan.md');
    });

    test('超过上限时截断，但总数仍是真实值', () async {
      for (int i = 0; i < 7; i++) {
        write('shot_$i.png', 1);
      }
      final GenerateScan scan = await StorageManager.listFiles(
        root.path,
        limit: 3,
      );
      expect(scan.files.length, 3);
      expect(scan.total, 7);
      expect(scan.capped, isTrue);
    });

    test('目录不存在时返回空，不抛异常', () async {
      final GenerateScan scan = await StorageManager.listFiles(
        '${root.path}/nope',
      );
      expect(scan.total, 0);
      expect(scan.files, isEmpty);
    });
  });

  group('deleteMany', () {
    test('删掉勾选的文件，返回实际删除数与释放的字节', () async {
      write('shot_a.png', 100);
      write('shot_b.png', 50);
      write('attachments/keep.jpg', 30);

      final GenerateScan scan = await StorageManager.listFiles(root.path);
      final List<GeneratedFile> picked = scan.files
          .where((GeneratedFile f) => f.kind == 'capture')
          .toList();

      final ({int count, int freed}) r = await deleteMany(picked);

      expect(r.count, 2);
      expect(r.freed, 150);
      // 没勾的必须还在。
      expect(
        File(
          '${root.path}${Platform.pathSeparator}attachments'
          '${Platform.pathSeparator}keep.jpg',
        ).existsSync(),
        isTrue,
      );
      expect((await StorageManager.listFiles(root.path)).total, 1);
    });

    test('文件已经不在时不虚报：计数按真正删掉的算', () async {
      write('shot_gone.png', 10);
      final GenerateScan scan = await StorageManager.listFiles(root.path);

      // 模拟"勾完之后别处把它删了"。
      scan.files.single.file.deleteSync();

      final ({int count, int freed}) r = await deleteMany(scan.files);
      expect(r.count, 0);
      expect(r.freed, 0);
    });
  });

  group('StorageManager.scan', () {
    test('按类统计的字节数与清单一致', () async {
      write('shot_a.png', 100);
      write('attachments/p.jpg', 30);
      write('other.bin', 7);

      final StorageReport r = await StorageManager.scan(root.path);
      expect(r.shotCount, 1);
      expect(r.shotBytes, 100);
      expect(r.attachCount, 1);
      expect(r.attachBytes, 30);
      expect(r.otherCount, 1);
      expect(r.otherBytes, 7);
    });
  });
}
