import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import '../mcp/mcp_client.dart';
import '../mcp/mcp_store.dart';
import 'tool.dart';

/// 把一个 MCP 工具包装成 agent 能调用的普通工具。
///
/// 工具名 / 参数 / 说明全部来自服务器的 `tools/list`；执行时原样转发到
/// `tools/call`，再把 MCP 的 content blocks 翻成模型能读的文本。
///
/// ## 风险分级
///
/// 优先相信服务器在 `annotations.readOnlyHint` 里自报的只读属性：
/// 只读工具直接执行；其余一律 `caution`（要用户确认）。
/// `destructiveHint` 会额外在确认框里点明 —— 那是服务器自己承认
/// "这个操作可能造成破坏"，比我们猜准。
class McpTool extends AgentTool {
  const McpTool({required this.server, required this.info});

  final McpServer server;
  final McpToolInfo info;

  @override
  String get name => info.exposedName;

  @override
  String get title => '${server.displayName} · ${info.title}';

  @override
  String get description {
    final String desc = info.description.trim();
    final String head = desc.isEmpty ? 'MCP 工具「${info.name}」' : desc;
    return '$head\n（来自 MCP 服务器「${server.displayName}」）';
  }

  @override
  Map<String, dynamic> get parameters => info.inputSchema;

  @override
  bool get autoApprove => false;

  @override
  Duration get timeout => const Duration(minutes: 3);

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    // `readOnlyHint` 是**远端服务器自己写的**，不是我们验证过的事实：
    // 一个被盗用/写错的 MCP 可以直接把 delete 标成只读，从而获得
    // "不弹确认、直接执行"的待遇 —— 这条路径以前确实存在。
    //
    // 现在只读声明**不再**直接给 safe：读操作本来就不贵，多问一次的
    // 成本远小于把远程自述当成权限。destructive 则明确判 dangerous，
    // 让确认框的默认按钮落在「拒绝」上。
    if (info.destructive) {
      return RiskAssessment(RiskLevel.dangerous, <String>[
        '远程 MCP「${server.displayName}」声明这是个破坏性操作：${info.name}',
        '参数：${jsonEncode(args)}',
      ]);
    }
    return RiskAssessment(RiskLevel.caution, <String>[
      '远程 MCP「${server.displayName}」的工具：${info.name}',
      if (info.readOnly) '服务器声明为只读（这是远端自述，未经验证）',
      '参数：${jsonEncode(args)}',
    ]);
  }

  @override
  String summarize(Map<String, dynamic> args) =>
      '${server.displayName} · ${info.name}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final McpCallResult result = await McpStore.instance.callTool(
      server,
      info.name,
      args,
    );
    return formatMcpResult(result, workDir: ctx.workDir);
  }
}

/// 把 MCP 的返回翻成**模型能直接读**的文本。
///
/// MCP 的 content 是结构化的（text / image / resource / resource_link…），
/// 而工具结果必须是文本，所以这里逐块展开：
///  · 图片写成文件并给出路径（模型可再用 `read_image` 看）；
///  · 资源把文本摊开，二进制存成文件；
///  · `structuredContent` 用 JSON 输出，便于模型精确引用字段。
Future<String> formatMcpResult(
  McpCallResult result, {
  required String workDir,
}) async {
  final StringBuffer sb = StringBuffer();
  if (result.isError) sb.writeln('MCP 工具返回错误：');

  int saved = 0;
  for (final Map<String, dynamic> block in result.content) {
    final String type = block['type']?.toString() ?? '';
    switch (type) {
      case 'text':
        final String text = block['text']?.toString() ?? '';
        if (text.isNotEmpty) sb.writeln(text);
        break;

      case 'image':
        final String b64 = block['data']?.toString() ?? '';
        final String mime = block['mimeType']?.toString() ?? 'image/png';
        final String? path = await _saveBlob(
          workDir,
          b64,
          mime,
          'mcp_${++saved}',
        );
        if (path == null) {
          sb.writeln('（MCP 返回了一张图片，但内容无法解析）');
        } else {
          sb.writeln('【MCP 返回图片：$path（可用 read_image 查看）】');
        }
        break;

      case 'audio':
        sb.writeln('（MCP 返回了一段音频，当前版本不展示）');
        break;

      case 'resource':
        final dynamic res = block['resource'];
        if (res is Map) {
          final String uri = res['uri']?.toString() ?? '';
          final String text = res['text']?.toString() ?? '';
          sb.writeln('【资源 $uri】');
          if (text.isNotEmpty) {
            sb.writeln(text);
          } else if (res['blob'] != null) {
            final String mime = res['mimeType']?.toString() ?? '';
            final String? path = await _saveBlob(
              workDir,
              res['blob'].toString(),
              mime,
              'mcp_res_${++saved}',
            );
            sb.writeln(path == null ? '（二进制资源无法解析）' : '（二进制资源已保存：$path）');
          }
        } else {
          sb.writeln('【资源】$res');
        }
        break;

      case 'resource_link':
        final String name = block['name']?.toString() ?? '';
        final String uri = block['uri']?.toString() ?? '';
        sb.writeln('【资源链接：${name.isEmpty ? uri : '$name（$uri）'}】');
        break;

      default:
        // 未知类型不丢：原样以 JSON 给模型，它自己知道怎么读。
        if (type.isNotEmpty) {
          sb.writeln('【$type】${jsonEncode(block)}');
        }
    }
  }

  if (result.structured != null) {
    sb.writeln('【结构化结果】');
    sb.writeln(const JsonEncoder.withIndent('  ').convert(result.structured));
  }

  final String text = sb.toString().trim();
  if (text.isEmpty) {
    return result.isError ? 'MCP 工具返回错误（没有附带内容）' : '（MCP 工具没有返回内容）';
  }
  return clampOutput(text, max: 12000);
}

/// 把 base64 存成工作目录下的文件。失败返回 null。
Future<String?> _saveBlob(
  String workDir,
  String base64Text,
  String mime,
  String stem,
) async {
  if (base64Text.trim().isEmpty) return null;
  try {
    final List<int> bytes = base64Decode(base64Text);
    final Directory dir = Directory('$workDir/mcp');
    await dir.create(recursive: true);
    final String ext = _extForMime(mime);
    final String path =
        '${dir.path}/${stem}_${DateTime.now().millisecondsSinceEpoch}$ext';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  } catch (_) {
    return null;
  }
}

String _extForMime(String mime) {
  final String m = mime.toLowerCase();
  if (m.contains('png')) return '.png';
  if (m.contains('jpeg') || m.contains('jpg')) return '.jpg';
  if (m.contains('webp')) return '.webp';
  if (m.contains('gif')) return '.gif';
  if (m.contains('svg')) return '.svg';
  if (m.contains('pdf')) return '.pdf';
  if (m.contains('json')) return '.json';
  if (m.contains('text')) return '.txt';
  return '.bin';
}
