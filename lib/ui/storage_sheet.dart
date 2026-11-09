import 'package:flutter/material.dart';

import '../core/platform_files.dart';
import '../core/storage.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'widgets.dart';

Future<void> showStorageSheet(
  BuildContext context, {
  required String workDir,
  VoidCallback? onCleared,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext ctx) =>
        _StorageSheet(workDir: workDir, onCleared: onCleared),
  );
}

/// 「文件清单」—— 工作目录里逐个文件勾选、批量删除。
///
/// 为什么另开一层，而不是把文件直接铺在存储页里：
/// 工作目录里动辄几百个文件，全塞进那屏会把存储页拉得又长又卡
/// （存储页那个 ListView 是一次性建全部子节点的）。独立一层能拿到整屏高度，
/// 列表也能按需构建（ListView.builder），几百行照样顺。
Future<void> showFileListSheet(
  BuildContext context, {
  required String workDir,
  VoidCallback? onCleared,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext ctx) =>
        _FileListSheet(workDir: workDir, onCleared: onCleared),
  );
}

class _StorageSheet extends StatefulWidget {
  const _StorageSheet({required this.workDir, this.onCleared});

  final String workDir;
  final VoidCallback? onCleared;

  @override
  State<_StorageSheet> createState() => _StorageSheetState();
}

class _StorageSheetState extends State<_StorageSheet> {
  StorageReport? _report;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final StorageReport r = await StorageManager.scan(widget.workDir);
    if (mounted) setState(() => _report = r);
  }

  /// 进文件清单转一圈。回来后重新扫一遍 —— 用户在里面可能删掉了一批文件，
  /// 不刷新的话上面那几行统计还停在删之前的数字。
  Future<void> _openFiles() async {
    await showFileListSheet(
      context,
      workDir: widget.workDir,
      onCleared: () => widget.onCleared?.call(),
    );
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _run(
    Future<int> Function() action, {
    required String what,
    String? warning,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          '删除$what？',
          style: AppFonts.body(
            size: 16.5,
            weight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        content: Text(
          warning ?? '删除后无法恢复。',
          style: AppFonts.body(size: 13.5, height: 1.6),
        ),
        actions: <Widget>[
          GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop(false)),
          GlassButton(
            label: '删除',
            danger: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    final int n = await action();
    await _refresh();
    widget.onCleared?.call();
    if (!mounted) return;
    setState(() => _busy = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已删除 $n 项'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final StorageReport? r = _report;

    return Container(
      constraints: BoxConstraints(
        // 让出状态栏：内容变长时标题会和时间/电量叠在一起。
        maxHeight: sheetMaxHeight(context, 0.82),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 12),
            child: Column(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.border,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '存储空间',
                  style: AppFonts.body(
                    size: 17,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: r == null
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 50),
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: <Widget>[
                      // 总览
                      SurfaceCard(
                        radius: AppRadius.card,
                        margin: const EdgeInsets.only(bottom: 14),
                        child: Row(
                          children: <Widget>[
                            _iconBlock(Icons.folder_outlined),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    r.isEmpty
                                        ? '没有占用'
                                        : StorageReport.human(r.totalBytes),
                                    style: AppFonts.body(
                                      size: 22,
                                      weight: FontWeight.w600,
                                      color: s.text,
                                      height: 1.15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    r.isEmpty
                                        ? '应用还没有产生任何文件'
                                        : '共 ${r.totalCount} 个文件',
                                    style: AppFonts.body(
                                      size: 12.5,
                                      color: s.muted,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!r.isEmpty && !_busy)
                              GlassButton(
                                label: '全部清理',
                                danger: true,
                                fontSize: 12.5,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 13,
                                  vertical: 8,
                                ),
                                onTap: () => _run(
                                  () => StorageManager.clearAll(widget.workDir),
                                  what: '全部文件',
                                  warning:
                                      '会清空应用产生的所有文件：'
                                      '截图、录屏、以及聊天里的图片和附件。\n\n'
                                      '历史消息还在，但里面的图片和附件会显示不出来。\n\n'
                                      '此操作无法撤销。',
                                ),
                              ),
                          ],
                        ),
                      ),

                      // 文件清单入口。放在分类之前：分类是"整类清空"的粗操作，
                      // 而"我只想删那两个大录屏"要走这里 —— 它才是更常用的那条路。
                      if (!r.isEmpty)
                        SurfaceCard(
                          radius: AppRadius.card,
                          margin: const EdgeInsets.only(bottom: 9),
                          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                          onTap: _busy ? null : _openFiles,
                          child: Row(
                            children: <Widget>[
                              _iconBlock(Icons.list_alt_rounded),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      '文件清单',
                                      style: AppFonts.body(
                                        size: 14.5,
                                        weight: FontWeight.w600,
                                        color: s.text,
                                        height: 1.3,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '逐个查看，勾选后批量删除',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppFonts.body(
                                        size: 12.5,
                                        color: s.muted,
                                        height: 1.35,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${r.totalCount} 个',
                                style: AppFonts.code(size: 12, color: s.muted),
                              ),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 20,
                                color: s.muted,
                              ),
                            ],
                          ),
                        ),

                      _row(
                        s,
                        icon: Icons.photo_camera_outlined,
                        title: '截图与录屏',
                        desc: '工具产生的中间文件，删除不影响历史记录',
                        count: r.shotCount,
                        bytes: r.shotBytes,
                        onDelete: () => _run(
                          () => StorageManager.clearCaptures(widget.workDir),
                          what: '截图与录屏',
                        ),
                      ),
                      _row(
                        s,
                        icon: Icons.attachment_outlined,
                        title: '聊天附件',
                        desc: '你发送的图片和文件。删除后历史消息里的它们会显示不出来',
                        count: r.attachCount,
                        bytes: r.attachBytes,
                        onDelete: () => _run(
                          () => StorageManager.clearAttachments(widget.workDir),
                          what: '聊天附件',
                          warning:
                              '这些是你之前发过的图片和文件。\n\n'
                              '删除后，历史消息里的附件会变成破图（文字内容不受影响），'
                              '而且无法恢复。\n\n'
                              '如果想让历史记录也一并干净，可以到「历史记录」里先清空会话。',
                        ),
                      ),
                      if (r.otherCount > 0)
                        _row(
                          s,
                          icon: Icons.help_outline_rounded,
                          title: '其它文件',
                          desc: '不属于以上分类的残留文件',
                          count: r.otherCount,
                          bytes: r.otherBytes,
                          onDelete: null,
                        ),

                      const SizedBox(height: 6),
                      Text(
                        '工作目录：${widget.workDir}',
                        style: AppFonts.code(size: 10.5, color: s.muted),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 列表行左侧的图标块：34×34、[AppRadius.code] 圆角、强调色 12% 底。
  ///
  /// 全局只有这一套 —— 存储、插件、MCP、性能页的行都长这个样子。
  /// 空分类时整块降为中性灰，一眼分得清"这一类有东西"和"这一类是空的"。
  Widget _iconBlock(IconData icon, {bool dim = false}) {
    final Color fg = dim ? AppColors.neutral : AppColors.accent;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Icon(icon, size: 18, color: fg),
    );
  }

  Widget _row(
    AppSurface s, {
    required IconData icon,
    required String title,
    required String desc,
    required int count,
    required int bytes,
    VoidCallback? onDelete,
  }) {
    final bool empty = count == 0;

    return SurfaceCard(
      radius: AppRadius.card,
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: <Widget>[
          _iconBlock(icon, dim: empty),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        title,
                        style: AppFonts.body(
                          size: 14.5,
                          weight: FontWeight.w600,
                          color: s.text,
                          height: 1.3,
                        ),
                      ),
                    ),
                    Text(
                      empty ? '—' : StorageReport.human(bytes),
                      style: AppFonts.code(
                        size: 12,
                        color: empty ? s.muted : s.text,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  empty ? '暂无文件' : '$count 个 · $desc',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12.5,
                    color: s.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (!empty && onDelete != null && !_busy)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              color: AppColors.danger,
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
            )
          else
            // 右侧留一个 chevron 位：可删的行是删除键，不可删的行
            // 也不让标题一直顶到卡片边缘 —— 两种行的文字起点因此对齐。
            const SizedBox(width: 8),
        ],
      ),
    );
  }
}

// ============================================================ 文件清单

class _FileListSheet extends StatefulWidget {
  const _FileListSheet({required this.workDir, this.onCleared});

  final String workDir;
  final VoidCallback? onCleared;

  @override
  State<_FileListSheet> createState() => _FileListSheetState();
}

class _FileListSheetState extends State<_FileListSheet> {
  List<GeneratedFile>? _files;

  /// 磁盘上实际有多少个文件（列表可能只显示最近的一部分）。
  int _total = 0;

  /// 勾选状态用**相对路径**做 key：File 对象每次扫描都是新的实例，
  /// 拿它当 key 会在刷新后全部失配，勾好的东西莫名全掉。
  final Set<String> _sel = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final GenerateScan scan = await StorageManager.listFiles(widget.workDir);
    if (!mounted) return;
    setState(() {
      _files = scan.files;
      _total = scan.total;
      // 已经不在了的（别处删了 / 被截断到列表外）从选中集合里摘掉，
      // 否则"已选 5 项"里可能有 3 项是幽灵，点删除也删不动还让人困惑。
      final Set<String> alive = scan.files
          .map((GeneratedFile f) => f.relPath)
          .toSet();
      _sel.removeWhere((String k) => !alive.contains(k));
    });
  }

  void _toggle(GeneratedFile f) {
    setState(() {
      if (!_sel.remove(f.relPath)) _sel.add(f.relPath);
    });
  }

  void _toggleAll() {
    final List<GeneratedFile> list = _files ?? <GeneratedFile>[];
    setState(() {
      if (_sel.length == list.length) {
        _sel.clear();
      } else {
        _sel
          ..clear()
          ..addAll(list.map((GeneratedFile f) => f.relPath));
      }
    });
  }

  /// 已选文件的大小合计。显示在删除按钮旁边 ——
  /// 删之前看见"要释放 320 MB"，比删完再看提示有用得多。
  int get _selBytes => (_files ?? <GeneratedFile>[])
      .where((GeneratedFile f) => _sel.contains(f.relPath))
      .fold(0, (int a, GeneratedFile f) => a + f.bytes);

  Future<void> _deleteSelected() async {
    final List<GeneratedFile> picked = (_files ?? <GeneratedFile>[])
        .where((GeneratedFile f) => _sel.contains(f.relPath))
        .toList();
    if (picked.isEmpty) return;

    // 附件是用户自己发的东西，删了历史消息里那块会变成破图。
    // 混选时必须点出"其中几个属于这类"，不能一并当作删截图处理。
    final int attach = picked
        .where((GeneratedFile f) => f.kind == 'attachment')
        .length;
    final String warn =
        '将永久删除这 ${picked.length} 个文件，无法恢复。'
        '${attach > 0 ? '\n\n其中 $attach 个是聊天附件 —— 删掉后历史消息里的图片和文件会显示不出来（消息文字不受影响）。' : ''}';

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          '删除所选的 ${picked.length} 项？',
          style: AppFonts.body(
            size: 16.5,
            weight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        content: Text(warn, style: AppFonts.body(size: 13.5, height: 1.6)),
        actions: <Widget>[
          GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop(false)),
          GlassButton(
            label: '删除',
            danger: true,
            onTap: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final ({int count, int freed}) r = await deleteMany(picked);
    await _load();
    widget.onCleared?.call();
    if (!mounted) return;
    setState(() => _busy = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // 报告**实际**结果，不是勾选数量：删不掉的（被占用）要说出来，
        // 不然用户看到"已删除 5 项"却发现文件还在，会怀疑整批都没删。
        content: Text(
          r.count == 0
              ? '没有文件被删除（可能被占用或已不存在）'
              : '已删除 ${r.count} 项 · 释放 ${StorageReport.human(r.freed)}'
                    '${r.count < picked.length ? '（${picked.length - r.count} 项删除失败）' : ''}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 时间显示：今天只给 HH:mm，更早给 MM-DD HH:mm。
  static String _stamp(DateTime t) {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final bool sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay
        ? '${two(t.hour)}:${two(t.minute)}'
        : '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// 文件所在子目录（根目录下的文件返回空串）。列表只显示文件名，
  /// 但 `notes/a.md` 和 `a.md` 是两回事，得让用户分得清。
  static String _dirOf(GeneratedFile f) {
    final int i = f.relPath.lastIndexOf('/');
    return i <= 0 ? '' : f.relPath.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<GeneratedFile>? files = _files;
    final bool allSel =
        files != null && files.isNotEmpty && _sel.length == files.length;

    return Container(
      constraints: BoxConstraints(
        // 让出状态栏，否则标题会和状态栏文字叠在一起。
        maxHeight: sheetMaxHeight(context, 0.9),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 12),
            child: Column(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: s.border,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '文件清单',
                  style: AppFonts.body(
                    size: 17,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          if (files == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 50),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                ),
              ),
            )
          else if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 46),
              child: Text(
                '工作目录里没有文件',
                style: AppFonts.body(size: 13, color: s.muted, height: 1.4),
              ),
            )
          else ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 13, 9),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _total > files.length
                          ? '共 $_total 个 · 这里显示最近 ${files.length} 个'
                          : '共 $_total 个文件',
                      style: AppFonts.body(
                        size: 12,
                        color: s.muted,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (!_busy)
                    GlassButton(
                      label: allSel ? '取消全选' : '全选',
                      fontSize: 12.5,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 7,
                      ),
                      onTap: _toggleAll,
                    ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                itemCount: files.length,
                itemBuilder: (BuildContext _, int i) => _fileRow(s, files[i]),
              ),
            ),
          ],
          if (_sel.isNotEmpty && !_busy) _selectionBar(s),
        ],
      ),
    );
  }

  Widget _fileRow(AppSurface s, GeneratedFile f) {
    final bool on = _sel.contains(f.relPath);
    final String dir = _dirOf(f);

    return SurfaceCard(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      onTap: _busy ? null : () => _toggle(f),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              on ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 19,
              color: on ? AppColors.accent : s.muted,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 14.5,
                    weight: on ? FontWeight.w600 : FontWeight.w500,
                    color: s.text,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${f.kindLabel} · ${StorageReport.human(f.bytes)}'
                  ' · ${_stamp(f.modified)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12.5,
                    color: s.muted,
                    height: 1.35,
                  ),
                ),
                if (dir.isNotEmpty)
                  Text(
                    '$dir/',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.code(
                      size: 10,
                      color: s.muted,
                      height: 1.35,
                    ),
                  ),
              ],
            ),
          ),
          // ---- 用其他应用打开 ----
          //
          // 这一列是**独立于勾选**的：这一页的主线是"挑几个删掉"，
          // 所以整行点击留给勾选；而"我想看看这个文件是什么"是另一件事，
          // 给它一个自己的按钮，两件事就不会互相打断。
          //
          // 走的是原生 FileProvider（`PlatformFiles.open`）：这些文件在
          // 应用私有目录里，直接给别的应用一个 `file://` 路径会被系统拒绝。
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded, size: 17),
            tooltip: '用其他应用打开',
            color: s.muted,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            padding: EdgeInsets.zero,
            onPressed: _busy ? null : () => _openWith(f),
          ),
        ],
      ),
    );
  }

  /// 交给系统上能打开它的应用。
  ///
  /// 失败**必须原样说清**：没有应用能打开某种扩展名、或者文件已经被删了，
  /// 这两件事用户该做的事完全不同（一个是"装个应用"，一个是"刷新一下"）。
  Future<void> _openWith(GeneratedFile f) async {
    final String? err = await PlatformFiles.open(f.file.path);
    if (!mounted || err == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err), duration: const Duration(seconds: 3)),
    );
  }

  Widget _selectionBar(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '已选 ${_sel.length} 项 · ${StorageReport.human(_selBytes)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                  size: 13,
                  weight: FontWeight.w600,
                  color: s.text,
                  height: 1.3,
                ),
              ),
            ),
            GlassButton(
              label: '删除',
              icon: Icons.delete_outline_rounded,
              danger: true,
              fontSize: 13,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              onTap: _deleteSelected,
            ),
          ],
        ),
      ),
    );
  }
}
