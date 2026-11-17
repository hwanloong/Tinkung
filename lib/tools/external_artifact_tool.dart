import '../core/external_artifact.dart';
import '../core/external_artifact_bridge.dart';
import '../core/models.dart';
import 'tool.dart';

/// 动态包装一个 External Artifact 工具。
class ExternalArtifactTool extends AgentTool {
  ExternalArtifactTool({
    required this.artifact,
    required this.toolDef,
  });

  final ExternalArtifact artifact;
  final ArtifactToolDef toolDef;

  @override
  String get name => '${artifact.packageName.replaceAll('.', '_')}__${toolDef.name}';

  @override
  String get title => '${artifact.label} · ${toolDef.title}';

  @override
  String get description =>
      '${toolDef.description.isEmpty ? toolDef.title : toolDef.description}'
      '（External Artifact，来自「${artifact.label}」）';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      for (final ArtifactParam p in toolDef.params)
        p.name: <String, dynamic>{
          'type': 'string',
          'description': p.description,
        },
    },
    'required': toolDef.params
        .where((ArtifactParam p) => p.required)
        .map((ArtifactParam p) => p.name)
        .toList(),
    'additionalProperties': false,
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) =>
      RiskAssessment(RiskLevel.caution, <String>['调用 External Artifact「${toolDef.title}」']);

  @override
  String summarize(Map<String, dynamic> args) =>
      '调用 ${artifact.label} · ${toolDef.title}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) {
    final Map<String, String> strArgs = args.map(
      (String k, dynamic v) => MapEntry<String, String>(k, v?.toString() ?? ''),
    );
    return ExternalArtifactBridge.instance.execute(
      authority: artifact.authority,
      tool: toolDef.name,
      args: strArgs,
    );
  }
}
