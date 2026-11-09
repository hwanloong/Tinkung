// MCP 客户端的三条底线：
//
//  1. **协议要真的走通**：initialize → notifications/initialized →
//     tools/list（翻页）→ tools/call。少一步，真实服务器就会 400。
//  2. **两种响应都要能读**：`application/json` 和 `text/event-stream`。
//     只解析 JSON 的客户端在 SSE 服务器上会"连上了但永远拿不到结果"。
//  3. **服务器给的东西不可信**：工具名要改成 OpenAI 能接受的形状，
//     schema 缺失/不是 object 时要补成合法 schema —— 否则一次 400
//     会把这一轮**所有**工具都废掉。
//
// 用一个本地 `HttpServer` 扮演 MCP 服务器，不依赖任何外部服务。
import 'dart:convert';
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/mcp/mcp_client.dart';
import 'package:dsh_agent/mcp/mcp_store.dart';
import 'package:dsh_agent/tools/mcp_tool.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMcp {
  FakeMcp._(this.server, this.log, this._sse, this._failOnce);

  final HttpServer server;

  /// 收到的所有 JSON-RPC method（按顺序）。
  final List<String> log;

  final bool _sse;
  final bool _failOnce;
  bool _failed = false;

  static Future<FakeMcp> start({
    bool sse = false,
    bool failOnce = false,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final List<String> log = <String>[];
    final FakeMcp fake = FakeMcp._(server, log, sse, failOnce);

    server.listen((HttpRequest req) async {
      if (req.method != 'POST') {
        req.response.statusCode = 405;
        await req.response.close();
        return;
      }
      // 只有 `/mcp` 是真正的端点：用来验证"只填主机名"时的补全逻辑。
      if (req.uri.path != '/mcp') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final String body = await utf8.decoder.bind(req).join();
      final Map<String, dynamic> msg = jsonDecode(body) as Map<String, dynamic>;
      final String method = msg['method']?.toString() ?? '';
      final dynamic id = msg['id'];
      log.add(method);

      Future<void> json(Map<String, dynamic> payload) async {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(payload));
        await req.response.close();
      }

      switch (method) {
        case 'notifications/initialized':
          req.response.statusCode = 202;
          await req.response.close();

        case 'initialize':
          req.response.headers.set('Mcp-Session-Id', 'sess-test');
          await json(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{
              'protocolVersion': '2025-06-18',
              'capabilities': <String, dynamic>{},
              'serverInfo': <String, dynamic>{
                'name': 'fake',
                'version': '0.0.1',
              },
            },
          });

        case 'tools/list':
          final String cursor = (msg['params'] is Map)
              ? (msg['params'] as Map)['cursor']?.toString() ?? ''
              : '';
          if (cursor.isEmpty) {
            await json(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'tools': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'echo',
                    'description': '回显文本',
                    'inputSchema': <String, dynamic>{
                      'type': 'object',
                      'properties': <String, dynamic>{
                        'text': <String, dynamic>{'type': 'string'},
                      },
                      'required': <String>['text'],
                    },
                  },
                  <String, dynamic>{
                    'name': 'notes.create',
                    'description': '可能写数据',
                    'annotations': <String, dynamic>{'destructiveHint': true},
                    'inputSchema': <String, dynamic>{'type': 'string'},
                  },
                ],
                'nextCursor': 'page2',
              },
            });
          } else {
            await json(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'tools': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'lookup',
                    'description': '只读查询',
                    'annotations': <String, dynamic>{'readOnlyHint': true},
                    'inputSchema': <String, dynamic>{
                      'type': 'object',
                      'properties': <String, dynamic>{},
                    },
                  },
                ],
              },
            });
          }

        case 'tools/call':
          if (fake._failOnce && !fake._failed) {
            fake._failed = true;
            req.response.statusCode = 404;
            await req.response.close();
            return;
          }
          final Map<String, dynamic> params = msg['params'] is Map
              ? Map<String, dynamic>.from(msg['params'] as Map)
              : <String, dynamic>{};
          final String name = params['name']?.toString() ?? '';
          final Map<String, dynamic> args = params['arguments'] is Map
              ? Map<String, dynamic>.from(params['arguments'] as Map)
              : <String, dynamic>{};

          if (fake._sse) {
            req.response.headers.set(
              'Content-Type',
              'text/event-stream; charset=utf-8',
            );
            // 先来一条通知（真实服务器会夹带进度/日志），再来结果。
            req.response.write(
              'event: message\ndata: '
              '{"jsonrpc":"2.0","method":"notifications/progress",'
              '"params":{"progress":50}}\n\n',
            );
            req.response.write(
              'event: message\ndata: '
              '${jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, dynamic>{
                  'content': <Map<String, dynamic>>[
                    <String, dynamic>{'type': 'text', 'text': 'sse:${args['text'] ?? ''}'},
                  ],
                },
              })}\n\n',
            );
            await req.response.close();
            return;
          }

          await json(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{
              if (name == 'echo')
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'text',
                    'text': 'echo:${args['text'] ?? ''}',
                  },
                  <String, dynamic>{
                    'type': 'image',
                    'data': base64Encode(<int>[137, 80, 78, 71]),
                    'mimeType': 'image/png',
                  },
                ]
              else
                'content': <Map<String, dynamic>>[
                  <String, dynamic>{'type': 'text', 'text': 'wrote it'},
                ],
              'structuredContent': <String, dynamic>{'ok': true},
            },
          });

        default:
          await json(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'error': <String, dynamic>{
              'code': -32601,
              'message': 'unknown method $method',
            },
          });
      }
    });
    return fake;
  }

  String get url => 'http://127.0.0.1:${server.port}/mcp';

  Future<void> close() => server.close(force: true);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dsh_mcp');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('协议', () {
    test('initialize 拿到会话 + 协议版本，之后能翻页列出工具', () async {
      final FakeMcp fake = await FakeMcp.start();
      addTearDown(fake.close);
      final McpClient client = McpClient();
      addTearDown(client.close);

      final McpSession session = await client.connect(fake.url);
      expect(session.sessionId, 'sess-test');
      expect(session.protocolVersion, '2025-06-18');
      expect(session.serverName, 'fake');

      final List<McpToolDef> tools = await client.listTools(session);
      expect(tools.map((McpToolDef t) => t.name), <String>[
        'echo',
        'notes.create',
        'lookup',
      ]);
      expect(fake.log.first, 'initialize');
      expect(fake.log[1], 'notifications/initialized');
      expect(
        fake.log.where((String m) => m == 'tools/list').length,
        2,
        reason: '必须跟着 nextCursor 翻页，不能只读第一页',
      );
    });

    test('SSE 响应里夹着通知也能取到结果', () async {
      final FakeMcp fake = await FakeMcp.start(sse: true);
      addTearDown(fake.close);
      final McpClient client = McpClient();
      addTearDown(client.close);

      final McpSession session = await client.connect(fake.url);
      final McpCallResult r = await client.callTool(
        session,
        'echo',
        <String, dynamic>{'text': 'hi'},
      );
      expect(r.isError, isFalse);
      expect(r.content.single['text'], 'sse:hi');
    });

    test('HTTP 404（会话过期）会在 store 层自动重连一次', () async {
      final FakeMcp fake = await FakeMcp.start(failOnce: true);
      addTearDown(fake.close);

      final McpStore store = await McpStore.configure(
        File('${tmp.path}/mcp.json'),
      );
      final McpServer server = store.addServer(name: 'fake', url: fake.url);
      expect(await store.refresh(server), isNull);

      final McpCallResult r = await store.callTool(
        server,
        'echo',
        <String, dynamic>{'text': 'retry'},
      );
      expect(r.content.first['text'], 'echo:retry');
      expect(
        fake.log.where((String m) => m == 'initialize').length,
        2,
        reason: '第一次 call 返回 404 后必须重新 initialize 再试',
      );
    });

    test('只填主机名时自动补 /mcp 再试一次', () async {
      final FakeMcp fake = await FakeMcp.start();
      addTearDown(fake.close);

      final McpStore store = await McpStore.configure(
        File('${tmp.path}/mcp2.json'),
      );
      final McpServer server = store.addServer(
        name: 'fake',
        url: 'http://127.0.0.1:${fake.server.port}',
      );

      expect(
        await store.refresh(server),
        isNull,
        reason: '用户经常只填域名，端点其实是 /mcp',
      );
      expect(server.url, endsWith('/mcp'), reason: '补全后要把地址记下来');
      expect(server.tools, hasLength(3));

      final String prompt = store.toPromptSection();
      expect(prompt, contains('MCP'));
      expect(prompt, contains('fake'));
      expect(prompt, contains('mcp_'), reason: '要告诉模型函数名以 mcp_ 开头');
    });
  });

  group('工具表', () {
    test('暴露给模型的名字合法、唯一、不超 64 字符', () {
      final McpServer server = McpServer(
        id: '1730000000000000_7',
        name: '我的笔记',
        url: 'https://example.com/mcp',
      );

      // id 去掉非字母数字后取末 4 位：`…0007`。
      expect(mcpExposedName(server, 'notes.create'), 'mcp_0007_notes_create');
      expect(
        mcpExposedName(server, '查询 天气'),
        'mcp_0007_tool',
        reason: '中文工具名 slug 后为空，要有兜底',
      );

      final String long = mcpExposedName(server, 'a' * 200);
      expect(long.length, lessThanOrEqualTo(64));
      expect(RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(long), isTrue);
    });

    test('英文服务器名会出现在工具名里（模型才认得出是哪个系统）', () {
      final McpServer server = McpServer(
        id: 'abc123',
        name: 'My Notes',
        url: 'https://example.com/mcp',
      );
      expect(
        mcpExposedName(server, 'create note'),
        'mcp_my_notes_c123_create_note',
      );
    });

    test('schema 缺失或不是 object 时补成合法 object', () {
      expect(sanitizeMcpSchema(null)['type'], 'object');
      expect(sanitizeMcpSchema(null)['properties'], isEmpty);

      final Map<String, dynamic> fixed = sanitizeMcpSchema(<String, dynamic>{
        'type': 'string',
        'properties': <String, dynamic>{'x': <String, dynamic>{}},
      });
      expect(fixed['type'], 'object');
      expect(fixed['properties'], isNotEmpty);
    });

    test('中转站不认的 schema 关键字（\$ref / oneOf…）会被清掉', () {
      final Map<String, dynamic> cleaned = sanitizeMcpSchema(<String, dynamic>{
        'type': 'object',
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        r'$defs': <String, dynamic>{},
        'properties': <String, dynamic>{
          'x': <String, dynamic>{
            r'$ref': '#/\$defs/X',
            'type': 'string',
            'oneOf': <dynamic>[],
          },
        },
        'oneOf': <dynamic>[],
      });

      expect(cleaned.containsKey(r'$schema'), isFalse);
      expect(cleaned.containsKey(r'$defs'), isFalse);
      expect(cleaned.containsKey('oneOf'), isFalse);
      expect(cleaned['properties'], <String, dynamic>{
        'x': <String, dynamic>{'type': 'string'},
      }, reason: r'$ref 被丢掉，但同级的 type 保留');
    });

    test('风险分级：远端只读声明只降到 caution，破坏性判 dangerous', () {
      final McpServer server = McpServer(
        id: 's1',
        name: 'fake',
        url: 'https://example.com/mcp',
      );
      const Map<String, dynamic> args = <String, dynamic>{};

      // `readOnlyHint` 是服务端自述，不是我们验证过的事实 —— 不能凭它
      // 拿到"直接执行、不弹确认"的待遇。
      final McpTool read = McpTool(
        server: server,
        info: const McpToolInfo(
          name: 'lookup',
          exposedName: 'mcp_s1_lookup',
          title: 'lookup',
          description: '',
          inputSchema: <String, dynamic>{'type': 'object'},
          readOnly: true,
        ),
      );
      final RiskAssessment readRisk = read.riskFor(args);
      expect(readRisk.level, RiskLevel.caution);
      expect(readRisk.reasons.join(), contains('未经验证'));

      final McpTool write = McpTool(
        server: server,
        info: const McpToolInfo(
          name: 'notes.create',
          exposedName: 'mcp_s1_notes_create',
          title: 'notes.create',
          description: '',
          inputSchema: <String, dynamic>{'type': 'object'},
          destructive: true,
        ),
      );
      final RiskAssessment risk = write.riskFor(args);
      expect(risk.level, RiskLevel.dangerous);
      expect(risk.reasons.join(), contains('破坏'));
    });
  });

  group('结果展开', () {
    test('text / image / resource / structuredContent 都要给到模型', () async {
      final McpCallResult result = McpCallResult(
        content: <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': '结论：42'},
          <String, dynamic>{
            'type': 'image',
            'data': base64Encode(<int>[137, 80, 78, 71, 13, 10, 26, 10]),
            'mimeType': 'image/png',
          },
          <String, dynamic>{
            'type': 'resource',
            'resource': <String, dynamic>{
              'uri': 'file:///a.txt',
              'text': '资源正文',
            },
          },
        ],
        structured: <String, dynamic>{'answer': 42},
      );

      final String out = await formatMcpResult(result, workDir: tmp.path);

      expect(out, contains('结论：42'));
      expect(out, contains('MCP 返回图片'));
      expect(out, contains('read_image'), reason: '图片要给模型一条后续动作');
      expect(out, contains('资源正文'));
      expect(out, contains('结构化结果'));
      expect(out, contains('"answer": 42'));

      final Directory mcpDir = Directory('${tmp.path}/mcp');
      expect(mcpDir.existsSync(), isTrue);
      expect(
        mcpDir.listSync().whereType<File>(),
        isNotEmpty,
        reason: '图片必须真的落盘，否则模型拿到一个不存在的路径',
      );
    });

    test('isError 的返回要明确标成错误', () async {
      final String out = await formatMcpResult(
        const McpCallResult(
          content: <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': 'permission denied'},
          ],
          isError: true,
        ),
        workDir: tmp.path,
      );
      expect(out, startsWith('MCP 工具返回错误'));
      expect(out, contains('permission denied'));
    });
  });
}
