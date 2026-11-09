import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// **变量库（varbank）**里的一条变量。
///
/// 和「对象池」（`obj://a`）的区别，是这一节最重要的设计决定：
///
/// | | 对象池 `obj://a` | 变量库 `{{名字}}` |
/// |---|---|---|
/// | 名字 | 自动的 `a`/`b`/`c` | **用户/AI 起的有意义的名字** |
/// | 存活 | 24h 后过期、LRU 淘汰 | **永久落盘**，直到主动删 |
/// | 内容 | 指向磁盘上的文件，只存引用 | **正文就存在库里**（可很大） |
/// | 谁用 | 模型在一场任务里搬大内容 | 用户和模型**长期共享**的语料 |
///
/// 所以它不能直接建在 `ObjStore` 上：对象池的句柄是"临时的、匿名的、
/// 指向别处的"，而变量库要的是"永久的、有名字的、自包含的"。
/// 两者混在一起会让"这个 a 还在不在"变成一个要靠 TTL 回答的问题 ——
/// 而用户说"把我刚才那段存起来"时，他要的显然不是 24 小时后过期的东西。
class Variable {
  Variable({
    required this.name,
    required this.text,
    this.note = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  /// 变量名。引用时写 `{{名字}}`。
  ///
  /// 限制为字母、数字、下划线、汉字 —— 见 [isValidName]。
  final String name;

  /// 变量的正文。这里就是全部内容，不是路径。
  String text;

  /// 一句话说明这是干什么用的。给用户在列表里看，也给模型判断该不该用。
  String note;

  final DateTime createdAt;
  DateTime updatedAt;

  int get bytes => utf8.encode(text).length;

  int get lines => text.isEmpty ? 0 : '\n'.allMatches(text).length + 1;

  /// 引用写法。
  String get ref => '{{$name}}';

  /// 给模型看的一行元数据。
  String get label =>
      '$ref  ${humanBytes(bytes)}  $lines 行'
      '${note.isEmpty ? '' : '  —— $note'}';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'text': text,
    'note': note,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  static Variable fromJson(Map<String, dynamic> j) => Variable(
    name: j['name']?.toString() ?? '',
    text: j['text']?.toString() ?? '',
    note: j['note']?.toString() ?? '',
    createdAt:
        DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt']?.toString() ?? '') ?? DateTime.now(),
  );
}

/// 变量库的存储。
///
/// ## 为什么是"一个 JSON 文件 + 单例"
///
/// 和 `MemoryStore` / `ObjStore` 同一个理由：引用要在**工具执行深处**
/// 被解析（`reader` 收到 `{{方案}}` 要展开、AI 输出里要展开、用户发消息
/// 前要展开），从 `main()` 一路透传下去要改十几个文件。
///
/// 落盘成单个 JSON：变量总量在"几十个、每个几十 KB"这个量级，
/// 一次全读进内存是几 MB，可以接受；而拆成一堆小文件会让"名字 → 文件"
/// 这一步多一次 stat，并且要处理文件名里的中文和特殊字符。
/// 真的有人把几百 MB 塞进来时，[maxTotalBytes] 会先拦住。
class VarBankStore extends ChangeNotifier {
  VarBankStore._(this._file);

  static VarBankStore? _instance;

  /// 没初始化时**返回一个纯内存的**，而不是抛异常。
  ///
  /// 和 `ObjStore` 同一考虑：它被用到的路径（展开引用）深处在工具执行里，
  /// 那里抛异常会把整场对话打断，而"少了个落盘目录"只是变量重启后没了。
  static VarBankStore get instance => _instance ??= VarBankStore._(null);

  static Future<VarBankStore> configure(File file) async {
    final VarBankStore s = VarBankStore._(file);
    _instance = s;
    await s.load();
    return s;
  }

  @visibleForTesting
  static void resetForTest() => _instance = null;

  final File? _file;
  final Map<String, Variable> _vars = <String, Variable>{};

  /// 单个变量的长度上限。20 万字（约 400KB）已经远超任何"要引用的语料"，
  /// 再大的东西该走 `geter` 的对象池（指向文件），而不是复制进库里。
  static const int maxVarChars = 200 * 1000;

  /// 变量总字节上限。所有变量都常驻内存，必须有个天花板。
  static const int maxTotalBytes = 8 * 1024 * 1024;

  /// 变量个数上限。
  static const int maxVars = 200;

  /// 名字合法性：字母、数字、下划线、汉字；不能以数字开头。
  ///
  /// 为什么不接受任意字符：`{{...}}` 会出现在**正则**（`grep`）、
  /// **shell 命令**、**markdown** 里，名字里带空格或标点会让这些地方
  /// 全部需要转义，而转义规则各不相同 —— 迟早有一处漏掉。
  static final RegExp _nameRe = RegExp(r'^[A-Za-z_\u4e00-\u9fa5][A-Za-z0-9_\u4e00-\u9fa5]{0,63}$');

  static bool isValidName(String name) => _nameRe.hasMatch(name.trim());

  /// 名字非法时给模型/用户看的原因。
  static String nameError(String name) {
    final String n = name.trim();
    if (n.isEmpty) return '变量名不能为空';
    if (n.length > 64) return '变量名太长（最多 64 个字符）';
    if (RegExp(r'^\d').hasMatch(n)) return '变量名不能以数字开头';
    return '变量名只能用字母、数字、下划线、汉字（不能有空格和标点）';
  }

  List<Variable> get all {
    final List<Variable> list = _vars.values.toList();
    list.sort((Variable a, Variable b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  bool get isEmpty => _vars.isEmpty;

  int get totalBytes =>
      _vars.values.fold<int>(0, (int s, Variable v) => s + v.bytes);

  Variable? get(String name) => _vars[name.trim()];

  bool has(String name) => _vars.containsKey(name.trim());

  Future<void> load() async {
    _vars.clear();
    final File? f = _file;
    if (f == null) {
      notifyListeners();
      return;
    }
    try {
      if (await f.exists()) {
        final dynamic data = jsonDecode(await f.readAsString());
        if (data is List) {
          for (final dynamic e in data) {
            final Variable v = Variable.fromJson(
              Map<String, dynamic>.from(e as Map),
            );
            if (v.name.isNotEmpty) _vars[v.name] = v;
          }
        }
      }
    } catch (_) {
      _vars.clear();
    }
    notifyListeners();
  }

  Future<void> save() async {
    final File? f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(_vars.values.map((Variable v) => v.toJson()).toList()),
      );
    } catch (_) {
      // 写失败不致命
    }
  }

  void _changed() {
    notifyListeners();
    save();
  }

  /// 存入一个变量。返回 null 表示成功，否则是给模型/用户看的失败原因。
  ///
  /// [overwrite] 为 false 时（默认）同名会报错 —— 覆盖一个已有变量是
  /// **破坏性**的，用户不会希望"随手存一段"把他精心整理的语料冲掉。
  String? set(
    String name,
    String text, {
    String note = '',
    bool overwrite = false,
  }) {
    final String n = name.trim();
    if (!isValidName(n)) return nameError(n);
    if (text.isEmpty) return '内容为空，没有存';

    final Variable? old = _vars[n];
    if (old != null && !overwrite) {
      return '已经有一个叫「$n」的变量了（${humanBytes(old.bytes)}，'
          '更新于 ${_ago(old.updatedAt)}）。\n'
          '要替换它请显式传 overwrite=true；想换个名字就换个名字。';
    }
    if (text.length > maxVarChars) {
      return '内容太长（${text.length} 字符，上限 $maxVarChars）。'
          '更大的内容应该放进文件、用 `geter` 登记成句柄，而不是复制进变量库。';
    }
    if (old == null && _vars.length >= maxVars) {
      return '变量个数已达上限（$maxVars）。先删掉一些不再需要的。';
    }

    final int nextTotal =
        totalBytes - (old?.bytes ?? 0) + utf8.encode(text).length;
    if (nextTotal > maxTotalBytes) {
      return '变量库总量会超过上限 ${humanBytes(maxTotalBytes)}'
          '（现在 ${humanBytes(totalBytes)}）。先删掉一些大的。';
    }

    if (old != null) {
      old.text = text;
      if (note.isNotEmpty) old.note = note;
      old.updatedAt = DateTime.now();
    } else {
      _vars[n] = Variable(name: n, text: text, note: note);
    }
    _changed();
    return null;
  }

  /// 追加内容。比 set 更适合"继续往里加"的场景。
  String? append(String name, String text) {
    final String n = name.trim();
    if (!isValidName(n)) return nameError(n);
    final Variable? v = _vars[n];
    if (v == null) return '没有叫「$n」的变量';
    return set(n, '${v.text}\n$text', overwrite: true);
  }

  bool drop(String name) {
    final bool removed = _vars.remove(name.trim()) != null;
    if (removed) _changed();
    return removed;
  }

  void clear() {
    _vars.clear();
    _changed();
  }

  /// 按名字或正文片段找。给"我不知道它叫什么了"的场景。
  List<Variable> search(String keyword) {
    final String k = keyword.trim().toLowerCase();
    if (k.isEmpty) return <Variable>[];
    return all
        .where(
          (Variable v) =>
              v.name.toLowerCase().contains(k) ||
              v.note.toLowerCase().contains(k) ||
              v.text.toLowerCase().contains(k),
        )
        .toList();
  }

  /// 取一段范围（按行或按字符）。
  ///
  /// `{{变量:10-20}}` 走行；`{{变量:0-500c}}` 走字符。和 `reader` 的
  /// range 语义保持一致，用户和模型不用记两套。
  String range(
    String name, {
    int? start,
    int? end,
    bool byLines = true,
  }) {
    final Variable? v = _vars[name.trim()];
    if (v == null) return '';
    final String text = v.text;
    if (byLines) {
      final List<String> lines = text.split('\n');
      final int s = ((start ?? 1) - 1).clamp(0, lines.length);
      final int e = (end == null || end <= 0)
          ? (s + 2000).clamp(0, lines.length)
          : end.clamp(0, lines.length);
      if (s >= lines.length) return '';
      return '${lines.sublist(s, e).join('\n')}\n';
    }
    final int s = (start ?? 0).clamp(0, text.length);
    final int e = (end == null || end <= 0) ? text.length : end.clamp(0, text.length);
    if (s >= text.length) return '';
    return text.substring(s, e);
  }

  /// 给模型看的一览。变量多时只列名字和大小，不列正文。
  String listForModel() {
    if (_vars.isEmpty) {
      return '变量库是空的。可以把一段要反复引用的内容存进来。';
    }
    final StringBuffer sb = StringBuffer('变量库（${_vars.length} 个）：\n');
    for (final Variable v in all) {
      sb.writeln('- ${v.label}');
    }
    sb.writeln(
      '引用：正文里写 `{{名字}}` 会展开成全文；'
      '`{{名字:10-20}}` 只要第 10–20 行；`{{名字:0-500c}}` 要前 500 个字符。',
    );
    return sb.toString();
  }

  /// 拼成注入系统提示词的一小段。
  ///
  /// **只列名字和用途，绝不注入正文**：变量库的正文常常是几万字，
  /// 每轮都带上会直接把上下文吃满。模型要用的时候自己展开。
  String toPromptSection() {
    if (_vars.isEmpty) return '';
    final StringBuffer sb = StringBuffer();
    sb.writeln();
    sb.writeln('## 变量库');
    sb.writeln(
      '用户和你可以共享一组**命名变量**。引用它们时写 `{{名字}}`，'
      '系统会自动替换成正文 —— **不要自己把正文抄一遍**。',
    );
    for (final Variable v in all.take(40)) {
      sb.writeln(
        '- `{{${v.name}}}`（${humanBytes(v.bytes)}，${v.lines} 行）'
        '${v.note.isEmpty ? '' : '：${v.note}'}',
      );
    }
    if (_vars.length > 40) {
      sb.writeln('（还有 ${_vars.length - 40} 个，用 `varbank` 工具列出来看。）');
    }
    sb.writeln(
      '可带范围：`{{名字:10-20}}`（第 10–20 行）、`{{名字:0-500c}}`（前 500 字符）。',
    );
    return sb.toString();
  }

  /// 把一段文本里所有**能认出来**的 `{{名字}}` 展开。
  ///
  /// 认不出的一律**原样留着**：那可能只是 markdown、代码里的花括号，
  /// 换成一句"找不到变量"反而是破坏。和 [Resolver] 的取舍一致。
  ///
  /// 展开**不做递归**：展开出来的内容里若又出现 `{{...}}`，不再扫一遍。
  /// 否则一个变量内容里写着 `{{自己}}` 就会无限循环。
  String expand(String input) {
    if (input.isEmpty || !input.contains('{{')) return input;
    final StringBuffer sb = StringBuffer();
    int cursor = 0;
    for (final RegExpMatch m in _mustache.allMatches(input)) {
      final String body = m.group(1)!.trim();
      final _VarRef? ref = _parse(body);
      if (ref == null) continue;
      final Variable? v = _vars[ref.name];
      if (v == null) continue;
      sb.write(input.substring(cursor, m.start));
      sb.write(_render(v, ref));
      cursor = m.end;
    }
    if (cursor == 0) return input;
    sb.write(input.substring(cursor));
    return sb.toString();
  }

  static final RegExp _mustache = RegExp(r'\{\{([^{}\n]*)\}\}');

  /// 解析 `名字` / `名字:10-20` / `名字:0-500c` / `名字[10:20]`。
  static _VarRef? _parse(String body) {
    if (body.isEmpty) return null;
    // 方括号写法
    final RegExpMatch? br = RegExp(
      r'^([A-Za-z_\u4e00-\u9fa5][A-Za-z0-9_\u4e00-\u9fa5]*)\[(\d*):(\d*)\](c?)$',
    ).firstMatch(body);
    if (br != null) {
      return _VarRef(
        name: br.group(1)!,
        start: br.group(2)!.isEmpty ? null : int.tryParse(br.group(2)!),
        end: br.group(3)!.isEmpty ? null : int.tryParse(br.group(3)!),
        byChars: br.group(4) == 'c',
      );
    }
    // 冒号写法
    final RegExpMatch? cm = RegExp(
      r'^([A-Za-z_\u4e00-\u9fa5][A-Za-z0-9_\u4e00-\u9fa5]*):(\d+)-(\d+)(c?)$',
    ).firstMatch(body);
    if (cm != null) {
      return _VarRef(
        name: cm.group(1)!,
        start: int.tryParse(cm.group(2)!),
        end: int.tryParse(cm.group(3)!),
        byChars: cm.group(4) == 'c',
      );
    }
    // 裸名字
    if (isValidName(body)) return _VarRef(name: body);
    return null;
  }

  String _render(Variable v, _VarRef ref) {
    if (ref.start == null && ref.end == null) return v.text;
    return range(
      v.name,
      start: ref.start ?? (ref.byChars ? 0 : 1),
      end: ref.end,
      byLines: !ref.byChars,
    );
  }

  /// 一段文本里出现了哪些**已存在**的变量名。给 UI 做高亮用。
  Set<String> namesIn(String text) {
    if (!text.contains('{{')) return <String>{};
    final Set<String> out = <String>{};
    for (final RegExpMatch m in _mustache.allMatches(text)) {
      final _VarRef? ref = _parse(m.group(1)!.trim());
      if (ref != null && _vars.containsKey(ref.name)) out.add(ref.name);
    }
    return out;
  }
}

class _VarRef {
  const _VarRef({required this.name, this.start, this.end, this.byChars = false});

  final String name;
  final int? start;
  final int? end;
  final bool byChars;
}

String humanBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}

String _ago(DateTime t) {
  final Duration d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}

/// 生成一个不冲突的变量名（`var1`、`var2`…）。
String freshVarName(VarBankStore store) {
  for (int i = 1; i < 100000; i++) {
    final String n = 'var$i';
    if (!store.has(n)) return n;
  }
  return 'var${DateTime.now().millisecondsSinceEpoch}';
}
