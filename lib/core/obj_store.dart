import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 一个「句柄对象」的类型。只影响**怎么读它**，不影响能不能引用。
enum ObjType {
  /// 纯文本：可以按行/按字符取范围，可以 grep。
  text,

  /// JSON：额外能报"顶层键"，让模型知道结构。
  json,

  /// 脚本：可被 `sheller` 直接执行。
  script,

  /// 已知的二进制（图片、压缩包…）：只能当路径用。
  binary,

  /// 目录：只能列，不能读内容。
  dir,
}

/// 对象池里的一个条目。
///
/// 两种存在形式，**不是"大就落盘、小就内存"这么随意**：
///
/// · [inline] 内存里存着全文。只给 `geter.define` 传入的短文本用
///   （64KB 以内），因为它的生命周期短、又不会被反复 rewind。
/// · [source] 指向磁盘上的真实文件。**任何来自文件的引用都走这条** ——
///   40 万字在内存里是一份，在文件里也只有一份，我们只读需要的那一段。
///
/// 搞成"读进内存再统一处理"会有一个很隐蔽的后果：引用大文件时，
/// 一次 `reader` 就能把应用的内存顶到系统开始杀后台，而用户只看到
/// "闪退了"，完全联想不到是刚才那次读文件。
class Obj {
  Obj({
    required this.id,
    required this.type,
    required this.size,
    this.source,
    this.inline,
    this.pinned = false,
    Duration? ttl,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       ttl = ttl ?? ObjStore.defaultTtl;

  /// 句柄短名。模型看到的是 `obj://<id>`。
  final String id;

  final ObjType type;

  /// 字节数（inline 时是 UTF-8 字节数）。
  int size;

  /// 磁盘上的真实路径。为 null 表示内容在 [inline] 里。
  String? source;

  /// 内存里的全文。只有短文本走这里。
  String? inline;

  /// 被 pin 住的对象不参与 TTL 淘汰 —— 用户明确说"这个留着"时用。
  bool pinned;

  /// 存活时长。默认 24h：一次任务通常几分钟，24h 足够覆盖"明天接着弄"。
  Duration ttl;

  final DateTime createdAt;

  /// 最近一次被引用/读取。LRU 淘汰按它排序，不按创建时间 ——
  /// 一个开场定义、中途一直在用的对象不该先被丢。
  DateTime lastUsed = DateTime.now();

  String? summaryCache;

  /// 行数缓存。大文件数一遍要几十毫秒，`reader` 的每次分页都会问它。
  int? linesCache;

  String get uri => 'obj://$id';

  bool get isFile => source != null;

  bool get expired => !pinned && DateTime.now().difference(createdAt) > ttl;

  /// 给模型看的一行元数据。
  String get label =>
      '$uri  ${ObjStore.humanBytes(size)}  ${type.name}'
      '${pinned ? '  [pinned]' : ''}';

  void touch() => lastUsed = DateTime.now();
}

/// 一条 grep 命中。
class GrepHit {
  GrepHit({
    required this.line,
    required this.text,
    this.before = const <String>[],
    List<String>? after,
  }) : after = after ?? <String>[];

  /// 1 起算的行号。
  final int line;
  final String text;
  final List<String> before;

  /// 命中行**之后**的上下文。扫描是单向的，所以这份是边扫边填的。
  final List<String> after;
}

/// **对象池**：把大内容从模型上下文里搬到系统侧。
///
/// ## 它解决的具体问题
///
/// 之前模型要"看一眼这个大文件"，只能 `file_op read` 把整份塞进上下文。
/// 工具自己截到 12k，于是模型看到的是**前 12k 加一句"已截断"** ——
/// 它不知道后面还有什么、也不知道该往哪读，只能换 `run_shell` 拼 `sed`，
/// 又多花一轮、还容易把路径拼错。40 万字的文件基本等于"读不了"。
///
/// 现在：文件注册成 `obj://a`，模型拿到的是**摘要 + 行数 + 句柄**。
/// 想细看就 `reader` 取某一段、或者 grep 一个关键词。**全文始终不进来。**
///
/// ## 为什么是单例
///
/// 和 `MemoryStore` / `RuleStore` 同一个理由：句柄要在**工具执行深处**
/// 被解析（`sheller` 把 `path://a` 换成真实路径、输出侧展开 `{{obj://a}}`），
/// 从 `main()` 一路透传下去要改十几个文件。而且句柄本来就是**一次会话内
/// 共享**的东西，多实例会让"刚才那个 a 是什么"对不上。
class ObjStore {
  ObjStore._(this._dir);

  static ObjStore? _instance;

  /// 进程内单例。
  ///
  /// **没配置时自动建一个纯内存的**，而不是像 MemoryStore 那样抛异常：
  /// 这个池子的失败模式是"工具报错"，而工具报错不该把整场对话打断。
  /// 纯内存实例在久置之前被用到，只是少了个落盘目录，功能仍然可用。
  static ObjStore get instance => _instance ??= ObjStore._(null);

  /// 配一个落盘目录。已存在的对象不受影响（它们各自记着自己的路径）。
  static Future<ObjStore> configure(Directory spillDir) async {
    final ObjStore s = ObjStore._(spillDir);
    _instance = s;
    return s;
  }

  /// 只在测试里用：丢掉单例，下一个用例从干净状态开始。
  @visibleForTesting
  static void resetForTest() => _instance = null;

  final Directory? _dir;

  final Map<String, Obj> _objs = <String, Obj>{};

  /// 超过这个大小的文本**必须**落盘，不进内存。
  ///
  /// 64KB 是个经验值：再大的文本进内存，一次引用就多一份拷贝，
  /// 而手机端最怕的正是这种"看不见的常驻占用"。
  static const int inlineLimit = 64 * 1024;

  /// 最多留多少个对象。超过就按 LRU 丢非 pinned 的。
  ///
  /// 一次长任务里 `filesearch` / `sheller` 会不断产出句柄，
  /// 不设上限的话一晚上能把临时目录堆到几百 MB。
  static const int maxObjects = 64;

  static const Duration defaultTtl = Duration(hours: 24);

  /// `reader` 单次最多返回多少行。超了就要求更精确的范围。
  static const int maxRangeLines = 2000;

  /// `full` 展开的上限（给 `geter.ref` 用）。
  static const int fullExpandLimit = 64 * 1024;

  int _seq = 0;

  List<Obj> get all => List<Obj>.unmodifiable(_objs.values);

  Obj? get(String id) {
    final Obj? o = _objs[id];
    if (o == null) return null;
    if (o.expired) {
      _objs.remove(id);
      return null;
    }
    o.touch();
    return o;
  }

  /// 认几种写法：`obj://a`、`out://a`、`path://a`、`stdin://a`、`@a`、`a`。
  ///
  /// 为什么要这么宽容：模型会照着提示词抄 `obj://a`，但也会顺手写
  /// `@a`（因为我们在别处提过这个简写）或者干脆只写 `a`。
  /// 每次都因为"少了四个字符"报错，只会白烧一轮。
  ///
  /// 也接受**串起来**的写法（`path://obj://a`）—— 模型把两种前缀
  /// 叠在一起是常事，为此报错没有意义。
  Obj? lookup(String ref) {
    String s = ref.trim();
    if (s.isEmpty) return null;
    while (true) {
      if (s.startsWith('@')) {
        s = s.substring(1);
        continue;
      }
      final int sep = s.indexOf('://');
      if (sep <= 0) break;
      final String scheme = s.substring(0, sep);
      if (!const <String>{'obj', 'out', 'path', 'stdin', 'file'}.contains(scheme)) {
        break;
      }
      s = s.substring(sep + 3);
    }
    // 去掉可能带上的范围尾巴（`a[10:20]` / `a:10-20` / `a{summary}`）
    final int cut = s.indexOf(RegExp(r'[\[\{]'));
    if (cut > 0) s = s.substring(0, cut);
    s = s.replaceAll(RegExp(r':\d+-\d+c?$'), '');
    return get(s);
  }

  /// 把一个路径包成一个**未注册**的对象，只用于立刻读它。
  ///
  /// 不自动注册：`reader` 只是读一次目录里的文件，没道理占掉一个句柄名额。
  /// 需要留着的走 `geter define`。
  Future<Obj?> fromPath(String path) async {
    final String p = path.trim();
    if (p.isEmpty) return null;
    final FileSystemEntityType t = await FileSystemEntity.type(p);
    if (t == FileSystemEntityType.notFound) return null;
    if (t == FileSystemEntityType.directory) {
      return Obj(id: '_tmp', type: ObjType.dir, size: 0, source: p);
    }
    final File f = File(p);
    int size = 0;
    try {
      size = await f.length();
    } catch (_) {
      return null;
    }
    final ObjType type = await _detectType(f, p);
    return Obj(id: '_tmp', type: type, size: size, source: p);
  }

  /// 登记一段文本。返回的对象可能落盘也可能留在内存。
  Future<Obj> putText(
    String text, {
    String? id,
    ObjType type = ObjType.text,
    String? source,
    bool pinned = false,
    Duration? ttl,
  }) async {
    final String key = _claimId(id);
    final int bytes = utf8.encode(text).length;

    if (bytes <= inlineLimit) {
      final Obj o = Obj(
        id: key,
        type: type,
        size: bytes,
        inline: text,
        source: source,
        pinned: pinned,
        ttl: ttl,
      );
      _store(o);
      return o;
    }

    // 超限：落盘，内存里不留全文
    final File f = await _spillFile(key);
    await f.writeAsString(text, flush: false);
    final Obj o = Obj(
      id: key,
      type: type,
      size: bytes,
      source: f.path,
      pinned: pinned,
      ttl: ttl,
    );
    _store(o);
    return o;
  }

  /// 登记一个已存在的文件（不复制内容）。
  Future<Obj> putFile(
    String path, {
    String? id,
    ObjType? type,
    bool pinned = false,
    Duration? ttl,
  }) async {
    final File f = File(path);
    final int size = await f.length();
    final String key = _claimId(id);
    final Obj o = Obj(
      id: key,
      type: type ?? await _detectType(f, path),
      size: size,
      source: path,
      pinned: pinned,
      ttl: ttl,
    );
    _store(o);
    return o;
  }

  /// 登记一个目录（只记路径，摘要时现列）。
  Future<Obj> putDir(
    String path, {
    String? id,
    bool pinned = false,
    Duration? ttl,
  }) async {
    final String key = _claimId(id);
    final Obj o = Obj(
      id: key,
      type: ObjType.dir,
      size: 0,
      source: path,
      pinned: pinned,
      ttl: ttl,
    );
    o.summaryCache = null;
    _store(o);
    return o;
  }

  void drop(String id) {
    final Obj? o = _objs.remove(id);
    if (o == null) return;
    _deleteSpill(o);
  }

  /// 清掉过期的，再按 LRU 裁到上限。
  void gc() {
    final DateTime now = DateTime.now();
    _objs.removeWhere((String k, Obj o) {
      if (o.pinned) return false;
      if (now.difference(o.createdAt) > o.ttl) {
        _deleteSpill(o);
        return true;
      }
      return false;
    });

    if (_objs.length <= maxObjects) return;
    final List<Obj> candidates =
        _objs.values.where((Obj o) => !o.pinned).toList()
          ..sort((Obj a, Obj b) => a.lastUsed.compareTo(b.lastUsed));
    final int extra = _objs.length - maxObjects;
    for (int i = 0; i < extra && i < candidates.length; i++) {
      _objs.remove(candidates[i].id);
      _deleteSpill(candidates[i]);
    }
  }

  void clear() {
    for (final Obj o in _objs.values) {
      _deleteSpill(o);
    }
    _objs.clear();
  }

  // ------------------------------------------------------------ 读取

  /// 读一段。`byLines` 时 [start]/[end] 是 **1 起算的闭区间**
  /// （`end <= 0` 表示"再往后 [maxRangeLines] 行"）；
  /// 否则是 **0 起算的字符区间**（end 不含）。
  ///
  /// 两条路都**只读需要的那一段**：行模式走流式解码，读到够了就 break，
  /// 40 万字的文件取第 10 万行也只读前 10 万行。
  Future<String> readRange(
    Obj o, {
    int start = 1,
    int end = 0,
    bool byLines = true,
  }) async {
    if (!byLines) {
      if (o.inline != null) return _charRange(o.inline!, start, end);
      final File? f = _fileOf(o);
      if (f == null) return '';
      return _readCharRange(f, start, end);
    }

    final int from = start <= 0 ? 1 : start;
    final int want = end < from ? maxRangeLines : (end - from + 1);
    final int take = want > maxRangeLines ? maxRangeLines : want;

    final StringBuffer sb = StringBuffer();
    int line = 0;
    int got = 0;
    await for (final String text in lineStream(o)) {
      line++;
      if (line < from) continue;
      if (got > 0) sb.write('\n');
      // 也要裁：`reader` 明确要某几行时，那几行本身可能是超长单行，
      // 不裁会绕开所有上限直接把整份内容送进上下文。
      sb.write(clampLine(text));
      got++;
      if (got >= take) break;
    }
    return sb.toString();
  }

  /// 全文（只在明确要、且不超上限时调用）。
  ///
  /// 截断按**字符**算，不按字节：按字节切会把一个中文字符劈成两半，
  /// `allowMalformed` 之后就是一串替换符 —— 那比截断本身更难读。
  Future<String> fullText(Obj o, {int limit = fullExpandLimit}) async {
    final String? inline = o.inline;
    if (inline != null) {
      return inline.length <= limit ? inline : inline.substring(0, limit);
    }
    final File? f = _fileOf(o);
    if (f == null) return '';

    // 先按字节粗读（UTF-8 中文最多 3 字节，所以多读一倍一定够），
    // 再精确裁到 limit 个字符。这样不用把 40 万字的文件整份解码。
    final int byteBudget = limit * 3 + 16;
    final RandomAccessFile raf = await f.open();
    try {
      final int n = await raf.length();
      final int take = n < byteBudget ? n : byteBudget;
      final Uint8List bytes = await raf.read(take);
      final String text = utf8.decode(bytes, allowMalformed: true);
      return text.length <= limit ? text : text.substring(0, limit);
    } finally {
      await raf.close();
    }
  }

  /// 行数。大文件按块扫，不整份进内存。
  ///
  /// 末行没有换行符时也要算一行 —— 习惯上"共 1 行"和"共 0 行"差别很大，
  /// 少算一行会让模型以为文件是空的。
  Future<int> lineCount(Obj o) async {
    final int? cached = o.linesCache;
    if (cached != null) return cached;

    int n;
    if (o.inline != null) {
      final String t = o.inline!;
      n = t.isEmpty ? 0 : '\n'.allMatches(t).length + 1;
    } else {
      final File? f = _fileOf(o);
      if (f == null) return 0;
      n = 0;
      bool lastWasNewline = true;
      await for (final List<int> chunk in f.openRead()) {
        if (chunk.isEmpty) continue;
        for (final int b in chunk) {
          if (b == 10) n++;
        }
        lastWasNewline = chunk.last == 10;
      }
      if (!lastWasNewline) n++;
    }
    o.linesCache = n;
    return n;
  }

  /// 单行最长保留多少字符。
  ///
  /// 压缩过的 JSON、minified 的 JS、导出的 CSV，都可能是**一整行几十万字**。
  /// 按行读时如果不管这个，`reader` 取"第 1–12 行"会原样返回一整个
  /// 50 万字的文件 —— 摘要就不再是摘要了。
  static const int maxLineWidth = 400;

  /// 把一行裁到 [maxLineWidth]，并标出裁了多少。
  static String clampLine(String line) {
    if (line.length <= maxLineWidth) return line;
    return '${line.substring(0, maxLineWidth)}…（这一行还有 '
        '${line.length - maxLineWidth} 个字符）';
  }

  /// 摘要：头部片段 + 结构统计。
  ///
  /// **这是"默认视图"**。模型追问"文件里写了什么"时先给这个，
  /// 它多半就够了；不够再让它指定 range 或 grep —— 那时它已经知道行数，
  /// 能给出一个具体范围，而不是"再给我看看"。
  Future<String> summary(Obj o) async {
    final String? cached = o.summaryCache;
    if (cached != null) return cached;

    final StringBuffer sb = StringBuffer();
    sb.writeln('${o.uri}（${o.type.name}，${humanBytes(o.size)}）');
    if (o.source != null) sb.writeln('路径：${o.source}');

    if (o.type == ObjType.dir) {
      final List<String> names = await _listDir(o.source!);
      sb.writeln('目录，共 ${names.length} 项');
      for (final String n in names.take(40)) {
        sb.writeln('  $n');
      }
      if (names.length > 40) sb.writeln('  …（还有 ${names.length - 40} 项）');
      return o.summaryCache = sb.toString();
    }

    if (o.type == ObjType.binary) {
      sb.writeln('二进制文件，内容不能直接读。');
      sb.writeln('要处理它就把它当路径传给 `sheller`（参数写 `path://${o.id}`）。');
      return o.summaryCache = sb.toString();
    }

    final int lines = await lineCount(o);
    sb.writeln('共 $lines 行、${humanBytes(o.size)}');

    final String head = await readRange(o, start: 1, end: 12);
    if (head.trim().isNotEmpty) {
      sb.writeln('--- 开头 12 行 ---');
      // 逐行裁剪：一整行几十万字的文件（minified JSON / CSV）不裁的话，
      // 摘要会比原文还长，那就完全失去摘要的意义了。
      for (final String line in head.split('\n')) {
        sb.writeln(clampLine(line));
      }
    }

    if (o.type == ObjType.json) {
      final String keys = await _jsonKeys(o);
      if (keys.isNotEmpty) sb.writeln('顶层键：$keys');
    }

    final List<String> marks = await outlineLines(o);
    if (marks.isNotEmpty) {
      sb.writeln('--- 结构（共 ${marks.length} 处，列前 12 处）---');
      for (final String m in marks.take(12)) {
        sb.writeln('  $m');
      }
    }

    sb.writeln();
    sb.writeln(
      '要看细节：`reader` 传 target="${o.uri}" 加 range（行号），'
      '或 mode="grep" 搜关键词。**不要把整份读进来。**',
    );

    return o.summaryCache = sb.toString();
  }

  /// 找"看起来像分节标题"的行：markdown 标题、常见语言的 def/class/func、
  /// 以及全大写/数字编号的短行。
  ///
  /// 这不是语法分析，只是**给模型一个"从哪下手"的索引**。
  /// 判错的代价很小（它拿到一个行号去读，读到的不是标题而已），
  /// 而判不出来时模型就只能从头读到尾 —— 那才是真贵。
  Future<List<String>> outlineLines(Obj o, {int max = 200}) async {
    final List<String> out = <String>[];
    final RegExp re = RegExp(
      r'^\s*(#{1,6}\s+\S|def\s+\w+|class\s+\w+|func\s+\w+|function\s+\w+|'
      r'export\s+(default\s+)?(function|class|const)|'
      r'[A-Z][A-Z0-9 _\-]{3,60}$|'
      r'第[一二三四五六七八九十百]+[章节部分]|'
      r'\d+(\.\d+)*[、.)]\s*\S)',
    );
    int line = 0;
    await for (final String text in lineStream(o)) {
      line++;
      if (text.trim().isEmpty) continue;
      if (re.hasMatch(text)) {
        final String t = text.trim();
        out.add('$line: ${t.length > 90 ? t.substring(0, 90) : t}');
        if (out.length >= max) break;
      }
    }
    return out;
  }

  /// grep：返回命中行 + 上下文。
  ///
  /// 一趟扫过去、不缓存全文：命中前用环形缓冲留着"before"，
  /// 命中后再把后续 [context] 行追加到 after。相邻的命中合并成一条，
  /// 否则一段里连着十行都命中时，输出会和原文一样长 —— 那正好是
  /// 我们要避免的东西。
  Future<List<GrepHit>> grep(
    Obj o,
    String pattern, {
    int context = 2,
    int max = 50,
    bool fixed = false,
  }) async {
    final RegExp? re = fixed ? null : _tryRegex(pattern);
    final List<GrepHit> results = <GrepHit>[];
    final List<String> ring = <String>[];
    final List<_PendingHit> pending = <_PendingHit>[];
    final int ctx = context < 0 ? 0 : context;
    int lineNo = 0;

    await for (final String text in lineStream(o)) {
      lineNo++;

      // 先把这一行补给**上一条**命中（它就是那一条的 after 上下文）。
      // 自己也可能是命中行，但它属于自己那条的正文，不是上下文。
      for (final _PendingHit p in pending) {
        if (p.want > 0 && lineNo > p.hit.line) {
          p.hit.after.add(text);
          p.want--;
        }
      }
      pending.removeWhere((_PendingHit p) => p.want <= 0);

      final bool hit = re != null ? re.hasMatch(text) : text.contains(pattern);
      if (hit) {
        final GrepHit? last = results.isEmpty ? null : results.last;
        if (last != null && lineNo - last.line <= ctx + 1) {
          // 离上一条命中够近 → 并进它：只把窗口重新打开，
          // 不再新起一条（否则一次搜索结果里会有一串重复的上下文）。
          pending.removeWhere((_PendingHit p) => p.hit == last);
          pending.add(_PendingHit(last, ctx));
        } else {
          final GrepHit h = GrepHit(
            line: lineNo,
            text: text,
            before: List<String>.of(ring),
          );
          results.add(h);
          pending.add(_PendingHit(h, ctx));
          if (results.length >= max) break;
        }
      }

      ring.add(text);
      if (ring.length > ctx) ring.removeAt(0);
    }

    return results;
  }

  /// 确保对象在磁盘上有一份，返回路径。
  ///
  /// `sheller` 传 `path://a` 时用它 —— 内存里的对象也得变成文件，
  /// 因为命令行里只能给路径。
  Future<String?> materialize(Obj o) async {
    final String? p = o.source;
    if (p != null) return p;
    final File f = await _spillFile(o.id);
    await f.writeAsString(o.inline ?? '', flush: false);
    o.source = f.path;
    o.inline = null;
    return f.path;
  }

  // ------------------------------------------------------------ 内部

  String _claimId(String? wanted) {
    if (wanted != null) {
      final String clean = wanted
          .trim()
          .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
      if (clean.isNotEmpty && !_objs.containsKey(clean)) return clean;
    }
    while (true) {
      final String id = _base26(_seq++);
      if (!_objs.containsKey(id)) return id;
    }
  }

  /// 0 → a, 25 → z, 26 → aa……
  static String _base26(int n) {
    final StringBuffer sb = StringBuffer();
    int v = n;
    do {
      sb.write(String.fromCharCode(97 + v % 26));
      v = v ~/ 26 - 1;
    } while (v >= 0);
    return sb.toString().split('').reversed.join();
  }

  void _store(Obj o) {
    _objs[o.id] = o;
    if (_objs.length > maxObjects) gc();
  }

  Future<File> _spillFile(String id) async {
    final Directory? dir = _dir;
    if (dir == null) {
      // 没有落盘目录时退到系统临时目录。功能不降级，只是重启就没了。
      return File('${Directory.systemTemp.path}/dsh_obj_$id.bin');
    }
    await dir.create(recursive: true);
    return File('${dir.path}/$id.bin');
  }

  File? _fileOf(Obj o) {
    final String? p = o.source;
    if (p == null) return null;
    return File(p);
  }

  void _deleteSpill(Obj o) {
    final String? p = o.source;
    if (p == null) return;
    // 只删**我们自己摊出来的**临时文件：`putFile` 登记的 source 是用户的
    // 原文件，删了就是删用户的东西。
    final Directory? dir = _dir;
    final bool ours = p.endsWith('.bin') &&
        (dir == null
            ? p.startsWith(Directory.systemTemp.path)
            : p.startsWith(dir.path));
    if (!ours) return;
    try {
      File(p).deleteSync();
    } catch (_) {
      // 删不掉就算了，下次 gc 还会遇到它
    }
  }

  static Future<ObjType> _detectType(File f, String path) async {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.json')) return ObjType.json;
    if (lower.endsWith('.sh') ||
        lower.endsWith('.py') ||
        lower.endsWith('.js') ||
        lower.endsWith('.dart')) {
      return ObjType.script;
    }
    // 二进制判定：前 4KB 里有 NUL 就不是文本
    try {
      final RandomAccessFile raf = await f.open();
      try {
        final Uint8List head = await raf.read(4096);
        for (final int b in head) {
          if (b == 0) return ObjType.binary;
        }
      } finally {
        await raf.close();
      }
    } catch (_) {
      return ObjType.binary;
    }
    return ObjType.text;
  }

  static Future<List<String>> _listDir(String path) async {
    try {
      final List<String> out = <String>[];
      await for (final FileSystemEntity e in Directory(
        path,
      ).list(followLinks: false)) {
        final String name = e.path.split(RegExp(r'[/\\]')).last;
        out.add(e is Directory ? '$name/' : name);
        if (out.length > 500) break;
      }
      out.sort();
      return out;
    } catch (_) {
      return <String>[];
    }
  }

  Future<String> _jsonKeys(Obj o) async {
    try {
      final String head = await fullText(o, limit: 8192);
      final dynamic v = jsonDecode(head);
      if (v is Map) return v.keys.take(30).join(', ');
      if (v is List) return '数组，${v.length} 项';
    } catch (_) {
      // 大 JSON 只读了前半段 → 解析必然失败，那就不报键，不误导
    }
    return '';
  }

  /// 逐行流式读。**唯一**的读入口 —— grep / outline / lineCount / readRange
  /// 都走它，这样"大文件不进内存"只有一处需要保证。
  Stream<String> lineStream(Obj o) async* {
    final String? text = o.inline;
    if (text != null) {
      yield* Stream<String>.fromIterable(text.split('\n'));
      return;
    }
    final File? f = _fileOf(o);
    if (f == null) return;
    // allowMalformed 兜住 GBK 之类的非 UTF-8 文本 —— 否则一个编码不对的
    // 日志文件会让整个工具抛异常，而模型只是想知道里面写了什么。
    yield* f
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
  }

  Future<String> _readCharRange(File f, int start, int end) async {
    final int from = start < 0 ? 0 : start;
    final int want = end <= from ? 4096 : end - from;
    final int take = want > inlineLimit ? inlineLimit : want;
    final RandomAccessFile raf = await f.open();
    try {
      await raf.setPosition(from);
      final Uint8List bytes = await raf.read(take);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await raf.close();
    }
  }

  static String _charRange(String text, int start, int end) {
    final int from = start < 0 ? 0 : (start > text.length ? text.length : start);
    final int to = end <= from
        ? (from + 4096 > text.length ? text.length : from + 4096)
        : (end > text.length ? text.length : end);
    return text.substring(from, to);
  }

  /// 人能一眼读懂的字节数。
  static String humanBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static RegExp? _tryRegex(String p) {
    try {
      return RegExp(p, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }
}

/// grep 期间"还在等后续上下文行"的一条命中。
class _PendingHit {
  _PendingHit(this.hit, this.want);

  final GrepHit hit;

  /// 还要再收几行 after。
  int want;
}
