import 'dart:convert';
import 'dart:io';

import 'platform_files.dart';

/// 一行差异。
///
/// 行号分新旧两列：删除的行只有旧行号，新增的行只有新行号，未变的行两列
/// 都有。这样用户点开修改记录时，看到的不只是“哪段变了”，而是“原来第几行、
/// 现在第几行”。
enum DiffKind {
  context,
  added,
  removed,

  /// 两段修改之间被省略的一大段未变内容。
  ///
  /// 只用于展示：存进会话里的差异已经压缩过，文件开头/结尾几百行没动的
  /// 内容不会把一张卡片撑成一本书。
  skip,
}

class DiffLine {
  const DiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  final DiffKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'text': text,
    if (oldLine != null) 'oldLine': oldLine,
    if (newLine != null) 'newLine': newLine,
  };

  static DiffLine fromJson(Map<String, dynamic> j) => DiffLine(
    kind: DiffKind.values.firstWhere(
      (DiffKind e) => e.name == j['kind'],
      orElse: () => DiffKind.context,
    ),
    text: j['text']?.toString() ?? '',
    oldLine: (j['oldLine'] as num?)?.toInt(),
    newLine: (j['newLine'] as num?)?.toInt(),
  );
}

/// 一次工具调用对某个文件造成的**行级**改动。
///
/// ## 为什么在运行时就把差异算好
///
/// 差异的“旧版本”只存在于修改发生之前。等聊天记录渲染出来时再去读文件，
/// 拿到的已经是新版本了 —— 那永远算不出“删了哪一行”。所以
/// [FileChangeTracker] 在工具执行前后各取一次快照，把差异连同行号一起存进
/// [ToolInvocation]，历史消息也能回看。
class FileChange {
  const FileChange({
    required this.path,
    required this.lines,
    required this.additions,
    required this.deletions,
    this.truncated = false,
    this.isNew = false,
  });

  final String path;
  final List<DiffLine> lines;
  final int additions;
  final int deletions;

  /// 改动太多，只保留了前一段（界面上会说明）。
  final bool truncated;

  /// 修改前文件不存在：整份内容都是新增。
  final bool isNew;

  bool get hasChanges => additions > 0 || deletions > 0;

  /// 用于和文件卡片里的路径对上号。模型偶尔会给出 `//sdcard/...`
  /// 或反斜杠路径，这里统一一次。
  String get pathKey => normalizePath(path);

  static String normalizePath(String p) {
    String out = p.trim().replaceAll('\\', '/');
    while (out.contains('//')) {
      out = out.replaceAll('//', '/');
    }
    if (out.length > 1 && out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    'lines': <Map<String, dynamic>>[for (final DiffLine l in lines) l.toJson()],
    'additions': additions,
    'deletions': deletions,
    if (truncated) 'truncated': true,
    if (isNew) 'isNew': true,
  };

  static FileChange fromJson(Map<String, dynamic> j) => FileChange(
    path: j['path']?.toString() ?? '',
    lines: <DiffLine>[
      for (final dynamic e in (j['lines'] as List?) ?? const <dynamic>[])
        if (e is Map) DiffLine.fromJson(Map<String, dynamic>.from(e)),
    ],
    additions: (j['additions'] as num?)?.toInt() ?? 0,
    deletions: (j['deletions'] as num?)?.toInt() ?? 0,
    truncated: j['truncated'] == true,
    isNew: j['isNew'] == true,
  );
}

/// 行级差异计算。
///
/// 用 Myers 的差分算法（和 git 的默认思路一致），对“改几行”的日常编辑
/// 足够快，也不会把一次移动误报成整段删除 + 整段新增。
class FileDiff {
  const FileDiff._();

  /// 单次比较的行数上限。再大就不做行级比较了 —— 手机内存比“看全”重要，
  /// 而且那种文件多半也不是用户会逐行读的。
  static const int maxLines = 3000;

  /// Myers 的编辑距离上限。超过它说明两边几乎不是同一个文件，硬算会吃光
  /// 内存，直接放弃比较（文件仍然能打开）。
  static const int maxEditDistance = 900;

  /// 生成一份可直接展示、也适合存进 JSON 的差异。
  ///
  /// 返回 null 表示“没有可展示的差异”（内容相同 / 太大 / 编码不可读）。
  static FileChange? compute(
    String path,
    String before,
    String after, {
    bool beforeMissing = false,
  }) {
    final List<String> a = splitLines(before);
    final List<String> b = splitLines(after);
    if (a.length > maxLines || b.length > maxLines) return null;
    if (!beforeMissing && before == after) return null;
    if (beforeMissing && b.isEmpty) return null;

    final List<DiffLine> all = beforeMissing
        ? <DiffLine>[
            for (int i = 0; i < b.length; i++)
              DiffLine(kind: DiffKind.added, text: b[i], newLine: i + 1),
          ]
        : _myers(a, b);
    if (all.isEmpty) return null;

    int additions = 0;
    int deletions = 0;
    for (final DiffLine l in all) {
      if (l.kind == DiffKind.added) additions++;
      if (l.kind == DiffKind.removed) deletions++;
    }
    if (additions == 0 && deletions == 0) return null;

    final (List<DiffLine> compact, bool truncated) = _compact(all);
    return FileChange(
      path: path,
      lines: compact,
      additions: additions,
      deletions: deletions,
      truncated: truncated,
      isNew: beforeMissing,
    );
  }

  /// 按行切分。`\r\n` / `\r` 都先归一化；末尾换行不额外造一个空行。
  static List<String> splitLines(String text) {
    if (text.isEmpty) return <String>[];
    String s = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (s.endsWith('\n')) s = s.substring(0, s.length - 1);
    return s.split('\n');
  }

  /// 只保留改动附近 [context] 行，其余折叠成 [DiffKind.skip]。
  static (List<DiffLine>, bool) _compact(
    List<DiffLine> all, {
    int context = 3,
    int maxStored = 1200,
  }) {
    final List<bool> keep = List<bool>.filled(all.length, false);
    for (int i = 0; i < all.length; i++) {
      if (all[i].kind == DiffKind.context) continue;
      final int from = i - context < 0 ? 0 : i - context;
      final int to = i + context >= all.length ? all.length - 1 : i + context;
      for (int j = from; j <= to; j++) {
        keep[j] = true;
      }
    }

    final List<DiffLine> out = <DiffLine>[];
    int i = 0;
    while (i < all.length) {
      if (keep[i]) {
        out.add(all[i]);
        i++;
        continue;
      }
      int j = i;
      while (j < all.length && !keep[j]) {
        j++;
      }
      final int skipped = j - i;
      if (skipped > 0) {
        out.add(
          DiffLine(
            kind: DiffKind.skip,
            text: '…… 跳过 $skipped 行未变内容 ……',
            oldLine: all[i].oldLine,
            newLine: all[i].newLine,
          ),
        );
      }
      i = j;
    }

    if (out.length <= maxStored) return (out, false);
    final List<DiffLine> cut = out.sublist(0, maxStored);
    cut.add(const DiffLine(kind: DiffKind.skip, text: '…… 改动较多，后面还有内容未显示 ……'));
    return (cut, true);
  }

  /// Myers diff。返回的顺序就是文件顺序，行号已经填好。
  static List<DiffLine> _myers(List<String> a, List<String> b) {
    final int n = a.length;
    final int m = b.length;
    if (n == 0) {
      return <DiffLine>[
        for (int i = 0; i < m; i++)
          DiffLine(kind: DiffKind.added, text: b[i], newLine: i + 1),
      ];
    }
    if (m == 0) {
      return <DiffLine>[
        for (int i = 0; i < n; i++)
          DiffLine(kind: DiffKind.removed, text: a[i], oldLine: i + 1),
      ];
    }

    final int max = n + m;
    final int offset = max + 1;
    final List<int> v = List<int>.filled(2 * max + 3, 0);
    final List<List<int>> trace = <List<int>>[];
    int found = -1;

    for (int d = 0; d <= max; d++) {
      if (d > maxEditDistance) return <DiffLine>[];
      trace.add(List<int>.from(v));
      for (int k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
          x = v[offset + k + 1];
        } else {
          x = v[offset + k - 1] + 1;
        }
        int y = x - k;
        while (x < n && y < m && a[x] == b[y]) {
          x++;
          y++;
        }
        v[offset + k] = x;
        if (x >= n && y >= m) {
          found = d;
          break;
        }
      }
      if (found >= 0) break;
    }
    if (found < 0) return <DiffLine>[];

    final List<DiffLine> reversed = <DiffLine>[];
    int x = n;
    int y = m;
    for (int d = found; d >= 0; d--) {
      final List<int> vd = trace[d];
      final int k = x - y;
      final int prevK;
      if (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      final int prevX = vd[offset + prevK];
      final int prevY = prevX - prevK;

      while (x > prevX && y > prevY) {
        x--;
        y--;
        reversed.add(
          DiffLine(
            kind: DiffKind.context,
            text: a[x],
            oldLine: x + 1,
            newLine: y + 1,
          ),
        );
      }
      if (d > 0) {
        if (x == prevX) {
          y--;
          reversed.add(
            DiffLine(kind: DiffKind.added, text: b[y], newLine: y + 1),
          );
        } else {
          x--;
          reversed.add(
            DiffLine(kind: DiffKind.removed, text: a[x], oldLine: x + 1),
          );
        }
      }
    }
    return reversed.reversed.toList(growable: false);
  }
}

/// 在工具执行前给文件拍一张“文本快照”，执行后算出差异。
///
/// 只处理**可能写文件**的工具（file_op 的 write/append、python、termux、
/// run_shell），而且只读文本：图片/Office 二进制没有“第几行”的概念，
/// 硬算只会得到一堆乱码。
class FileChangeTracker {
  const FileChangeTracker._();

  static const int _maxBytes = 1024 * 1024;
  static const int _maxFiles = 12;

  /// 可能写文件的工具。别的工具（搜索、生图、读文件）不拍快照，省 I/O。
  static bool tracks(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'python':
        final String code = args['code']?.toString() ?? '';
        return _pythonMayWrite.hasMatch(code);
      case 'termux':
      case 'run_shell':
      case 'sheller':
        return true;
      case 'writer':
        // writer 就是"改文件"，差异是它的**主要产出** ——
        // 思考链里要直接把改动片段画出来（见 tool_line.dart 的
        // `_writerDiff`）。没有快照就没有那段片段。
        return true;
      case 'file_op':
        final String action = args['action']?.toString() ?? '';
        return action == 'write' || action == 'append';
      case 'reader':
        // 只有写操作才值得拍快照。读的时候拍一次等于把整个文件
        // 读两遍 —— 而这个工具的存在意义正是"别读整份"。
        return (args['op']?.toString() ?? 'read') == 'write';
      default:
        return false;
    }
  }

  /// Python 代码里出现这些形状时才值得拍快照。
  ///
  /// 每次跑 Python 都在前后读一遍文件不便宜；只读代码（算数、正则、解析）
  /// 不该为“可能没有的修改”付这份 I/O。
  static final RegExp _pythonMayWrite = RegExp(
    r'''(open\s*\([^)]*['"][wax]|'''
    r'''\.write_text\s*\(|\.write_bytes\s*\(|'''
    r'''\.to_csv\s*\(|\.to_excel\s*\(|\.to_json\s*\(|'''
    r'''\.save\s*\(|os\.(rename|replace|remove|unlink|makedirs)\s*\(|'''
    r'''shutil\.|zipfile\.|tarfile\.)''',
  );

  /// 工具执行前调用。返回 null 表示这次调用不需要/没法跟踪。
  static Future<FileChangeSnapshot?> snapshot(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (!tracks(toolName, args)) return null;
    final List<String> paths = candidatePaths(toolName, args);
    if (paths.isEmpty) return null;

    final Map<String, String> before = <String, String>{};
    final Set<String> existed = <String>{};
    final Map<String, String> resolved = <String, String>{};
    for (final String path in paths.take(_maxFiles)) {
      final String normalized = FileChange.normalizePath(path);
      if (normalized.isEmpty) continue;

      // `/shared/a.txt` 这类 Linux 路径在 Android 侧并不存在：
      // 解析成真实文件后再拍快照，否则差异永远算不出来。
      String actual = normalized;
      final String? real = await PlatformFiles.resolve(normalized);
      if (real != null && real.isNotEmpty && !real.startsWith('content://')) {
        actual = real;
      }
      resolved[normalized] = actual;

      final File file = File(actual);
      try {
        final FileStat stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        existed.add(actual);
        if (stat.size > _maxBytes) continue;
        final String? text = await _readText(file);
        if (text != null) before[actual] = text;
      } catch (_) {
        // 读不到就当作不存在：工具可能自己会创建它。
      }
    }

    return FileChangeSnapshot(
      candidates: <String>[
        for (final String p in paths.take(_maxFiles))
          FileChange.normalizePath(p),
      ],
      before: before,
      existedBefore: existed,
      resolved: resolved,
    );
  }

  /// 从参数里找“看起来像文件”的绝对路径。
  ///
  /// 不是所有工具都像 file_op 一样有明确的 `path`：Python / shell 的路径
  /// 藏在代码里。这里只做保守提取 —— 绝对路径、带常见文本扩展名，或者被
  /// 引号完整包住。宁可少抓一个，也不要拿 `/v1/models` 这种接口路径去
  /// 读半天文件。
  static List<String> candidatePaths(
    String toolName,
    Map<String, dynamic> args,
  ) {
    final List<String> out = <String>[];
    void add(String raw) {
      final String p = FileChange.normalizePath(raw);
      if (p.isEmpty || p == '/' || p.startsWith('//')) return;
      if (!p.startsWith('/') && !_drivePath.hasMatch(p)) return;
      if (out.contains(p)) return;
      out.add(p);
    }

    // file_op 的 path 是精确的，不受“有没有扩展名”限制。
    if (toolName == 'file_op') {
      final String p = args['path']?.toString() ?? '';
      if (p.isNotEmpty) add(p);
    }

    // reader 的 target 同理：写文件时它就是要跟踪的那个文件。
    // 只有写操作才走到这里（见 [tracks]），所以不会为读操作多读一遍。
    if (toolName == 'reader') {
      final String p = args['target']?.toString() ?? '';
      // 句柄（obj://a）不是路径，`normalizePath` 之后也不会以 `/` 开头，
      // `add` 会自己挡掉。
      if (p.isNotEmpty && !p.contains('://') && !p.startsWith('@')) add(p);
    }

    // writer 的 path 一定是它要改的那个文件。
    if (toolName == 'writer') {
      final String p = args['path']?.toString() ?? '';
      if (p.isNotEmpty) add(p);
    }

    final List<String> texts = <String>[];
    void collect(dynamic value) {
      if (value is String) {
        if (value.trim().isNotEmpty) texts.add(value);
      } else if (value is Map) {
        for (final dynamic v in value.values) {
          collect(v);
        }
      } else if (value is Iterable) {
        for (final dynamic v in value) {
          collect(v);
        }
      }
    }

    collect(args);
    for (final String text in texts) {
      // 带空格的路径通常会被引号包住；先按引号整体抓一次。
      for (final RegExpMatch m in _quotedPath.allMatches(text)) {
        final String p = m.group(1)?.trim() ?? '';
        final String clean = _clean(p);
        if (_looksTextPath(clean)) add(clean);
      }
      final String unescaped = text.replaceAll(r'\/', '/');
      for (final RegExpMatch m in _absPath.allMatches(unescaped)) {
        final String clean = _clean(m.group(1) ?? '');
        if (_looksTextPath(clean)) add(clean);
      }
    }
    return out;
  }

  static final RegExp _quotedPath = RegExp(r'''['"]([^'"\n]+)['"]''');
  static final RegExp _absPath = RegExp(
    r'''(?<![\w~])(~?/(?!/)[^\[\]()<>"'`\s，。；：、）】]+)''',
  );

  static String _clean(String p) {
    String s = p.trim();
    s = s.replaceAll(RegExp(r'[.,;:!?，。；：、）】»]+$'), '');
    return s;
  }

  static bool _looksTextPath(String path) {
    if (path.length < 5 || path.length > 4096) return false;
    if (!path.startsWith('/') && !_drivePath.hasMatch(path)) return false;
    final int slash = path.lastIndexOf('/');
    final String name = slash < 0 ? path : path.substring(slash + 1);
    final int dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return false;
    final String ext = name.substring(dot + 1).toLowerCase();
    return _textExts.contains(ext);
  }

  static final RegExp _drivePath = RegExp(r'^[A-Za-z]:/');

  static const Set<String> _textExts = <String>{
    'txt',
    'md',
    'markdown',
    'rst',
    'log',
    'csv',
    'tsv',
    'json',
    'jsonl',
    'xml',
    'html',
    'htm',
    'css',
    'scss',
    'sass',
    'less',
    'js',
    'mjs',
    'cjs',
    'ts',
    'tsx',
    'jsx',
    'vue',
    'svelte',
    'py',
    'pyw',
    'dart',
    'java',
    'kt',
    'kts',
    'c',
    'h',
    'cc',
    'cpp',
    'cxx',
    'hpp',
    'cs',
    'go',
    'rs',
    'rb',
    'php',
    'sh',
    'bash',
    'zsh',
    'fish',
    'ps1',
    'bat',
    'cmd',
    'yaml',
    'yml',
    'toml',
    'ini',
    'cfg',
    'conf',
    'properties',
    'gradle',
    'sql',
    'tex',
    'typ',
    'lua',
    'pl',
    'pm',
    'r',
    'swift',
    'scala',
    'groovy',
    'clj',
    'ex',
    'exs',
    'erl',
    'hs',
    'sol',
    'asm',
    's',
    'gitignore',
    'env',
    'lock',
  };

  static Future<String?> _readText(File file) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      if (bytes.isEmpty) return '';
      if (bytes.length > _maxBytes) return null;
      // 含 NUL 的九成是二进制。Office/PDF/图片都在这里被挡掉。
      for (final int b in bytes) {
        if (b == 0) return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// 拍快照的结果。工具执行后调用 [changes] 得到差异。
class FileChangeSnapshot {
  const FileChangeSnapshot({
    required this.candidates,
    required this.before,
    required this.existedBefore,
    this.resolved = const <String, String>{},
  });

  final List<String> candidates;
  final Map<String, String> before;
  final Set<String> existedBefore;

  /// 界面路径 → 设备真实路径。老调用不传时按原路径处理。
  final Map<String, String> resolved;

  Future<List<FileChange>> changes() async {
    final List<FileChange> out = <FileChange>[];
    for (final String path in candidates) {
      if (path.isEmpty) continue;
      final String actual = resolved[path] ?? path;
      final File file = File(actual);
      try {
        final FileStat stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        if (stat.size > FileChangeTracker._maxBytes) continue;
        final String? after = await FileChangeTracker._readText(file);
        if (after == null) continue;

        final String? old = before[actual];
        final bool missingBefore = !existedBefore.contains(actual);
        if (!missingBefore && old == null) continue;
        final FileChange? change = FileDiff.compute(
          path,
          old ?? '',
          after,
          beforeMissing: missingBefore,
        );
        if (change != null) out.add(change);
      } catch (_) {
        // 文件被删了 / 读不了：没有可展示的差异，但工具本身的结果照常。
      }
    }
    return out;
  }
}
