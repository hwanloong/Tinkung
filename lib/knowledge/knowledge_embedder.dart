import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/net_error.dart';
import '../core/store.dart';
import 'knowledge_chunker.dart';

/// 向量化能力的抽象。
///
/// 抽成接口不是"为了架构好看"，而是为了两件事：
///  · 测试里可以塞一个确定性的假 embedder，不依赖网络；
///  · 没配 Embedding 模型时，知识库仍然能以"关键词检索"模式工作。
abstract class KnowledgeEmbedder {
  bool get available;

  /// 给人看的来源说明（写进知识库状态卡）。
  String get label;

  /// 把一批文本转成**已经单位化**的向量。
  Future<List<List<double>>> embed(List<String> texts);
}

/// 走 OpenAI 兼容的 `POST /embeddings`。
///
/// 参数显式传入（而不是只收一个 `Settings`），这样设置弹窗里
/// 「测试」按钮能用**还没保存**的输入直接试一次。
class ApiKnowledgeEmbedder implements KnowledgeEmbedder {
  ApiKnowledgeEmbedder({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) : _base = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       _key = apiKey.trim(),
       _model = model.trim();

  factory ApiKnowledgeEmbedder.fromSettings(Settings s) {
    final String base = s.embeddingBaseUrl.trim().isEmpty
        ? s.baseUrl
        : s.embeddingBaseUrl;
    final String key = s.embeddingApiKey.trim().isEmpty
        ? s.apiKey
        : s.embeddingApiKey;
    return ApiKnowledgeEmbedder(
      baseUrl: base,
      apiKey: key,
      model: s.embeddingModel,
    );
  }

  static const int _batch = 16;

  final String _model;
  final String _base;
  final String _key;

  @override
  bool get available =>
      _model.isNotEmpty && _key.isNotEmpty && _base.isNotEmpty;

  @override
  String get label => _model.isEmpty ? '未配置向量模型（关键词检索）' : '向量模型：$_model';

  Uri get _endpoint {
    final String b = _base;
    return Uri.parse(b.endsWith('/embeddings') ? b : '$b/embeddings');
  }

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    if (!available) {
      throw StateError('没有配置 Embedding 模型');
    }
    if (texts.isEmpty) return <List<double>>[];

    final List<List<double>> out = <List<double>>[];
    final http.Client client = http.Client();
    try {
      for (int start = 0; start < texts.length; start += _batch) {
        final int end = (start + _batch) > texts.length
            ? texts.length
            : start + _batch;
        final List<String> batch = texts.sublist(start, end);
        final List<List<double>> vectors = await _embedBatch(client, batch);
        if (vectors.length != batch.length) {
          throw const FormatException('Embedding 返回条数与输入不一致');
        }
        out.addAll(vectors);
      }
      final int? dim = out.isEmpty ? null : out.first.length;
      if (dim != null && out.any((List<double> v) => v.length != dim)) {
        throw const FormatException('同一批向量维度不一致，请检查 Embedding 模型');
      }
      return out;
    } finally {
      client.close();
    }
  }

  Future<List<List<double>>> _embedBatch(
    http.Client client,
    List<String> batch,
  ) async {
    Object? last;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final http.Response resp = await client
            .post(
              _endpoint,
              headers: <String, String>{
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $_key',
              },
              body: jsonEncode(<String, dynamic>{
                'model': _model,
                'input': batch,
              }),
            )
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode == 429 || resp.statusCode >= 500) {
          last = FormatException('Embedding 服务暂时不可用（HTTP ${resp.statusCode}）');
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 900));
            continue;
          }
        }
        if (resp.statusCode != 200) {
          throw FormatException(_humanError(resp));
        }
        final dynamic json = jsonDecode(utf8.decode(resp.bodyBytes));
        final List<dynamic> data = (json is Map && json['data'] is List)
            ? json['data'] as List<dynamic>
            : <dynamic>[];
        if (data.isEmpty) {
          throw const FormatException('Embedding 返回里没有 data');
        }
        // 有些服务不按 index 排序，按 index 还原。
        data.sort((dynamic a, dynamic b) {
          final int ai = (a is Map ? a['index'] as num? : null)?.toInt() ?? 0;
          final int bi = (b is Map ? b['index'] as num? : null)?.toInt() ?? 0;
          return ai.compareTo(bi);
        });
        final List<List<double>> vectors = <List<double>>[];
        for (final dynamic item in data) {
          if (item is! Map || item['embedding'] is! List) {
            throw const FormatException('Embedding 返回格式不对');
          }
          final List<double> v = (item['embedding'] as List<dynamic>)
              .map((dynamic e) => (e as num).toDouble())
              .toList();
          if (v.isEmpty) throw const FormatException('Embedding 返回了空向量');
          vectors.add(normalizeVector(v));
        }
        return vectors;
      } on TimeoutException {
        last = const FormatException('Embedding 请求超时（60 秒）');
      } on http.ClientException catch (e) {
        last = FormatException(NetError.describe(e));
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    }
    throw last ?? const FormatException('Embedding 失败');
  }

  static String _humanError(http.Response resp) {
    final String body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    try {
      final dynamic j = jsonDecode(body);
      if (j is Map) {
        final dynamic err = j['error'];
        if (err is Map && err['message'] != null) {
          return 'Embedding 失败（HTTP ${resp.statusCode}）：${err['message']}';
        }
        if (j['message'] != null) {
          return 'Embedding 失败（HTTP ${resp.statusCode}）：${j['message']}';
        }
      }
    } catch (_) {
      // 不是 JSON，截断原文
    }
    final String snippet = body.length > 200
        ? '${body.substring(0, 200)}…'
        : body.trim();
    return 'Embedding 失败（HTTP ${resp.statusCode}）'
        '${snippet.isEmpty ? '' : '：$snippet'}';
  }
}

/// 可选的 Cross-Encoder 精排。
///
/// 走常见的 `POST /rerank`（Jina / SiliconFlow / Cohere 的形状）：
/// 请求 `{model, query, documents, top_n}`，返回
/// `{results:[{index, relevance_score}]}`。
///
/// 失败时**静默退回本地混合分**：精排是加分项，不该让整次检索失败。
class KnowledgeReranker {
  KnowledgeReranker(this.settings);

  final Settings settings;

  String get _model => settings.rerankModel.trim();

  String get _base {
    final String custom = settings.rerankBaseUrl.trim();
    return (custom.isEmpty
            ? (settings.embeddingBaseUrl.trim().isEmpty
                  ? settings.baseUrl
                  : settings.embeddingBaseUrl)
            : custom)
        .trim()
        .replaceAll(RegExp(r'/+$'), '');
  }

  String get _key {
    final String custom = settings.rerankApiKey.trim();
    if (custom.isNotEmpty) return custom;
    final String emb = settings.embeddingApiKey.trim();
    return emb.isNotEmpty ? emb : settings.apiKey.trim();
  }

  bool get available =>
      _model.isNotEmpty && _key.isNotEmpty && _base.isNotEmpty;

  Uri get _endpoint {
    final String b = _base;
    return Uri.parse(b.endsWith('/rerank') ? b : '$b/rerank');
  }

  /// 返回 `index → 分数`；失败返回 null。
  Future<Map<int, double>?> rerank(
    String query,
    List<String> documents, {
    int topN = 20,
  }) async {
    if (!available || documents.isEmpty) return null;
    final http.Client client = http.Client();
    try {
      final http.Response resp = await client
          .post(
            _endpoint,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_key',
            },
            body: jsonEncode(<String, dynamic>{
              'model': _model,
              'query': query,
              'documents': documents,
              'top_n': topN,
            }),
          )
          .timeout(const Duration(seconds: 45));
      if (resp.statusCode != 200) return null;
      final dynamic json = jsonDecode(utf8.decode(resp.bodyBytes));
      final List<dynamic> results = (json is Map && json['results'] is List)
          ? json['results'] as List<dynamic>
          : <dynamic>[];
      final Map<int, double> out = <int, double>{};
      for (final dynamic r in results) {
        if (r is! Map) continue;
        final int? idx = (r['index'] as num?)?.toInt();
        final double? score = ((r['relevance_score'] ?? r['score']) as num?)
            ?.toDouble();
        if (idx != null &&
            score != null &&
            idx >= 0 &&
            idx < documents.length) {
          out[idx] = score;
        }
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}
