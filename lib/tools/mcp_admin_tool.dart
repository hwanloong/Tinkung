import '../core/models.dart';
import '../mcp/mcp_store.dart';
import 'tool.dart';

/// 让 agent **管理 MCP 服务器本身**：列出、添加、启用/停用、删除、重新发现。
///
/// ## 和 [McpTool] 的分工
///
/// `McpTool` 是"用某台服务器上的某个工具"；这一个管的是**服务器名单**。
/// 分成两个工具而不是给每个 MCP 工具加一个 `admin` 参数，是因为：
///  · 名单操作不依赖任何一台服务器是否连得上；
///  · 它的风险等级和调用 MCP 工具完全不同（见下）；
///  · 模型看到一堆 `mcp_xxx` 函数时，很难意识到"还能加一个"。
///
/// ## 风险分级
///
/// 加一台服务器 = **把一批外部工具挂进 agent 的能力面**。这不是"查资料"，
/// 是改变它能做什么，所以 `add` 必须让用户点一下确认；`remove` 更重，
/// 落到 dangerous（确认框默认拒绝）。
///
/// 特别地，`add` 允许带 `headers`（通常是 `Authorization: Bearer …`）。
/// 那是**凭据**：一旦写进对话，它就留在了聊天记录里。工具输出里会明确
/// 提醒这一点，并且回显时打码 —— 不打印完整 token。
class McpAdminTool extends AgentTool {
  const McpAdminTool();

  @override
  String get name => 'mcp_admin';

  @override
  String get title => 'MCP 服务器管理';

  @override
  String get description =>
      '管理 MCP 服务器（外部工具来源）：查看 / 添加 / 启用停用 / 删除 / 重新连接。\n'
      '\n'
      '**什么时候用**：用户说"帮我接一个 MCP 服务器""把 xxx 的 MCP 加上"'
      '"那个服务器不要了""重新连一下"时。\n'
      '\n'
      '动作：\n'
      '· `list`：所有服务器 + 是否启用 + 工具数 + 上次错误。\n'
      '· `add`：参数 `url`（必需，HTTP 端点）、`name`（可选，显示名）、'
      '`headers`（可选，JSON 对象，如 {"Authorization":"Bearer xxx"}）。'
      '加完会自动连接并发现工具。\n'
      '· `remove`：参数 `target`（服务器名字或 id）。\n'
      '· `enable` / `disable`：参数 `target`。\n'
      '· `refresh`：重新连接并拉取工具清单。不给 `target` 就刷新全部。\n'
      '\n'
      '**规矩**：\n'
      '· 地址必须是用户给的或能对上的官方地址，**不要自己编**；\n'
      '· `headers` 里是密钥 —— 只在用户明确给出时填写，'
      '并在回复里说"已保存，不会显示在设置外"；\n'
      '· 删除是不可恢复的，先说清删哪一台。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['list', 'add', 'remove', 'enable', 'disable', 'refresh'],
      },
      'url': <String, dynamic>{
        'type': 'string',
        'description': 'add 时的 HTTP 端点（通常以 /mcp 结尾）',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': 'add 时的显示名；不填就用域名',
      },
      'headers': <String, dynamic>{
        'type': 'object',
        'description': 'add 时的请求头，键值都是字符串（鉴权用）',
      },
      'target': <String, dynamic>{
        'type': 'string',
        'description': 'remove / enable / disable / refresh 时针对哪一台：名字或 id',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    switch (args.str('action')) {
      case 'remove':
        return const RiskAssessment(RiskLevel.dangerous, <String>[
          '删除 MCP 服务器配置，不可恢复',
        ]);
      case 'add':
        return RiskAssessment(RiskLevel.caution, <String>[
          '接入新服务器会给 AI 增加一批外部工具',
          if (args['headers'] is Map && (args['headers'] as Map).isNotEmpty)
            '包含鉴权请求头，会写入本机配置',
        ]);
      case 'enable':
      case 'disable':
        return const RiskAssessment(RiskLevel.caution, <String>[]);
      default:
        return const RiskAssessment(RiskLevel.safe, <String>[]);
    }
  }

  @override
  String summarize(Map<String, dynamic> args) {
    switch (args.str('action')) {
      case 'list':
        return '查看 MCP 服务器';
      case 'add':
        return '接入 MCP 服务器：${args.str('name').trim().isEmpty ? args.str('url') : args.str('name')}';
      case 'remove':
        return '删除 MCP 服务器：${args.str('target')}';
      case 'enable':
        return '启用 MCP 服务器：${args.str('target')}';
      case 'disable':
        return '停用 MCP 服务器：${args.str('target')}';
      default:
        return '重新连接 MCP 服务器';
    }
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final McpStore? store = McpStore.maybeInstance;
    if (store == null) return 'MCP 还没初始化（设置里没接服务器时也会是空的）。';

    final String action = args.str('action');
    switch (action) {
      case 'list':
        return _list(store);
      case 'add':
        return _add(store, args);
      case 'remove':
        return _remove(store, args);
      case 'enable':
      case 'disable':
        return _toggle(store, args, on: action == 'enable');
      case 'refresh':
        return _refresh(store, args);
      default:
        return '错误：未知 action「$action」';
    }
  }

  String _list(McpStore store) {
    if (store.servers.isEmpty) {
      return '还没有接入任何 MCP 服务器。'
          '如果用户想接一台，用 action=add 并让用户给出端点地址。';
    }
    final StringBuffer sb = StringBuffer();
    sb.writeln('MCP 服务器（${store.servers.length} 台，'
        '${store.toolCount} 个可用工具）：');
    for (final McpServer s in store.servers) {
      sb.writeln(
        '- ${s.displayName}${s.enabled ? '' : '（已停用）'}'
        ' · ${s.tools.length} 个工具'
        ' · ${s.url}',
      );
      if (s.lastError.trim().isNotEmpty) {
        sb.writeln('  上次错误：${s.lastError}');
      }
    }
    return sb.toString();
  }

  Future<String> _add(McpStore store, Map<String, dynamic> args) async {
    final String url = args.str('url').trim();
    if (url.isEmpty) return '错误：add 需要 url。';
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return '错误：url 要以 http:// 或 https:// 开头。';
    }
    // 同一个地址加两次只会得到两台看起来一样的服务器，工具名还会撞车。
    for (final McpServer s in store.servers) {
      if (s.url.trim() == url) {
        return '这个地址已经接过了：${s.displayName}（${s.tools.length} 个工具）。'
            '要更新工具清单用 action=refresh。';
      }
    }

    final Map<String, String> headers = <String, String>{};
    final dynamic raw = args['headers'];
    if (raw is Map) {
      raw.forEach((dynamic k, dynamic v) {
        final String key = k?.toString().trim() ?? '';
        if (key.isEmpty) return;
        headers[key] = v?.toString() ?? '';
      });
    }

    String name = args.str('name').trim();
    if (name.isEmpty) {
      try {
        name = Uri.parse(url).host;
      } catch (_) {
        name = url;
      }
    }

    final McpServer server = store.addServer(
      name: name,
      url: url,
      headers: headers,
    );
    // 加完立刻连一次：不然用户会看到一台"0 个工具"的服务器，
    // 而真正的原因（地址写错 / 需要鉴权）要等他手动点刷新才知道。
    final String? err = await store.refresh(server);

    final StringBuffer sb = StringBuffer();
    sb.writeln('已接入「${server.displayName}」（$url）。');
    if (headers.isNotEmpty) {
      sb.writeln(
        '请求头：${headers.keys.map(_mask).join('、')} —— 已保存到本机，'
        '不会再显示完整值。',
      );
    }
    if (err != null) {
      sb.writeln('但连接失败：$err');
      sb.writeln(
        '服务器已经留在列表里（停用状态也别删）。请把错误原样告诉用户，'
        '并问他：地址是否正确、是否需要鉴权头。',
      );
      store.setEnabled(server, false);
    } else {
      sb.writeln(
        '连接成功，发现 ${server.tools.length} 个工具：'
        '${server.tools.take(10).map((McpToolInfo t) => t.title.trim().isEmpty ? t.name : t.title).join('、')}'
        '${server.tools.length > 10 ? ' 等' : ''}。',
      );
      sb.writeln('现在就可以直接调用它们（函数名以 `mcp_` 开头）。');
    }
    return sb.toString();
  }

  String _remove(McpStore store, Map<String, dynamic> args) {
    final McpServer? s = _resolve(store, args.str('target'));
    if (s == null) return _notFound(store, args.str('target'));
    final String name = s.displayName;
    final int tools = s.tools.length;
    store.removeServer(s.id);
    return '已删除 MCP 服务器「$name」（连同 $tools 个工具）。'
        '要恢复只能重新添加。';
  }

  String _toggle(McpStore store, Map<String, dynamic> args, {required bool on}) {
    final McpServer? s = _resolve(store, args.str('target'));
    if (s == null) return _notFound(store, args.str('target'));
    store.setEnabled(s, on);
    if (!on) return '已停用「${s.displayName}」。它的工具暂时不会出现在工具表里。';
    final String note = s.tools.isEmpty
        ? '它还没有成功发现过工具，可以用 action=refresh 连一次。'
        : '它现在有 ${s.tools.length} 个工具可用。';
    return '已启用「${s.displayName}」。$note';
  }

  Future<String> _refresh(McpStore store, Map<String, dynamic> args) async {
    final String target = args.str('target').trim();
    final List<McpServer> list = target.isEmpty
        ? store.servers
        : <McpServer>[
            if (_resolve(store, target) case final McpServer s) s,
          ];
    if (list.isEmpty) {
      return target.isEmpty
          ? '还没有任何 MCP 服务器。'
          : _notFound(store, target);
    }

    final StringBuffer sb = StringBuffer();
    for (final McpServer s in list) {
      final String? err = await store.refresh(s);
      if (err == null) {
        sb.writeln('- ${s.displayName}：${s.tools.length} 个工具');
      } else {
        sb.writeln('- ${s.displayName}：失败（$err）');
      }
    }
    return sb.toString().trimRight();
  }

  /// 按 id、再按名字（精确 → 忽略大小写 → 包含）找服务器。
  McpServer? _resolve(McpStore store, String raw) {
    final String q = raw.trim();
    if (q.isEmpty) return null;
    for (final McpServer s in store.servers) {
      if (s.id == q) return s;
    }
    for (final McpServer s in store.servers) {
      if (s.displayName == q) return s;
    }
    final String low = q.toLowerCase();
    for (final McpServer s in store.servers) {
      if (s.displayName.toLowerCase() == low) return s;
    }
    for (final McpServer s in store.servers) {
      if (s.displayName.toLowerCase().contains(low)) return s;
    }
    return null;
  }

  String _notFound(McpStore store, String raw) {
    if (store.servers.isEmpty) {
      return '还没有接入任何 MCP 服务器（要找的是「${raw.trim()}」）。';
    }
    return '找不到 MCP 服务器「${raw.trim()}」。现有：'
        '${store.servers.map((McpServer s) => '「${s.displayName}」').join('、')}';
  }

  /// 只留头几个字符：`Authorization` → `Autho…`。
  ///
  /// 头名字本身不是秘密，但和具体服务绑在一起有时能反推出用的是哪家；
  /// 打码一下成本很低，而完整打印一遍就等于把它写进对话记录。
  static String _mask(String key) =>
      key.length <= 5 ? '***' : '${key.substring(0, 5)}…';
}
