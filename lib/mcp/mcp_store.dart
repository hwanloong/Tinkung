import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/ids.dart';
import '../core/net_error.dart';
import 'mcp_client.dart';

/// 一个 MCP 工具在**本应用里**的样子。
///
/// 和 [McpToolDef] 的区别：
///  · `name` 是服务器那边的原始名，调用时必须原样回传；
///  · `exposedName` 是给模型看的函数名，必须满足 OpenAI 的限制
///    （`[a-zA-Z0-9_-]{1,64}`，且不能和已有工具重名）。
class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.exposedName,
    required this.title,
    required this.description,
    required this.inputSchema,
    this.readOnly = false,
    this.destructive = false,
  });

  final String name;
  final String exposedName;
  final String title;
  final String description;
  final Map<String, dynamic> inputSchema;
  final bool readOnly;
  final bool destructive;

  factory McpToolInfo.fromDef(McpToolDef d, {required String exposedName}) =>
      McpToolInfo(
        name: d.name,
        exposedName: exposedName,
        title: d.title,
        description: d.description,
        inputSchema: sanitizeMcpSchema(d.inputSchema),
        readOnly: d.readOnly,
        destructive: d.destructive,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'exposedName': exposedName,
    'title': title,
    'description': description,
    'inputSchema': inputSchema,
    'readOnly': readOnly,
    'destructive': destructive,
  };

  static McpToolInfo fromJson(Map<String, dynamic> j) => McpToolInfo(
    name: j['name']?.toString() ?? '',
    exposedName: j['exposedName']?.toString() ?? '',
    title: j['title']?.toString() ?? '',
    description: j['description']?.toString() ?? '',
    inputSchema: sanitizeMcpSchema(j['inputSchema']),
    readOnly: j['readOnly'] == true,
    destructive: j['destructive'] == true,
  );
}

/// 一个用户配置的 MCP 服务器。
class McpServer {
  McpServer({
    required this.id,
    required this.name,
    required this.url,
    Map<String, String>? headers,
    this.enabled = true,
    List<McpToolInfo>? tools,
    this.lastError = '',
    this.lastConnectedAt,
  }) : headers = Map<String, String>.from(headers ?? <String, String>{}),
       tools = List<McpToolInfo>.from(tools ?? <McpToolInfo>[]);

  final String id;
  String name;
  String url;

  /// 自定义请求头（通常是 `Authorization: Bearer …`）。
  /// 只在本地存、**不进备份**（和 API Key 同一条规则）。
  Map<String, String> headers;

  bool enabled;

  /// 上一次成功发现到的工具（离线也能用：直接注册缓存的这一份）。
  List<McpToolInfo> tools;

  /// 上一次连接失败的原因；空 = 正常。
  String lastError;

  /// 服务器在 initialize 里自报的名字（只用于展示）。
  String serverName = '';

  DateTime? lastConnectedAt;

  String get displayName => name.trim().isEmpty ? url : name.trim();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'url': url,
    'headers': headers,
    'enabled': enabled,
    'tools': tools.map((McpToolInfo t) => t.toJson()).toList(),
    'lastError': lastError,
    'serverName': serverName,
    'lastConnectedAt': lastConnectedAt?.toIso8601String(),
  };

  static McpServer fromJson(Map<String, dynamic> j) {
    final dynamic rawTools = j['tools'];
    final List<McpToolInfo> tools = <McpToolInfo>[];
    if (rawTools is List) {
      for (final dynamic e in rawTools) {
        if (e is Map) {
          tools.add(McpToolInfo.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    final Map<String, String> headers = <String, String>{};
    if (j['headers'] is Map) {
      (j['headers'] as Map).forEach((dynamic k, dynamic v) {
        if (k != null) headers[k.toString()] = v?.toString() ?? '';
      });
    }
    return McpServer(
      id: j['id']?.toString() ?? newId(),
      name: j['name']?.toString() ?? '',
      url: j['url']?.toString() ?? '',
      headers: headers,
      enabled: j['enabled'] != false,
      tools: tools,
      lastError: j['lastError']?.toString() ?? '',
      lastConnectedAt: DateTime.tryParse(
        j['lastConnectedAt']?.toString() ?? '',
      ),
    )..serverName = j['serverName']?.toString() ?? '';
  }
}

/// MCP 服务器的存储 + 发现 + 调用入口。
///
/// 做成单例：工具注册发生在 `chat_page._buildRegistry()`，那条路径
/// 拿不到 main 里的局部变量（和 MemoryStore / RuleStore 同一个理由）。
class McpStore extends ChangeNotifier {
  McpStore._(this._file);

  static McpStore? _instance;

  /// 未初始化时返回 null。
  ///
  /// 工具注册表会在 `ChatPage` 里被构建，而某些测试/早期路径并不经过
  /// `main()`。这里不能像提示词那几个 store 一样直接抛：没有 MCP 只是
  /// "少一组工具"，不该让整页崩掉。
  static McpStore? get maybeInstance => _instance;

  static McpStore get instance {
    final McpStore? s = _instance;
    if (s == null) {
      throw StateError('McpStore 还没初始化。应该在 main() 里调用 McpStore.configure()。');
    }
    return s;
  }

  static Future<McpStore> configure(File file) async {
    final McpStore s = McpStore._(file);
    _instance = s;
    await s.load();
    return s;
  }

  final File _file;
  final List<McpServer> servers = <McpServer>[];

  /// **内存里**的会话（进程重启后重新 initialize 即可，不落盘）。
  final Map<String, McpSession> _sessions = <String, McpSession>{};

  List<McpServer> get enabledServers =>
      servers.where((McpServer s) => s.enabled).toList();

  int get toolCount =>
      enabledServers.fold<int>(0, (int n, McpServer s) => n + s.tools.length);

  /// 拼成注入系统提示词的一段，**主动告诉模型"你有哪些外部工具"**。
  ///
  /// 工具表里本来就有它们的 schema，为什么还要这段？
  ///
  /// 因为内置工具有三十多个，MCP 工具排在最后。模型（尤其是小模型）
  /// 经常只盯着前面那几个熟悉的名字，压根想不到"用户接了一个笔记服务"。
  /// 用户反馈的"命不中 / 查不出来"多半就是这个：不是调用失败，是**没想到**。
  ///
  /// 这里只列服务器和工具标题（不重复完整 description），控制在几十个
  /// token 的量级；真正的参数说明还在 schema 里。
  String toPromptSection() {
    final List<McpServer> active = enabledServers
        .where((McpServer s) => s.tools.isNotEmpty)
        .toList();
    if (active.isEmpty) return '';

    final StringBuffer sb = StringBuffer();
    sb.writeln();
    sb.writeln('可用的 MCP 外部工具（用户在设置里接入的服务器，和内置工具一样可以直接调用）：');
    int shown = 0;
    for (final McpServer s in active) {
      final List<String> titles = <String>[];
      for (final McpToolInfo t in s.tools.take(8)) {
        final String label = t.title.trim().isEmpty ? t.name : t.title.trim();
        titles.add(label);
      }
      sb.writeln(
        '- 「${s.displayName}」（${s.tools.length} 个）：${titles.join('、')}'
        '${s.tools.length > 8 ? ' 等' : ''}',
      );
      shown += s.tools.length;
      if (shown >= 30) break;
    }
    sb.writeln(
      '需要外部系统的数据或操作时优先考虑这些工具（函数名以 `mcp_` 开头，'
      '参数说明见各自的 description）；不要因为名字陌生就跳过它们。',
    );
    return sb.toString();
  }

  Future<void> load() async {
    servers.clear();
    try {
      if (await _file.exists()) {
        final dynamic data = jsonDecode(await _file.readAsString());
        if (data is List) {
          for (final dynamic e in data) {
            if (e is! Map) continue;
            final McpServer s = McpServer.fromJson(
              Map<String, dynamic>.from(e),
            );
            if (s.url.trim().isEmpty) continue;
            servers.add(s);
          }
        }
      }
    } catch (_) {
      // 文件坏了就当没有配置；不要让它影响启动。
      servers.clear();
    }
    notifyListeners();
  }

  Future<void> save() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        jsonEncode(servers.map((McpServer s) => s.toJson()).toList()),
      );
    } catch (_) {
      // 写失败不致命
    }
  }

  void _changed() {
    notifyListeners();
    save();
  }

  McpServer addServer({
    required String name,
    required String url,
    Map<String, String>? headers,
  }) {
    final McpServer s = McpServer(
      id: newId(),
      name: name.trim(),
      url: url.trim(),
      headers: headers,
    );
    servers.add(s);
    _changed();
    return s;
  }

  void updateServer(McpServer server) => _changed();

  void removeServer(String id) {
    servers.removeWhere((McpServer s) => s.id == id);
    _sessions.remove(id);
    _changed();
  }

  void setEnabled(McpServer server, bool on) {
    server.enabled = on;
    _changed();
  }

  /// 连接服务器并刷新工具列表。返回 null 表示成功，否则是错误文案。
  Future<String?> refresh(McpServer server) async {
    final McpClient client = McpClient(headers: server.headers);
    try {
      // ---- 地址容错 ----
      //
      // 最常见的配置错误：用户只填了主机名（`https://example.com`），
      // 而端点其实是 `https://example.com/mcp`。这时 POST 会 404，
      // 界面上看起来就是"连不上 / 查不出工具"。
      //
      // 只在**路径为空**时补 `/mcp` 试一次 —— 不动用户填了具体路径的地址。
      McpSession? session;
      String? lastError;
      for (final String candidate in _urlCandidates(server.url)) {
        try {
          session = await client.connect(candidate);
          if (candidate != server.url.trim()) server.url = candidate;
          break;
        } on McpProtocolError catch (e) {
          lastError = e.message;
          if (!_looksLikeWrongEndpoint(e)) break;
        }
      }
      if (session == null) {
        throw McpProtocolError(lastError ?? '连接失败');
      }

      final List<McpToolDef> defs = await client.listTools(session);
      _sessions[server.id] = session;
      server.serverName = session.serverName;

      // 生成不重复的模型侧函数名：两个原始名 slug 之后可能撞车
      //（`foo.bar` 和 `foo bar`），撞了就加 `_2`、`_3`。
      final Set<String> used = <String>{};
      final List<McpToolInfo> next = <McpToolInfo>[];
      for (final McpToolDef d in defs) {
        final String base = mcpExposedName(server, d.name);
        String name = base;
        int i = 2;
        while (!used.add(name)) {
          final String suffix = '_$i';
          name = base.length + suffix.length > 64
              ? '${base.substring(0, 64 - suffix.length)}$suffix'
              : '$base$suffix';
          i++;
        }
        next.add(McpToolInfo.fromDef(d, exposedName: name));
      }
      server.tools = next;
      server.lastError = '';
      server.lastConnectedAt = DateTime.now();
      _changed();
      return null;
    } catch (e) {
      _sessions.remove(server.id);
      server.lastError = e is McpProtocolError
          ? e.message
          : NetError.describe(e);
      _changed();
      return server.lastError;
    } finally {
      client.close();
    }
  }

  /// 启动时补一次发现：只做"启用了、但还没成功拿到过工具"的服务器。
  ///
  /// 不刷新已有缓存的服务器：启动时没必要每个人都发一轮网络请求，
  /// 缓存里的工具照样能用；要更新就在设置里点「刷新」。
  Future<void> refreshMissing() async {
    for (final McpServer s in servers) {
      if (!s.enabled || s.tools.isNotEmpty) continue;
      await refresh(s);
    }
  }

  /// 调用工具。会话过期（服务器重启 / 404）时自动重建一次。
  Future<McpCallResult> callTool(
    McpServer server,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    Future<McpCallResult> attempt(McpSession? existing) async {
      final McpClient client = McpClient(headers: server.headers);
      try {
        final McpSession session = existing ?? await client.connect(server.url);
        _sessions[server.id] = session;
        return await client.callTool(session, toolName, args);
      } finally {
        client.close();
      }
    }

    try {
      return await attempt(_sessions[server.id]);
    } on McpProtocolError catch (e) {
      if (!e.sessionExpired) rethrow;
      _sessions.remove(server.id);
      return attempt(null);
    }
  }
}

/// 给模型看的工具名：`mcp_<服务器名>_<id 尾 4 位>_<工具名>`。
///
/// ## 为什么三段都要
///
/// · **服务器名**：模型靠它判断"这是哪个系统的东西"。只有 id 尾巴时，
///   工具名是一串 `mcp_0007_…`，模型很难把它和"用户在设置里接的
///   笔记服务"联系起来，该调的时候想不起来（用户说的"命中率低"）。
/// · **id 尾巴**：两个服务器可以同名（都叫 "Notes"）。撞名之后模型会
///   随机调错一个，而且从名字上完全看不出来。
/// · **工具名**：服务器原始名 slug 之后的形状，调用时再映射回原名。
///
/// 服务器名 slug 太长时截到 16 字符；整体保证 ≤ 64。
String mcpExposedName(McpServer server, String tool) {
  final String idPart = server.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final String tail = idPart.length <= 4
      ? idPart
      : idPart.substring(idPart.length - 4);
  String serverSlug = _mcpSlug(server.name);
  if (serverSlug.length > 16) serverSlug = serverSlug.substring(0, 16);
  final String toolSlug = _mcpSlug(tool);
  final String body = toolSlug.isEmpty ? 'tool' : toolSlug;

  final String prefix = serverSlug.isEmpty
      ? 'mcp_${tail.isEmpty ? 'srv' : tail}_'
      : 'mcp_${serverSlug}_${tail.isEmpty ? 'srv' : tail}_';
  final int keep = 64 - prefix.length;
  if (keep <= 0) return 'mcp_tool';
  String name = '$prefix${body.length > keep ? body.substring(0, keep) : body}';
  while (name.endsWith('_')) {
    name = name.substring(0, name.length - 1);
  }
  return name.length < 4 ? 'mcp_tool' : name;
}

/// 补 `/mcp` 的候选列表。只在用户**没写路径**时追加。
List<String> _urlCandidates(String raw) {
  final String url = raw.trim();
  final Uri? u = Uri.tryParse(url);
  final String base = url.replaceAll(RegExp(r'/+$'), '');
  if (u != null && (u.path.isEmpty || u.path == '/')) {
    return <String>[base, '$base/mcp'];
  }
  return <String>[url];
}

/// 这个失败是不是"端点写错了，换个候选地址可能就好"。
bool _looksLikeWrongEndpoint(McpProtocolError e) =>
    e.message.contains('HTTP 404') || e.message.contains('HTTP 405');

String _mcpSlug(String raw) {
  final String s = raw.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '_',
  );
  return s.replaceAll(RegExp(r'^_+|_+$'), '');
}

/// 把服务器给的 JSON Schema 整理成 OpenAI 兼容接口能接受的形状。
///
/// ## 为什么要"白名单"式清洗，而不是原样转发
///
/// MCP 服务器可以用完整的 JSON Schema：`$ref` / `$defs` / `oneOf` /
/// `allOf` / `if-then` 都合法。但 OpenAI 兼容端点（尤其是中转站）
/// 对工具参数 schema 的支持**很不完整**：遇到不认识的字段会直接 400，
/// 而 400 是**整个请求**失败 —— 不是"MCP 工具不能用"，是这一轮
/// 连普通对话都发不出去。用户看到的现象就是"接了 MCP 之后 AI 不说话了"。
///
/// 所以只保留各家都认的字段，其余一律丢掉；`properties` 递归清洗。
/// 语法信息损失一点，换来的是**整个工具表可用**。
///
/// 另外两种常见坏情况也在这里兜住：
///  · 服务器**没给** `inputSchema`（无参数工具很常见）；
///  · 给的 `type` 不是 `object`（比如直接给了某个字段的 schema）。
Map<String, dynamic> sanitizeMcpSchema(dynamic raw) {
  final Map<String, dynamic> m = _cleanSchema(raw);
  if (m['type'] != 'object') m['type'] = 'object';
  if (m['properties'] is! Map) m['properties'] = <String, dynamic>{};
  return m;
}

/// 各家 OpenAI 兼容接口都认的 JSON Schema 关键字。
const Set<String> _kSafeSchemaKeys = <String>{
  'type',
  'properties',
  'required',
  'description',
  'title',
  'enum',
  'const',
  'items',
  'default',
  'format',
  'minimum',
  'maximum',
  'exclusiveMinimum',
  'exclusiveMaximum',
  'minLength',
  'maxLength',
  'pattern',
  'minItems',
  'maxItems',
  'uniqueItems',
  'additionalProperties',
  'examples',
};

Map<String, dynamic> _cleanSchema(dynamic raw) {
  if (raw is! Map) return <String, dynamic>{};
  final Map<String, dynamic> out = <String, dynamic>{};
  raw.forEach((dynamic key, dynamic value) {
    final String k = key.toString();
    if (!_kSafeSchemaKeys.contains(k)) return;
    if (k == 'properties') {
      if (value is! Map) return;
      final Map<String, dynamic> props = <String, dynamic>{};
      value.forEach((dynamic pk, dynamic pv) {
        props[pk.toString()] = _cleanSchema(pv);
      });
      out[k] = props;
    } else if (k == 'items') {
      out[k] = _cleanSchema(value);
    } else if (k == 'additionalProperties') {
      out[k] = value is Map
          ? _cleanSchema(value)
          : value is bool
          ? value
          : true;
    } else if (k == 'required') {
      if (value is List) {
        out[k] = value.map((dynamic e) => e.toString()).toList();
      }
    } else if (k == 'enum' || k == 'examples') {
      if (value is List) out[k] = value;
    } else {
      out[k] = value;
    }
  });
  return out;
}
