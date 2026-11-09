import 'dart:io';

import 'obj_store.dart';

/// 一次引用解析的结果。
class Resolved {
  const Resolved({
    required this.text,
    this.warnings = const <String>[],
    this.truncated = false,
  });

  /// 展开后的文本（`render` 模式）或解析出的路径（`exec` 模式）。
  final String text;

  /// 展不开 / 降级 / 超限之类的说明。**要一起交给模型** ——
  /// 悄悄降级会让它以为自己拿到了全文。
  final List<String> warnings;

  /// 是否因为超限被截断。
  final bool truncated;
}

/// 解析模式。
enum ResolveMode {
  /// 输出侧渲染：把引用换成文本内容（超限降级成摘要）。
  render,

  /// 执行侧：把引用换成**真实路径**，绝不展开全文。
  ///
  /// 这是整个方案里最关键的一条：命令行有 `ARG_MAX`（Linux 上约 2MB，
  /// 而 Android 的 `bionic` 更小），把 40 万字拼进参数会直接 `E2BIG`。
  /// 更要命的是那种失败**看起来像"命令写错了"**，模型会去改命令，
  /// 而真正的原因是它根本不该把内容放进命令行。
  path,

  /// 解析成 stdin 流（给需要从标准输入读的命令用）。
  stdin,
}

/// **引用解析器**：把 `{{obj://a}}` / `@a[10:20]` 换成内容或路径。
///
/// ## 为什么引用语法要带"怎么用"的信息
///
/// 光有 `{{obj://a}}` 不够：同一个对象在**输出**里要全文（或摘要），
/// 在**命令行参数**里只能给路径，在**管道**里要给 stdin。三种用途
/// 解析结果完全不同，而模型并不总能说清自己要哪种。
///
/// 所以语法里带上形态：`path://a` 一定解析成路径，`stdin://a` 一定
/// 解析成流。裸的 `{{obj://a}}` 只在输出侧出现 —— 那是唯一"展开成文本"
/// 说得通的地方。
///
/// ## 防递归
///
/// 展开出来的内容**不再扫一遍**。否则一个文件里写着 `{{obj://b}}`
/// 就会把 b 也拉进来，写成 `{{obj://a}}` 时直接自引用无限循环。
/// 只展开一层是刻意的限制，不是没做完。
class Resolver {
  const Resolver._();

  /// 匹配 `{{...}}`（最外层，不嵌套）和 `@名字` 简写。
  ///
  /// `@` 简写**必须**前后是空白/行首/标点，否则 `a@b.com` 这种邮箱
  /// 会被当成引用 —— 而这个文本是要交给模型的，改错一个字符就是事故。
  static final RegExp _mustache = RegExp(r'\{\{([^{}]*)\}\}');
  static final RegExp _at = RegExp(r'(^|[\s(\[,;:、，。])@([A-Za-z][A-Za-z0-9_]*)');

  /// 解析一段文本里的所有引用。
  static Future<Resolved> resolve(
    String input, {
    required ResolveMode mode,
    ObjStore? store,
    int limit = ObjStore.inlineLimit,
  }) async {
    final ObjStore s = store ?? ObjStore.instance;
    final List<String> warnings = <String>[];
    bool truncated = false;

    String out = input;

    // ---- `{{...}}` ----
    //
    // 用**收集后统一替换**而不是边扫边 replaceAll：替换进去的内容里
    // 可能恰好含有 `{{`，边替换会把它当成新的引用再展开一次。
    final List<({int start, int end, String body})> mustacheHits =
        <({int start, int end, String body})>[];
    for (final RegExpMatch m in _mustache.allMatches(input)) {
      mustacheHits.add((start: m.start, end: m.end, body: m.group(1)!.trim()));
    }

    if (mustacheHits.isNotEmpty) {
      final StringBuffer sb = StringBuffer();
      int cursor = 0;
      for (final ({int start, int end, String body}) h in mustacheHits) {
        sb.write(input.substring(cursor, h.start));
        final _Expansion e = await _expand(
          h.body,
          mode: mode,
          store: s,
          limit: limit,
        );
        sb.write(e.text);
        warnings.addAll(e.warnings);
        truncated = truncated || e.truncated;
        cursor = h.end;
      }
      sb.write(input.substring(cursor));
      out = sb.toString();
    }

    // ---- `@a` 简写 ----
    //
    // 只在 `render` 模式下展开：执行侧的 `@a` 容易被当成其他含义
    // （awk 的 `@`、某些工具的参数），自动替换会破坏命令。
    if (mode == ResolveMode.render && out.contains('@')) {
      final StringBuffer sb = StringBuffer();
      int cursor = 0;
      for (final RegExpMatch m in _at.allMatches(out)) {
        final String id = m.group(2)!;
        final Obj? o = s.lookup(id);
        // 认不出来就**原样留着**：那可能只是正文里提到某人的 @，
        // 换成一句「引用不存在」反而是破坏。
        if (o == null) continue;
        sb.write(out.substring(cursor, m.start));
        sb.write(m.group(1) ?? '');
        final _Expansion e = await _expand(
          id,
          mode: ResolveMode.render,
          store: s,
          limit: limit,
        );
        sb.write(e.text);
        warnings.addAll(e.warnings);
        truncated = truncated || e.truncated;
        cursor = m.end;
      }
      if (cursor > 0) {
        sb.write(out.substring(cursor));
        out = sb.toString();
      }
    }

    return Resolved(text: out, warnings: warnings, truncated: truncated);
  }

  /// 解析**一个**引用（工具参数里单值的那种）。
  static Future<Resolved> resolveOne(
    String ref, {
    required ResolveMode mode,
    ObjStore? store,
    int limit = ObjStore.inlineLimit,
  }) async {
    final ObjStore s = store ?? ObjStore.instance;
    final _Expansion e = await _expand(ref, mode: mode, store: s, limit: limit);
    return Resolved(
      text: e.text,
      warnings: e.warnings,
      truncated: e.truncated,
    );
  }

  /// 语法：`obj://a`、`path://a`、`stdin://a`、`@a`、`a`，
  /// 可带 `[起:止]`（行）或 `[起:止]c`（字符）或 `{summary}`。
  static Future<_Expansion> _expand(
    String raw, {
    required ResolveMode mode,
    required ObjStore store,
    required int limit,
  }) async {
    String body = raw.trim();
    if (body.isEmpty) return _Expansion(raw);

    // 显式形态前缀
    bool wantPath = false;
    bool wantStdin = false;
    if (body.startsWith('path://')) {
      wantPath = true;
      body = body.substring(7);
    } else if (body.startsWith('stdin://')) {
      wantStdin = true;
      body = body.substring(8);
    } else if (body.startsWith('obj://') || body.startsWith('out://')) {
      body = body.substring(body.indexOf('://') + 3);
    } else if (body.startsWith('@')) {
      body = body.substring(1);
    }

    // 取后缀：{summary} / [a:b] / [a:b]c / :a-b / :a-bc
    bool wantSummary = false;
    int? rangeStart;
    int? rangeEnd;
    bool rangeByChars = false;

    final int brace = body.indexOf('{');
    if (brace >= 0 && body.endsWith('}')) {
      final String kind = body.substring(brace + 1, body.length - 1).trim();
      body = body.substring(0, brace);
      if (kind == 'summary') wantSummary = true;
      // 不认识的 {xxx} 不当作后缀，原样当 id 的一部分 —— 报"找不到"
      // 比默默改成摘要更好，后者会让模型以为自己在看正文。
      if (!wantSummary) return _Expansion(raw);
    }

    // 方括号写法：`a[10:20]` / `a[10:20]c`
    final RegExpMatch? rm = RegExp(
      r'^(.*)\[(\d*):(\d*)\](c?)$',
    ).firstMatch(body);
    if (rm != null) {
      body = rm.group(1)!;
      rangeStart = rm.group(2)!.isEmpty ? null : int.tryParse(rm.group(2)!);
      rangeEnd = rm.group(3)!.isEmpty ? null : int.tryParse(rm.group(3)!);
      rangeByChars = rm.group(4) == 'c';
    } else {
      // 冒号写法：`{{obj://a:10-20}}`（提示词里教的就是这个）。
      //
      // 句柄 id 只有字母数字下划线，所以末尾的 `数字-数字` 一定是范围，
      // 不会和 id 本身混淆。
      final RegExpMatch? cm = RegExp(
        r'^(.*?):(\d+)-(\d+)(c?)$',
      ).firstMatch(body);
      if (cm != null) {
        body = cm.group(1)!;
        rangeStart = int.tryParse(cm.group(2)!);
        rangeEnd = int.tryParse(cm.group(3)!);
        rangeByChars = cm.group(4) == 'c';
      }
    }

    final Obj? o = store.lookup(body);
    if (o == null) {
      // 实在认不出来：路径模式原样返回（模型可能只是想传一个普通路径），
      // 渲染模式留一句明确的说明 —— 静默返回空串会让它以为文件是空的。
      if (mode != ResolveMode.render) return _Expansion(raw);
      return _Expansion(
        '',
        warnings: <String>['引用 `$raw` 找不到对应对象（可能已过期，重新定义或直接给路径）'],
      );
    }

    if (wantStdin) {
      final String? p = await store.materialize(o);
      return _Expansion(p ?? o.uri);
    }

    if (wantPath || mode == ResolveMode.path) {
      final String? p = await store.materialize(o);
      if (p == null) {
        return _Expansion(
          '',
          warnings: <String>['`${o.uri}` 没法落到磁盘，不能当路径用'],
        );
      }
      return _Expansion(p);
    }

    if (mode == ResolveMode.stdin) {
      final String? p = await store.materialize(o);
      return _Expansion(p ?? o.uri);
    }

    // ---- render ----
    if (wantSummary) {
      return _Expansion(await store.summary(o));
    }

    final bool hasRange = rangeStart != null || rangeEnd != null;
    if (!hasRange) {
      // 没给范围：小的给全文，大的降级成摘要。
      final bool small = o.size <= limit;
      if (small) {
        return _Expansion(await store.fullText(o, limit: limit));
      }
      return _Expansion(
        await store.summary(o),
        truncated: true,
        warnings: <String>[
          '`${o.uri}` 有 ${ObjStore.humanBytes(o.size)}，超过单次展开上限，'
          '已换成摘要。要正文请用 `reader` 指定 range 或 grep。',
        ],
      );
    }

    final String body2 = await store.readRange(
      o,
      start: rangeStart ?? (rangeByChars ? 0 : 1),
      end: rangeEnd ?? 0,
      byLines: !rangeByChars,
    );
    return _Expansion(body2);
  }
}

class _Expansion {
  const _Expansion(
    this.text, {
    this.warnings = const <String>[],
    this.truncated = false,
  });

  final String text;
  final List<String> warnings;
  final bool truncated;
}

/// 把一个参数值解析成**真实路径**。给 `sheller` 用。
///
/// 规则很简单：能解析成对象就给它的磁盘路径，否则当普通路径原样返回。
/// 调用方负责再 quote 一次 —— 这里只负责"字符串 → 路径"。
Future<String> resolvePathArg(String value, {ObjStore? store}) async {
  final ObjStore s = store ?? ObjStore.instance;
  final String v = value.trim();
  if (!v.contains('://') && !v.startsWith('@')) return value;

  final Obj? o = s.lookup(v);
  if (o == null) {
    // `path://xxx` 但 xxx 不是句柄时，xxx 本身就是路径
    if (v.startsWith('path://')) return v.substring(7);
    return value;
  }
  final String? p = await s.materialize(o);
  return p ?? value;
}

/// 目录里所有文件加起来有多大。给 `filesearch` 的 `total_estimate` 用。
///
/// 只在已经拿到的条目上算，**不额外扫盘** —— 为了一个"估算"再去遍历
/// 一遍目录，比它带来的信息价值贵得多。
String totalHint(int items, int bytes) {
  if (items == 0) return '没有匹配的文件';
  return '$items 项，合计 ${ObjStore.humanBytes(bytes)}';
}

/// 把一段输出包成 `out://` 句柄，只回摘要。
///
/// `sheller` / `reader` 的输出都走这里：**大结果绝不直接进上下文**。
/// 阈值比 `inlineLimit` 小得多（8KB 对 64KB），因为工具输出是
/// **每一轮都要重发一遍**的东西 —— 一次 60KB 的输出，十轮就是 600KB。
Future<Resolved> packOutput(
  String text, {
  String? label,
  int inlineMax = 8192,
  ObjStore? store,
}) async {
  final ObjStore s = store ?? ObjStore.instance;
  if (text.length <= inlineMax) {
    return Resolved(text: text);
  }
  final Obj o = await s.putText(text, type: ObjType.text);
  final String head = text.substring(0, inlineMax);
  return Resolved(
    text: '$head\n\n'
        '（输出共 ${text.length} 字符，已在 ${o.uri} 处完整保存${label == null ? '' : '：$label'}。'
        '要看后面的部分用 `reader` 传 target="${o.uri}" 加 range，'
        '或 grep 关键词。**不要把整份读回来**。）',
    truncated: true,
    warnings: <String>['输出超过 $inlineMax 字符，完整内容存为 ${o.uri}'],
  );
}

/// 当前进程里有没有可用的落盘目录（给诊断信息用）。
String spillState(ObjStore store) {
  final List<Obj> all = store.all;
  if (all.isEmpty) return '对象池为空';
  int bytes = 0;
  for (final Obj o in all) {
    bytes += o.size;
  }
  return '${all.length} 个对象，合计 ${ObjStore.humanBytes(bytes)}';
}

/// 判断一个字符串是不是一个已存在的本地路径。
Future<bool> looksLikePath(String s) async {
  final String v = s.trim();
  if (v.isEmpty) return false;
  if (v.contains('\n')) return false;
  if (v.length > 512) return false;
  try {
    return await File(v).exists() || await Directory(v).exists();
  } catch (_) {
    return false;
  }
}
