import '../core/models.dart';
import '../knowledge/knowledge_store.dart';
import 'tool.dart';

/// 让 agent 检索用户自己的知识库（真 RAG：切片 + 向量 + 可选精排）。
///
/// ## 为什么是"先搜再答"，而不是把整库塞进上下文
///
/// 全量塞进去会把上下文吃光、也会把不相关的段落一起带进来；
/// 这里每次只召回 Top-K 片段，并带出处，模型据此回答。
/// 检索质量不够时它会如实说"没找到"，而不是编。
class KnowledgeTool extends AgentTool {
  const KnowledgeTool();

  @override
  String get name => 'knowledge';

  @override
  String get title => '知识库';

  @override
  String get description =>
      '知识库：检索用户导入的资料，也能**新增 / 删除**内容。\n'
      '\n'
      '**查询**：用户问"我的资料 / 之前导入的文档 / 知识库里…"时，'
      '先 `search`，再根据返回片段回答；用【1】【2】标注来源，'
      '片段里没有的信息就直说没有，不要凭印象补。\n'
      '`list` 看有哪些库、每个库多少文档与片段。`kb` 填库名或 id，不填搜全部。\n'
      '\n'
      '**写入**（用户明确要求"把这段存进知识库 / 新建一个库 / 删掉那篇"时）：\n'
      '· `create_base`：新建一个空库，参数 `name`。\n'
      '· `add_text`：往库里加一段文本，参数 `kb` + `title` + `text`'
      '（`source` 可选，写清出处）。会自己切分和向量化。\n'
      '· `add_url`：抓一个网页并存入，参数 `kb` + `url`。\n'
      '· `delete_doc`：删掉一篇文档，参数 `kb` + `doc`（标题或 id）。\n'
      '· `delete_base`：删掉整个库（连同里面所有文档），参数 `kb`。\n'
      '· `reindex`：库换了 Embedding 模型后重建向量。\n'
      '\n'
      '**规矩**：`text` 用用户给的原文，不要改写、不要总结后再存；'
      '删除是不可恢复的，调用前一句话说清"要删哪个库里的哪篇"。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'list',
          'search',
          'create_base',
          'add_text',
          'add_url',
          'delete_doc',
          'delete_base',
          'reindex',
        ],
      },
      'query': <String, dynamic>{
        'type': 'string',
        'description': 'search 时的问题或关键词',
      },
      'kb': <String, dynamic>{
        'type': 'string',
        'description': '知识库名字或 id；search 时不填搜全部',
      },
      'top_k': <String, dynamic>{
        'type': 'integer',
        'description': '可选：返回几个片段（默认取设置里的值，最大 20）',
      },
      'name': <String, dynamic>{
        'type': 'string',
        'description': 'create_base 时的库名',
      },
      'title': <String, dynamic>{
        'type': 'string',
        'description': 'add_text 时的文档标题（一句话概括这段是什么）',
      },
      'text': <String, dynamic>{
        'type': 'string',
        'description': 'add_text 时要存入的正文（原文，不要自行改写）',
      },
      'source': <String, dynamic>{
        'type': 'string',
        'description': '可选：出处（网址、文件名、谁说的）',
      },
      'url': <String, dynamic>{
        'type': 'string',
        'description': 'add_url 时要抓取并存入的网址',
      },
      'doc': <String, dynamic>{
        'type': 'string',
        'description': 'delete_doc 时删哪一篇（文档标题或 id）',
      },
    },
    'required': <String>['action'],
  };

  /// 风险分级：**查是 safe，写是 caution，删是 dangerous**。
  ///
  /// 写入本身不毁东西（只是多了几段资料），但它改的是用户的私有资料库，
  /// 值得让用户点一下；删除不可恢复，必须落到 dangerous —— 确认框的默认
  /// 按钮在那一档是「拒绝」。
  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    switch (args.str('action')) {
      case 'delete_doc':
      case 'delete_base':
        return RiskAssessment(RiskLevel.dangerous, <String>[
          '删除知识库内容不可恢复',
        ]);
      case 'create_base':
      case 'add_text':
      case 'add_url':
      case 'reindex':
        return const RiskAssessment(RiskLevel.caution, <String>[]);
      default:
        return const RiskAssessment(RiskLevel.safe, <String>[]);
    }
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String kb = args.str('kb').trim();
    switch (args.str('action')) {
      case 'list':
        return '查看知识库';
      case 'create_base':
        return '新建知识库：${args.str('name')}';
      case 'add_text':
        return '存入知识库${kb.isEmpty ? '' : '「$kb」'}：${args.str('title')}';
      case 'add_url':
        return '抓取网页存入知识库：${args.str('url')}';
      case 'delete_doc':
        return '删除文档${kb.isEmpty ? '' : '「$kb」'}：${args.str('doc')}';
      case 'delete_base':
        return '删除整个知识库$kb';
      case 'reindex':
        return '重建向量${kb.isEmpty ? '' : '：$kb'}';
      default:
        return '检索知识库：${args.str('query')}';
    }
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final KnowledgeStore? store = KnowledgeStore.maybeInstance;
    if (store == null) return '知识库还没有初始化。';

    final String action = args.str('action');
    if (action == 'list') {
      if (store.bases.isEmpty) {
        return '（还没有知识库。可以在 设置 → 数据与扩展 → 知识库 里新建并导入文档）';
      }
      final StringBuffer sb = StringBuffer();
      sb.writeln('共 ${store.bases.length} 个知识库：');
      for (final KnowledgeBase b in store.bases) {
        sb.writeln(
          '- 「${b.name}」：${b.docs.length} 篇 · ${b.chunks.length} 个片段'
          '${b.dim > 0 ? ' · 向量 ${b.dim} 维' : ' · 关键词检索'}',
        );
      }
      sb.writeln(
        store.vectorReady
            ? '（检索时会先向量召回，再按混合分排序）'
            : '（未配置 Embedding 模型，当前按关键词 BM25 检索）',
      );
      return clampOutput(sb.toString(), max: 4000);
    }

    if (action != 'search') {
      // ---- 写入类动作 ----
      //
      // 集中在这里而不是散在下面：查询和写入是两条完全不同的路径，
      // 混在一起读代码时要来回跳。`search` 的正文很长（拼来源、片段），
      // 挪到后面单独一段。
      final String? written = await _runWrite(store, action, args);
      if (written != null) return written;
      if (action != 'search') {
        return '错误：未知 action「$action」';
      }
    }

    final String query = args.str('query').trim();
    if (query.isEmpty) return '错误：search 需要 query';

    final KnowledgeBase? kb = store.resolve(args.str('kb'));
    if (args.str('kb').trim().isNotEmpty && kb == null) {
      return '找不到知识库「${args.str('kb')}」。可以先用 action=list 看看有哪些。';
    }

    final List<KnowledgeHit> hits = await store.search(
      query: query,
      baseId: kb?.id,
      topK: args.intVal('top_k', fallback: 0) > 0
          ? args.intVal('top_k').clamp(1, 20)
          : null,
    );

    if (hits.isEmpty) {
      return '没有在知识库里找到和「$query」相关的片段。\n'
          '（可以换个说法，或先用 action=list 确认库里有哪些文档；'
          '如果确实没有，就直接告诉用户没有这份资料，不要编。）';
    }

    final StringBuffer sb = StringBuffer();
    sb.writeln('知识库检索结果（共 ${hits.length} 条，按相关度排序）：');
    if (!store.vectorReady) {
      sb.writeln('注意：当前未配置 Embedding 模型，以下是关键词检索结果。');
    }
    sb.writeln();
    for (int i = 0; i < hits.length; i++) {
      final KnowledgeHit h = hits[i];
      final String heading = h.chunk.heading.trim();
      sb.writeln(
        '【${i + 1}】《${h.doc.title}》'
        '${heading.isEmpty ? '' : ' · $heading'}'
        ' · 片段 ${h.chunk.index + 1}'
        ' · 相关度 ${h.score.toStringAsFixed(2)}',
      );
      if (h.doc.source.trim().isNotEmpty) {
        sb.writeln('来源：${h.doc.source}');
      }
      sb.writeln(h.chunk.text.trim());
      sb.writeln();
    }
    sb.writeln('回答时请用【1】【2】标注来源；片段没有覆盖的信息不要补。');
    return clampOutput(sb.toString(), max: 10000);
  }

  /// 写入类动作。返回 null = 这个 action 不是写入，交给调用方继续处理。
  ///
  /// 每个分支都把 `KnowledgeStore` 的返回值（`String?`，null 表示成功）
  /// 翻译成**模型能看懂的结果**：成功就说清"存到哪、切了几段"，
  /// 失败就说清"缺了什么"，而不是把 null 当成功、把异常串丢回去。
  Future<String?> _runWrite(
    KnowledgeStore store,
    String action,
    Map<String, dynamic> args,
  ) async {
    switch (action) {
      case 'create_base':
        final String name = args.str('name').trim();
        if (name.isEmpty) return '错误：create_base 需要 name（库名）。';
        final String? err = await store.createBase(name);
        if (err != null) {
          return '新建失败：$err\n'
              '（同名库已存在的话，直接往那个库里 add_text 就行，不要建重名的。）';
        }
        return '已新建知识库「$name」。接下来用 add_text / add_url 往里加内容。';

      case 'add_text':
        final KnowledgeBase? b = _requireBase(store, args);
        if (b == null) return _baseError(store, args.str('kb'));
        final String title = args.str('title').trim();
        final String text = args.str('text');
        if (title.isEmpty) return '错误：add_text 需要 title（一句话说明这段是什么）。';
        if (text.trim().isEmpty) return '错误：add_text 的 text 是空的。';
        // 单次导入上限：这不是知识库的限制，是**一次工具调用**的合理量。
        // 再长应该分批（或让用户用"导入文件"），否则切分和向量化会占用
        // 很久，用户看到的是"一直转圈"。
        if (text.length > 200000) {
          return '这段文本有 ${text.length} 字符，一次存太多了。'
              '请说明需要分批（每次 20 万字符以内），或者让用户在'
              '「设置 → 数据与扩展 → 知识库」里直接导入这个文件。';
        }
        final String? err = await store.importText(
          b.id,
          title: title,
          text: text,
          source: args.str('source').trim(),
        );
        if (err != null) return '存入失败：$err';
        final KnowledgeDoc? doc = b.docs.isEmpty ? null : b.docs.last;
        return '已存入「${b.name}」：$title'
            '${doc == null ? '' : '（${doc.chars} 字 · ${doc.chunkCount} 个片段）'}'
            '${doc != null && doc.error.isNotEmpty ? '\n注意：${doc.error}' : ''}';

      case 'add_url':
        final KnowledgeBase? b = _requireBase(store, args);
        if (b == null) return _baseError(store, args.str('kb'));
        final String url = args.str('url').trim();
        if (url.isEmpty) return '错误：add_url 需要 url。';
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          return '错误：url 要以 http:// 或 https:// 开头。';
        }
        final String? err = await store.importUrl(b.id, url);
        if (err != null) return '抓取失败：$err';
        return '已抓取并存入「${b.name}」：$url';

      case 'delete_doc':
        final KnowledgeBase? b = _requireBase(store, args);
        if (b == null) return _baseError(store, args.str('kb'));
        final String want = args.str('doc').trim();
        if (want.isEmpty) return '错误：delete_doc 需要 doc（文档标题或 id）。';
        // 标题匹配做成"先精确、再包含"，因为用户嘴里说的是标题，
        // 而界面里可能存在同名/近名文档 —— 包含匹配只取第一个，
        // 并且明确告诉模型删的是哪一篇，它才好向用户复述。
        KnowledgeDoc? target;
        for (final KnowledgeDoc d in b.docs) {
          if (d.id == want) {
            target = d;
            break;
          }
        }
        if (target == null) {
          for (final KnowledgeDoc d in b.docs) {
            if (d.title.trim() == want) {
              target = d;
              break;
            }
          }
        }
        if (target == null) {
          final List<KnowledgeDoc> fuzzy = b.docs
              .where((KnowledgeDoc d) => d.title.contains(want))
              .toList();
          if (fuzzy.length == 1) {
            target = fuzzy.first;
          } else if (fuzzy.length > 1) {
            return '「$want」匹配到 ${fuzzy.length} 篇：'
                '${fuzzy.map((KnowledgeDoc d) => '《${d.title}》').join('、')}。\n'
                '请用完整的标题或 id 再调用一次。';
          }
        }
        if (target == null) {
          return '「${b.name}」里没有文档「$want」。'
              '可以先用 action=list 或让用户确认标题。';
        }
        await store.removeDoc(b.id, target.id);
        return '已从「${b.name}」删除《${target.title}》（${target.chunkCount} 个片段）。';

      case 'delete_base':
        final KnowledgeBase? b = _requireBase(store, args);
        if (b == null) return _baseError(store, args.str('kb'));
        // 删库要报清代价：这里删的是文档 + 向量，不可恢复。
        final int docs = b.docs.length;
        final int chunks = b.chunks.length;
        await store.removeBase(b.id);
        return '已删除知识库「${b.name}」（$docs 篇文档、$chunks 个片段）。';

      case 'reindex':
        final KnowledgeBase? b = _requireBase(store, args);
        if (b == null) return _baseError(store, args.str('kb'));
        final String? err = await store.reindex(b.id);
        if (err != null) return '重建失败：$err';
        return '已重建「${b.name}」的向量索引（${b.chunks.length} 个片段，'
            '${b.dim} 维）。';

      default:
        return null;
    }
  }

  /// 写入类动作都要指定库；只有一个库时可以省略 `kb`。
  ///
  /// 这是刻意的宽容：用户说"存到知识库"时，几乎总是"那个唯一的库"。
  /// 让模型因为没传 kb 而失败一次，等于白烧一次调用。
  KnowledgeBase? _requireBase(KnowledgeStore store, Map<String, dynamic> args) {
    final String q = args.str('kb').trim();
    if (q.isEmpty) {
      return store.bases.length == 1 ? store.bases.first : null;
    }
    return store.resolve(q);
  }

  String _baseError(KnowledgeStore store, String raw) {
    final String q = raw.trim();
    if (q.isEmpty && store.bases.length > 1) {
      return '有多个知识库，需要指定 kb。现有：'
          '${store.bases.map((KnowledgeBase b) => '「${b.name}」').join('、')}';
    }
    if (store.bases.isEmpty) {
      return '还没有任何知识库。先用 create_base 建一个。';
    }
    return '找不到知识库「$q」。现有：'
        '${store.bases.map((KnowledgeBase b) => '「${b.name}」').join('、')}';
  }
}
