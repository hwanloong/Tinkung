import 'dart:convert';

/// 工具参数的**结构校验**，以及"同一条调用"的**规范化标识**。
///
/// ## 为什么要在执行前再校验一次
///
/// `parseToolArgs` 只回答"这是不是一个 JSON 对象"。模型给出的
/// `{"action":"list"}` 对 `writer` 来说是**合法 JSON、错误调用** ——
/// 少了必填的 `path`/`old`。以前的处理是原样交给工具，由每个工具各写
/// 一段自己的 `if (x.isEmpty) return '错误：缺少 x'`：
///
///  · 有的写全了，有的漏；漏的那个会把 `null` 当空串静默做点什么；
///  · 错误文本格式各不相同，模型拿到后往往不理解是"参数不合法"，
///    而是以为"这个工具坏了"，于是换工具或者向用户报告失败；
///  · 校验发生在**确认之后**：用户先被问了一次"要不要执行"，
///    点完才发现根本执行不了 —— 那一次打扰完全是白费的。
///
/// 所以这里在**弹确认框之前**按工具自己声明的 `parameters` 校验一遍：
/// 缺必填、类型不对、枚举值不在允许集合里，都直接判 failed，错误文本
/// 写清楚"哪个字段、期望什么、收到了什么"，只回给模型，不打扰用户。
///
/// ## 刻意**不**拒绝未知字段
///
/// 模型多带一个 `purpose` / `reason` 是很常见的（有时是上一版 schema
/// 的残留）。为此把一条本来能正常工作的调用判失败，代价远大于收益：
/// 工具读参数都是按 key 取的，多出来的字段会被自然忽略。
///
/// ## 校验的是 schema，不是实现
///
/// 只认 JSON Schema 里最常用的那几个关键字（required / type / enum）。
/// 工具没写 `required` 或 `type` 的字段一律放行 —— 宁可漏检，
/// 也不要因为 schema 写得简单就把合法调用拦下来。
class ToolArgsCheck {
  const ToolArgsCheck(this.ok, this.message);

  final bool ok;

  /// 失败时给**模型**看的说明；成功时为空串。
  final String message;

  static const ToolArgsCheck pass = ToolArgsCheck(true, '');
}

/// 按 [schema]（工具的 `parameters`）校验 [args]。
///
/// [toolName] 只用在错误文本里 —— 模型一次可能发好几条调用，
/// 说清楚是哪一条的哪个字段不对，它才改得准。
ToolArgsCheck validateToolArgs(
  String toolName,
  Map<String, dynamic> schema,
  Map<String, dynamic> args,
) {
  final List<String> problems = <String>[];

  // ---- 必填 ----
  final dynamic rawRequired = schema['required'];
  if (rawRequired is List) {
    final List<String> missing = <String>[
      for (final dynamic e in rawRequired)
        if (e is String && e.isNotEmpty && !_present(args, e)) e,
    ];
    if (missing.isNotEmpty) {
      problems.add('缺少必填参数：${missing.join('、')}');
    }
  }

  // ---- 类型 / 枚举 ----
  final dynamic rawProps = schema['properties'];
  if (rawProps is Map) {
    rawProps.forEach((dynamic key, dynamic def) {
      if (key is! String || def is! Map) return;
      final Map<String, dynamic> prop = Map<String, dynamic>.from(def);
      if (!_present(args, key)) return;

      final dynamic value = args[key];
      final dynamic rawType = prop['type'];
      if (rawType is String && !_typeMatches(rawType, value)) {
        problems.add(
          '参数 $key 应为 $rawType，收到的是 '
          '${_describe(value)}',
        );
        return;
      }

      final dynamic rawEnum = prop['enum'];
      if (rawEnum is List && rawEnum.isNotEmpty && !rawEnum.contains(value)) {
        problems.add(
          '参数 $key 只能是 ${_enumList(rawEnum)} 之一，'
          '收到的是 ${_describe(value)}',
        );
      }
    });
  }

  if (problems.isEmpty) return ToolArgsCheck.pass;

  return ToolArgsCheck(
    false,
    '错误：调用「$toolName」的参数不符合要求 —— '
    '${problems.join('；')}。'
    '请按工具定义修正参数后重新发起调用，不要原样重发。',
  );
}

/// 字段**出现且不是 null** 才算给了。
///
/// 模型把可选字段写成 `"path": null` 是常见输出；按"没给"处理，
/// 才不会把它当成类型错误（空串 `""` 仍算"给了" —— 有些工具用它表示
/// 明确的空值，是否合法由工具自己决定）。
bool _present(Map<String, dynamic> args, String key) =>
    args.containsKey(key) && args[key] != null;

bool _typeMatches(String type, dynamic value) {
  return switch (type) {
    'string' => value is String,
    // 模型有时给 3 而不是 3.0；整数也接受 number
    'number' => value is num,
    'integer' => value is int || (value is double && value == value.roundToDouble()),
    'boolean' => value is bool,
    'array' => value is List,
    'object' => value is Map,
    // 认不出的类型（联合类型、自定义）一律放行
    _ => true,
  };
}

String _describe(dynamic value) {
  if (value == null) return 'null';
  final String text = value is String ? value : jsonEncode(value);
  if (text.length <= 60) return '「$text」';
  return '「${text.substring(0, 60)}…」';
}

String _enumList(List<dynamic> values) =>
    values.map((dynamic e) => e.toString()).join(' / ');

/// 同一条调用的**规范化标识**：`工具名 + 按 key 排序后的参数`。
///
/// 原来两处（同轮去重、失败熔断）都用 `名字 + 原始 JSON 原文` 做键，
/// 而模型对同一件事的两次输出经常只差空白或 **key 的顺序**：
///
/// ```
/// {"path":"/a.txt","mode":"raw"}
/// {"mode":"raw","path":"/a.txt"}
/// ```
///
/// 语义完全一样，原文不同 —— 去重失效（重复执行、重复计 token），
/// 熔断失效（同一条坏调用可以无限重试，每次烧一整轮请求）。
///
/// [raw] 用于"解析根本不成功"的情况（那时没有结构化参数可比），
/// 此时退回原文，至少保证一模一样的坏 JSON 能被认出来。
String canonicalToolKey(
  String name,
  Map<String, dynamic> args, {
  String raw = '',
}) {
  String body;
  if (args.isNotEmpty) {
    body = _stableJson(args);
  } else {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return '$name\u0000{}';
    body = trimmed;
    try {
      final dynamic decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        body = _stableJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 解析不了就用原文（上面已经赋过），至少一模一样的坏 JSON 能认出来
    }
  }
  return '$name\u0000$body';
}

/// key 排序后再编码，保证同一组参数只有一种写法。
String _stableJson(Map<String, dynamic> map) {
  final List<String> keys = map.keys.map((String k) => k).toList()..sort();
  return jsonEncode(<String, dynamic>{for (final String k in keys) k: map[k]});
}
