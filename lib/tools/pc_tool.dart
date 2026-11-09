import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../core/store.dart';
import 'tool.dart';

/// 和**电脑上的 `pc_agent.exe`** 通信：在电脑上跑命令、读写文件。
///
/// ## 为什么需要这个工具（而不是让模型用 `web`）
///
/// `web` 工具只能 GET 一个网址、读回正文。而"在电脑上执行命令"必须
/// **POST 一个 JSON 过去**，还要带口令头 —— `web` 做不到。
///
/// 没有这个工具的话，模型拿到 token 和 IP 也只能干看着：
/// 它会把网址拼进 `web` fetch，然后收到 405 或者一堆乱码。
///
/// ## 为什么要 `connect` 一次而不是每次带全套参数
///
/// 地址和口令是一段**会话级的**事实，不是每条命令的一部分。
/// 每次都让模型重复传 3 个参数，它迟早会漏掉一个（通常是 token），
/// 然后报 401 —— 而 401 看起来像"口令错了"，实际是"这次没带"。
///
/// 所以 `connect` 把地址存进设置，后续动作只传命令本身。
///
/// ## 为什么口令放在 URL 里
///
/// 电脑那边的 exe 启动时打印的就是一条带 token 的完整 URL，
/// 用户复制粘贴一次就完事。让他再拆成"地址"和"口令"两个输入框，
/// 是在给一个已经很难的操作再加一步。
class PcTool extends AgentTool {
  const PcTool();

  @override
  String get name => 'pc';

  @override
  String get title => '电脑';

  @override
  String get description =>
      '在**这台电脑**上执行命令、读写文件。需要用户先在电脑上运行 '
      '`pc_agent.exe`（打成一个工具包，在「设置 → 工具」里能看到说明）。\n'
      '用法顺序：先 `connect` 粘上 exe 窗口里打印的那条地址，'
      '之后直接 exec / read / write 就行。\n'
      'action:\n'
      '· `connect` —— params {url}，形如 '
      '`http://192.168.43.5:8765/?token=abc123`\n'
      '· `ping` —— 看连没连上、对端是什么机器\n'
      '· `exec` —— params {cmd, timeout_ms?, cwd?, shell?}。'
      '**这是最有用的动作**：跑 cmd 命令并拿回 stdout/stderr/退出码。'
      'shell 默认 cmd，可以给 `powershell`\n'
      '· `read` —— params {path, max?} 读文本文件\n'
      '· `write` —— params {path, content, append?} 写文本文件\n'
      '· `ls` —— params {path} 列目录\n'
      '· `info` —— 系统信息（盘符、核数、IP）\n'
      '· `kill` —— params {pid} 结束进程（含子进程）\n'
      '注意：\n'
      '· 命令跑在**电脑**上，不是手机上 —— 路径要用 Windows 写法'
      '（`D:\\work\\a.txt`），不要用 `/sdcard`\n'
      '· 中文输出已经按系统代码页解码，能直接看\n'
      '· 输出超过 200KB 会被截断；长命令记得给 timeout_ms';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'connect',
          'ping',
          'exec',
          'read',
          'write',
          'ls',
          'info',
          'kill',
        ],
      },
      'url': <String, dynamic>{
        'type': 'string',
        'description': 'connect 用：电脑上 exe 打印的完整地址（含 token）',
      },
      'cmd': <String, dynamic>{
        'type': 'string',
        'description': 'exec 要执行的命令（Windows 写法）',
      },
      'path': <String, dynamic>{
        'type': 'string',
        'description': 'read / write / ls 的路径',
      },
      'content': <String, dynamic>{
        'type': 'string',
        'description': 'write 的内容',
      },
      'append': <String, dynamic>{
        'type': 'boolean',
        'description': 'write 时追加而不是覆盖',
      },
      'cwd': <String, dynamic>{'type': 'string', 'description': 'exec 的工作目录'},
      'shell': <String, dynamic>{
        'type': 'string',
        'enum': <String>['cmd', 'powershell'],
        'description': 'exec 用哪个 shell，默认 cmd',
      },
      'timeout_ms': <String, dynamic>{
        'type': 'integer',
        'description': 'exec 超时毫秒数，默认 30000，上限 600000',
      },
      'pid': <String, dynamic>{'type': 'integer', 'description': 'kill 的进程号'},
      'max': <String, dynamic>{
        'type': 'integer',
        'description': 'read 最多读多少字符，默认 65536',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    return switch (args.str('action')) {
      // 在电脑上执行命令 / 写文件 / 杀进程：都会改对端状态
      'exec' || 'write' || 'kill' => const RiskAssessment(
        RiskLevel.caution,
        <String>['会在这台电脑上执行或修改东西'],
      ),
      _ => RiskAssessment.safe,
    };
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String a = args.str('action');
    return switch (a) {
      'connect' => '连接电脑',
      'exec' => '电脑执行 ${clampOutput(args.str('cmd'), max: 40)}',
      'read' => '读电脑文件 ${clampOutput(args.str('path'), max: 40)}',
      'write' => '写电脑文件 ${clampOutput(args.str('path'), max: 40)}',
      'ls' => '列电脑目录',
      'info' => '电脑信息',
      'kill' => '结束进程 ${args.str('pid')}',
      _ => '电脑 $a',
    };
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String action = args.str('action').trim().toLowerCase();
    final Settings settings = ctx.settings;

    // ---- connect：解析并记住地址 ----
    if (action == 'connect') {
      final String raw = args.str('url').trim();
      if (raw.isEmpty) return 'connect 失败：需要 url（电脑上 exe 打印的那条地址）';

      final Uri? u = Uri.tryParse(raw);
      if (u == null || u.host.isEmpty) {
        return 'connect 失败：地址不合法。应该形如 '
            '`http://192.168.43.5:8765/?token=abc123`';
      }
      final String token = u.queryParameters['token'] ?? '';
      if (token.isEmpty) {
        return 'connect 失败：地址里没有 token=…。'
            '请从 pc_agent.exe 窗口里**整条复制**那条地址。';
      }

      settings.update(() => settings.pcUrl = raw);

      // 连上之后立刻 ping 一次：地址粘错（比如复制了 127.0.0.1）
      // 在这里就能发现，而不是等用户发第一条命令才报错。
      final PcResponse r = await PcClient(
        baseUrl: '${u.scheme}://${u.host}:${u.port}',
        token: token,
      ).ping();
      if (!r.ok) {
        return '已记下地址，但**连不上**：${r.error}\n\n'
            '检查：电脑上 pc_agent.exe 还在跑吗？手机和电脑在同一个热点吗？'
            '地址里的 IP 是不是电脑的局域网地址（不是 127.0.0.1）？';
      }
      return '已连接电脑：${r.data?['machine'] ?? '?'}'
          '（${r.data?['os'] ?? '?'}）\n'
          '默认工作目录：${r.data?['cwd'] ?? '?'}\n'
          '现在可以用 exec / read / write / ls 了。';
    }

    // ---- 其余动作：用已记住的地址 ----
    final PcClient? client = PcClient.fromSettings(settings);
    if (client == null) {
      return '还没有连接电脑。先在电脑上运行 pc_agent.exe，'
          '然后把窗口里打印的地址用 `connect` 粘过来。';
    }

    final PcResponse r = switch (action) {
      'ping' => await client.ping(),
      'exec' => await client.exec(
        args.str('cmd'),
        timeoutMs: args.intVal('timeout_ms', fallback: 30000),
        cwd: args.str('cwd'),
        shell: args.str('shell'),
      ),
      'read' => await client.read(
        args.str('path'),
        max: args.intVal('max', fallback: 65536),
      ),
      'write' => await client.write(
        args.str('path'),
        args.str('content'),
        append: args.boolVal('append', fallback: false),
      ),
      'ls' => await client.ls(args.str('path')),
      'info' => await client.info(),
      'kill' => await client.kill(args.intVal('pid', fallback: 0)),
      _ => PcResponse.fail('未知 action「$action」'),
    };

    if (!r.ok) {
      // 401 单独说清楚 —— 这个错误最常见是自己改了 token
      if (r.code == 'BAD_TOKEN') {
        return '电脑那边说口令不对。重新在电脑上运行 pc_agent.exe，'
            '把新打印的地址用 `connect` 粘一次。';
      }
      return '操作失败${r.code == null ? '' : '（${r.code}）'}：${r.error}';
    }

    return r.describe(action);
  }
}

/// 一次请求的结果。失败时 [code] / [error] 说明原因。
class PcResponse {
  const PcResponse._({required this.ok, this.data, this.code, this.error});

  final bool ok;
  final Map<String, dynamic>? data;
  final String? code;
  final String? error;

  PcResponse.fail(String msg)
    : ok = false,
      data = null,
      code = 'LOCAL',
      error = msg;

  /// 只给测试用：直接构造一个结果，验证 [describe] 输出的措辞。
  @visibleForTesting
  const PcResponse.forTest({
    required this.ok,
    this.data,
    this.code,
    this.error,
  });

  /// 把结果整理成模型能直接读的文本。
  ///
  /// 为什么不直接甩 JSON：模型读自然语言比读嵌套 JSON 更省 token、
  /// 也更不容易漏字段。而 `stdout`/`stderr`/`exit` 这三样是它真正
  /// 需要区分的（"失败了" 和 "成功但没输出" 是两回事）。
  String describe(String action) {
    final Map<String, dynamic> d = data ?? const <String, dynamic>{};

    switch (action) {
      case 'exec':
        final StringBuffer sb = StringBuffer();
        final Object? exit = d['exit'];
        sb.writeln(
          '退出码：${exit ?? '?'}'
          '（${d['duration_ms'] ?? '?'}ms）',
        );
        final String out = (d['stdout'] ?? '').toString().trimRight();
        final String err = (d['stderr'] ?? '').toString().trimRight();
        sb.writeln('--- stdout ---');
        sb.writeln(out.isEmpty ? '（无）' : out);
        if (err.isNotEmpty) {
          sb.writeln('--- stderr ---');
          sb.writeln(err);
        }
        return sb.toString().trimRight();

      case 'read':
        return (d['content'] ?? '').toString();

      case 'write':
        return '已写入 ${d['path']}（${d['chars'] ?? d['bytes'] ?? '?'} '
            '${d['bytes'] != null ? '字节' : '字符'}）';

      case 'ls':
        final List<dynamic> entries =
            (d['entries'] as List<dynamic>?) ?? <dynamic>[];
        if (entries.isEmpty) return '目录是空的：${d['path']}';
        final StringBuffer sb = StringBuffer('${d['path']}：\n');
        for (final dynamic e in entries) {
          final Map<String, dynamic> m = Map<String, dynamic>.from(e as Map);
          final bool isDir = m['dir'] == true;
          final Object? size = m['size'];
          sb.writeln(
            '- ${isDir ? '[目录] ' : ''}${m['name']}'
            '${size == null ? '' : '  ($size 字节)'}',
          );
        }
        return sb.toString().trimRight();

      case 'info':
      case 'ping':
        final StringBuffer sb = StringBuffer();
        sb.writeln('机器：${d['machine'] ?? '?'} · 用户：${d['user'] ?? '?'}');
        sb.writeln('系统：${d['os'] ?? '?'}');
        if (d['cwd'] != null) sb.writeln('默认目录：${d['cwd']}');
        if (d['cores'] != null) sb.writeln('核数：${d['cores']}');
        final List<dynamic>? drives = d['drives'] as List<dynamic>?;
        if (drives != null && drives.isNotEmpty) {
          sb.writeln('磁盘：');
          for (final dynamic dv in drives) {
            final Map<String, dynamic> m = Map<String, dynamic>.from(dv as Map);
            sb.writeln(
              '  ${m['name']}  ${m['free_gb']}/${m['total_gb']} GB 可用',
            );
          }
        }
        final List<dynamic>? ips = d['ips'] as List<dynamic>?;
        if (ips != null && ips.isNotEmpty) {
          sb.writeln('地址：${ips.join(', ')}');
        }
        return sb.toString().trimRight();

      case 'kill':
        return '已结束进程 ${d['pid']}';

      default:
        return jsonEncode(d);
    }
  }
}

/// 和电脑上那个 exe 说话的最小客户端。
class PcClient {
  PcClient({required this.baseUrl, required this.token});

  /// 从设置里取上次 `connect` 记住的地址。没连过返回 null。
  static PcClient? fromSettings(Settings settings) {
    final String raw = settings.pcUrl.trim();
    if (raw.isEmpty) return null;
    final Uri? u = Uri.tryParse(raw);
    if (u == null || u.host.isEmpty) return null;
    final String token = u.queryParameters['token'] ?? '';
    if (token.isEmpty) return null;
    return PcClient(baseUrl: '${u.scheme}://${u.host}:${u.port}', token: token);
  }

  /// `http://host:port`（末尾不带斜杠）
  final String baseUrl;
  final String token;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> get _headers => <String, String>{
    'X-Token': token,
    'Content-Type': 'application/json; charset=utf-8',
  };

  Future<PcResponse> _get(String path) async {
    try {
      final http.Response r = await http
          .get(_u(path), headers: _headers)
          .timeout(const Duration(seconds: 20));
      return _parse(r);
    } catch (e) {
      return PcResponse.fail(_humanize(e));
    }
  }

  Future<PcResponse> _post(String path, Map<String, dynamic> body) async {
    try {
      final http.Response r = await http
          .post(_u(path), headers: _headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 120));
      return _parse(r);
    } catch (e) {
      return PcResponse.fail(_humanize(e));
    }
  }

  PcResponse _parse(http.Response r) {
    Map<String, dynamic>? d;
    try {
      final dynamic j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) d = Map<String, dynamic>.from(j);
    } catch (_) {
      // 不是 JSON → 说明连上的不是 pc_agent（或被防火墙页面拦了）
    }
    if (d == null) {
      return PcResponse.fail(
        '对方返回的不是 pc_agent 的格式（HTTP ${r.statusCode}）。'
        '地址可能指向了别的东西。',
      );
    }
    return PcResponse._(
      ok: d['ok'] == true,
      data: d,
      code: d['code']?.toString(),
      error: d['error']?.toString(),
    );
  }

  /// 网络异常的说明要**能指导行动**。
  /// `SocketException: Connection refused` 这串东西对用户毫无意义。
  static String _humanize(Object e) {
    final String s = e.toString();
    if (s.contains('Connection refused') || s.contains('errno = 111')) {
      return '电脑那边没有在监听这个端口。pc_agent.exe 还开着吗？';
    }
    if (s.contains('No route to host') || s.contains('errno = 113')) {
      return '网络不通。确认手机和电脑连的是同一个热点。';
    }
    if (s.contains('TimeoutException') || s.contains('timed out')) {
      return '等太久没回应。可能是防火墙挡住了，或者电脑休眠了。';
    }
    if (s.contains('Failed host lookup')) {
      return '找不到这个地址。检查 IP 有没有打错。';
    }
    return s;
  }

  Future<PcResponse> ping() => _get('/ping');
  Future<PcResponse> info() => _get('/info');
  Future<PcResponse> kill(int pid) =>
      _post('/kill', <String, dynamic>{'pid': pid});

  Future<PcResponse> exec(
    String cmd, {
    int timeoutMs = 30000,
    String cwd = '',
    String shell = '',
  }) {
    if (cmd.trim().isEmpty) {
      return Future<PcResponse>.value(PcResponse.fail('cmd 不能为空'));
    }
    return _post('/exec', <String, dynamic>{
      'cmd': cmd,
      'timeout_ms': timeoutMs,
      if (cwd.trim().isNotEmpty) 'cwd': cwd,
      if (shell.trim().isNotEmpty) 'shell': shell,
    });
  }

  Future<PcResponse> read(String path, {int max = 65536}) {
    if (path.trim().isEmpty) {
      return Future<PcResponse>.value(PcResponse.fail('path 不能为空'));
    }
    return _get('/read?path=${Uri.encodeQueryComponent(path)}&max=$max');
  }

  Future<PcResponse> write(String path, String content, {bool append = false}) {
    if (path.trim().isEmpty) {
      return Future<PcResponse>.value(PcResponse.fail('path 不能为空'));
    }
    return _post('/write', <String, dynamic>{
      'path': path,
      'content': content,
      'append': append,
    });
  }

  Future<PcResponse> ls(String path) =>
      _get('/ls?path=${Uri.encodeQueryComponent(path)}');
}
