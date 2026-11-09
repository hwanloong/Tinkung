import 'dart:io';

/// 存储占用报告
class StorageReport {
  const StorageReport({
    required this.shotCount,
    required this.shotBytes,
    required this.attachCount,
    required this.attachBytes,
    required this.otherCount,
    required this.otherBytes,
  });

  /// 截图与录屏
  final int shotCount;
  final int shotBytes;

  /// 聊天附件（图片、文件）
  final int attachCount;
  final int attachBytes;

  /// 其它残留
  final int otherCount;
  final int otherBytes;

  int get totalBytes => shotBytes + attachBytes + otherBytes;
  int get totalCount => shotCount + attachCount + otherCount;

  bool get isEmpty => totalCount == 0;

  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

/// 应用自己产生的文件的清点与清理。
///
/// 工作目录布局（`workDir` 是应用的外部私有目录）：
///   `shot_*.png`      截图（screen_capture 工具产出）
///   `rec_*.mp4`       录屏
///   `attachments/`    聊天附件（选图、选文件时复制进来）
///
/// 有一点必须提醒用户：**删掉 attachments 会让历史记录里的图片/文件失效**。
/// 消息本身还在，但附件会显示成破图。所以清理前要明确告知。
class StorageManager {
  const StorageManager._();

  static const String attachDirName = 'attachments';

  /// 这些前缀的文件算「截图与录屏」，可以安全删除（它们只是工具的中间产物）
  static bool _isCapture(String name) =>
      name.startsWith('shot_') || name.startsWith('rec_');

  /// 路径是否落在 attachments 目录里。
  ///
  /// 两种形态都要认：相对路径是 `attachments/a.jpg`（**开头没有斜杠**），
  /// 绝对路径是 `/data/.../attachments/a.jpg`。只判 `contains('/attachments/')`
  /// 会把根目录下的附件全判成"其它" —— 分类标签出错，用户按类别判断
  /// "这个删了会不会破图"时就被误导了。
  static bool _inAttachDir(String path) =>
      path.startsWith('$attachDirName/') || path.contains('/$attachDirName/');

  static Future<StorageReport> scan(String workDir) async {
    int shotCount = 0, shotBytes = 0;
    int attachCount = 0, attachBytes = 0;
    int otherCount = 0, otherBytes = 0;

    final Directory root = Directory(workDir);
    if (!await root.exists()) {
      return const StorageReport(
        shotCount: 0,
        shotBytes: 0,
        attachCount: 0,
        attachBytes: 0,
        otherCount: 0,
        otherBytes: 0,
      );
    }

    try {
      await for (final FileSystemEntity e in root.list(recursive: true)) {
        if (e is! File) continue;
        final int size = await e.length();
        final String name = e.uri.pathSegments.last;

        // 同样先归一化斜杠：Windows 上（测试、桌面调试）路径是 `\`，
        // 不归一化就判不出 attachments，附件会被算进"其它"。
        if (_inAttachDir(e.path.replaceAll(r'\', '/'))) {
          attachCount++;
          attachBytes += size;
        } else if (_isCapture(name)) {
          shotCount++;
          shotBytes += size;
        } else {
          otherCount++;
          otherBytes += size;
        }
      }
    } catch (_) {
      // 目录被并发修改时忽略，返回已统计到的部分
    }

    return StorageReport(
      shotCount: shotCount,
      shotBytes: shotBytes,
      attachCount: attachCount,
      attachBytes: attachBytes,
      otherCount: otherCount,
      otherBytes: otherBytes,
    );
  }

  /// 列出工作目录里的**每一个文件**（新的在前）。
  ///
  /// 存储页用它渲染可勾选的清单 —— 统计只能整类清空，
  /// 而用户想删的往往是其中几个。
  ///
  /// [limit] 兜住"工具跑了一整天、目录里几千个文件"的情况：列表不是浏览器，
  /// 几千行既没人看也拖慢渲染。超出时按修改时间取最近的这些，
  /// 并在调用方那里说明"只显示最近 N 个"。
  ///
  /// 返回值带上 [GenerateScan.total]（扫到的**全部**文件数）：只给一个截断后的
  /// 列表，界面就没法说清"是只有这 300 个，还是还有更多没显示" ——
  /// 用户会以为文件丢了。分开报，两边都是事实。
  static Future<GenerateScan> listFiles(
    String workDir, {
    int limit = 300,
  }) async {
    final List<GeneratedFile> out = <GeneratedFile>[];
    final Directory root = Directory(workDir);
    if (!await root.exists()) {
      return const GenerateScan(files: <GeneratedFile>[], total: 0);
    }

    // 统一成 `/` 再比较：Android 上本来就是 `/`，但**测试和桌面调试跑在
    // Windows 上**，那里 `path` 用的是 `\`。不归一化的话，相对路径会退化成
    // 光秃秃的文件名，子目录一起消失，"attachments 里那几张图"就分不出来了。
    final String rootPath = root.absolute.path.replaceAll(r'\', '/');
    try {
      await for (final FileSystemEntity e in root.list(recursive: true)) {
        if (e is! File) continue;
        try {
          final int size = await e.length();
          final DateTime m = await e.lastModified();
          final String abs = e.absolute.path.replaceAll(r'\', '/');
          final String rel = abs.startsWith('$rootPath/')
              ? abs.substring(rootPath.length + 1)
              : e.uri.pathSegments.last;
          final String name = rel.split('/').last;
          out.add(
            GeneratedFile(
              file: e,
              relPath: rel,
              bytes: size,
              modified: m,
              kind: _inAttachDir(rel)
                  ? 'attachment'
                  : (_isCapture(name) ? 'capture' : 'other'),
            ),
          );
        } catch (_) {
          // 单个文件读不到（并发被删）就跳过
        }
      }
    } catch (_) {
      // 目录被并发修改时忽略，返回已列到的部分
    }

    out.sort(
      (GeneratedFile a, GeneratedFile b) => b.modified.compareTo(a.modified),
    );
    return GenerateScan(
      files: out.length > limit ? out.sublist(0, limit) : out,
      total: out.length,
    );
  }

  static Future<int> _deleteWhere(
    String workDir,
    bool Function(File file) match,
  ) async {
    int removed = 0;
    final Directory root = Directory(workDir);
    if (!await root.exists()) return 0;

    try {
      await for (final FileSystemEntity e in root.list(recursive: true)) {
        if (e is! File) continue;
        if (!match(e)) continue;
        try {
          await e.delete();
          removed++;
        } catch (_) {
          // 单个文件删不掉不影响其它
        }
      }
    } catch (_) {
      // 忽略目录遍历失败
    }
    return removed;
  }

  /// 删除截图与录屏。这些是工具的中间产物，删了不影响历史记录。
  static Future<int> clearCaptures(String workDir) {
    return _deleteWhere(workDir, (File f) {
      final String name = f.uri.pathSegments.last;
      return !_inAttachDir(f.path.replaceAll(r'\', '/')) && _isCapture(name);
    });
  }

  /// 删除聊天附件。
  ///
  /// 注意：历史消息里对这些文件的引用会失效（显示成破图），
  /// 消息本身和文本内容不受影响。
  static Future<int> clearAttachments(String workDir) {
    return _deleteWhere(workDir, (File f) {
      return _inAttachDir(f.path.replaceAll(r'\', '/'));
    });
  }

  /// 清空整个工作目录
  static Future<int> clearAll(String workDir) async {
    int removed = 0;
    final Directory root = Directory(workDir);
    if (!await root.exists()) return 0;

    try {
      await for (final FileSystemEntity e in root.list()) {
        try {
          await e.delete(recursive: true);
          removed++;
        } catch (_) {
          // 忽略
        }
      }
    } catch (_) {
      // 忽略
    }
    return removed;
  }

  /// 自动清理超过 [olderThan] 的截图与录屏。
  ///
  /// 这两类是工具的**中间产物**（给模型看完就没用了），历史记录不引用它们，
  /// 所以可以放心按时间自动清理，不需要每次都问用户。
  /// 聊天附件不在此列 —— 那是用户自己发的内容，只在用户明确要求时才删。
  static Future<int> clearOldCaptures(
    String workDir,
    Duration olderThan,
  ) async {
    final DateTime cutoff = DateTime.now().subtract(olderThan);
    return _deleteWhere(workDir, (File f) {
      final String name = f.uri.pathSegments.last;
      if (_inAttachDir(f.path.replaceAll(r'\', '/'))) return false;
      if (!_isCapture(name)) return false;
      try {
        return f.statSync().modified.isBefore(cutoff);
      } catch (_) {
        return false;
      }
    });
  }
}

/// 工作目录里的**一个文件**（存储页要能逐个看、逐个删）。
///
/// 为什么要逐个列出来，而不是只给"截图 12 个 / 附件 5 个"这种统计：
/// 统计只能让你**整类清空**，而用户真正想删的往往是**其中几个**
/// ——"这个 300MB 的录屏不要了，那几个截图留着"。
/// 只有列出文件，才有"选择"这件事。
class GeneratedFile {
  const GeneratedFile({
    required this.file,
    required this.relPath,
    required this.bytes,
    required this.modified,
    required this.kind,
  });

  final File file;

  /// 相对 workDir 的路径（列表里显示这个，比一长串绝对路径好认）。
  final String relPath;
  final int bytes;
  final DateTime modified;

  /// `capture`（截图/录屏，工具的中间产物，删了没影响）/
  /// `attachment`（聊天附件，**删了历史里的图会变成破图**）/
  /// `other`（其它，可能是 agent 给你生成的成果，删前看一眼名字）。
  final String kind;

  String get name => relPath.split('/').last;

  String get kindLabel => switch (kind) {
    'capture' => '截图/录屏',
    'attachment' => '聊天附件',
    _ => '其它',
  };
}

/// [StorageManager.listFiles] 的结果：**显示用的列表** + **实际扫到的总数**。
///
/// 两者分开是因为列表有条数上限。界面要能说出"共 812 个，这里显示最近 300 个"，
/// 而不是让用户对着 300 行猜"剩下的去哪了"。
class GenerateScan {
  const GenerateScan({required this.files, required this.total});

  /// 按修改时间倒序、已按 limit 截断的清单。
  final List<GeneratedFile> files;

  /// 工作目录里实际有多少个文件（没有被截断的那个数）。
  final int total;

  /// 有没有因为上限而没列出来。
  bool get capped => total > files.length;
}

/// 把这些文件删掉，返回**真正删掉了几个**和**实际释放的字节数**。
///
/// 逐个删、逐个计数：某个文件删不掉（被占用、权限）不该让整批停下来，
/// 而"删了几个、释放了多少"必须是真数出来的 —— 拿勾选数量去汇报，
/// 用户会以为白删的和真的删掉的一样多。
Future<({int count, int freed})> deleteMany(List<GeneratedFile> files) async {
  int count = 0;
  int freed = 0;
  for (final GeneratedFile f in files) {
    try {
      final int size = await f.file.length();
      await f.file.delete();
      count++;
      freed += size;
    } catch (_) {
      // 删不掉就跳过（它在别人手里，或者已经不在了）
    }
  }
  return (count: count, freed: freed);
}
