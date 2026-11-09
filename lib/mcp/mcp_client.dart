import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// MCP（Model Context Protocol）客户端。
///
/// ## 支持范围
///
/// 只做 **Streamable HTTP**（MCP 2025 规范里的标准远程传输）：
///   `POST {url}`，响应可以是 `application/json`，也可以是
///   `text/event-stream`（SSE）。
///
/// 不做 stdio 与旧的 HTTP+SSE：前者要在手机上跑 MCP 子进程（本项目的
/// Alpine/Python 默认没有 `mcp` 包），后者的规范已经废弃，新服务器
/// 基本都是 Streamable HTTP。
///
/// ## 为什么手写而不是引 SDK
///
/// 协议本身很小（JSON-RPC 2.0 + 五个方法）：initialize / initialized /
/// tools/list / tools/call。引一个 SDK 反而会把 transport、鉴权和
/// Android 网络配置都锁死在别人的实现里；而这里需要精确控制
/// 会话头、SSE 解析和错误文案。
class McpClient {
  McpClient({Map<String, String>? headers})
    : headers = Map<String, String>.from(headers ?? <String, String>{});

  /// 客户端声明支持的协议版本。服务器可以回一个它自己的版本，
  /// 之后所有请求都按**协商结果**带 `MCP-Protocol-Version`。
  static const String protocolVersion = '2025-06-18';

  static const String clientName = 'Tinkung';

  /// 服务器要求的所有自定义头（通常是 `Authorization`）。
  final Map<String, String> headers;

  final http.Client _http = http.Client();
  int _nextId = 0;

  void close() => _http.close();

  /// 解析并校验服务器地址。
  ///
  /// 只接受 http/https —— MCP 的远程传输就是 HTTP，
  /// 别的 scheme（file、ftp）既没有意义，也容易变成误配置下的本地读取。
  static Uri parseEndpoint(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) throw const McpProtocolError('地址为空');
    final Uri? uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) {
      throw McpProtocolError('地址不合法：$raw');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw McpProtocolError('地址必须以 http:// 或 https:// 开头：$raw');
    }
    return uri;
  }

  /// 建连：initialize → notifications/initialized。
  ///
  /// 返回的 [McpSession] 里带着会话 id（如果服务器发了）和协商后的版本。
  Future<McpSession> connect(String url) async {
    final Uri endpoint = parseEndpoint(url);
    final McpSession session = McpSession(endpoint: endpoint);

    final _RpcReply reply = await _send(
      endpoint: endpoint,
      payload: <String, dynamic>{
        'jsonrpc': '2.0',
        'id': ++_nextId,
        'method': 'initialize',
        'params': <String, dynamic>{
          'protocolVersion': protocolVersion,
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{'name': clientName, 'version': '1.0'},
        },
      },
    );
    session.sessionId = reply.sessionId;
    final Map<String, dynamic> result = _resultOf(reply.json);
    session.protocolVersion =
        result['protocolVersion']?.toString().trim().isNotEmpty == true
        ? result['protocolVersion'].toString().trim()
        : protocolVersion;
    session.serverName = (result['serverInfo'] is Map)
        ? (result['serverInfo'] as Map)['name']?.toString() ?? ''
        : '';

    // 规范要求 initialize 之后再发一条 initialized 通知。
    await _send(
      endpoint: endpoint,
      session: session,
      expectResponse: false,
      payload: <String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
    );
    return session;
  }

  /// 拉取全部工具（自动翻页）。
  Future<List<McpToolDef>> listTools(McpSession session) async {
    final List<McpToolDef> out = <McpToolDef>[];
    String cursor = '';
    // 最多 20 页：正常服务器一页就够，这个上限只防"服务器永远给
    // 同一个 cursor"导致死循环。
    for (int page = 0; page < 20; page++) {
      final Map<String, dynamic> result = _resultOf(
        (await _request(
          session,
          'tools/list',
          cursor.isEmpty
              ? <String, dynamic>{}
              : <String, dynamic>{'cursor': cursor},
        )).json,
      );
      final List<dynamic> tools =
          (result['tools'] as List<dynamic>?) ?? <dynamic>[];
      for (final dynamic e in tools) {
        if (e is! Map) continue;
        out.add(McpToolDef.fromJson(Map<String, dynamic>.from(e)));
      }
      final String next = result['nextCursor']?.toString() ?? '';
      if (next.isEmpty || next == cursor) break;
      cursor = next;
    }
    return out;
  }

  /// 调用一个工具。
  Future<McpCallResult> callTool(
    McpSession session,
    String name,
    Map<String, dynamic> args,
  ) async {
    final _RpcReply reply = await _request(
      session,
      'tools/call',
      <String, dynamic>{'name': name, 'arguments': args},
    );
    final Map<String, dynamic> result = _resultOf(reply.json);
    final List<Map<String, dynamic>> content = <Map<String, dynamic>>[];
    final List<dynamic> rawContent =
        (result['content'] as List<dynamic>?) ?? <dynamic>[];
    for (final dynamic e in rawContent) {
      if (e is Map) content.add(Map<String, dynamic>.from(e));
    }
    final dynamic structured = result['structuredContent'];
    return McpCallResult(
      content: content,
      structured: structured is Map
          ? Map<String, dynamic>.from(structured)
          : null,
      isError: result['isError'] == true,
    );
  }

  // ------------------------------------------------------------------ 传输

  Future<_RpcReply> _request(
    McpSession session,
    String method, [
    Map<String, dynamic>? params,
  ]) {
    return _send(
      endpoint: session.endpoint,
      session: session,
      payload: <String, dynamic>{
        'jsonrpc': '2.0',
        'id': ++_nextId,
        'method': method,
        'params': ?params,
      },
    );
  }

  Future<_RpcReply> _send({
    required Uri endpoint,
    required Map<String, dynamic> payload,
    McpSession? session,
    bool expectResponse = true,
  }) async {
    final http.Request req = http.Request('POST', endpoint);
    req.headers.addAll(<String, String>{
      'Content-Type': 'application/json',
      // 两种都要声明：服务器可以按自己的心情回 JSON 或 SSE。
      'Accept': 'application/json, text/event-stream',
      ...headers,
    });
    if (session != null) {
      if (session.sessionId.isNotEmpty) {
        req.headers['Mcp-Session-Id'] = session.sessionId;
      }
      req.headers['MCP-Protocol-Version'] = session.protocolVersion.isEmpty
          ? protocolVersion
          : session.protocolVersion;
    }
    req.body = jsonEncode(payload);

    final http.StreamedResponse resp;
    try {
      resp = await _http.send(req).timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw const McpProtocolError('连接 MCP 服务器超时（45 秒）');
    } on http.ClientException catch (e) {
      throw McpProtocolError(_networkError(e));
    }

    final String sessionId = resp.headers['mcp-session-id'] ?? '';

    // 通知：服务器回 202/204，没有 body。
    if (!expectResponse) {
      try {
        await resp.stream.drain<void>();
      } catch (_) {
        // 通知发失败不致命：继续用现有会话即可。
      }
      if (resp.statusCode >= 400) {
        throw McpProtocolError(
          'MCP 拒绝了 ${payload['method']}（HTTP ${resp.statusCode}）',
        );
      }
      return _RpcReply(null, sessionId);
    }

    if (resp.statusCode == 202) {
      await resp.stream.drain<void>();
      throw const McpProtocolError(
        '服务器接受了请求但没有返回结果（HTTP 202）',
        sessionExpired: true,
      );
    }
    if (resp.statusCode != 200) {
      final String body = await resp.stream.bytesToString();
      throw McpProtocolError(
        _httpError(resp.statusCode, body),
        // 404 常见于服务器重启后旧会话失效；重连一次通常就好。
        sessionExpired: resp.statusCode == 404,
      );
    }

    final String contentType = (resp.headers['content-type'] ?? '')
        .toLowerCase();
    final int? wantId = payload['id'] as int?;

    Map<String, dynamic>? json;
    if (contentType.contains('text/event-stream')) {
      json = await _readSse(resp.stream, wantId);
    } else {
      final String body = await resp.stream.bytesToString();
      json = _pickRpc(body, wantId);
    }
    if (json == null) {
      throw McpProtocolError(
        'MCP 返回里没有这次请求的结果（id=$wantId，'
        'content-type=${contentType.isEmpty ? '未知' : contentType}）',
      );
    }
    return _RpcReply(json, sessionId);
  }

  /// 从 SSE 里读出**和请求 id 对应**的那条 JSON-RPC 响应。
  ///
  /// 流里可能先来几条通知（进度、日志），也可能被服务器一直挂着；
  /// 所以看到目标 id 就立刻返回（`await for` 会取消订阅），不等连接关闭。
  Future<Map<String, dynamic>?> _readSse(
    http.ByteStream stream,
    int? wantId,
  ) async {
    final StringBuffer data = StringBuffer();
    await for (final String line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        // 空行 = 一个事件结束
        if (data.isEmpty) continue;
        final Map<String, dynamic>? msg = _tryJson(data.toString());
        data.clear();
        if (msg != null && _isReplyFor(msg, wantId)) return msg;
        continue;
      }
      if (line.startsWith(':')) continue; // 注释 / keep-alive
      if (line.startsWith('data:')) {
        final String part = line.substring(5).trimLeft();
        if (data.isNotEmpty) data.write('\n');
        data.write(part);
      }
      // event: / id: / retry: 对"取一条响应"没有用，忽略
    }
    // 有些服务器最后一条事件不带结尾空行
    if (data.isNotEmpty) {
      final Map<String, dynamic>? msg = _tryJson(data.toString());
      if (msg != null && _isReplyFor(msg, wantId)) return msg;
    }
    return null;
  }

  static bool _isReplyFor(Map<String, dynamic> msg, int? wantId) {
    if (!msg.containsKey('result') && !msg.containsKey('error')) return false;
    if (wantId == null) return true;
    return msg['id']?.toString() == wantId.toString();
  }

  static Map<String, dynamic>? _pickRpc(String body, int? wantId) {
    final dynamic parsed = _tryJsonAny(body);
    if (parsed is Map) return Map<String, dynamic>.from(parsed);
    if (parsed is List) {
      for (final dynamic e in parsed) {
        if (e is Map) {
          final Map<String, dynamic> m = Map<String, dynamic>.from(e);
          if (_isReplyFor(m, wantId)) return m;
        }
      }
    }
    return null;
  }

  static dynamic _tryJsonAny(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _tryJson(String text) {
    final dynamic v = _tryJsonAny(text);
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  static Map<String, dynamic> _resultOf(Map<String, dynamic>? json) {
    if (json == null) throw const McpProtocolError('MCP 没有返回结果');
    final dynamic err = json['error'];
    if (err is Map) {
      final String code = err['code']?.toString() ?? '';
      final String msg = err['message']?.toString() ?? err.toString();
      // JSON-RPC 里也有"会话不存在"这种错误（-32001 等），一并当作可重连。
      final String lower = msg.toLowerCase();
      final bool expired =
          lower.contains('session') &&
          (lower.contains('not found') ||
              lower.contains('expired') ||
              lower.contains('invalid'));
      throw McpProtocolError(
        'MCP 错误${code.isEmpty ? '' : ' $code'}：$msg',
        sessionExpired: expired,
      );
    }
    final dynamic result = json['result'];
    if (result is Map) return Map<String, dynamic>.from(result);
    if (result == null) return <String, dynamic>{};
    throw const McpProtocolError('MCP 返回的 result 不是对象');
  }

  static String _httpError(int status, String body) {
    final String text = body.trim();
    final String snippet = text.length > 300
        ? '${text.substring(0, 300)}…'
        : text;
    if (status == 401 || status == 403) {
      return 'HTTP $status：鉴权失败。检查服务器地址和 Headers 里的 Token。'
          '${snippet.isEmpty ? '' : '\n$snippet'}';
    }
    if (status == 404) {
      return 'HTTP 404：地址不对，或会话已过期。'
          '${snippet.isEmpty ? '' : '\n$snippet'}';
    }
    return 'HTTP $status${snippet.isEmpty ? '' : '：$snippet'}';
  }

  static String _networkError(http.ClientException e) {
    final String s = e.message.toLowerCase();
    if (s.contains('cleartext')) {
      return '明文 HTTP 被系统拦截（Android 9+ 默认禁止），请改用 https。';
    }
    if (s.contains('failed host lookup')) {
      return '域名解析失败，检查网址和网络。';
    }
    if (s.contains('connection refused')) {
      return '连接被拒绝，目标地址没有服务在监听。';
    }
    return '连接失败：${e.message}';
  }
}

/// 一次 MCP 会话。
///
/// [sessionId] 只活在内存里（进程重启后重新 initialize 即可）：
/// 规范没有要求持久化，而且服务器重启后旧 id 也会失效。
class McpSession {
  McpSession({
    required this.endpoint,
    this.sessionId = '',
    this.protocolVersion = '',
    this.serverName = '',
  });

  final Uri endpoint;
  String sessionId;
  String protocolVersion;
  String serverName;
}

/// 服务器声明的工具。
class McpToolDef {
  const McpToolDef({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    this.readOnly = false,
    this.destructive = false,
  });

  /// 服务器那边的原始工具名（调用时必须原样回传）。
  final String name;

  /// 展示用标题（服务器没给就用原始名）。
  final String title;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// MCP 的 `annotations.readOnlyHint` —— 只读工具可以免确认。
  final bool readOnly;

  /// `annotations.destructiveHint`：服务器自己说这个操作可能造成破坏。
  final bool destructive;

  static McpToolDef fromJson(Map<String, dynamic> j) {
    final String name = j['name']?.toString() ?? '';
    final Map<String, dynamic> annotations = j['annotations'] is Map
        ? Map<String, dynamic>.from(j['annotations'] as Map)
        : <String, dynamic>{};
    final dynamic schema = j['inputSchema'];
    return McpToolDef(
      name: name,
      title: (j['title']?.toString().trim().isNotEmpty ?? false)
          ? j['title'].toString().trim()
          : name,
      description: j['description']?.toString() ?? '',
      inputSchema: schema is Map
          ? Map<String, dynamic>.from(schema)
          : <String, dynamic>{},
      readOnly: annotations['readOnlyHint'] == true,
      destructive: annotations['destructiveHint'] == true,
    );
  }
}

/// 工具调用结果。
class McpCallResult {
  const McpCallResult({
    required this.content,
    this.structured,
    this.isError = false,
  });

  /// MCP content blocks（text / image / resource / …），原样保留。
  final List<Map<String, dynamic>> content;

  /// 新版规范的 `structuredContent`。
  final Map<String, dynamic>? structured;

  final bool isError;
}

/// 协议 / 网络层错误。
class McpProtocolError implements Exception {
  const McpProtocolError(this.message, {this.sessionExpired = false});

  final String message;

  /// 是不是"会话过期，重新 initialize 就好"（HTTP 404/202 那类）。
  final bool sessionExpired;

  @override
  String toString() => message;
}

class _RpcReply {
  const _RpcReply(this.json, this.sessionId);

  final Map<String, dynamic>? json;
  final String sessionId;
}
