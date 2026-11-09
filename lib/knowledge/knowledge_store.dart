import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/ids.dart';
import '../core/store.dart';
import 'document_parser.dart';
import 'knowledge_chunker.dart';
import 'knowledge_embedder.dart';

/// 知识库里的一篇文档（只存元信息；正文在切片里）。
class KnowledgeDoc {
  KnowledgeDoc({
    required this.id,
    required this.title,
    required this.source,
    required this.kind,
    required this.chars,
    required this.chunkCount,
    DateTime? createdAt,
    this.error = '',
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String title;
  String source;
  String kind;
  int chars;
  int chunkCount;
  final DateTime createdAt;

  /// 向量化失败等非致命问题（文档仍然可以关键词检索）。
  String error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'source': source,
    'kind': kind,
    'chars': chars,
    'chunkCount': chunkCount,
    'createdAt': createdAt.toIso8601String(),
    'error': error,
  };

  static KnowledgeDoc fromJson(Map<String, dynamic> j) => KnowledgeDoc(
    id: j['id']?.toString() ?? '',
    title: j['title']?.toString() ?? '',
    source: j['source']?.toString() ?? '',
    kind: j['kind']?.toString() ?? '文本',
    chars: (j['chars'] as num?)?.toInt() ?? 0,
    chunkCount: (j['chunkCount'] as num?)?.toInt() ?? 0,
    createdAt:
        DateTime.tryParse(j['createdAt']?.toString() ?? '') ?? DateTime.now(),
    error: j['error']?.toString() ?? '',
  );
}

/// 一个切片。
class KnowledgeChunk {
  KnowledgeChunk({
    required this.id,
    required this.docId,
    required this.index,
    required this.heading,
    required this.text,
    this.vector,
  });

  final String id;
  final String docId;

  /// 在文档里的顺序（从 0 开始），用于展示与引用。
  final int index;
  final String heading;
  final String text;

  /// 单位化后的向量；没有配置 Embedding 模型时为 null。
  List<double>? vector;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'docId': docId,
    'index': index,
    'heading': heading,
    'text': text,
  };

  static KnowledgeChunk fromJson(Map<String, dynamic> j) => KnowledgeChunk(
    id: j['id']?.toString() ?? '',
    docId: j['docId']?.toString() ?? '',
    index: (j['index'] as num?)?.toInt() ?? 0,
    heading: j['heading']?.toString() ?? '',
    text: j['text']?.toString() ?? '',
  );
}

/// 一个知识库。
class KnowledgeBase {
  KnowledgeBase({
    required this.id,
    required this.name,
    DateTime? createdAt,
    List<KnowledgeDoc>? docs,
    List<KnowledgeChunk>? chunks,
    this.dim = 0,
    this.embeddingModel = '',
  }) : createdAt = createdAt ?? DateTime.now(),
       docs = docs ?? <KnowledgeDoc>[],
       chunks = chunks ?? <KnowledgeChunk>[];

  final String id;
  String name;
  final DateTime createdAt;
  final List<KnowledgeDoc> docs;
  final List<KnowledgeChunk> chunks;

  /// 向量维度；0 = 还没有向量。
  int dim;
  String embeddingModel;

  int get chars => docs.fold<int>(0, (int n, KnowledgeDoc d) => n + d.chars);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'dim': dim,
    'embeddingModel': embeddingModel,
    'docs': docs.map((KnowledgeDoc d) => d.toJson()).toList(),
  };
}

/// 一条检索命中。
class KnowledgeHit {
  const KnowledgeHit({
    required this.base,
    required this.chunk,
    required this.doc,
    required this.score,
    required this.vectorScore,
    required this.lexicalScore,
  });

  final KnowledgeBase base;
  final KnowledgeChunk chunk;
  final KnowledgeDoc doc;
  final double score;
  final double vectorScore;
  final double lexicalScore;
}

/// 导入 / 重建索引的进度（UI 用来画一条进度线）。
class KnowledgeJob {
  const KnowledgeJob(this.label, this.progress);

  final String label;
  final double progress;
}

/// 知识库的存储、切片、向量化与检索。
///
/// ## 为什么是"真 RAG"
///
/// 不做"整篇塞进上下文"的伪 RAG：每篇文档先切分、向量化入库；
/// 提问时只召回最相关的几个片段（可选的 Cross-Encoder 精排），
/// 再交给聊天模型回答。答案能带出处，长文档也不受上下文窗口限制。
class KnowledgeStore extends ChangeNotifier {
  KnowledgeStore._(this._root, this._settings, this._embedderOverride);

  static KnowledgeStore? _instance;

  static KnowledgeStore get instance {
    final KnowledgeStore? s = _instance;
    if (s == null) {
      throw StateError(
        'KnowledgeStore 还没初始化。应该在 main() 里调用 KnowledgeStore.configure()。',
      );
    }
    return s;
  }

  /// 未初始化时返回 null（工具/页面在极端路径下不崩）。
  static KnowledgeStore? get maybeInstance => _instance;

  static Future<KnowledgeStore> configure(
    Directory root, {
    Settings? settings,
    KnowledgeEmbedder? embedder,
  }) async {
    final KnowledgeStore s = KnowledgeStore._(root, settings, embedder);
    _instance = s;
    await s.load();
    return s;
  }

  final Directory _root;
  final Settings? _settings;

  /// 测试注入；为 null 时按 Settings 建 API embedder。
  final KnowledgeEmbedder? _embedderOverride;

  final List<KnowledgeBase> bases = <KnowledgeBase>[];
  KnowledgeJob? job;

  KnowledgeEmbedder? get embedder =>
      _embedderOverride ??
      (_settings == null ? null : ApiKnowledgeEmbedder.fromSettings(_settings));

  KnowledgeReranker? get reranker =>
      _settings == null ? null : KnowledgeReranker(_settings);

  bool get vectorReady => embedder?.available == true;

  int get defaultTopK => (_settings?.ragTopK ?? 6).clamp(1, 20);

  KnowledgeBase? byId(String id) {
    for (final KnowledgeBase b in bases) {
      if (b.id == id) return b;
    }
    return null;
  }

  KnowledgeBase? byName(String name) {
    final String n = name.trim().toLowerCase();
    for (final KnowledgeBase b in bases) {
      if (b.name.trim().toLowerCase() == n) return b;
    }
    return null;
  }

  KnowledgeBase? resolve(String? idOrName) {
    final String q = (idOrName ?? '').trim();
    if (q.isEmpty) return null;
    return byId(q) ?? byName(q);
  }

  // ------------------------------------------------------------------ 持久化

  File get _indexFile => File('${_root.path}/index.json');

  Directory _baseDir(String id) => Directory('${_root.path}/$id');

  Future<void> load() async {
    bases.clear();
    try {
      if (await _root.exists()) {
        final File index = _indexFile;
        if (await index.exists()) {
          final dynamic data = jsonDecode(await index.readAsString());
          if (data is List) {
            for (final dynamic e in data) {
              if (e is! Map) continue;
              // 单个库坏了不该拖垮整页：跳过它，其余照常加载。
              try {
                final KnowledgeBase? b = await _loadBase(
                  Map<String, dynamic>.from(e),
                );
                if (b != null) bases.add(b);
              } catch (_) {
                continue;
              }
            }
          }
        } else {
          // 没有 index.json：扫目录兜底（旧版本/手工拷贝进来的库）
          await for (final FileSystemEntity e in _root.list()) {
            if (e is! Directory) continue;
            final File meta = File('${e.path}/meta.json');
            if (!await meta.exists()) continue;
            final String id = e.path.split(RegExp(r'[/\\]')).last;
            try {
              final KnowledgeBase? b = await _loadBase(<String, dynamic>{
                'id': id,
                'name': id,
              });
              if (b != null) bases.add(b);
            } catch (_) {
              continue;
            }
          }
        }
      }
    } catch (_) {
      bases.clear();
    }
    notifyListeners();
  }

  Future<KnowledgeBase?> _loadBase(Map<String, dynamic> entry) async {
    final String id = entry['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final File metaFile = File('${_baseDir(id).path}/meta.json');
    if (!await metaFile.exists()) return null;
    final Map<String, dynamic> meta = Map<String, dynamic>.from(
      jsonDecode(await metaFile.readAsString()) as Map,
    );

    final List<KnowledgeDoc> docs = <KnowledgeDoc>[];
    if (meta['docs'] is List) {
      for (final dynamic d in meta['docs'] as List<dynamic>) {
        if (d is Map) {
          docs.add(KnowledgeDoc.fromJson(Map<String, dynamic>.from(d)));
        }
      }
    }

    final List<KnowledgeChunk> chunks = <KnowledgeChunk>[];
    final File chunksFile = File('${_baseDir(id).path}/chunks.json');
    if (await chunksFile.exists()) {
      final dynamic data = jsonDecode(await chunksFile.readAsString());
      if (data is List) {
        for (final dynamic c in data) {
          if (c is Map) {
            chunks.add(KnowledgeChunk.fromJson(Map<String, dynamic>.from(c)));
          }
        }
      }
    }

    final int dim = (meta['dim'] as num?)?.toInt() ?? 0;
    final File vecFile = File('${_baseDir(id).path}/vectors.f32');
    if (dim > 0 && await vecFile.exists()) {
      final Uint8List bytes = await vecFile.readAsBytes();
      final int need = chunks.length * dim * 4;
      if (bytes.length >= need) {
        final ByteData bd = ByteData.sublistView(bytes);
        for (int i = 0; i < chunks.length; i++) {
          final List<double> v = List<double>.generate(
            dim,
            (int j) => bd.getFloat32((i * dim + j) * 4, Endian.little),
          );
          // 全 0 = 这一片没有向量（导入时向量化失败留下的空位）。
          // 不能当成"和任何问题都正交"的真实向量去算。
          chunks[i].vector = v.every((double x) => x == 0) ? null : v;
        }
      }
    }

    final KnowledgeBase b = KnowledgeBase(
      id: id,
      name: meta['name']?.toString() ?? entry['name']?.toString() ?? '知识库',
      createdAt:
          DateTime.tryParse(meta['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      docs: docs,
      chunks: chunks,
      dim: dim,
      embeddingModel: meta['embeddingModel']?.toString() ?? '',
    );
    return b;
  }

  Future<void> _saveIndex() async {
    await _root.create(recursive: true);
    await _indexFile.writeAsString(
      jsonEncode(
        bases
            .map(
              (KnowledgeBase b) => <String, dynamic>{
                'id': b.id,
                'name': b.name,
                'createdAt': b.createdAt.toIso8601String(),
              },
            )
            .toList(),
      ),
    );
  }

  Future<void> _saveBase(KnowledgeBase b) async {
    final Directory dir = _baseDir(b.id);
    await dir.create(recursive: true);

    // 只要**有一部分**向量，就把整张表写下来：没有向量的片段写 0 行。
    // 不能因为"这次有片段向量化失败"就把整个文件删掉 —— 那会把之前
    // 已经算好的向量一起丢掉，下次重启全库退回关键词。
    final bool hasAnyVector = b.chunks.any(
      (KnowledgeChunk c) => c.vector != null,
    );
    if (hasAnyVector && b.dim > 0) {
      final ByteData bd = ByteData(b.chunks.length * b.dim * 4);
      for (int i = 0; i < b.chunks.length; i++) {
        final List<double>? v = b.chunks[i].vector;
        if (v == null) continue; // 保持 0
        for (int j = 0; j < b.dim; j++) {
          bd.setFloat32(
            (i * b.dim + j) * 4,
            j < v.length ? v[j] : 0,
            Endian.little,
          );
        }
      }
      await File('${dir.path}/vectors.f32')
          .writeAsBytes(bd.buffer.asUint8List(), flush: true);
    } else {
      final File old = File('${dir.path}/vectors.f32');
      if (await old.exists()) await old.delete();
    }

    await File('${dir.path}/chunks.json').writeAsString(
      jsonEncode(b.chunks.map((KnowledgeChunk c) => c.toJson()).toList()),
    );
    await File('${dir.path}/meta.json').writeAsString(jsonEncode(b.toJson()));
    await _saveIndex();
  }

  // ------------------------------------------------------------------ CRUD

  Future<String?> createBase(String name) async {
    final String n = name.trim();
    if (n.isEmpty) return '名字不能为空';
    if (bases.any((KnowledgeBase b) => b.name.trim() == n)) {
      return '已经有同名知识库';
    }
    final KnowledgeBase b = KnowledgeBase(id: newId(), name: n);
    bases.add(b);
    await _saveBase(b);
    notifyListeners();
    return null;
  }

  Future<void> renameBase(KnowledgeBase b, String name) async {
    final String n = name.trim();
    if (n.isEmpty) return;
    b.name = n;
    await _saveBase(b);
    notifyListeners();
  }

  Future<void> removeBase(String id) async {
    bases.removeWhere((KnowledgeBase b) => b.id == id);
    try {
      final Directory dir = _baseDir(id);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    await _saveIndex();
    notifyListeners();
  }

  void _startJob(String label) {
    job = KnowledgeJob(label, 0);
    notifyListeners();
  }

  void _stepJob(double p, [String? label]) {
    job = KnowledgeJob(label ?? job?.label ?? '', p.clamp(0, 1));
    notifyListeners();
  }

  void _endJob() {
    job = null;
    notifyListeners();
  }

  // ------------------------------------------------------------------ 导入

  /// 导入一段文本。返回 null = 成功；否则是给用户看的警告/错误。
  Future<String?> importText(
    String baseId, {
    required String title,
    required String text,
    String source = '',
    String kind = '文本',
  }) async {
    final KnowledgeBase? b = byId(baseId);
    if (b == null) return '找不到这个知识库';
    if (text.trim().isEmpty) return '内容为空';

    final List<KnowledgeChunkDraft> drafts = chunkKnowledgeText(
      text,
      maxChars: 700,
      overlap: 120,
    );
    if (drafts.isEmpty) return '没有可切分的内容';

    _startJob('切分「$title」…');
    final KnowledgeDoc doc = KnowledgeDoc(
      id: newId(),
      title: title.trim().isEmpty ? '未命名文档' : title.trim(),
      source: source,
      kind: kind,
      chars: text.length,
      chunkCount: drafts.length,
    );

    final List<KnowledgeChunk> chunks = <KnowledgeChunk>[];
    for (int i = 0; i < drafts.length; i++) {
      chunks.add(
        KnowledgeChunk(
          id: newId(),
          docId: doc.id,
          index: i,
          heading: drafts[i].heading,
          text: drafts[i].text,
        ),
      );
    }

    String warning = '';
    if (vectorReady) {
      try {
        _stepJob(0.15, '向量化「$title」…');
        final List<List<double>> vectors = await embedder!.embed(
          drafts.map((KnowledgeChunkDraft d) => d.text).toList(),
        );
        if (vectors.length != chunks.length) {
          throw const FormatException('向量条数与切片数不一致');
        }
        final int dim = vectors.first.length;
        if (b.dim > 0 && b.dim != dim) {
          // 换了维度不同的模型：旧向量全部作废，整库需要重建
          for (final KnowledgeChunk c in b.chunks) {
            c.vector = null;
          }
          b.dim = 0;
        }
        b.dim = dim;
        b.embeddingModel = _settings?.embeddingModel.trim() ?? '';
        for (int i = 0; i < chunks.length; i++) {
          chunks[i].vector = vectors[i];
        }
        _stepJob(0.85, '写入索引…');
      } catch (e) {
        // 向量失败仍然保留文本：关键词检索可用，UI 会显示警告
        warning = '已入库，但向量化失败：$e';
        doc.error = warning;
      }
    }

    b.docs.add(doc);
    b.chunks.addAll(chunks);
    await _saveBase(b);
    _endJob();
    return warning.isEmpty ? null : warning;
  }

  /// 导入本地文件（自动解析格式）。
  Future<String?> importFile(String baseId, String path) async {
    final KnowledgeBase? b = byId(baseId);
    if (b == null) return '找不到这个知识库';
    _startJob('解析文档…');
    try {
      final ParsedDocument doc = await parseKnowledgeFile(path);
      if (doc.text.trim().isEmpty) {
        _endJob();
        return '没有解析出文字';
      }
      final String name = _uniqueTitle(b, doc.title);
      return await importText(
        baseId,
        title: name,
        text: doc.text,
        source: path,
        kind: doc.kind,
      );
    } catch (e) {
      _endJob();
      return '导入失败：$e';
    }
  }

  /// 导入一个网址的正文。
  Future<String?> importUrl(String baseId, String url) async {
    final KnowledgeBase? b = byId(baseId);
    if (b == null) return '找不到这个知识库';
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasAbsolutePath) return '网址不合法';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '只支持 http/https';
    }
    _startJob('抓取网页…');
    final http.Client client = http.Client();
    try {
      final http.Response resp = await client
          .get(
            uri,
            headers: <String, String>{
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14) Zeus',
            },
          )
          .timeout(const Duration(seconds: 45));
      if (resp.statusCode != 200) {
        _endJob();
        return '抓取失败：HTTP ${resp.statusCode}';
      }
      final String ct = (resp.headers['content-type'] ?? '').toLowerCase();
      final String raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final String text = ct.contains('html')
          ? htmlToPlainText(raw)
          : raw.trim();
      if (text.isEmpty) {
        _endJob();
        return '没有抓到正文';
      }
      final String name = _uniqueTitle(
        b,
        uri.host + (uri.path.isEmpty ? '' : uri.path),
      );
      return await importText(
        baseId,
        title: name,
        text: text,
        source: url,
        kind: '网页',
      );
    } catch (e) {
      _endJob();
      return '抓取失败：$e';
    } finally {
      client.close();
    }
  }

  static String _uniqueTitle(KnowledgeBase b, String raw) {
    String base = raw.trim();
    if (base.isEmpty) base = '未命名';
    if (base.length > 80) base = base.substring(0, 80);
    String title = base;
    int i = 2;
    while (b.docs.any((KnowledgeDoc d) => d.title == title)) {
      title = '$base ($i)';
      i++;
    }
    return title;
  }

  Future<void> removeDoc(String baseId, String docId) async {
    final KnowledgeBase? b = byId(baseId);
    if (b == null) return;
    b.docs.removeWhere((KnowledgeDoc d) => d.id == docId);
    b.chunks.removeWhere((KnowledgeChunk c) => c.docId == docId);
    if (b.chunks.isEmpty) {
      b.dim = 0;
      b.embeddingModel = '';
    }
    await _saveBase(b);
    notifyListeners();
  }

  /// 用当前 Embedding 模型重建整个库的向量。
  Future<String?> reindex(String baseId) async {
    final KnowledgeBase? b = byId(baseId);
    if (b == null) return '找不到这个知识库';
    if (!vectorReady) return '还没有配置 Embedding 模型（设置里填模型名）';
    if (b.chunks.isEmpty) return '这个库里还没有内容';
    _startJob('重建向量索引…');
    try {
      final List<List<double>> vectors = await embedder!.embed(
        b.chunks.map((KnowledgeChunk c) => c.text).toList(),
      );
      final int dim = vectors.first.length;
      b.dim = dim;
      b.embeddingModel = _settings?.embeddingModel.trim() ?? '';
      for (int i = 0; i < b.chunks.length; i++) {
        b.chunks[i].vector = vectors[i];
      }
      await _saveBase(b);
      _endJob();
      return null;
    } catch (e) {
      _endJob();
      return '重建失败：$e';
    }
  }

  // ------------------------------------------------------------------ 检索

  /// 从全部知识库（或指定库）里召回最相关的片段。
  Future<List<KnowledgeHit>> search({
    required String query,
    String? baseId,
    int? topK,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) return <KnowledgeHit>[];
    final int k = (topK ?? defaultTopK).clamp(1, 20);

    final KnowledgeBase? only = baseId == null ? null : byId(baseId);
    final List<KnowledgeBase> pool = only == null
        ? bases
        : <KnowledgeBase>[only];
    if (pool.isEmpty) return <KnowledgeHit>[];

    // ---- 词法分（BM25）----
    final List<String> qTokens = knowledgeTokens(q).toSet().toList();
    final List<_Candidate> candidates = <_Candidate>[];
    int totalTokens = 0;
    for (final KnowledgeBase b in pool) {
      for (final KnowledgeChunk c in b.chunks) {
        KnowledgeDoc? doc;
        for (final KnowledgeDoc d in b.docs) {
          if (d.id == c.docId) {
            doc = d;
            break;
          }
        }
        // 文档已被删但切片残留（异常中断）时跳过，不编一个假标题。
        if (doc == null) continue;
        final List<String> toks = knowledgeTokens(c.text);
        totalTokens += toks.length;
        candidates.add(_Candidate(b, doc, c, toks));
      }
    }
    if (candidates.isEmpty) return <KnowledgeHit>[];
    final double avgdl = totalTokens / candidates.length;

    final Map<String, int> df = <String, int>{};
    for (final String t in qTokens) {
      int n = 0;
      for (final _Candidate c in candidates) {
        if (c.tf.containsKey(t)) n++;
      }
      df[t] = n;
    }
    final int N = candidates.length;
    const double k1 = 1.4;
    const double bParam = 0.75;
    double maxLex = 0;
    for (final _Candidate c in candidates) {
      double score = 0;
      for (final String t in qTokens) {
        final int tf = c.tf[t] ?? 0;
        if (tf == 0) continue;
        final double idf = _idf(df[t] ?? 0, N);
        final double dl = c.tokens.length.toDouble();
        score +=
            idf *
            (tf * (k1 + 1)) /
            (tf + k1 * (1 - bParam + bParam * dl / (avgdl <= 0 ? 1 : avgdl)));
      }
      c.lexicalRaw = score;
      if (score > maxLex) maxLex = score;
    }
    for (final _Candidate c in candidates) {
      c.lexical = maxLex <= 0 ? 0 : c.lexicalRaw / maxLex;
    }

    // ---- 向量分 ----
    bool hasVectors = false;
    List<double>? qvec;
    if (vectorReady) {
      for (final _Candidate c in candidates) {
        if (c.chunk.vector != null) {
          hasVectors = true;
          break;
        }
      }
    }
    if (hasVectors) {
      try {
        final List<List<double>> v = await embedder!.embed(<String>[q]);
        qvec = v.first;
      } catch (_) {
        qvec = null; // 查询向量失败：退回词法检索，不让整次搜索失败
      }
    }
    for (final _Candidate c in candidates) {
      if (qvec != null && c.chunk.vector != null) {
        c.vectorScore = cosineSimilarity(qvec, c.chunk.vector!);
      }
      c.score = qvec != null && c.chunk.vector != null
          ? 0.72 * c.vectorScore.clamp(0.0, 1.0) + 0.28 * c.lexical
          : c.lexical;
    }

    candidates.sort((_Candidate a, _Candidate b) => b.score.compareTo(a.score));

    // ---- 可选精排 ----
    final KnowledgeReranker? rr = reranker;
    if (rr != null && rr.available && candidates.length > 1) {
      final int take = (k * 3).clamp(k, candidates.length);
      final List<_Candidate> head = candidates.sublist(0, take);
      final Map<int, double>? ranked = await rr.rerank(
        q,
        head.map((_Candidate c) => c.chunk.text).toList(),
        topN: k,
      );
      if (ranked != null) {
        for (int i = 0; i < head.length; i++) {
          final double? s = ranked[i];
          if (s != null) head[i].rerank = s;
        }
        head.sort((_Candidate a, _Candidate b) {
          final bool hasA = a.rerank != null;
          final bool hasB = b.rerank != null;
          if (hasA != hasB) return hasA ? -1 : 1;
          if (hasA && hasB) return b.rerank!.compareTo(a.rerank!);
          return b.score.compareTo(a.score);
        });
        candidates
          ..removeRange(0, take)
          ..insertAll(0, head);
      }
    }

    return candidates
        .take(k)
        .map(
          (_Candidate c) => KnowledgeHit(
            base: c.base,
            chunk: c.chunk,
            doc: c.doc,
            score: c.rerank ?? c.score,
            vectorScore: c.vectorScore,
            lexicalScore: c.lexical,
          ),
        )
        .toList();
  }

  /// BM25 的 idf（+0.5 平滑）。
  static double _idf(int df, int n) =>
      math.log(1 + (n - df + 0.5) / (df + 0.5));
}

class _Candidate {
  _Candidate(this.base, this.doc, this.chunk, this.tokens) {
    for (final String t in tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
  }

  final KnowledgeBase base;
  final KnowledgeDoc doc;
  final KnowledgeChunk chunk;
  final List<String> tokens;
  final Map<String, int> tf = <String, int>{};

  double lexicalRaw = 0;
  double lexical = 0;
  double vectorScore = 0;
  double score = 0;
  double? rerank;
}
