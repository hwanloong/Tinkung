import 'dart:io';

import '../core/model_paths.dart';
import '../core/models.dart';
import '../core/varbank.dart';
import 'tool.dart';

/// **变量库工具**：把长内容存成有名变量，之后只引用不搬运。
///
/// ## 它和 `geter`（对象池）的分工
///
/// 两者都能"把大内容移出上下文"，但用途不同：
/// · `geter` 是**一次任务里的搬运**：`obj://a` 匿名、24h 过期，
///   适合"这个命令输出我要用几次"。
/// · `varbank` 是**长期共享的语料**：有名字、永久落盘，
///   适合"这段方案我后面每个对话都要引用"。
///
/// 用户说"把这段存起来，以后引用"时用这个；模型自己为了省 token
/// 搬一次输出，用 `geter`。
///
/// ## `store` 的三种来源
///
/// · `text`：直接给正文（用户粘一段时）；
/// · `source`：一个文件路径 —— 这时可以配合 `range` / `grep`
///   只存其中一段（用户要的"把第 24 到 90 行存进 varbank"）。
class VarBankTool extends AgentTool {
  const VarBankTool();

  @override
  String get name => 'varbank';

  @override
  String get title => '变量库';

  @override
  String get description =>
      '变量库：把要反复引用的长内容存成**有名变量**，之后用 `{{名字}}` 引用。\n'
      '引用时系统自动替换成正文，你和用户**都不需要把内容抄一遍**。\n'
      '\n'
      '动作：\n'
      '· save：存一个变量。name（名字）+ text（正文），或 source（文件路径）\n'
      '  —— 给了 source 还能配 `range`（行范围）或 `grep`（按关键词取段）只存一部分\n'
      '· get：取一个变量的内容或范围，as=full（默认）/ range / summary\n'
      '· list：列出所有变量（名字、大小、行数、用途）\n'
      '· search：按名字或正文关键词找变量\n'
      '· drop：删掉一个变量（**不可恢复**，删前跟用户确认）\n'
      '· append：往已有变量末尾追加内容\n'
      '\n'
      '引用语法（在输出、工具参数、用户消息里都能用）：\n'
      '· `{{名字}}` —— 全文\n'
      '· `{{名字:10-20}}` —— 第 10–20 行\n'
      '· `{{名字:0-500c}}` —— 前 500 个字符\n'
      '\n'
      '**什么时候该存**：用户给了一段要反复引用的内容（规格、方案、长代码、\n'
      '原始数据），或者你自己产出了一份后面还要用的长文本。\n'
      '**什么时候不该存**：一次性的中间结果（那是 `geter` 的活）、\n'
      '或者用户明确说"就用这一次"。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'op': <String, dynamic>{
        'type': 'string',
        'enum': <String>['save', 'get', 'list', 'search', 'drop', 'append'],
        'description': '默认 save。',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': '变量名（字母、数字、下划线、汉字，不能以数字开头）。',
      },
      'text': <String, dynamic>{
        'type': 'string',
        'description': 'save/append 的正文。和 source 二选一。',
      },
      'source': <String, dynamic>{
        'type': 'string',
        'description': 'save 时从文件读取（此时可配 range / grep 只存一段）。',
      },
      'range': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'start': <String, dynamic>{'type': 'integer', 'description': '起始行，1 起算'},
          'end': <String, dynamic>{'type': 'integer', 'description': '结束行，含'},
        },
        'description': '只存文件/变量的某几行。',
      },
      'grep': <String, dynamic>{
        'type': 'string',
        'description': '只存含这个关键词（或正则）的行，连同它前后 2 行。',
      },
      'note': <String, dynamic>{
        'type': 'string',
        'description': '一句话说明这个变量是干什么用的（给用户和模型看）。',
      },
      'overwrite': <String, dynamic>{
        'type': 'boolean',
        'description': 'save 时同名变量已存在，是否覆盖。默认 false（会报错）。',
      },
      'as': <String, dynamic>{
        'type': 'string',
        'enum': <String>['full', 'range', 'summary'],
        'description': 'get 时取哪种形态，默认 full。',
      },
      'query': <String, dynamic>{
        'type': 'string',
        'description': 'search 的关键词。',
      },
    },
    'required': <String>['op'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String op = args.str('op', fallback: 'save');
    if (op == 'drop') {
      return RiskAssessment(RiskLevel.caution, <String>[
        '删掉变量「${args.str('name')}」（不可恢复）',
      ]);
    }
    if (op == 'save' && args.boolVal('overwrite', fallback: false)) {
      return RiskAssessment(RiskLevel.caution, <String>[
        '覆盖变量「${args.str('name')}」（旧内容会丢失）',
      ]);
    }
    return RiskAssessment.safe;
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String op = args.str('op', fallback: 'save');
    final String name = args.str('name');
    return switch (op) {
      'list' => '看变量库',
      'search' => '在变量库里找 ${args.str('query')}',
      'drop' => '删变量 $name',
      'get' => '取变量 $name',
      'append' => '往 $name 追加',
      _ => name.isEmpty ? '存进变量库' : '存成 {{$name}}',
    };
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final VarBankStore store = VarBankStore.instance;
    final String op = args.str('op', fallback: 'save');

    switch (op) {
      case 'list':
        return store.listForModel();

      case 'search':
        final List<Variable> hits = store.search(args.str('query'));
        if (hits.isEmpty) {
          return '变量库里没有匹配「${args.str('query')}」的变量。';
        }
        final StringBuffer sb = StringBuffer('找到 ${hits.length} 个：\n');
        for (final Variable v in hits.take(20)) {
          sb.writeln('- ${v.label}');
        }
        return sb.toString();

      case 'drop':
        final String name = args.str('name');
        if (!store.has(name)) return '没有叫「$name」的变量。';
        store.drop(name);
        return '已删掉变量「$name」。';

      case 'append':
        final String err = store.append(args.str('name'), args.str('text')) ?? '';
        if (err.isNotEmpty) return err;
        final Variable? v = store.get(args.str('name'));
        return '已追加到「${args.str('name')}」，'
            '现在 ${v?.lines ?? 0} 行 / ${v?.bytes ?? 0} 字节。';

      case 'get':
        return _get(store, args);

      default:
        return _save(ctx, store, args);
    }
  }

  Future<String> _get(VarBankStore store, Map<String, dynamic> args) async {
    final String name = args.str('name').trim();
    final Variable? v = store.get(name);
    if (v == null) {
      return '没有叫「$name」的变量。用 `varbank` 的 list 看看有哪些。';
    }
    final String as = args.str('as', fallback: 'full');
    if (as == 'summary') return v.label;

    final Map<String, dynamic> range = args.mapVal('range');
    final int start = (range['start'] as num?)?.toInt() ?? 1;
    final int end = (range['end'] as num?)?.toInt() ?? 0;
    if (as == 'range' || range.isNotEmpty) {
      final String body = store.range(v.name, start: start, end: end);
      return '【{{${v.name}}} 第 $start–${end > 0 ? end : start + 1999} 行，'
          '共 ${v.lines} 行】\n$body';
    }
    return '【{{${v.name}}}，共 ${v.lines} 行】\n${v.text}';
  }

  Future<String> _save(
    ToolContext ctx,
    VarBankStore store,
    Map<String, dynamic> args,
  ) async {
    final String name = args.str('name').trim();
    if (!VarBankStore.isValidName(name)) {
      return '变量名不合法：${VarBankStore.nameError(name)}';
    }

    final String source = args.str('source').trim();
    String text = args.str('text');

    // ---- 从文件读 ----
    if (source.isNotEmpty) {
      final String path = resolveModelPath(source, baseDir: ctx.workDir);
      final File f = File(path);
      if (!await f.exists()) {
        if (text.isEmpty) {
          return '找不到文件 $source。用 `filesearch` 确认路径，'
              '或者直接把内容放在 text 里。';
        }
      } else {
        try {
          text = await f.readAsString();
        } catch (e) {
          return '$source 读不成文本（可能是二进制）：$e';
        }
        final Map<String, dynamic> range = args.mapVal('range');
        final String grep = args.str('grep').trim();
        if (grep.isNotEmpty) {
          text = _grepSection(text, grep);
          if (text.isEmpty) {
            return '$source 里没有匹配「$grep」的行，什么都没存。';
          }
        } else if (range.isNotEmpty) {
          final List<String> lines = text.split('\n');
          final int s = (((range['start'] as num?)?.toInt() ?? 1) - 1)
              .clamp(0, lines.length);
          final int e = ((range['end'] as num?)?.toInt() ?? lines.length)
              .clamp(s, lines.length);
          text = '${lines.sublist(s, e).join('\n')}\n';
        }
      }
    }

    if (text.isEmpty) {
      return '没有内容可以存：给 text，或者给一个能读到的 source。';
    }

    final String? err = store.set(
      name,
      text,
      note: args.str('note'),
      overwrite: args.boolVal('overwrite', fallback: false),
    );
    if (err != null) return err;

    final Variable? v = store.get(name);
    return '已存成 `{{$name}}`'
        '（${v?.lines ?? 0} 行，${v?.bytes ?? 0} 字节）。\n'
        '以后在正文里写 `{{$name}}` 就会展开成这段内容；'
        '也可以写 `{{$name:10-20}}` 只取第 10–20 行。'
        '**不要自己把正文抄一遍。**';
  }

  /// 取含关键词的行 + 前后各 2 行。
  static String _grepSection(String text, String pattern) {
    final List<String> lines = text.split('\n');
    final RegExp re;
    try {
      re = RegExp(pattern, caseSensitive: false);
    } catch (_) {
      // 不是合法正则就按纯文本找。
      final String low = pattern.toLowerCase();
      final List<String> out = <String>[];
      for (int i = 0; i < lines.length; i++) {
        if (!lines[i].toLowerCase().contains(low)) continue;
        for (int j = (i - 2).clamp(0, lines.length);
            j <= (i + 2).clamp(0, lines.length - 1);
            j++) {
          out.add(lines[j]);
        }
        out.add('---');
      }
      return out.join('\n');
    }
    final List<String> out = <String>[];
    for (int i = 0; i < lines.length; i++) {
      if (!re.hasMatch(lines[i])) continue;
      for (int j = (i - 2).clamp(0, lines.length);
          j <= (i + 2).clamp(0, lines.length - 1);
          j++) {
        out.add(lines[j]);
      }
      out.add('---');
    }
    return out.join('\n');
  }
}
