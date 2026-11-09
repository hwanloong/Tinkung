import 'dart:convert';

import '../core/ids.dart';
import '../core/models.dart';
import '../plugins/plugin.dart';
import 'tool.dart';

/// 让 agent **看见并修改**自定义插件。
///
/// ## 为什么需要它
///
/// 插件是"不写代码就给 agent 加工具"的机制：声明名字、参数、
/// 把这些参数拼成 shell 命令或 HTTP 请求，运行时就是一个标准工具。
///
/// 但在此之前，它只能由用户在界面里一条条填表单 —— 而"加一个能查天气的
/// 工具""把那个查 IP 的插件改成走另一个接口"这类话说出来是没人接的。
/// agent 既不晓得插件存在，也改不了。
///
/// 接上之后，用户可以直接说"给我加一个查快递的工具"，
/// agent 用 [PluginTool] 建出来，**下一次对话它就能自己调**。
///
/// ## 为什么只允许 shell / http 两种
///
/// 插件的执行引擎就这两种（见 [PluginKind]）。让模型"写一段 Dart"
/// 是不行的 —— 那需要运行时编译，而这个机制成立的前提正是
/// "不改代码也能扩展"。所以这里如实限定，模型编不出来。
class PluginManageTool extends AgentTool {
  const PluginManageTool();

  @override
  String get name => 'plugin';

  @override
  String get title => '插件';

  @override
  String get description =>
      '管理**自定义插件**。插件 = 给 agent 新增一个可调用的工具，'
      '本质是"把参数拼进一条 shell 命令或一个 HTTP 请求"。\n'
      '用户说"帮我加一个能查 X 的工具""把那个插件改成…""禁用掉 Y 插件"时用它。\n'
      'action:\n'
      '· `list` —— 列出所有插件（含 id、kind、模板、是否启用）\n'
      '· `get` —— 看某个插件的完整定义\n'
      '· `create` —— 新建。必须给 name（函数名，英文标识符）、title、'
      'kind（shell/http）、template；可给 params 描述参数\n'
      '· `update` —— 改已有插件（只需给要改的字段）\n'
      '· `enable` / `disable` —— 按 id 开关\n'
      '· `delete` —— 按 id 删除（**不可撤销**）\n'
      '模板里用 `{{参数名}}` 占位，例如 shell 的 `getprop {{key}}`、'
      'http 的 `https://api.x.com/v1/{{path}}`。\n'
      '注意：建好/改好后**下一轮对话**它才会出现在你的工具列表里 —— '
      '当前这一轮调用不了它。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'list',
          'get',
          'create',
          'update',
          'enable',
          'disable',
          'delete',
        ],
      },
      'id': <String, dynamic>{
        'type': 'string',
        'description':
            '插件 id（get/update/enable/disable/delete 用）。'
            '也可以用 name 代替。',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description':
            '函数名（英文标识符，如 get_weather）。'
            '是模型调用时用的名字。',
      },
      'title': <String, dynamic>{
        'type': 'string',
        'description': '给人看的短标题，如「查天气」',
      },
      'description': <String, dynamic>{
        'type': 'string',
        'description':
            '给模型看的说明：什么时候该用它。'
            '写清楚能显著提高它被正确调用的概率。',
      },
      'kind': <String, dynamic>{
        'type': 'string',
        'enum': <String>['shell', 'http'],
        'description': 'shell = 拼命令交给终端；http = 发请求',
      },
      'template': <String, dynamic>{
        'type': 'string',
        'description':
            '模板。shell 是命令（`getprop {{key}}`）；'
            'http 是 URL（`https://api.x.com/v1/{{path}}`）',
      },
      'method': <String, dynamic>{
        'type': 'string',
        'description': 'http 的方法，GET / POST…',
      },
      'headers': <String, dynamic>{
        'type': 'object',
        'description': 'http 请求头，如 {"X-Key": "{{key}}"}',
      },
      'body': <String, dynamic>{
        'type': 'string',
        'description': 'http 的请求体模板（POST 用）',
      },
      'params': <String, dynamic>{
        'type': 'array',
        'description':
            '参数列表。每项 {name, description, required, '
            'defaultValue}。name 要和模板里的 {{…}} 对上。',
        'items': <String, dynamic>{'type': 'object'},
      },
      'risk': <String, dynamic>{
        'type': 'string',
        'enum': <String>['safe', 'caution', 'dangerous'],
        'description':
            '风险等级。只读查询用 safe；'
            '会改状态的用 caution（默认）；危险操作 dangerous。',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    return switch (args.str('action')) {
      // 改/删插件等于**改 agent 自己的能力边界**，必须让用户过一眼
      'create' || 'update' || 'delete' || 'enable' || 'disable' =>
        const RiskAssessment(RiskLevel.caution, <String>['会改变 agent 可用的工具']),
      _ => RiskAssessment.safe,
    };
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String a = args.str('action');
    return switch (a) {
      'create' => '新建插件 ${args.str('name')}',
      'update' => '修改插件 ${args.str('id').ifEmpty(args.str('name'))}',
      'list' => '列出插件',
      _ => '$a ${args.str('id').ifEmpty(args.str('name'))}',
    };
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final PluginStore store = ctx.plugins;
    final String action = args.str('action').trim().toLowerCase();

    switch (action) {
      case 'list':
        if (store.plugins.isEmpty) {
          return '还没有任何自定义插件。\n'
              '（用户想加的话，你可以用 action=create 建一个，'
              'kind 只能是 shell 或 http。）';
        }
        final StringBuffer sb = StringBuffer(
          '共 ${store.plugins.length} 个插件：\n',
        );
        for (final CustomPlugin p in store.plugins) {
          sb.writeln('- ${p.name}（${p.title}）· id: ${p.id}');
          sb.writeln(
            '  kind: ${p.kind.name} · '
            '${p.enabled ? '已启用' : '已禁用'} · 风险: ${p.risk.name}',
          );
          sb.writeln('  模板: ${p.template}');
          if (p.description.isNotEmpty) {
            sb.writeln('  说明: ${clampOutput(p.description, max: 80)}');
          }
        }
        return sb.toString();

      case 'get':
        final CustomPlugin? p = _find(store, args);
        if (p == null) return 'get 失败：找不到这个插件。';
        return const JsonEncoder.withIndent('  ').convert(p.toJson());

      case 'create':
        return _create(store, args);

      case 'update':
        return _update(store, args);

      case 'enable':
      case 'disable':
        final CustomPlugin? p = _find(store, args);
        if (p == null) return '$action 失败：找不到这个插件。';
        p.enabled = action == 'enable';
        await store.saveQuietly();
        return '已${action == 'enable' ? '启用' : '禁用'}「${p.title}」。'
            '${action == 'enable' ? '' : '（它不会再出现在工具列表里）'}';

      case 'delete':
        final CustomPlugin? p = _find(store, args);
        if (p == null) return 'delete 失败：找不到这个插件。';
        final String name = p.title;
        store.plugins.removeWhere((CustomPlugin e) => e.id == p.id);
        await store.saveQuietly();
        return '已删除插件「$name」。';

      default:
        return '未知 action「$action」。可用：list / get / create / update / '
            'enable / disable / delete';
    }
  }

  Future<String> _create(PluginStore store, Map<String, dynamic> args) async {
    final String name = args.str('name').trim();
    final String template = args.str('template').trim();

    if (name.isEmpty) return 'create 失败：name 不能为空（英文标识符）。';
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) {
      return 'create 失败：name 必须是合法标识符'
          '（字母/下划线开头，只含字母数字下划线），当前是「$name」。';
    }
    if (store.plugins.any((CustomPlugin p) => p.name == name)) {
      return 'create 失败：已经有一个叫 $name 的插件了。'
          '想改它请用 update。';
    }
    if (template.isEmpty) return 'create 失败：template 不能为空。';

    final PluginKind kind = _kindOf(args.str('kind'));
    final List<PluginParam> params = _paramsOf(args['params']);

    // 模板里引用了不存在的参数 → 运行时那个占位符永远不会被替换，
    // 命令会带着字面量 {{x}} 去执行，报错还很莫名。
    // 所以这里就挡掉，而不是等跑的时候才发现。
    final String? missing = _missingPlaceholder(template, params);
    if (missing != null && params.isNotEmpty) {
      return 'create 失败：模板里用了 {{$missing}}，'
          '但 params 里没有叫 $missing 的参数。';
    }

    final CustomPlugin p = CustomPlugin(
      id: 'pl_${newId()}',
      name: name,
      title: args.str('title').trim().ifEmpty(name),
      description: args.str('description').trim(),
      kind: kind,
      template: template,
      method: args.str('method').trim().ifEmpty('GET').toUpperCase(),
      headers: _headersOf(args['headers']),
      body: args.str('body'),
      params: params,
      risk: _riskOf(args.str('risk')),
    );

    store.plugins.add(p);
    await store.saveQuietly();
    return _created(p);
  }

  Future<String> _update(PluginStore store, Map<String, dynamic> args) async {
    final CustomPlugin? p = _find(store, args);
    if (p == null) return 'update 失败：找不到这个插件。';

    if (args.containsKey('title')) {
      p.title = args.str('title').trim().ifEmpty(p.title);
    }
    if (args.containsKey('description')) {
      p.description = args.str('description').trim();
    }
    if (args.containsKey('kind')) p.kind = _kindOf(args.str('kind'));
    if (args.containsKey('template')) {
      final String t = args.str('template').trim();
      if (t.isEmpty) return 'update 失败：template 不能为空。';
      p.template = t;
    }
    if (args.containsKey('method')) {
      p.method = args.str('method').trim().ifEmpty(p.method).toUpperCase();
    }
    if (args.containsKey('headers')) p.headers = _headersOf(args['headers']);
    if (args.containsKey('body')) p.body = args.str('body');
    if (args.containsKey('params')) p.params = _paramsOf(args['params']);
    if (args.containsKey('risk')) p.risk = _riskOf(args.str('risk'));
    if (args.containsKey('enabled')) {
      p.enabled = args.str('enabled') != 'false';
    }

    final String? missing = _missingPlaceholder(p.template, p.params);
    if (missing != null && p.params.isNotEmpty) {
      // 已经改在对象上了，但模板和参数对不上 —— 回滚这一块，别留下坏插件
      return 'update 失败：模板里用了 {{$missing}}，'
          '但 params 里没有这个参数。请同时更新 params。';
    }

    await store.saveQuietly();
    return '已更新插件「${p.title}」。改动下一轮对话生效。';
  }

  static CustomPlugin? _find(PluginStore store, Map<String, dynamic> args) {
    final String id = args.str('id').trim();
    final String name = args.str('name').trim();
    for (final CustomPlugin p in store.plugins) {
      if (id.isNotEmpty && p.id == id) return p;
      if (id.isNotEmpty && p.name == id) return p;
      if (name.isNotEmpty && p.name == name) return p;
    }
    return null;
  }

  static PluginKind _kindOf(String raw) =>
      raw.trim().toLowerCase() == 'http' ? PluginKind.http : PluginKind.shell;

  static RiskLevel _riskOf(String raw) {
    final String r = raw.trim().toLowerCase();
    for (final RiskLevel l in RiskLevel.values) {
      if (l.name == r) return l;
    }
    return RiskLevel.caution;
  }

  static Map<String, String> _headersOf(dynamic raw) {
    if (raw is! Map) return <String, String>{};
    return raw.map(
      (dynamic k, dynamic v) =>
          MapEntry<String, String>(k.toString(), v.toString()),
    );
  }

  static List<PluginParam> _paramsOf(dynamic raw) {
    if (raw is! List) return <PluginParam>[];
    final List<PluginParam> out = <PluginParam>[];
    for (final dynamic e in raw) {
      if (e is Map) {
        final PluginParam p = PluginParam.fromJson(
          Map<String, dynamic>.from(e),
        );
        if (p.name.trim().isNotEmpty) out.add(p);
      }
    }
    return out;
  }

  /// 模板里第一个"没有对应参数"的占位符名，没有则 null。
  static String? _missingPlaceholder(String template, List<PluginParam> ps) {
    for (final RegExpMatch m in RegExp(
      r'\{\{\s*([a-zA-Z0-9_]+)\s*\}\}',
    ).allMatches(template)) {
      final String key = m.group(1)!;
      if (!ps.any((PluginParam p) => p.name == key)) return key;
    }
    return null;
  }

  static String _created(CustomPlugin p) {
    final StringBuffer sb = StringBuffer();
    sb.writeln('已创建插件「${p.title}」（函数名 ${p.name}，id: ${p.id}）');
    sb.writeln('kind: ${p.kind.name}');
    sb.writeln('模板: ${p.template}');
    if (p.params.isNotEmpty) {
      sb.writeln('参数: ${p.params.map((PluginParam e) => e.name).join(', ')}');
    }
    sb.writeln('');
    sb.writeln(
      '⚠️ **这一轮你还调用不了它** —— 工具列表在每轮开始时构建。'
      '下一轮对话它就会出现。',
    );
    return sb.toString();
  }
}

extension _StrX on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
