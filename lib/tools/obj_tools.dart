import 'dart:io';

import '../core/models.dart';
import '../core/obj_store.dart';
import '../core/resolver.dart';
import '../core/varbank.dart';
import '../core/terminal_session.dart';
import '../core/model_paths.dart';
import 'python_tool.dart';
import 'risk.dart';
import 'tool.dart';

/// 目录遍历的公共部分：`filesearch` 用它，`reader` 列目录也用它。
///
/// 为什么自己走 `Directory.list` 而不是拼一条 `find` 交给 shell：
/// · 不想为一个"列文件"动用 Shizuku（那是系统级权限，用在这里太重）；
/// · `find` 的输出得再解析一遍，而路径里带空格/换行的文件很常见；
/// · 这条路径要能在**没有 shell 权限**时也работать（比如用户还没授权）。
class _Walk {
  const _Walk._();

  /// 用来挡掉 `node_modules` 这类"一进去就出不来"的目录。
  static const Set<String> _skipDirs = <String>{
    '.git',
    '.svn',
    '.hg',
    'node_modules',
    '__pycache__',
    '.gradle',
    '.dart_tool',
    '.idea',
    'build',
    'dist',
    '.venv',
    'venv',
  };

  static bool shouldSkip(String name, List<String> exclude) {
    if (_skipDirs.contains(name)) return true;
    for (final String e in exclude) {
      if (e.isEmpty) continue;
      if (name == e) return true;
      if (e.startsWith('*') && name.endsWith(e.substring(1))) return true;
    }
    return false;
  }

  static bool matches(String name, String pattern, bool useRegex) {
    if (pattern.isEmpty || pattern == '*') return true;
    if (useRegex) {
      try {
        return RegExp(pattern, caseSensitive: false).hasMatch(name);
      } catch (_) {
        return name.contains(pattern);
      }
    }
    if (!pattern.contains('*') && !pattern.contains('?')) {
      return name.toLowerCase().contains(pattern.toLowerCase());
    }
    // glob → 正则。只支持 `*` 和 `?`，因为它们覆盖了绝大部分需求，
    // 而完整 glob（`[a-z]`、`**`）的边界情况多到不值当。
    final String re = pattern
        .replaceAll('.', r'\.')
        .replaceAll('*', '.*')
        .replaceAll('?', '.');
    try {
      return RegExp('^$re\$', caseSensitive: false).hasMatch(name);
    } catch (_) {
      return name.toLowerCase().contains(pattern.toLowerCase());
    }
  }
}

/// 一条搜索结果。
class _Hit {
  _Hit(this.path, this.size, this.modified, this.isDir);

  final String path;
  final int size;
  final DateTime modified;
  final bool isDir;
}

/// **浏览器式列目录 / 找文件**：结构化、分页、不灌上下文。
///
/// 存在的理由：模型以前找文件只能"猜路径 → `file_op list` → 猜错再猜"，
/// 或者 `run_shell` 拼 `find`。前者烧轮次，后者要 Shizuku 权限、
/// 而且 `find` 一跑就是几千行。
///
/// 这个工具一次给一页（默认 50 条），带 `next_cursor`，模型想看下一页
/// 就再要一次。**它不会一次把整个盘的结果塞进上下文。**
class FileSearchTool extends AgentTool {
  const FileSearchTool();

  @override
  String get name => 'filesearch';

  @override
  String get title => '找文件';

  @override
  String get description =>
      '在目录里找文件，返回结构化结果（路径 / 大小 / 修改时间），分页。\n'
      '什么时候用：用户说"手机里有个 xx 文件"、需要按名字找日志/下载/截图、'
      '或者要确认某个目录里到底有什么。\n'
      '参数：\n'
      '· root：起始目录，如 /sdcard/Download\n'
      '· pattern：文件名匹配。`*.log`（通配）、以 `\\.json` 结尾的正则'
      '（mode=regex）、'
      '或 `报告`（模糊，默认 mode=fuzzy）\n'
      '· max_depth：往下找几层，默认 3，上限 12\n'
      '· limit：这一页最多几条，默认 50，上限 200\n'
      '· cursor：上一页返回的 next_cursor，用来翻页\n'
      '结果超过一页时会给你 next_cursor —— **别自己调大 limit 去一次拉完**，'
      '按页看就够了。\n'
      '整个结果也会存成一个句柄，需要总览时可以引用它。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'root': <String, dynamic>{
        'type': 'string',
        'description': '起始目录，如 /sdcard/Download。默认当前工作目录。',
      },
      'pattern': <String, dynamic>{
        'type': 'string',
        'description': '文件名匹配。默认 *（按类型/大小筛时可以不传）。',
      },
      'mode': <String, dynamic>{
        'type': 'string',
        'enum': <String>['glob', 'regex', 'fuzzy'],
        'description':
            'pattern 的匹配方式。glob=通配（默认），regex=正则，'
            'fuzzy=名字里含这个词。',
      },
      'max_depth': <String, dynamic>{
        'type': 'integer',
        'description': '向下遍历的层数，默认 3，上限 12。',
      },
      'limit': <String, dynamic>{
        'type': 'integer',
        'description': '每页条数，默认 50，上限 200。',
      },
      'cursor': <String, dynamic>{
        'type': 'string',
        'description': '上一页结果里的 next_cursor，原样传回来即可翻页。',
      },
      'exclude': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description': '要跳过的目录名。常见的大目录（node_modules/.git）默认已跳过。',
      },
      'min_size': <String, dynamic>{
        'type': 'integer',
        'description': '只看大于这么多字节的文件。',
      },
      'modified_within_hours': <String, dynamic>{
        'type': 'integer',
        'description': '只看最近这么多小时内改过的文件。找"刚下的那个"很有用。',
      },
    },
    'required': <String>[],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) {
    final String root = args.str('root', fallback: '.');
    final String p = args.str('pattern', fallback: '*');
    return '$root 里的 $p';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    String root = args.str('root').trim();
    if (root.isEmpty) root = ctx.workDir;
    final int maxDepth = args.intVal('max_depth', fallback: 3).clamp(0, 12);
    final int limit = args.intVal('limit', fallback: 50).clamp(1, 200);
    final String pattern = args.str('pattern', fallback: '*');
    final String mode = args.str('mode', fallback: 'glob');
    final List<String> exclude = args.listVal('exclude');
    final int minSize = args.intVal('min_size', fallback: 0);
    final int withinHours = args.intVal('modified_within_hours', fallback: 0);

    final Directory dir = Directory(root);
    if (!await dir.exists()) {
      return '目录不存在：$root\n'
          '（如果是想找它在哪，改用 `root="/sdcard"` 并缩小 pattern。）';
    }

    final int offset = decodeCursor(args.str('cursor'));
    final DateTime? since = withinHours > 0
        ? DateTime.now().subtract(Duration(hours: withinHours))
        : null;

    final List<_Hit> hits = <_Hit>[];
    int scanned = 0;
    int skipped = 0;
    bool depthCapped = false;

    try {
      await for (final FileSystemEntity e in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        scanned++;
        if (scanned > 200000) {
          depthCapped = true;
          break;
        }

        final String rel = _relative(root, e.path);
        // 层级 = 相对路径里有几个分隔符
        final int depth = '/'.allMatches(rel).length;
        if (depth > maxDepth) {
          skipped++;
          continue;
        }

        // 跳过逻辑要按**路径的每一级**判断，不能只看文件名：
        // `node_modules/pkg/index.js` 的文件名是 index.js，
        // 只看最后一段的话整个 node_modules 都会被走一遍。
        final List<String> parts = rel.split('/');
        bool inSkippedDir = false;
        for (final String part in parts) {
          if (part.isEmpty) continue;
          if (_Walk.shouldSkip(part, exclude)) {
            inSkippedDir = true;
            break;
          }
        }
        if (inSkippedDir) continue;

        final String name = e.path.split(RegExp(r'[/\\]')).last;

        final bool isDir = e is Directory;
        if (!isDir && !_Walk.matches(name, pattern, mode == 'regex')) {
          continue;
        }
        // 目录只在 pattern 明确想要时列出来（默认 `*` 时列目录会很吵）
        if (isDir &&
            pattern != '*' &&
            !_Walk.matches(name, pattern, mode == 'regex')) {
          continue;
        }

        int size = 0;
        DateTime modified;
        try {
          final FileStat st = await e.stat();
          size = st.size;
          modified = st.modified;
        } catch (_) {
          modified = DateTime.fromMillisecondsSinceEpoch(0);
        }

        if (!isDir && size < minSize) continue;
        if (since != null && modified.isBefore(since)) continue;

        hits.add(_Hit(e.path, size, modified, isDir));
      }
    } catch (e) {
      return '遍历失败：$e\n'
          '（可能是权限不足。到 /sdcard 下找文件需要「所有文件访问」权限。）';
    }

    // 新改的排前面：找"刚才下的那个文件"时，按名字排序毫无帮助。
    hits.sort((_Hit a, _Hit b) {
      final int byTime = b.modified.compareTo(a.modified);
      return byTime != 0 ? byTime : a.path.compareTo(b.path);
    });

    if (hits.isEmpty) {
      return '没有匹配的文件（扫了 $scanned 项'
          '${skipped > 0 ? '，跳过 $skipped 项超深层的' : ''}）。\n'
          '可以试试：放宽 pattern（用 `*`）、调大 max_depth、'
          '或者换一个 root。';
    }

    final List<_Hit> page = hits.skip(offset).take(limit).toList();
    final bool more = offset + page.length < hits.length;

    final StringBuffer sb = StringBuffer();
    sb.writeln(
      '在 $root 找到 ${hits.length} 项，这是第 ${offset + 1}–'
      '${offset + page.length} 项：',
    );
    for (final _Hit h in page) {
      final String size = h.isDir
          ? '  <dir>  '
          : ObjStore.humanBytes(h.size).padLeft(8);
      sb.writeln('$size  ${h.path}');
    }

    if (more) {
      sb.writeln();
      sb.writeln('下一页：cursor="${encodeCursor(offset + page.length)}"');
    }
    if (depthCapped) {
      sb.writeln('（扫到 20 万项就停了，结果可能不全 —— 缩小 root 或 pattern 更可靠）');
    }

    sb.writeln();
    sb.writeln('要读其中某个文件的内容：`reader` 传 target="<路径>"（默认只回摘要）。');

    // 结果整体也存成句柄：模型想看"全部清单"时可以引用一次，
    // 而不是反复翻页。
    final Obj o = await ObjStore.instance.putText(
      sb.toString(),
      type: ObjType.text,
    );
    return '${sb.toString()}（本次结果也存为 ${o.uri}）';
  }

  static String _relative(String root, String path) {
    String p = path;
    if (p.startsWith(root)) {
      p = p.substring(root.length);
      if (p.startsWith('/') || p.startsWith('\\')) p = p.substring(1);
    }
    return p.replaceAll('\\', '/');
  }

  /// 游标就是偏移量的 base64。
  ///
  /// 用 base64 而不是裸数字：游标是给模型**原样传回**的，裸数字很容易
  /// 被它当成"页数"自己加一（`cursor=2` 其实表示跳过 2 条）。
  static String encodeCursor(int offset) =>
      // 编码后固定 8 字符，短、也不像"页号"
      'c${offset.toRadixString(36)}';

  static int decodeCursor(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return 0;
    if (!s.startsWith('c')) return int.tryParse(s) ?? 0;
    return int.tryParse(s.substring(1), radix: 36) ?? 0;
  }
}

/// **直接读写文件**：默认只回摘要，范围读、grep、写入。
///
/// 和 `file_op` 的分工：`file_op` 是"一整个文件拿过来/丢过去"，
/// 这个工具是"只碰我需要的那一段"。**大部分任务应该用这个** ——
/// 拿整个文件进上下文，代价随文件大小线性增长，而 90% 的任务
/// 只需要其中的几段。
class ReaderTool extends AgentTool {
  const ReaderTool();

  @override
  String get name => 'reader';

  @override
  String get title => '读文件';

  @override
  String get description =>
      '读 / 写文件，默认只返回摘要，按需取片段。\n'
      '**读（op=read，默认）**：默认给摘要（大小、行数、开头、结构索引），'
      '不返回全文。要正文就指定 range，或 mode=grep 搜关键词。\n'
      '  · target：路径或句柄（obj://a）\n'
      '  · range：{start, end} 行号（1 起算，闭区间）；也可以直接传 offset/limit\n'
      '  · mode：summary（默认）/ raw（按 range 取正文）/ outline（目录索引）/ '
      'grep（搜关键词，返回命中行 + 上下文）\n'
      '  · grep：{pattern, context}\n'
      '  · save_to：把读到的这一段**存进变量库**（传变量名），之后用 {{名字}} 引用，'
      '不用再读一遍文件\n'
      '**写（op=write）**：\n'
      '  · write_mode：overwrite（覆盖）/ append（追加）/ replace_range（替换某几行）\n'
      '  · content 支持引用，如 "{{obj://a:0-500}}" —— 大内容会被流式展开写入，\n'
      '    不会先变成一整个字符串。\n'
      '**为什么默认不给全文**：一个 40 万字的文件塞进上下文，不仅贵，'
      '还会把真正有用的东西挤出去。先看摘要，再精确地取。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'op': <String, dynamic>{
        'type': 'string',
        'enum': <String>['read', 'write'],
        'description': '默认 read。',
      },
      'target': <String, dynamic>{
        'type': 'string',
        'description': '文件路径，或句柄 obj://a。',
      },
      'mode': <String, dynamic>{
        'type': 'string',
        'enum': <String>['summary', 'raw', 'outline', 'grep'],
        'description': 'read 的模式，默认 summary。',
      },
      'range': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'start': <String, dynamic>{
            'type': 'integer',
            'description': '起始行，1 起算',
          },
          'end': <String, dynamic>{'type': 'integer', 'description': '结束行，含'},
        },
        'description': '行范围。别一次要几千行 —— 单次上限 2000 行。',
      },
      'offset': <String, dynamic>{
        'type': 'integer',
        'description': 'range 的简写：起始行（1 起算）。',
      },
      'limit': <String, dynamic>{
        'type': 'integer',
        'description': 'range 的简写：读多少行。',
      },
      'grep': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pattern': <String, dynamic>{
            'type': 'string',
            'description': '正则或关键词',
          },
          'context': <String, dynamic>{
            'type': 'integer',
            'description': '命中行前后各留几行，默认 2',
          },
          'fixed': <String, dynamic>{
            'type': 'boolean',
            'description': 'true 时按纯文本匹配，不当正则',
          },
        },
        'description': 'mode=grep 时用。',
      },
      'write_mode': <String, dynamic>{
        'type': 'string',
        'enum': <String>['overwrite', 'append', 'replace_range'],
        'description': 'write 时用，默认 overwrite。',
      },
      'content': <String, dynamic>{
        'type': 'string',
        'description': 'write 要写入的内容，支持 {{obj://a}} 引用。',
      },
      'dry_run': <String, dynamic>{
        'type': 'boolean',
        'description': 'true 时只报告"会写多少字节"，不真的落盘。',
      },
      'save_to': <String, dynamic>{
        'type': 'string',
        'description':
            'read 时可选：把这次读到的内容存进变量库，用这个变量名。'
            '之后写 {{名字}} 就能引用它，不必再读一遍文件。',
      },
    },
    'required': <String>['target'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String op = args.str('op', fallback: 'read');
    final String target = args.str('target');
    if (op != 'write') return RiskAssessment.safe;

    final String mode = args.str('write_mode', fallback: 'overwrite');
    return RiskAssessment(RiskLevel.caution, <String>[
      mode == 'overwrite' ? '覆盖写入 $target（原内容会丢失）' : '修改 $target',
    ]);
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String op = args.str('op', fallback: 'read');
    final String target = args.str('target');
    if (op == 'write') {
      return '写 ${_short(target)}（${args.str('write_mode', fallback: 'overwrite')}）';
    }
    final String mode = args.str('mode', fallback: 'summary');
    final Map<String, dynamic> range = args.mapVal('range');
    if (range.isNotEmpty) {
      return '读 ${_short(target)} 第 ${range['start']}–${range['end']} 行';
    }
    if (mode == 'grep') {
      return '在 ${_short(target)} 里搜 ${args.mapVal('grep')['pattern'] ?? ''}';
    }
    return '看 ${_short(target)} 的${{"summary": "摘要", "outline": "结构", "raw": "内容"}[mode] ?? mode}';
  }

  static String _short(String s) =>
      s.length > 48 ? '${s.substring(0, 48)}…' : s;

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String op = args.str('op', fallback: 'read');
    final String target = args.str('target').trim();
    if (target.isEmpty) return '错误：target 不能为空';

    if (op == 'write') return _write(ctx, args, target);
    return _read(ctx, args, target);
  }

  Future<String> _read(
    ToolContext ctx,
    Map<String, dynamic> args,
    String target,
  ) async {
    final ObjStore store = ObjStore.instance;

    // target 可以是句柄，也可以是普通路径。
    // 句柄走对象池（已经有摘要缓存），路径即时读。
    final Obj? existing = store.lookup(target);
    // 相对路径按**当前工作目录**解释。绝对路径、句柄原样返回。
    final String resolved = existing != null
        ? target
        : resolveModelPath(target, baseDir: ctx.workDir);
    final Obj? o = existing ?? await store.fromPath(resolved);
    if (o == null) {
      return '找不到 $target。\n'
          '· 如果它在当前工作空间里，直接用**相对路径**，例如 `notes/x.md`\n'
          '· 否则用 `filesearch` 找一下具体在哪\n'
          '· 或者它是个句柄，但已经过期了 —— 重新 define 一次';
    }

    final String mode = args.str('mode', fallback: 'summary');

    if (mode == 'grep') {
      final Map<String, dynamic> g = args.mapVal('grep');
      final String pattern = g['pattern']?.toString() ?? args.str('pattern');
      if (pattern.isEmpty) return '错误：mode=grep 需要 grep.pattern';

      final List<GrepHit> hits = await store.grep(
        o,
        pattern,
        context: (g['context'] as num?)?.toInt() ?? 2,
        fixed: g['fixed'] == true,
      );
      if (hits.isEmpty) {
        return '$target 里没有匹配 `$pattern` 的行。\n'
            '（试过的是正则匹配；如果模式里有多余的元字符，加 fixed=true 按纯文本搜。）';
      }

      final StringBuffer sb = StringBuffer();
      sb.writeln('在 $target 里命中 ${hits.length} 处：');
      for (final GrepHit h in hits) {
        sb.writeln('--- 第 ${h.line} 行 ---');
        for (int i = 0; i < h.before.length; i++) {
          sb.writeln('  ${h.line - h.before.length + i}: ${h.before[i]}');
        }
        sb.writeln('> ${h.line}: ${h.text}');
        for (int i = 0; i < h.after.length; i++) {
          sb.writeln('  ${h.line + 1 + i}: ${h.after[i]}');
        }
      }
      final Resolved packed = await packOutput(sb.toString());
      final String saved = _maybeSave(args, sb.toString(), '检索结果');
      return '${packed.text}$saved';
    }

    if (mode == 'outline') {
      final List<String> marks = await store.outlineLines(o);
      if (marks.isEmpty) {
        return '$target 里没找到明显的分节标题（markdown #、def/class/func、'
            '编号、全大写行）。\n可能是一整段散文 —— 直接用 grep 找关键词。';
      }
      final StringBuffer sb = StringBuffer(
        '$target 的结构（共 ${marks.length} 处）：\n',
      );
      for (final String m in marks.take(80)) {
        sb.writeln(m);
      }
      if (marks.length > 80) sb.writeln('…（还有 ${marks.length - 80} 处）');
      sb.writeln('\n用 `reader` 传 mode="raw" + range 读其中某一段。');
      return sb.toString();
    }

    // ---- raw：按范围取正文 ----
    final Map<String, dynamic> range = args.mapVal('range');
    final int offset = args.intVal('offset', fallback: 0);
    final int limit = args.intVal('limit', fallback: 0);
    final int start =
        (range['start'] as num?)?.toInt() ?? (offset > 0 ? offset : 1);
    final int end =
        (range['end'] as num?)?.toInt() ?? (limit > 0 ? start + limit - 1 : 0);

    if (mode == 'raw') {
      if (start <= 1 && end <= 0) {
        // 明说要正文又没给范围：给开头一段，并说清这是"开头"，
        // 而不是装作这就是全文。
        final int lines = await store.lineCount(o);
        final String head = await store.readRange(o, start: 1, end: 200);
        final Resolved packed = await packOutput(head);
        if (lines > 200) {
          return '${packed.text}\n\n'
              '（这是第 1–200 行，全文件共 $lines 行。'
              '要别的地方就传 range。）';
        }
        return packed.text;
      }

      final int lines = await store.lineCount(o);
      final String body = await store.readRange(o, start: start, end: end);
      if (body.isEmpty) {
        return '第 $start–${end > 0 ? end : start + ObjStore.maxRangeLines - 1} 行没有内容'
            '（文件共 $lines 行，可能已经到底了）。';
      }
      final int shownEnd = end > 0 ? end : start + ObjStore.maxRangeLines - 1;
      final Resolved packed = await packOutput(body);
      // 可选：把这一段存进变量库。存的是**原文**（不是打包后的文本），
      // 这样之后 `{{名字}}` 展开出来就是干净的文件片段。
      final String saved = _maybeSave(args, body, '第 $start–$shownEnd 行');
      return '【第 $start–$shownEnd 行，共 $lines 行】\n${packed.text}\n'
          '${shownEnd < lines ? '（要继续读就 offset=${shownEnd + 1}）' : '（已到文件末尾）'}'
          '$saved';
    }

    // ---- summary（默认）----
    final String s = await store.summary(o);
    // 把临时对象也登记一次：模型接下来很可能要按句柄继续读，
    // 没句柄的话它只能重新传一遍路径。
    if (existing == null) {
      final Obj reg = await store.putFile(o.source!);
      return '$s\n（句柄：${reg.uri} —— 后续用 target="${reg.uri}" 就行）';
    }
    return s;
  }

  /// `save_to` 的落点：把这次读到的正文存进变量库。
  ///
  /// 返回一句追加在结果里的话（空串 = 没要求保存）。
  ///
  /// ## 为什么读文件要能顺手存
  ///
  /// "读第 24–90 行 → 后面反复用"是个高频组合。不存的话，模型每用一次
  /// 就得再 `reader` 读一遍文件（一次几十毫秒 + 一次工具往返），而且
  /// 文件一旦被改过，第二次读到的就**不是同一段内容**了。
  /// 存成变量之后，引用的是当时那一份，语义稳定。
  String _maybeSave(Map<String, dynamic> args, String body, String what) {
    final String name = args.str('save_to').trim();
    if (name.isEmpty || body.trim().isEmpty) return '';
    final String? err = VarBankStore.instance.set(
      name,
      body,
      note: what,
    );
    if (err != null) return '\n（没能存进变量库：$err）';
    return '\n已把$what存成 `{{$name}}`（${body.length} 字符），'
        '之后直接引用它，不用再读这个文件。';
  }

  Future<String> _write(
    ToolContext ctx,
    Map<String, dynamic> args,
    String target,
  ) async {
    final String writeMode = args.str('write_mode', fallback: 'overwrite');
    final bool dryRun = args.boolVal('dry_run', fallback: false);

    // 相对路径按当前工作目录解释（见 resolveModelPath）。
    target = resolveModelPath(target, baseDir: ctx.workDir);

    // 内容里的引用**在写入前**展开。注意这里用 render 模式：
    // 写文件要的就是文本本身。展开上限按 inlineLimit 卡，
    // 超了会拿到摘要而不是全文 —— 那种情况下宁可报错让模型分段写，
    // 也不能悄悄写进去一个摘要。
    final Resolved content = await Resolver.resolve(
      args.str('content'),
      mode: ResolveMode.render,
    );
    if (content.truncated) {
      return '要写入的内容里有引用超过单次展开上限，'
          '已经被换成摘要了。**这样写进去会把摘要当成正文**，所以没有执行。\n'
          '请改成写一段具体的范围，例如 "{{obj://a:1-500}}"，分几次写完。\n'
          '${content.warnings.join('\n')}';
    }

    final String text = content.text;
    final int bytes = text.length;

    if (dryRun) {
      return '会写入 $bytes 个字符到 $target（$writeMode），没有真的写。';
    }

    final File f = File(target);
    try {
      if (writeMode == 'append') {
        await f.parent.create(recursive: true);
        await f.writeAsString(text, mode: FileMode.append);
        return '已追加 $bytes 个字符到 $target（现有 ${await f.length()} 字节）。\n'
            '检查一下：`reader` 传 mode="raw" 加 range 读末尾几行。';
      }

      if (writeMode == 'replace_range') {
        final Map<String, dynamic> range = args.mapVal('range');
        final int start = (range['start'] as num?)?.toInt() ?? 1;
        final int end = (range['end'] as num?)?.toInt() ?? start;
        if (!await f.exists()) return '文件不存在：$target（replace_range 需要先有文件）';

        final List<String> lines = await f.readAsLines();
        if (start < 1 || start > lines.length + 1) {
          return '起始行 $start 超出范围（文件共 ${lines.length} 行）。';
        }
        final int from = start - 1;
        final int to = end.clamp(start, lines.length);
        final List<String> next = <String>[
          ...lines.sublist(0, from),
          ...text.split('\n'),
          ...lines.sublist(to),
        ];
        await f.writeAsString(next.join('\n'));
        return '已把第 $start–$to 行替换成 ${text.split('\n').length} 行'
            '（文件现在共 ${next.length} 行）。';
      }

      await f.parent.create(recursive: true);
      await f.writeAsString(text);
      return '已写入 $bytes 个字符到 $target（共 ${await f.length()} 字节）。\n'
          '改动会显示在这次工具调用的差异卡片里。';
    } catch (e) {
      final String msg = e.toString();
      if (msg.contains('errno = 1') ||
          msg.contains('Operation not permitted')) {
        return '没有权限写 $target。\n\n'
            '这是 Android 的分区存储限制，不是路径写错了：往 /sdcard 这类公共目录'
            '写需要「所有文件访问」权限。\n'
            '请让用户去「设置 → 应用 → 特殊权限 → 所有文件访问」里给本应用授权，'
            '然后重试。**不要换个路径重试** —— 换到哪都会被拒。';
      }
      return '写入失败：$e';
    }
  }
}

/// **直接执行 sh / py**，参数可以引用句柄。
///
/// 和 `run_shell` / `termux` 的区别不在"能跑什么"，而在**怎么把大内容
/// 交给命令**：这里参数值支持 `path://a` / `stdin://a`，由系统解析成
/// 文件路径或标准输入，**绝不把内容拼进命令行**。
///
/// 这一条解决的是一个真实故障：模型把 40 万字塞进 `echo` 的参数里，
/// 命令因为 `ARG_MAX` 直接失败，而失败信息看起来像"引号写错了"，
/// 模型就去改引号，改到轮次用完也修不好。
class ShellerTool extends AgentTool {
  const ShellerTool();

  @override
  String get name => 'sheller';

  @override
  String get title => '执行脚本';

  @override
  String get description =>
      '执行一段 sh 或 py，参数可以引用大内容而不把它拼进命令行。\n'
      '和 `run_shell` 的区别：`run_shell` 是"跑一条系统命令"（pm/am/settings）；'
      '这个是"跑一段脚本，并用句柄把文件喂给它"。\n'
      '参数：\n'
      '· lang：sh（默认）或 py\n'
      '· script：脚本正文；也可以传句柄 obj://s 复用之前的脚本\n'
      '· args：要传给脚本的参数。值写成 `path://a` 会解析成 a 的真实路径，'
      '`stdin://a` 会把 a 接到标准输入。**不要**把大内容的原文贴进来。\n'
      '· stdin：另一个句柄，作为标准输入\n'
      '· timeout_ms：超时，默认 60000\n'
      '· cwd：工作目录\n'
      '返回 exit_code、stdout 摘要（超 8KB 自动转成句柄）、错误的 stderr。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'lang': <String, dynamic>{
        'type': 'string',
        'enum': <String>['sh', 'py'],
        'description': '脚本语言，默认 sh。',
      },
      'script': <String, dynamic>{
        'type': 'string',
        'description': '脚本正文，或 obj://a 句柄。',
      },
      'args': <String, dynamic>{
        'type': 'object',
        'description':
            '传给脚本的参数。值支持 path://a（解析成路径）和 '
            'stdin://a（接到标准输入）。会按顺序变成 \$1 \$2 …',
      },
      'stdin': <String, dynamic>{
        'type': 'string',
        'description': '标准输入的句柄，如 stdin://a。',
      },
      'cwd': <String, dynamic>{'type': 'string', 'description': '工作目录。'},
      'timeout_ms': <String, dynamic>{
        'type': 'integer',
        'description': '超时毫秒，默认 60000，上限 600000。',
      },
      'env': <String, dynamic>{'type': 'object', 'description': '额外的环境变量。'},
    },
    'required': <String>['script'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String lang = args.str('lang', fallback: 'sh');
    final String script = args.str('script');
    if (lang == 'py') {
      // 复用 Python 那套分级：它已经按"删文件 / 起进程 / 网络"分得很细，
      // 这里再写一份必然会出现两边判断不一致。
      return PythonRisk.classify(script);
    }
    return RiskClassifier.assessShell(script);
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String lang = args.str('lang', fallback: 'sh');
    final String s = args.str('script').trim().replaceAll(RegExp(r'\s+'), ' ');
    final String short = s.length > 70 ? '${s.substring(0, 70)}…' : s;
    return '[$lang] $short';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String lang = args.str('lang', fallback: 'sh');
    String script = args.str('script');

    // script 本身也可以是句柄：长脚本复用一次，不用重新打一遍。
    if (script.trim().startsWith('obj://') || script.trim().startsWith('@')) {
      final Obj? o = ObjStore.instance.lookup(script);
      if (o != null) {
        script = await ObjStore.instance.fullText(o, limit: 256 * 1024);
      }
    }
    if (script.trim().isEmpty) return '错误：script 不能为空';

    // ---- 参数：句柄 → 路径 ----
    final Map<String, dynamic> rawArgs = args.mapVal('args');
    final List<String> positional = <String>[];
    final List<String> notes = <String>[];
    for (final MapEntry<String, dynamic> e in rawArgs.entries) {
      final String v = e.value?.toString() ?? '';
      if (v.startsWith('path://') || v.startsWith('stdin://')) {
        final String p = await resolvePathArg(v);
        if (p == v) {
          notes.add('参数 ${e.key} 引用的 $v 找不到，已按原样传入');
        }
        positional.add(p);
      } else {
        positional.add(v);
      }
    }

    // ---- stdin ----
    String? stdinText;
    final String stdinRef = args.str('stdin');
    if (stdinRef.isNotEmpty) {
      final Obj? o = ObjStore.instance.lookup(stdinRef);
      if (o == null) {
        return '找不到 stdin 引用的对象：$stdinRef';
      }
      stdinText = await ObjStore.instance.fullText(o, limit: 512 * 1024);
    }

    final int timeoutMs = args
        .intVal('timeout_ms', fallback: 60000)
        .clamp(1000, 600000);
    final String cwd = args.str('cwd').trim();

    // ---- 跑 ----
    //
    // 走 TerminalSession：模型跑的命令要进终端页的流水，
    // 和用户手敲的命令排在一起 —— 用户得能在同一个地方看全谁动了系统。
    final String command;
    final List<String> usePositional;
    if (lang == 'py') {
      // Python 走 sh 里的 `python3 -c`：内置 Alpine 里有 python3，
      // 而内嵌的 Chaquopy 解释器在应用进程里，跑不了"给一段 stdin 的脚本"。
      final String quotedScript = _quote(script);
      command = 'python3 -c $quotedScript';
      usePositional = positional;
    } else {
      command = 'sh -c ${_quote(script)} sh';
      usePositional = positional;
    }

    final StringBuffer full = StringBuffer(command);
    for (final String a in usePositional) {
      full.write(' ');
      full.write(_quote(a));
    }

    final ShellResultLike r = await _run(
      full.toString(),
      cwd: cwd.isEmpty ? null : cwd,
      timeoutMs: timeoutMs,
      stdin: stdinText,
    );

    final StringBuffer sb = StringBuffer();
    sb.writeln('exit_code: ${r.exitCode}');
    if (r.timedOut) sb.writeln('（超时，已终止）');
    if (notes.isNotEmpty) sb.writeln('注意：${notes.join('；')}');
    sb.writeln('--- stdout ---');
    sb.writeln(r.stdout.trim().isEmpty ? '(空)' : r.stdout.trim());
    if (r.stderr.trim().isNotEmpty) {
      sb.writeln('--- stderr ---');
      sb.writeln(r.stderr.trim());
    }

    final Resolved packed = await packOutput(sb.toString());
    return packed.text;
  }

  /// sh 单引号转义。脚本和参数都走它 —— 拼错一个引号就是命令注入面。
  static String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  Future<ShellResultLike> _run(
    String command, {
    String? cwd,
    required int timeoutMs,
    String? stdin,
  }) async {
    // 走 TerminalSession 而不是直接调 Linux/Termux：模型跑的命令要进
    // 终端页的流水，和用户手敲的命令排在一起 —— 用户得能在同一个地方
    // 看全"谁动了系统"。
    final ShellResult res = await TerminalSession.instance.run(
      command,
      workdir: cwd,
      timeout: Duration(milliseconds: timeoutMs),
      stdin: stdin,
    );
    return ShellResultLike(
      exitCode: res.exitCode,
      stdout: res.combined,
      stderr: '',
      timedOut: false,
    );
  }
}

class ShellResultLike {
  const ShellResultLike({
    required this.exitCode,
    required this.stdout,
    this.stderr = '',
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

/// **变量池 / 对象池**：把大内容定义成句柄，之后只引用不搬运。
///
/// 这是"40 万字文件 → 模型输出 token < 1KB"那条验收标准的落点：
/// 模型 `define` 一次，之后所有地方都用 `{{obj://a}}`。
class GeterTool extends AgentTool {
  const GeterTool();

  @override
  String get name => 'geter';

  @override
  String get title => '对象池';

  @override
  String get description =>
      '把一段大内容（文件、命令输出、长文本）登记成句柄，之后只引用它。\n'
      '动作：\n'
      '· define：source 可以是文件路径、句柄、或直接给 text。返回 obj://x\n'
      '· list：看当前有哪些句柄、各多大、还能活多久\n'
      '· ref：把句柄按指定形态取出来 —— '
      'as=summary（摘要，默认）/ path（真实路径）/ full（全文，有上限）\n'
      '· drop：扔掉一个句柄（pin 住的要先解 pin）\n'
      '**为什么用它**：同一份大内容在一场对话里会被引用很多次。'
      '每次重贴一遍原文，代价是"大小 × 次数"；存成句柄之后每次都只花几个字符。\n'
      '引用写法：输出里写 `{{obj://a}}` 会展开成内容；'
      '`{{obj://a:10-20}}` 只要第 10–20 行；`{{obj://a:0-500}}` 要前 500 个字符。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'op': <String, dynamic>{
        'type': 'string',
        'enum': <String>['define', 'list', 'ref', 'drop'],
        'description': '默认 define。',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': 'define 时想要的短名（字母数字下划线）。不给就自动分配 a/b/c…',
      },
      'source': <String, dynamic>{
        'type': 'string',
        'description': 'define 的来源：文件路径，或已有的句柄。',
      },
      'text': <String, dynamic>{
        'type': 'string',
        'description': 'define 时直接给一段文本（和 source 二选一）。',
      },
      'as': <String, dynamic>{
        'type': 'string',
        'enum': <String>['summary', 'path', 'full'],
        'description': 'ref 时取哪种形态，默认 summary。',
      },
      'pin': <String, dynamic>{
        'type': 'boolean',
        'description': 'define 时 pin 住，不参与过期淘汰。',
      },
      'ttl': <String, dynamic>{
        'type': 'integer',
        'description': 'define 时的存活秒数，默认 86400。',
      },
    },
    'required': <String>['op'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) {
    final String op = args.str('op', fallback: 'define');
    if (op == 'list') return '看对象池';
    if (op == 'drop') return '丢弃 ${args.str('name')}';
    if (op == 'ref') {
      return '取 ${args.str('name')} 的${args.str('as', fallback: 'summary')}';
    }
    final String name = args.str('name');
    final String src = args.str('source').trim();
    return name.isEmpty ? '登记 ${src.isEmpty ? '一段文本' : src}' : '登记 $name';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final ObjStore store = ObjStore.instance;
    final String op = args.str('op', fallback: 'define');

    switch (op) {
      case 'list':
        final List<Obj> all = store.all;
        if (all.isEmpty) {
          return '对象池是空的。用 `geter` 的 define 把大文件或长输出登记进来。';
        }
        final StringBuffer sb = StringBuffer('当前 ${all.length} 个对象：\n');
        for (final Obj o in all) {
          final String ttl = o.pinned
              ? 'pinned'
              : '还剩 ${_humanDuration(o.ttl - DateTime.now().difference(o.createdAt))}';
          sb.writeln('  ${o.label}  $ttl');
          if (o.source != null) sb.writeln('      ${o.source}');
        }
        return sb.toString();

      case 'drop':
        final Obj? o = store.lookup(args.str('name'));
        if (o == null) return '没有这个对象：${args.str('name')}';
        if (o.pinned) {
          return '${o.uri} 被 pin 住了，不会被动丢弃。'
              '（pin 是防误删的，这里不做"悄悄解 pin 再删"。）';
        }
        store.drop(o.id);
        return '已丢弃 ${o.uri}。';

      case 'ref':
        final Obj? o = store.lookup(args.str('name'));
        if (o == null) return '没有这个对象：${args.str('name')}';
        final String as = args.str('as', fallback: 'summary');
        if (as == 'path') {
          final String? p = await store.materialize(o);
          return p ?? '${o.uri} 没法落到磁盘';
        }
        if (as == 'full') {
          if (o.size > ObjStore.fullExpandLimit) {
            return '${o.uri} 有 ${ObjStore.humanBytes(o.size)}，'
                '超过 full 展开上限 ${ObjStore.humanBytes(ObjStore.fullExpandLimit)}。\n'
                '改用 `reader` 传 target="${o.uri}" 加 range，只取需要的那一段。';
          }
          return store.fullText(o);
        }
        return store.summary(o);

      default:
        return _define(store, args);
    }
  }

  Future<String> _define(ObjStore store, Map<String, dynamic> args) async {
    final String name = args.str('name').trim();
    final String source = args.str('source').trim();
    final String text = args.str('text');
    final bool pin = args.boolVal('pin', fallback: false);
    final int ttlSec = args.intVal('ttl', fallback: 86400);

    if (source.isEmpty && text.isEmpty) {
      return 'define 需要 source（文件路径或已有句柄）或 text 其中之一。';
    }

    // 已有句柄 → 给它起个新名字（复制一份元数据，不复制内容）
    if (source.isNotEmpty) {
      final Obj? src = store.lookup(source);
      if (src != null) {
        final Obj o = src.inline != null
            ? await store.putText(
                src.inline!,
                id: name.isEmpty ? null : name,
                type: src.type,
                pinned: pin,
                ttl: Duration(seconds: ttlSec),
              )
            : await store.putFile(
                src.source!,
                id: name.isEmpty ? null : name,
                type: src.type,
                pinned: pin,
                ttl: Duration(seconds: ttlSec),
              );
        return _defined(o, '（从 $source 复制）');
      }

      // 普通路径
      final FileSystemEntityType t = await FileSystemEntity.type(source);
      if (t == FileSystemEntityType.notFound) {
        if (text.isEmpty) {
          return '找不到 $source。用 `filesearch` 确认一下路径，'
              '或者直接把内容放在 text 里。';
        }
      } else if (t == FileSystemEntityType.directory) {
        final Obj o = await store.putDir(
          source,
          id: name.isEmpty ? null : name,
          pinned: pin,
          ttl: Duration(seconds: ttlSec),
        );
        return _defined(o, null);
      } else {
        final Obj o = await store.putFile(
          source,
          id: name.isEmpty ? null : name,
          pinned: pin,
          ttl: Duration(seconds: ttlSec),
        );
        return _defined(o, null);
      }
    }

    final Obj o = await store.putText(
      text,
      id: name.isEmpty ? null : name,
      pinned: pin,
      ttl: Duration(seconds: ttlSec),
    );
    return _defined(o, null);
  }

  String _defined(Obj o, String? extra) {
    final String name = o.uri;
    return '已登记 $name（${o.type.name}，${ObjStore.humanBytes(o.size)}）'
        '${extra ?? ''}\n'
        '之后在需要的地方写 `{{$name}}` 就会展开成内容；'
        '只要某一段就写 `{{$name:10-20}}`（行）或 `{{$name:0-500}}`（字符）。'
        '当路径传给命令就写 `$name` 加 `path://` 前缀。';
  }

  static String _humanDuration(Duration d) {
    if (d.isNegative) return '已过期';
    if (d.inHours >= 1) return '${d.inHours} 小时';
    if (d.inMinutes >= 1) return '${d.inMinutes} 分钟';
    return '${d.inSeconds} 秒';
  }
}
