import 'dart:io';

import '../core/file_diff.dart';
import '../core/models.dart';
import '../core/model_paths.dart';
import 'tool.dart';

/// **改写文件**：按「找一段 → 换成另一段」的方式改，而不是整份重写。
///
/// ## 为什么不用 `reader` 的 write
///
/// `reader` 的 write 是**整份覆盖**：模型得先把原文完整贴一遍，再在中间
/// 改几个字。这有三个真问题：
///
/// 1. **贵**：40KB 的文件改一行，输出 token 是 40KB 而不是 40 字节；
/// 2. **危险**：模型记漏一行、少一个空格，那次"改一行"就变成"重写整个
///    文件"。而这个错误**没有报错** —— 文件写成功了，只是内容错了；
/// 3. **没法审**：整份重写产生的差异是"全文替换"，用户看不出到底改了
///    哪几个字。
///
/// `writer` 让模型只给出**要替换的那一段**和**替换成什么**。原文不经过
/// 模型的嘴，所以它不可能记漏；差异天然只有那一段，思考链里直接就能显示。
///
/// ## 全程走本地文件 API，不经过 termux
///
/// 这是刻意的：改一个文本文件不该依赖 Linux 环境（那意味着用户要装
/// Termux、要等 Alpine 启动、还要处理 `/sdcard` 和 proot 的路径映射）。
/// 这里直接用 `dart:io`，所以：
///  · 手机上一装就能用，零配置；
///  · 路径就是真实路径，不经过两层映射，出错信息也对得上；
///  · 写之前**先备份**（见 [backup]），改坏了能立刻恢复。
///
/// 只有需要 GNU 工具链（`grep -P`、`sed -i` 扩展、编译）时才该用 termux ——
/// 那不是"改文件"，那是"跑工具"。
///
/// ## 三种改写方式
///
/// · `replace`（默认）：给 `old` 和 `new`，把 `old` 换成 `new`。
///   `old` **必须唯一命中**（见 [_locate]），否则拒绝执行 —— 见那里的说明。
/// · `insert`：在 `after` 那一行之后插入 `new`。
/// · `delete`：删掉 `old` 命中的那一段。
///
/// 三种都只碰命中处，其余内容原样保留。这就是"配合 reader"的意思：
/// 先用 `reader` 看摘要/片段，再用 `writer` 精准改那一点。
class WriterTool extends AgentTool {
  const WriterTool();

  @override
  String get name => 'writer';

  @override
  String get title => '改文件';

  @override
  String get description =>
      '改写文件里的**某一段**，其余内容原样保留。'
      '这是本机直改：不需要 termux / Linux 环境。\n'
      '和 `reader` 配合：先用 `reader` 看摘要或取一段，再用它改那一点。\n'
      '参数：\n'
      '· path：要改的文件（绝对路径）\n'
      '· op：replace（默认，把 old 换成 new）/ insert（在 after 行后插入 new）/ '
      'delete（删掉 old）\n'
      '· old：要被替换/删除的原文。**必须和文件里一字不差**（含缩进），'
      '而且通常要唯一 —— 如果它在文件里出现多次，要带上更多上下文让它唯一，'
      '或者用 line 指定行号。\n'
      '· new：替换成什么（op=delete 时不用）\n'
      '· line：可选。给出行号，只在那一行附近匹配，避免"出现多次"的报错\n'
      '· create：true 时文件不存在就新建（此时不用 old）\n'
      '改完会返回改了第几行、增删了多少行，改动片段会显示在聊天里。\n'
      '**不要用它整份重写文件** —— 那正是这个工具要替代的做法。'
      '**也不要为了改一个文本文件去调 termux / run_shell 拼 sed**：'
      '那样要额外权限、引号一错就改坏、用户还看不到改动片段。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'path': <String, dynamic>{'type': 'string', 'description': '要改的文件绝对路径。'},
      'op': <String, dynamic>{
        'type': 'string',
        'enum': <String>['replace', 'insert', 'delete'],
        'description': '默认 replace。',
      },
      'old': <String, dynamic>{
        'type': 'string',
        'description': '要被替换/删除的原文（一字不差，含缩进）。',
      },
      'new': <String, dynamic>{'type': 'string', 'description': '替换成什么。'},
      'after': <String, dynamic>{
        'type': 'integer',
        'description': 'op=insert 时，插入到第几行之后（1 起算，0 表示文件开头）。',
      },
      'line': <String, dynamic>{
        'type': 'integer',
        'description': '可选：在第几行附近找 old。用于 old 出现多次的情况。',
      },
      'create': <String, dynamic>{
        'type': 'boolean',
        'description': 'true 时文件不存在就新建（把 new 当全文写入）。',
      },
    },
    'required': <String>['path'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String path = args.str('path');
    final String op = args.str('op', fallback: 'replace');
    final bool create = args.boolVal('create', fallback: false);
    if (create) {
      return RiskAssessment(RiskLevel.caution, <String>['新建文件 $path']);
    }
    return RiskAssessment(RiskLevel.caution, <String>[
      op == 'delete' ? '从 $path 删掉一段' : '修改 $path',
    ]);
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String op = args.str('op', fallback: 'replace');
    final String path = args.str('path');
    final String name = path.split(RegExp(r'[/\\]')).last;
    final String old = args.str('old').trim();
    final String hint = old.isEmpty
        ? ''
        : '「${old.length > 24 ? '${old.substring(0, 24)}…' : old.replaceAll(RegExp(r'\s+'), ' ')}」';
    return switch (op) {
      'insert' => '在 $name 第 ${args.intVal('after', fallback: 0)} 行后插入',
      'delete' => '从 $name 删掉$hint',
      _ => '改 $name$hint',
    };
  }

  /// 单文件大小上限。超过就不做行级改写 —— 那种文件逐段改的收益很低，
  /// 而把几百 MB 读进内存会把应用拖死。
  static const int maxFileBytes = 4 * 1024 * 1024;

  /// 备份保留多久 / 最多几份。
  ///
  /// 为什么只留最近几份而不是按版本管理：这是**误操作恢复**，不是历史记录。
  /// 用户改坏了、想退回上一次，答案几乎总是"刚才那份"。留太多反而占空间，
  /// 而真正的历史应该在用户的 git / 备份里。
  static const int backupKeep = 3;

  /// 写之前给原文件留一份备份。
  ///
  /// ## 为什么必须有
  ///
  /// `writer` 是按"找一段换一段"改的，听起来比整份重写安全得多 ——
  /// 但它仍然是**直接覆盖用户的文件**，而且没有 undo。模型把 `old` 写对了、
  /// 但 `new` 里少了一个闭合括号这种事，完全可能发生（它确实改对了地方，
  /// 只是改出了语法错误）。
  ///
  /// 有备份之后，用户至少能说"退回上一版"。这个成本很低（一次 copy），
  /// 而收益是"改坏了不至于丢东西"。
  ///
  /// 备份放在**同目录的 `.dsh_backup/`** 里：跟着文件走，用户在原位置就能
  /// 找到；不放进系统临时目录（那里清缓存就没了，而清缓存往往正是
  /// 出问题的时刻）。
  Future<String?> backup(File f) async {
    try {
      if (!await f.exists()) return null;
      final int size = await f.length();
      // 太大就不备份：复制一份 4MB 也要时间，而那种文件本来就该用
      // 别的工具处理（见 maxFileBytes）。
      if (size > maxFileBytes) return null;

      final String name = f.path.split(RegExp(r'[/\\]')).last;
      final Directory dir = Directory('${f.parent.path}/.dsh_backup');
      await dir.create(recursive: true);

      final String stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final String target = '${dir.path}/$name.$stamp.bak';
      await f.copy(target);

      // 只留最近 [backupKeep] 份，把更早的删掉。
      await _pruneBackups(dir, name);
      return target;
    } catch (_) {
      // 备份失败不该阻止改动本身：主流程是"帮用户改文件"，
      // 备份是附加保险。但下面会在返回里说明"这次没有备份"。
      return null;
    }
  }

  Future<void> _pruneBackups(Directory dir, String name) async {
    try {
      final List<File> olds = <File>[];
      await for (final FileSystemEntity e in dir.list()) {
        if (e is! File) continue;
        final String n = e.path.split(RegExp(r'[/\\]')).last;
        if (n.startsWith('$name.') && n.endsWith('.bak')) olds.add(e);
      }
      if (olds.length <= backupKeep) return;
      olds.sort((File a, File b) => a.path.compareTo(b.path));
      for (int i = 0; i < olds.length - backupKeep; i++) {
        try {
          await olds[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    String path = args.str('path').trim();
    if (path.isEmpty) return '错误：path 不能为空';
    // 相对路径按当前工作目录解释 —— 模型不用自己拼绝对路径。
    path = resolveModelPath(path, baseDir: ctx.workDir);
    final String op = args.str('op', fallback: 'replace');
    final bool create = args.boolVal('create', fallback: false);

    final File f = File(path);
    final bool exists = await f.exists();

    // ---- 新建 ----
    if (!exists) {
      if (!create) {
        return '文件不存在：$path\n'
            '如果是想新建，加上 create=true（会用 `new` 作为全文）；'
            '如果是路径记错了，用 `filesearch` 找一下。';
      }
      final String body = args.str('new');
      try {
        await f.parent.create(recursive: true);
        await f.writeAsString(body);
      } catch (e) {
        return _explainWriteError(path, e);
      }
      return '已新建 $path（${body.length} 字符）。';
    }

    // ---- 读原文 ----
    int size;
    try {
      size = await f.length();
    } catch (e) {
      return '读不到 $path：$e';
    }
    if (size > maxFileBytes) {
      return '$path 有 ${_human(size)}，超过单文件改写上限 ${_human(maxFileBytes)}。\n'
          '这么大的文件请用 `sheller` 跑 sed / python 处理，'
          '或者先用 `reader` 确认范围，再针对性地改。';
    }

    String before;
    try {
      before = await f.readAsString();
    } catch (e) {
      return '这个文件读不成文本（可能是二进制或编码特殊）：$e\n'
          '改用 `sheller`。';
    }

    final String oldText = args.str('old');
    final String newText = args.str('new');
    final int hintLine = args.intVal('line', fallback: 0);

    // ---- 定位 ----
    if (op == 'insert') {
      final int after = args.intVal('after', fallback: 0);
      return _insert(f, path, before, after, newText);
    }

    if (oldText.isEmpty) {
      return '错误：op=$op 需要 old（要被${op == 'delete' ? '删' : '替换'}的原文）。';
    }

    final _Locate loc = _locate(before, oldText, hintLine: hintLine);
    if (loc.error != null) return loc.error!;

    final String after = op == 'delete'
        ? before.replaceRange(loc.start, loc.end, '')
        : before.replaceRange(loc.start, loc.end, newText);

    if (after == before) {
      return '内容没有变化（替换前后的文本相同），没有写盘。';
    }

    // 写前备份：改坏了能退回去。失败不阻止改动，但要在结果里说清。
    final String? bak = await backup(f);

    try {
      await f.writeAsString(after);
    } catch (e) {
      return _explainWriteError(path, e);
    }

    // ---- 报告 ----
    final int line = _lineAt(before, loc.start);
    final String? diff = _shortDiff(before, after, line);
    final String action = switch (op) {
      'delete' => '已删除 $path 第 $line 处的那一段',
      _ => '已修改 $path（第 $line 行附近）',
    };
    return '$action。\n${diff ?? ''}'
        '（文件现在 ${after.length} 字符。改动片段会显示在聊天里，'
        '点开可以看到完整的增删行。）'
        '${bak == null ? '\n注意：这次没能留下备份（原文件太大或磁盘满了）。' : '\n原文件已备份到 ${bak.split(RegExp(r'[/\\\\]')).last}（同目录 .dsh_backup/ 里）。'}';
  }

  /// 在 [after] 行之后插入。
  ///
  /// 用"行号之后"而不是"某个锚点之后"：插入的典型场景是"补一行配置"、
  /// "在函数开头加一句"，而模型此刻手里已经有 `reader` 给的行号了。
  /// 锚点式插入（"在 xxx 之后加"）在锚点出现多次时同样是歧义的。
  Future<String> _insert(
    File f,
    String path,
    String before,
    int afterLine,
    String newText,
  ) async {
    final List<String> lines = FileDiff.splitLines(before);
    final int at = afterLine.clamp(0, lines.length);
    final List<String> insert = newText.split('\n');
    final List<String> next = <String>[
      ...lines.sublist(0, at),
      ...insert,
      ...lines.sublist(at),
    ];
    final String after = '${next.join('\n')}\n';
    try {
      await f.writeAsString(after);
    } catch (e) {
      return _explainWriteError(path, e);
    }
    return '已在 $path 第 $at 行之后插入 ${insert.length} 行。\n'
        '（现在共 ${next.length} 行。）';
  }

  /// 找 `old` 在文中出现的位置。
  ///
  /// ## 为什么必须唯一
  ///
  /// 这是这个工具唯一有风险的地方：`old` 在文件里出现几次，就意味着
  /// "改哪一处"是歧义的。悄悄改第一处是最坏的选择 —— 用户看到的是
  /// "AI 改错了地方"，而 AI 以为改对了，**两边都不知道出过问题**。
  ///
  /// ## 给了 `line` 之后为什么也不猜"第一处"
  ///
  /// 给了行号时取**离那一行最近的命中**，而不是简单地"缩小搜索窗口
  /// 再看剩下几个"。窗口法有个隐蔽的坑：文件只有 6 行时，
  /// `line - 40` 会被钳到第 1 行，于是整个文件又落进窗口 ——
  /// 结果和没给行号一模一样。
  ///
  /// 取"最近"符合用户的意思（"我指的是第 5 行那个"），而且有个明确的
  /// 失效条件：最近的命中离得太远（超过 [nearLines] 行）就仍然报错，
  /// 因为那时行号多半是记错了。
  static const int nearLines = 40;

  _Locate _locate(String text, String old, {int hintLine = 0}) {
    final List<int> hits = <int>[];
    int from = 0;
    while (true) {
      final int i = text.indexOf(old, from);
      if (i < 0) break;
      hits.add(i);
      from = i + 1;
      // 只需要知道"有几个"和"离目标多远"，不用全找出来
      if (hits.length > 40) break;
    }

    if (hits.isEmpty) {
      return const _Locate.error(
        '在文件里找不到这段原文。\n'
        '可能的原因：缩进/空行和实际不一致、或者它已经被上一次改动换掉了。\n'
        '用 `reader` 重新看一眼那一段（mode="raw" 加 range），照原样复制过来。',
      );
    }

    // ---- 给了行号：取最近的那一处 ----
    if (hintLine > 0) {
      int best = hits.first;
      int bestDist = (_lineAt(text, best) - hintLine).abs();
      for (final int h in hits) {
        final int d = (_lineAt(text, h) - hintLine).abs();
        if (d < bestDist) {
          best = h;
          bestDist = d;
        }
      }
      if (bestDist <= nearLines) {
        return _Locate(best, best + old.length);
      }
      return _Locate.error(
        '第 $hintLine 行附近没有这段原文。最近的一处在第 ${_lineAt(text, best)} 行'
        '（相差 $bestDist 行），差得太远，没有动文件。\n'
        '行号可能记错了（文件被改过之后行号会变）。'
        '用 `reader` 的 mode="raw" + range 重新看一眼，或者把 `line` 改成 '
        '${_lineAt(text, best)}。',
      );
    }

    // ---- 没给行号：必须唯一 ----
    if (hits.length > 1) {
      final List<String> where = <String>[
        for (final int h in hits.take(5)) '第 ${_lineAt(text, h)} 行',
      ];
      return _Locate.error(
        '"${old.length > 40 ? '${old.substring(0, 40)}…' : old}" 在文件里出现了 '
        '${hits.length} 次（${where.join('、')}），不知道该改哪一处，'
        '所以**没有动文件**。\n'
        '两种办法：\n'
        '· 传 `line` 指定大概的行号；\n'
        '· 或者把 old 写长一点，带上前后文，让它只匹配一处。',
      );
    }

    return _Locate(hits.first, hits.first + old.length);
  }

  int _lineAt(String text, int offset) {
    int line = 1;
    final int end = offset < text.length ? offset : text.length;
    for (int i = 0; i < end; i++) {
      if (text[i] == '\n') line++;
    }
    return line;
  }

  /// 给模型看的**回声**：改动处前后几行。
  ///
  /// 为什么不直接把完整差异塞进工具结果：差异卡片已经挂在这次调用上
  /// （见 [ToolInvocation.changes]），界面上会画出来。这里再贴一份等于
  /// **同一份内容进两遍上下文**，而工具结果每轮都要重发。
  String? _shortDiff(String before, String after, int around) {
    try {
      final FileChange? change = FileDiff.compute('', before, after);
      if (change == null) return null;
      final StringBuffer sb = StringBuffer();
      int shown = 0;
      for (final DiffLine l in change.lines) {
        if (l.kind == DiffKind.skip) {
          sb.writeln('  …');
          continue;
        }
        final String mark = switch (l.kind) {
          DiffKind.added => '+',
          DiffKind.removed => '-',
          _ => ' ',
        };
        sb.writeln('$mark ${l.text}');
        shown++;
        if (shown >= 24) {
          sb.writeln('  …（还有更多改动，见聊天里的差异卡片）');
          break;
        }
      }
      return sb.toString();
    } catch (_) {
      return null;
    }
  }

  /// 把写入失败翻译成人能看懂的原因。
  ///
  /// `errno = 1` 那条尤其重要：它是 Android 分区存储的拒绝，不是路径
  /// 写错了。不解释的话，模型会一直换个路径重试，而换到哪都会被拒。
  String _explainWriteError(String path, Object e) {
    final String msg = e.toString();
    if (msg.contains('errno = 1') || msg.contains('Operation not permitted')) {
      return '没有权限写 $path。\n\n'
          '这是 Android 的分区存储限制，不是路径写错了：往 /sdcard 这类公共目录写，'
          '需要「所有文件访问」权限。\n'
          '请让用户去「设置 → 应用 → 特殊权限 → 所有文件访问」给本应用授权，'
          '然后重试。**不要换个路径重试** —— 换到哪都会被拒。';
    }
    if (msg.contains('Read-only file system')) {
      return '$path 所在的分区是只读的，改不了。';
    }
    return '写入失败：$e';
  }

  static String _human(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// [_locate] 的结果：要么是区间，要么是一句给模型看的错误说明。
class _Locate {
  const _Locate(this.start, this.end) : error = null;

  const _Locate.error(this.error) : start = 0, end = 0;

  final int start;
  final int end;
  final String? error;
}
