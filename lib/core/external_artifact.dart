import 'package:flutter/foundation.dart';

/// 单个 External Artifact 工具参数
class ArtifactParam {
  const ArtifactParam({
    required this.name,
    this.description = '',
    this.required = true,
  });
  final String name;
  final String description;
  final bool required;

  static ArtifactParam fromJson(Map<String, dynamic> j) => ArtifactParam(
    name: j['name']?.toString() ?? '',
    description: j['description']?.toString() ?? '',
    required: j['required'] != false,
  );
}

/// 单个工具声明（来自第三方 app）
class ArtifactToolDef {
  const ArtifactToolDef({
    required this.name,
    required this.title,
    this.description = '',
    this.params = const <ArtifactParam>[],
  });
  final String name;
  final String title;
  final String description;
  final List<ArtifactParam> params;

  static ArtifactToolDef fromJson(Map<String, dynamic> j) => ArtifactToolDef(
    name: j['name']?.toString() ?? '',
    title: j['title']?.toString() ?? j['name']?.toString() ?? '',
    description: j['description']?.toString() ?? '',
    params: ((j['params'] as List<dynamic>?) ?? <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(ArtifactParam.fromJson)
        .toList(),
  );
}

/// 一个已安装的 External Artifact 提供方
class ExternalArtifact {
  const ExternalArtifact({
    required this.packageName,
    required this.authority,
    required this.label,
    required this.tools,
  });
  final String packageName;
  final String authority;
  final String label;        // app 显示名
  final List<ArtifactToolDef> tools;
}

/// 管理已发现的 External Artifact
class ExternalArtifactStore extends ChangeNotifier {
  ExternalArtifactStore._();
  static final ExternalArtifactStore instance = ExternalArtifactStore._();

  List<ExternalArtifact> _artifacts = <ExternalArtifact>[];
  List<ExternalArtifact> get artifacts => List.unmodifiable(_artifacts);

  void update(List<ExternalArtifact> list) {
    _artifacts = list;
    notifyListeners();
  }
}
