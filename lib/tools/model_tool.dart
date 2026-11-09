import 'dart:convert';

import '../core/ids.dart';
import '../core/model_profile.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'tool.dart';

/// 让模型自己管理模型档案。
///
/// 这是一个**高权限工具**：改一条档案的地址，下一轮对话的提示词和
/// 工具结果就会发到另一个服务器。所以除 `list` 外一律按 dangerous
/// 处理，必须由用户点确认；用户点过「全部运行」后才自动执行。
class ModelManagerTool extends AgentTool {
  const ModelManagerTool();

  @override
  String get name => 'model_manager';

  @override
  String get title => '模型管理';

  @override
  String get description =>
      '查看、添加、修改、切换、删除模型档案，或调整当前模型的思考深度。'
      'action=list 只读；其它 action 会修改本机配置，需要用户确认。'
      '不会回显 API Key。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'list',
          'add',
          'update',
          'switch',
          'set_thinking',
          'delete',
        ],
        'description': '要执行的操作',
      },
      'id': <String, dynamic>{
        'type': 'string',
        'description': '模型档案 id；也可以改用 name 或 model 匹配',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': '展示名；add 时必填，其它操作可作为定位条件',
      },
      'note': <String, dynamic>{
        'type': 'string',
        'description': '备注，说明这个模型拿来做什么',
      },
      'base_url': <String, dynamic>{
        'type': 'string',
        'description': 'OpenAI 兼容接口地址，例如 https://api.deepseek.com',
      },
      'api_key': <String, dynamic>{
        'type': 'string',
        'description': 'API Key。add 时通常需要；update 时留空表示不改',
      },
      'model': <String, dynamic>{
        'type': 'string',
        'description': 'API 里的模型名，例如 deepseek-flash',
      },
      'thinking': <String, dynamic>{'type': 'boolean', 'description': '是否开启思考'},
      'effort': <String, dynamic>{
        'type': 'string',
        'enum': <String>['low', 'high', 'max'],
        'description': '思考深度',
      },
      'thinking_style': <String, dynamic>{
        'type': 'string',
        'enum': <String>['effort', 'deepseek', 'openai', 'anthropic', 'none'],
        'description': '思考参数形状；普通 OpenAI 兼容服务用 effort',
      },
      'vision': <String, dynamic>{'type': 'boolean', 'description': '是否支持图像输入'},
      'chat': <String, dynamic>{'type': 'boolean', 'description': '是否能用于对话'},
      'context_limit': <String, dynamic>{
        'type': 'integer',
        'description': '上下文窗口 token 数，0 表示默认',
      },
      'basic_tools': <String, dynamic>{
        'type': 'boolean',
        'description':
            'true 表示只开放联网、Python、笔记、任务、模型管理等基础工具；'
            'false 表示不限制',
      },
      'activate': <String, dynamic>{
        'type': 'boolean',
        'description': 'add 后或 update 后是否立即切换到这个模型',
      },
    },
    'required': <String>['action'],
    'additionalProperties': false,
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    if (args.str('action') == 'list') return RiskAssessment.safe;
    return const RiskAssessment(RiskLevel.dangerous, <String>[
      '会修改模型地址、密钥或当前使用的模型',
    ]);
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String action = args.str('action', fallback: 'list');
    final String target = args.str('name').trim().isNotEmpty
        ? args.str('name').trim()
        : args.str('id').trim();
    return target.isEmpty ? '模型管理 · $action' : '模型管理 · $action · $target';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final Settings settings = ctx.settings;
    final String action = args.str('action').trim().toLowerCase();

    switch (action) {
      case 'list':
        return _list(settings);
      case 'add':
        return _add(settings, args);
      case 'update':
        return _update(settings, args);
      case 'switch':
        return _switch(settings, args);
      case 'set_thinking':
        return _setThinking(settings, args);
      case 'delete':
        return _delete(settings, args);
      default:
        return 'BAD_ARG — action 只能是 list / add / update / switch / '
            'set_thinking / delete。';
    }
  }

  String _list(Settings settings) {
    if (settings.profiles.isEmpty) {
      return '当前没有模型档案。可以用 action=add 添加一个。';
    }
    final List<Map<String, dynamic>> rows = settings.profiles
        .map(
          (ModelProfile p) => <String, dynamic>{
            'id': p.id,
            'name': p.displayName,
            'model': p.model,
            'base_url': p.baseUrl,
            'active': settings.isActive(p.id),
            'usable': p.usable,
            'chat': p.chat,
            'vision': p.vision,
            'thinking': p.thinking,
            'effort': p.reasoningEffort,
            'tools': p.basicToolsOnly ? 'basic' : 'all',
            'builtin': p.builtinFree,
            'note': p.note,
          },
        )
        .toList();
    return const JsonEncoder.withIndent('  ').convert(rows);
  }

  Future<String> _add(Settings settings, Map<String, dynamic> args) async {
    final String name = args.str('name').trim();
    final String baseUrl = args.str('base_url').trim();
    final String model = args.str('model').trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      return 'BAD_ARG — add 需要 name、base_url、model 三个字段。';
    }
    if (!_validUrl(baseUrl)) {
      return 'BAD_ARG — base_url 要写成完整网址，例如 https://api.deepseek.com';
    }

    final ModelProfile p = ModelProfile(
      id: newId(),
      name: name,
      note: args.str('note').trim(),
      baseUrl: baseUrl,
      apiKey: args.str('api_key').trim(),
      model: model,
      thinking: args.boolVal('thinking', fallback: true),
      thinkingStyle: _styleOf(args.str('thinking_style')),
      reasoningEffort: _effortOf(args.str('effort')),
      vision: args.boolVal('vision', fallback: true),
      chat: args.boolVal('chat', fallback: true),
      contextLimit: args.intVal('context_limit'),
      toolAllowlist: args.boolVal('basic_tools') ? kBasicToolAllowlist : null,
    );
    final bool activate = args.boolVal('activate', fallback: true);
    await settings.update(() => settings.addProfile(p, activate: activate));
    if (activate) _syncTopLevel(settings);
    return 'OK — 已${activate ? '添加并切换到' : '添加'}「${p.displayName}」'
        '（${p.model} @ ${p.host}）。';
  }

  Future<String> _update(Settings settings, Map<String, dynamic> args) async {
    final ModelProfile? target = _resolve(settings, args);
    if (target == null) return _notFound(args);

    final bool clearAllow =
        args.containsKey('basic_tools') && !args.boolVal('basic_tools');
    final ModelProfile next = target.copyWith(
      name: args.containsKey('name') ? args.str('name').trim() : null,
      note: args.containsKey('note') ? args.str('note').trim() : null,
      baseUrl: args.containsKey('base_url')
          ? args.str('base_url').trim()
          : null,
      apiKey: args.str('api_key').trim().isEmpty
          ? null
          : args.str('api_key').trim(),
      model: args.containsKey('model') ? args.str('model').trim() : null,
      thinking: args.containsKey('thinking') ? args.boolVal('thinking') : null,
      thinkingStyle: args.containsKey('thinking_style')
          ? _styleOf(args.str('thinking_style'))
          : null,
      reasoningEffort: args.containsKey('effort')
          ? _effortOf(args.str('effort'))
          : null,
      vision: args.containsKey('vision') ? args.boolVal('vision') : null,
      chat: args.containsKey('chat') ? args.boolVal('chat') : null,
      contextLimit: args.containsKey('context_limit')
          ? args.intVal('context_limit')
          : null,
      toolAllowlist: args.boolVal('basic_tools') ? kBasicToolAllowlist : null,
      clearToolAllowlist: clearAllow,
    );
    if (!_validUrl(next.baseUrl)) {
      return 'BAD_ARG — base_url 要写成完整网址，例如 https://api.deepseek.com';
    }

    await settings.update(() {
      settings.updateProfile(next);
      if (args.boolVal('activate', fallback: false)) {
        settings.selectProfile(next.id);
      }
    });
    if (settings.isActive(next.id)) _syncTopLevel(settings);
    return 'OK — 已更新「${next.displayName}」。';
  }

  Future<String> _switch(Settings settings, Map<String, dynamic> args) async {
    final ModelProfile? target = _resolve(settings, args);
    if (target == null) return _notFound(args);
    if (!target.chat) {
      return 'BAD_ARG — 「${target.displayName}」被标记为仅生图，不能切换成对话模型。';
    }
    await settings.update(() {
      settings.selectProfile(target.id);
    });
    _syncTopLevel(settings);
    return 'OK — 已切换到「${target.displayName}」'
        '（${target.model}，思考 ${target.reasoningEffort}）。';
  }

  Future<String> _setThinking(
    Settings settings,
    Map<String, dynamic> args,
  ) async {
    final ModelProfile? target = _resolve(settings, args);
    if (target == null) return _notFound(args);
    final bool enabled = args.containsKey('thinking')
        ? args.boolVal('thinking')
        : target.thinking;
    final String effort = args.containsKey('effort')
        ? _effortOf(args.str('effort'))
        : target.reasoningEffort;

    final ModelProfile next = target.copyWith(
      thinking: enabled,
      reasoningEffort: effort,
      thinkingStyle: args.containsKey('thinking_style')
          ? _styleOf(args.str('thinking_style'))
          : null,
    );
    await settings.update(() {
      settings.updateProfile(next);
      if (settings.isActive(next.id)) {
        settings.thinkingEnabled = enabled;
        settings.reasoningEffort = effort;
      }
    });
    return 'OK —「${next.displayName}」思考${enabled ? '开启' : '关闭'}，'
        '深度 $effort。';
  }

  Future<String> _delete(Settings settings, Map<String, dynamic> args) async {
    final ModelProfile? target = _resolve(settings, args);
    if (target == null) return _notFound(args);
    if (target.builtinFree) {
      return 'BAD_ARG — 内置免费模型不能删除；可以切换或编辑它。';
    }
    await settings.update(() => settings.removeProfile(target.id));
    return 'OK — 已删除「${target.displayName}」。';
  }

  ModelProfile? _resolve(Settings settings, Map<String, dynamic> args) {
    final String id = args.str('id').trim();
    final String name = args.str('name').trim();
    final String model = args.str('model').trim();
    for (final ModelProfile p in settings.profiles) {
      if (id.isNotEmpty && p.id == id) return p;
    }
    for (final ModelProfile p in settings.profiles) {
      if (name.isNotEmpty &&
          (p.name == name || p.displayName == name || p.model == name)) {
        return p;
      }
    }
    for (final ModelProfile p in settings.profiles) {
      if (model.isNotEmpty && p.model == model) return p;
    }
    return null;
  }

  String _notFound(Map<String, dynamic> args) {
    final String q = <String>[
      args.str('id').trim(),
      args.str('name').trim(),
      args.str('model').trim(),
    ].where((String s) => s.isNotEmpty).join(' / ');
    return q.isEmpty
        ? 'BAD_ARG — 要指定 id、name 或 model 来定位模型。'
        : 'NO_ELEMENT — 找不到「$q」。先用 action=list 看现有档案。';
  }

  void _syncTopLevel(Settings settings) {
    final ModelProfile? p = settings.activeProfile;
    if (p == null) return;
    settings.thinkingEnabled = p.thinking;
    settings.reasoningEffort = p.reasoningEffort;
    settings.temperature = p.temperature;
  }

  static bool _validUrl(String raw) {
    final Uri? u = Uri.tryParse(raw.trim());
    return u != null && u.hasScheme && u.host.isNotEmpty;
  }

  static String _effortOf(String raw) {
    final String v = raw.trim().toLowerCase();
    return <String>{'low', 'high', 'max'}.contains(v) ? v : 'high';
  }

  static ThinkingStyle _styleOf(String raw) {
    final String v = raw.trim().toLowerCase();
    for (final ThinkingStyle s in ThinkingStyle.values) {
      if (s.id == v) return s;
    }
    return ThinkingStyle.effortOnly;
  }
}
