import 'dart:convert';
import 'package:flutter/services.dart';
import 'external_artifact.dart';

class ExternalArtifactBridge {
  ExternalArtifactBridge._();
  static final ExternalArtifactBridge instance = ExternalArtifactBridge._();

  static const MethodChannel _ch = MethodChannel('dsh/external_artifact');
  static const EventChannel _inboxEvents =
      EventChannel('dsh/artifact_inbox_events');

  /// 订阅来自第三方 artifact 的主动消息。
  /// 返回的 Stream 每条是一个 Map：
  ///   type: 'artifact_ask'
  ///   authority: String
  ///   label: String
  ///   message: String
  ///   convId: String (空串 = 自动分配)
  Stream<Map<String, dynamic>> get inboxEvents =>
      _inboxEvents.receiveBroadcastStream()
          .where((dynamic e) => e is Map)
          .map((dynamic e) => Map<String, dynamic>.from(e as Map));

  /// 发现已安装的 artifact 提供方，更新 store 并返回列表。
  Future<List<ExternalArtifact>> discover() async {
    try {
      final List<dynamic> raw =
          await _ch.invokeMethod<List<dynamic>>('discover') ?? <dynamic>[];
      final List<ExternalArtifact> result = <ExternalArtifact>[];
      for (final dynamic item in raw) {
        final Map<String, dynamic> info = Map<String, dynamic>.from(item as Map);
        final String authority = info['authority']?.toString() ?? '';
        final String packageName = info['packageName']?.toString() ?? '';
        final String label = info['label']?.toString() ?? packageName;
        if (authority.isEmpty) continue;

        List<ArtifactToolDef> tools = <ArtifactToolDef>[];
        try {
          final String toolsJson =
              await _ch.invokeMethod<String>('list_tools', <String, String>{
                'authority': authority,
              }) ?? '[]';
          final List<dynamic> toolsDyn = jsonDecode(toolsJson) as List<dynamic>;
          tools = toolsDyn
              .whereType<Map<String, dynamic>>()
              .map(ArtifactToolDef.fromJson)
              .toList();
        } catch (e) {
          // list_tools 失败不影响发现：仍然添加 artifact，工具列表为空
          // ignore: avoid_print
          print('ExternalArtifact list_tools failed for $authority: $e');
        }

        // 无论 list_tools 是否成功都添加（工具列表可能为空）
        result.add(ExternalArtifact(
          packageName: packageName,
          authority: authority,
          label: label,
          tools: tools,
        ));
      }
      ExternalArtifactStore.instance.update(result);
      return result;
    } on MissingPluginException {
      return <ExternalArtifact>[];
    } catch (e) {
      // ignore: avoid_print
      print('ExternalArtifact discover failed: $e');
      return <ExternalArtifact>[];
    }
  }

  /// 执行工具，返回结果字符串。
  Future<String> execute({
    required String authority,
    required String tool,
    required Map<String, String> args,
  }) async {
    try {
      final Map<dynamic, dynamic> resp =
          await _ch.invokeMethod<Map<dynamic, dynamic>>('execute', <String, dynamic>{
            'authority': authority,
            'tool': tool,
            'args': args,
          }) ?? <dynamic, dynamic>{};
      final String? error = resp['error']?.toString();
      if (error != null && error.isNotEmpty) return '错误：$error';
      return resp['result']?.toString() ?? '（无返回值）';
    } on MissingPluginException {
      return '错误：当前平台不支持 External Artifact';
    } catch (e) {
      return '错误：$e';
    }
  }
}
