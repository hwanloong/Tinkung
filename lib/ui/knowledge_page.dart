import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/store.dart';
import '../knowledge/knowledge_embedder.dart';
import '../knowledge/knowledge_store.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// 知识库：真 RAG 的入口。
///
/// 一页是"库列表"，点进去是"文档 + 检索测试 + 索引状态"。
/// 这里不做导入向导：拖一批文件进来、能搜到，就是全部。
class KnowledgePage extends StatefulWidget {
  const KnowledgePage({super.key, required this.settings});

  final Settings settings;

  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  KnowledgeStore get _store => KnowledgeStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final TextEditingController c = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('新建知识库'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名字',
            hintText: '例如：产品文档',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    final String? err = await _store.createBase(name);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final KnowledgeBase? b = _store.byName(name);
    if (b == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) =>
            KnowledgeBasePage(settings: widget.settings, baseId: b.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<KnowledgeBase> bases = _store.bases;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '知识库',
            subtitle: bases.isEmpty
                ? '真 RAG：切片、向量、检索、出处'
                : '${bases.length} 个 · '
                      '${bases.fold<int>(0, (int n, KnowledgeBase b) => n + b.chunks.length)} 个片段',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.add_rounded, size: 22),
                tooltip: '新建知识库',
                color: s.text,
                onPressed: _add,
              ),
            ],
          ),
          if (_store.job != null) _jobBar(s, _store.job!),
          Expanded(
            child: bases.isEmpty
                ? const EmptyHint(
                    icon: Icons.menu_book_outlined,
                    title: '还没有知识库',
                    desc:
                        '把文档、网页或截图导入进来，它会先切片、再向量化入库。\n'
                        '之后提问时只召回最相关的片段，答案带出处 —— 不是把整篇塞进上下文。\n\n'
                        '点右上角新建，然后导入文件。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
                    itemCount: bases.length,
                    itemBuilder: (BuildContext _, int i) => _tile(s, bases[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(AppSurface s, KnowledgeBase b) {
    final bool vec = b.dim > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext _) =>
                KnowledgeBasePage(settings: widget.settings, baseId: b.id),
          ),
        ),
        child: Row(
          children: <Widget>[
            // 和笔记文件夹、工作空间文件行共用的 34×34 图标块。
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.code),
              ),
              child: Icon(
                Icons.menu_book_outlined,
                size: 18,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.body(
                            size: 14,
                            weight: FontWeight.w600,
                            color: s.text,
                            height: 1.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _chip(s, vec ? '向量' : '关键词', accent: vec),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${b.docs.length} 篇 · ${b.chunks.length} 个片段'
                    '${b.chars > 0 ? ' · ${_human(b.chars)} 字' : ''}',
                    style: AppFonts.body(size: 12.5, color: s.muted),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: s.muted.withValues(alpha: 0.8),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个知识库：文档、检索测试、索引状态。
class KnowledgeBasePage extends StatefulWidget {
  const KnowledgeBasePage({
    super.key,
    required this.settings,
    required this.baseId,
  });

  final Settings settings;
  final String baseId;

  @override
  State<KnowledgeBasePage> createState() => _KnowledgeBasePageState();
}

class _KnowledgeBasePageState extends State<KnowledgeBasePage> {
  KnowledgeStore get _store => KnowledgeStore.instance;

  final TextEditingController _query = TextEditingController();
  List<KnowledgeHit> _hits = <KnowledgeHit>[];
  bool _searching = false;
  String? _searchError;

  KnowledgeBase? get _base => _store.byId(widget.baseId);

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    _query.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    if (_base == null) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------------ 导入

  Future<void> _importFiles() async {
    final KnowledgeBase? b = _base;
    if (b == null) return;
    const XTypeGroup group = XTypeGroup(
      label: '文档',
      extensions: <String>[
        'pdf',
        'docx',
        'xlsx',
        'csv',
        'tsv',
        'txt',
        'md',
        'markdown',
        'html',
        'htm',
        'json',
        'png',
        'jpg',
        'jpeg',
        'webp',
      ],
    );
    final List<XFile> files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[group],
    );
    if (files.isEmpty || !mounted) return;

    final List<String> warnings = <String>[];
    int ok = 0;
    for (final XFile f in files) {
      final int before = _store.byId(b.id)?.docs.length ?? 0;
      final String? warn = await _store.importFile(b.id, f.path);
      final int after = _store.byId(b.id)?.docs.length ?? 0;
      if (after > before) {
        // 入库成功；warning 可能只是"向量化失败，文本仍可关键词检索"
        ok++;
        if (warn != null) warnings.add('${f.name}：$warn');
      } else {
        warnings.add('${f.name}：${warn ?? '导入失败'}');
      }
      if (!mounted) return;
    }
    if (!mounted) return;
    setState(() {});
    _snack(
      warnings.isEmpty ? '已导入 $ok 个文件' : '已导入 $ok 个；${warnings.join('\n')}',
    );
  }

  Future<void> _importUrl() async {
    final KnowledgeBase? b = _base;
    if (b == null) return;
    final TextEditingController c = TextEditingController();
    final String? url = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('从网址导入'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '网页地址',
            hintText: 'https://example.com/article',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(c.text.trim()),
            child: const Text('抓取'),
          ),
        ],
      ),
    );
    c.dispose();
    if (url == null || url.isEmpty || !mounted) return;
    final String? warn = await _store.importUrl(b.id, url);
    if (!mounted) return;
    setState(() {});
    _snack(warn ?? '已导入网页');
  }

  // ------------------------------------------------------------------ 操作

  Future<void> _reindex() async {
    final KnowledgeBase? b = _base;
    if (b == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重建向量索引？'),
        content: Text(
          '会用当前的 Embedding 模型把 ${b.chunks.length} 个片段重新向量化。\n'
          '这一步会按片段数消耗 Embedding 额度。',
          style: AppFonts.body(size: 14, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重建'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final String? err = await _store.reindex(b.id);
    if (!mounted) return;
    _snack(err ?? '向量索引已重建');
  }

  Future<void> _deleteDoc(KnowledgeDoc d) async {
    final KnowledgeBase? b = _base;
    if (b == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这篇文档？'),
        content: Text(
          '《${d.title}》的 ${d.chunkCount} 个片段会从索引里移除。',
          style: AppFonts.body(size: 14, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.removeDoc(b.id, d.id);
    if (mounted) setState(() {});
  }

  Future<void> _deleteBase() async {
    final KnowledgeBase? b = _base;
    if (b == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除整个知识库？'),
        content: Text(
          '「${b.name}」的 ${b.docs.length} 篇文档和向量索引都会被删除，无法恢复。',
          style: AppFonts.body(size: 14, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 删除后 store 会通知；`_onChange` 发现库不存在会自己退回上一页。
    await _store.removeBase(b.id);
  }

  Future<void> _search() async {
    final KnowledgeBase? b = _base;
    final String q = _query.text.trim();
    if (b == null || q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final List<KnowledgeHit> hits = await _store.search(
        query: q,
        baseId: b.id,
      );
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = '$e';
      });
    }
  }

  // ------------------------------------------------------------------ 视图

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final KnowledgeBase? b = _base;
    if (b == null) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: b.name,
            subtitle: '${b.docs.length} 篇 · ${b.chunks.length} 个片段',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            // 三颗图标按钮和 AppHeader 里 `leading` 的返回键同规格（22），
            // 不再套一层玻璃圆片：浮动圆片在平面顶栏上会变成三个深浅不一的
            // 实心点，和左边那颗返回键也不成套。
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.note_add_outlined, size: 22),
                tooltip: '导入文件',
                color: s.text,
                onPressed: _store.job == null ? _importFiles : null,
              ),
              IconButton(
                icon: const Icon(Icons.link_rounded, size: 22),
                tooltip: '从网址导入',
                color: s.text,
                onPressed: _store.job == null ? _importUrl : null,
              ),
              IconButton(
                icon: const Icon(Icons.tune_rounded, size: 22),
                tooltip: '检索设置',
                color: s.text,
                onPressed: () => showKnowledgeSettings(context, widget.settings),
              ),
            ],
          ),
          if (_store.job != null) _jobBar(s, _store.job!),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
              children: <Widget>[
                _statusCard(s, b),
                const SizedBox(height: 14),
                _searchCard(s, b),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    Text(
                      '文档 ${b.docs.length}',
                      style: AppFonts.body(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: s.muted,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      b.dim > 0 ? '向量 ${b.dim} 维' : '未向量化',
                      style: AppFonts.body(size: 11.5, color: s.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (b.docs.isEmpty)
                  // 这一块在页面中段而不是整页空态（上面还有状态卡和检索框），
                  // 所以用一条轻提示，不套整张卡片 —— 卡片会让人以为
                  // "这里本来就该有一份文档列表，只是加载失败了"。
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: s.chipBg.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(AppRadius.code),
                    ),
                    child: Text(
                      '还没有文档。点右上角的「导入文件」或「从网址导入」。\n'
                      '支持 PDF / Word / Excel / CSV / Markdown / 网页 / 图片 OCR。',
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.6,
                      ),
                    ),
                  )
                else
                  ...b.docs.map((KnowledgeDoc d) => _docTile(s, d)),
                const SizedBox(height: 20),
                Center(
                  child: TextButton(
                    onPressed: _deleteBase,
                    child: Text(
                      '删除这个知识库',
                      style: AppFonts.body(size: 13, color: AppColors.danger),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(AppSurface s, KnowledgeBase b) {
    final bool ready = _store.vectorReady;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                ready ? Icons.hub_outlined : Icons.manage_search_rounded,
                size: 17,
                color: ready ? AppColors.accent : AppColors.warning,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  ready ? '向量检索已启用' : '关键词检索模式',
                  style: AppFonts.body(
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: s.text,
                  ),
                ),
              ),
              _chip(s, ready ? 'RAG' : 'BM25', accent: ready),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            ready
                ? '切片 → Embedding → 向量召回 → 可选精排。'
                      '${b.dim > 0 ? '当前索引 ${b.dim} 维。' : '导入第一篇文档时建立索引。'}'
                : '没有配置 Embedding 模型，仍然能按关键词检索；'
                      '配置后点「重建向量化」，命中会更准。',
            style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              TextButton(
                onPressed: () =>
                    showKnowledgeSettings(context, widget.settings),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(
                  ready ? '检索设置' : '配置向量模型',
                  style: AppFonts.body(size: 12.5, color: AppColors.accent),
                ),
              ),
              if (b.chunks.isNotEmpty) ...<Widget>[
                const SizedBox(width: 4),
                TextButton(
                  onPressed: _store.job == null ? _reindex : null,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    '重建向量化',
                    style: AppFonts.body(
                      size: 12.5,
                      color: ready ? AppColors.accent : s.muted,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (b.embeddingModel.isNotEmpty)
                Flexible(
                  child: Text(
                    b.embeddingModel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.code(size: 10.5, color: s.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _searchCard(AppSurface s, KnowledgeBase b) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '检索测试',
            style: AppFonts.body(
              size: 12.5,
              weight: FontWeight.w600,
              color: s.muted,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  style: AppFonts.body(size: 13.5, color: s.text),
                  // 三态边框都显式给同一份圆角和描边：只写 `border` 时，
                  // 聚焦态会被主题换成默认 radius，输入时框会"跳"一下。
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '问一个库里应该有的问题',
                    hintStyle: AppFonts.body(size: 12.5, color: s.muted),
                    filled: true,
                    fillColor: s.codeBg.withValues(alpha: 0.6),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                      borderSide: BorderSide(color: s.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                      borderSide: BorderSide(color: s.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.field),
                      borderSide: BorderSide(
                        color: AppColors.accent,
                        width: 1.2,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _searching ? null : _search,
                child: _searching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('检索'),
              ),
            ],
          ),
          if (_searchError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _searchError!,
              style: AppFonts.body(
                size: 12,
                color: AppColors.danger,
                height: 1.4,
              ),
            ),
          ],
          if (_hits.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            for (int i = 0; i < _hits.length; i++) _hitTile(s, _hits[i], i + 1),
          ],
        ],
      ),
    );
  }

  Widget _hitTile(AppSurface s, KnowledgeHit h, int n) {
    final String heading = h.chunk.heading.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: s.chipBg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '【$n】',
                style: AppFonts.body(
                  size: 11.5,
                  weight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
              Expanded(
                child: Text(
                  '《${h.doc.title}》${heading.isEmpty ? '' : ' · $heading'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12,
                    weight: FontWeight.w600,
                    color: s.text,
                  ),
                ),
              ),
              Text(
                h.score.toStringAsFixed(2),
                style: AppFonts.code(size: 11, color: s.muted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            h.chunk.text.length > 240
                ? h.chunk.text.substring(0, 240)
                : h.chunk.text,
            style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _docTile(AppSurface s, KnowledgeDoc d) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(13, 10, 6, 10),
        child: Row(
          children: <Widget>[
            Icon(
              d.error.isEmpty
                  ? Icons.description_outlined
                  : Icons.warning_amber_rounded,
              size: 17,
              color: d.error.isEmpty ? s.muted : AppColors.warning,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    d.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 14.5,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${d.kind} · ${d.chunkCount} 个片段 · ${_human(d.chars)} 字'
                    '${d.error.isEmpty ? '' : ' · ${d.error}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 12.5,
                      color: d.error.isEmpty ? s.muted : AppColors.warning,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 16),
              tooltip: '删除这篇文档',
              color: s.muted,
              visualDensity: VisualDensity.compact,
              onPressed: () => _deleteDoc(d),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 设置

/// 打开检索设置（Embedding / Rerank / Top-K）。
Future<void> showKnowledgeSettings(
  BuildContext context,
  Settings settings,
) async {
  final TextEditingController embModel = TextEditingController(
    text: settings.embeddingModel,
  );
  final TextEditingController embUrl = TextEditingController(
    text: settings.embeddingBaseUrl,
  );
  final TextEditingController embKey = TextEditingController(
    text: settings.embeddingApiKey,
  );
  final TextEditingController rrModel = TextEditingController(
    text: settings.rerankModel,
  );
  final TextEditingController rrUrl = TextEditingController(
    text: settings.rerankBaseUrl,
  );
  final TextEditingController rrKey = TextEditingController(
    text: settings.rerankApiKey,
  );
  double topK = settings.ragTopK.toDouble();
  String test = '';
  bool testing = false;

  await showDialog<void>(
    context: context,
    builder: (BuildContext ctx) {
      return StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setState) {
          Future<void> runTest() async {
            setState(() {
              testing = true;
              test = '';
            });
            try {
              // 用**当前输入框里的值**试，不用先保存。
              final KnowledgeEmbedder e = ApiKnowledgeEmbedder(
                baseUrl: embUrl.text.trim().isEmpty
                    ? settings.baseUrl
                    : embUrl.text.trim(),
                apiKey: embKey.text.trim().isEmpty
                    ? settings.apiKey
                    : embKey.text.trim(),
                model: embModel.text.trim(),
              );
              if (!e.available) {
                throw StateError('还没有配置 Embedding 模型 / Key');
              }
              final List<List<double>> v = await e.embed(<String>['这是一次检索测试']);
              setState(() {
                test = '成功：返回 ${v.first.length} 维向量';
                testing = false;
              });
            } catch (err) {
              setState(() {
                test = '失败：$err';
                testing = false;
              });
            }
          }

          final AppSurface s = AppSurface.of(ctx);
          return AlertDialog(
            title: const Text('检索设置'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _label(s, '向量模型（留空 = 关键词检索）'),
                    TextField(
                      controller: embModel,
                      decoration: const InputDecoration(
                        hintText: 'text-embedding-3-small / bge-m3 ',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: embUrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '向量接口地址（可选）',
                        hintText: '留空复用当前模型地址',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: embKey,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '向量 API Key（可选）',
                        hintText: '留空复用当前模型 Key',
                      ),
                    ),
                    const SizedBox(height: 14),
                    _label(s, '精排模型（可选）'),
                    TextField(
                      controller: rrModel,
                      decoration: const InputDecoration(
                        hintText: 'bge-reranker-v2-m3 / jina-reranker ',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: rrUrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '精排接口地址（可选）',
                        hintText: '留空复用向量地址',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: rrKey,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '精排 API Key（可选）',
                        hintText: '留空复用向量 Key',
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        Text(
                          '默认召回片段数',
                          style: AppFonts.body(size: 12.5, color: s.text),
                        ),
                        const Spacer(),
                        Text(
                          '${topK.round()}',
                          style: AppFonts.code(
                            size: 12,
                            color: AppColors.accent,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: topK,
                      min: 2,
                      max: 12,
                      divisions: 10,
                      label: '${topK.round()}',
                      onChanged: (double v) => setState(() => topK = v),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        TextButton(
                          onPressed: testing ? null : runTest,
                          child: Text(testing ? '测试中' : '测试 Embedding'),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            test,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(
                              size: 11.5,
                              color: test.startsWith('失败')
                                  ? AppColors.danger
                                  : s.muted,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () async {
                  await settings.update(() {
                    settings.embeddingModel = embModel.text.trim();
                    settings.embeddingBaseUrl = embUrl.text.trim();
                    settings.embeddingApiKey = embKey.text.trim();
                    settings.rerankModel = rrModel.text.trim();
                    settings.rerankBaseUrl = rrUrl.text.trim();
                    settings.rerankApiKey = rrKey.text.trim();
                    settings.ragTopK = topK.round();
                  });
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
  embModel.dispose();
  embUrl.dispose();
  embKey.dispose();
  rrModel.dispose();
  rrUrl.dispose();
  rrKey.dispose();
}

Widget _label(AppSurface s, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    text,
    style: AppFonts.body(size: 12.5, weight: FontWeight.w600, color: s.muted),
  ),
);

Widget _jobBar(AppSurface s, KnowledgeJob job) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(job.label, style: AppFonts.body(size: 11.5, color: s.muted)),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: job.progress <= 0 ? null : job.progress,
          minHeight: 2,
          color: AppColors.accent,
        ),
      ],
    ),
  );
}

Widget _chip(AppSurface s, String text, {bool accent = false}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: accent ? AppColors.accent.withValues(alpha: 0.12) : s.chipBg,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      border: Border.all(
        color: accent ? AppColors.accent.withValues(alpha: 0.3) : s.border,
        width: 0.8,
      ),
    ),
    child: Text(
      text,
      style: AppFonts.body(
        size: 10,
        weight: FontWeight.w600,
        color: accent ? AppColors.accent : s.muted,
        height: 1.2,
      ),
    ),
  );
}

String _human(int n) {
  if (n < 1000) return '$n';
  if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 1000).round()}k';
}
