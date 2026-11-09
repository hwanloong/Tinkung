import 'package:flutter/material.dart';

import '../core/productivity.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';
import 'note_editor_page.dart';
import 'widgets.dart';

String _two(int v) => v.toString().padLeft(2, '0');

String fmtDateTime(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

// ------------------------------------------------------- 图标按钮的统一规格
//
// 「笔记」「计划」两页里所有**次要操作**（搜索 / 新建文件夹 / 新建 /
// 显示已完成 / 文件夹的「⋯」/ 弹窗里的删除、清除时间）都是同一颗按钮，
// 规格收在这一段。
//
// ## 为什么不再用 GlassIconButton
//
// 那是"液态玻璃"圆片：靠背后一层模糊 + 一圈半透明底色把图标托起来。
// 头部现在是**平面**的 iOS 栏（无 elevation、无 tint、只有一条发丝分隔线），
// 圆片背后没有任何东西可以模糊 —— 三颗 36 的圆片于是退化成三个比底色
// 深一档的实心圆点：既没有层次，又和左边那颗 22 的返回键差着一整档尺寸，
// 看上去就是"三个大小不一的盘子浮在标题旁边"。行内那个「⋯」和弹窗里的
// 删除键是同一个毛病，只是底色从栏变成了卡片/面板。
//
// ## 为什么也不直接用默认的 IconButton
//
// 默认触达区是 48（`kMinButtonSize`），加上 `AppHeader` 自己留的 6 像素
// 尾距，最后一个图标的右缘会落在离屏幕边 19 像素处 —— 而这一页的正文是 16。
// 差 3 像素摆在同一块屏上是一条看得出来"右边多出一点点"的竖线。
// 44 是 iOS 导航栏按钮的热区：44 的方框里 22 的图标内缩 11，6 + 11 = 17，
// 正好回到正文那条线上；三颗并排时图标间距 22，也不会散成三个"各浮各的"点。
//
// ## 为什么间距不写成 SizedBox
//
// 相邻两颗按钮的方框直接相邻（额外间距 0）。只要不把 IconButton 那层 8 的
// 内边距归零（见 [_flatIconButton] 里的 `padding: EdgeInsets.zero`），
// "图标间距"就变成 8 + 间距 + 8，改间距时永远算不准；而相邻方框直接相接时，
// 图标间距恒等于 `_kActionTap - _kActionIcon` = 22，要调疏密只动这一个减法。

/// 图标本体尺寸。和 `leading` 那颗返回键（`iconSize: 22`）同规格。
const double _kActionIcon = 22;

/// 头部那排图标按钮的触达区。44 的来历见上面那段推导。
const double _kActionTap = 44;

/// 列表行内 / 弹窗里那颗图标的触达区，比头部小一档。
///
/// 它长在卡片或面板**内部**，卡片自己已经给了上下内边距；再套一个 44 的
/// 方框会把文件夹行撑高 8 像素 —— 而这一行的职责是"让你进文件夹"，
/// 不是"让你点「⋯」"。
const double _kRowActionTap = 36;

/// 平面图标按钮。尺寸 / 触达区 / 视觉密度只在这里写一次。
///
/// 散在七八处各写一遍的后果这次已经看到了：同一种按钮出现三种尺寸，
/// 而漏改的那一颗夹在其它几颗中间**一眼就能看出来**。
Widget _flatIconButton(
  AppSurface s, {
  required IconData icon,
  required String tooltip,
  VoidCallback? onTap,
  Color? color,
  bool inRow = false,
}) {
  final double box = inRow ? _kRowActionTap : _kActionTap;
  return IconButton(
    // 尺寸和颜色都显式给：`color` 在这里承担语义（危险操作是红的），
    // 不能让它从 IconTheme 里被主题盖掉。
    icon: Icon(icon, size: _kActionIcon, color: color ?? s.text),
    tooltip: tooltip,
    onPressed: onTap,
    // 内边距归零 + 固定方框：只有这样"触达区到底多宽"才是确定的。
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(width: box, height: box),
    // 密度钉成 standard：`VisualDensity.compact` 是 (-2, -2)，
    // `effectiveConstraints` 会在宽高上各减 2 × 2 = 4，于是声明的 44
    // 实际只有 40，右缘又跑回屏幕边附近。
    visualDensity: VisualDensity.standard,
  );
}

// ============================================================ 笔记

class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.store});

  final NoteStore store;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  final TextEditingController _search = TextEditingController();
  bool _searching = false;

  /// 当前选中的标签筛选。null = 不筛选。
  ///
  /// 和搜索是**叠加**关系而不是二选一：选了标签之后再搜关键词，
  /// 是在这个标签范围内搜。这样"找工作时笔记里提到 X 的那条"才成立。
  String? _activeTag;

  /// 当前打开的文件夹。**null = 根级**（显示文件夹列表 + 未归类的笔记）。
  String? _openFolderId;

  bool get _atRoot => _openFolderId == null;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    _search.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    // 标签可能因为编辑/删除而不复存在，筛选项要跟着失效，
    // 否则会停在"筛一个已经不存在的标签"然后显示空列表
    if (_activeTag != null && !_allTags().contains(_activeTag)) {
      _activeTag = null;
    }
    // 文件夹被删掉时同理：还停在那个文件夹里会显示一片空白
    if (_openFolderId != null &&
        widget.store.folderById(_openFolderId) == null) {
      _openFolderId = null;
    }
    setState(() {});
  }

  /// 当前范围内出现过的标签。
  ///
  /// **按文件夹取而不是取全部** —— 在"工作"文件夹里列出"菜谱"标签
  /// 只会让人困惑（点了必然是空列表）。
  List<String> _allTags() =>
      widget.store.tagsIn(folderId: _atRoot ? null : _openFolderId);

  /// 当前要显示的笔记。
  ///
  /// 根级只显示**未归类的** —— 归了类的在文件夹里，重复显示会让
  /// 根级变成一个越来越长的混合列表，那文件夹就白做了。
  List<Note> _visibleNotes() => widget.store.filter(
    folderId: _atRoot ? null : _openFolderId,
    keyword: _search.text,
    tag: _activeTag,
  );

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<String> tags = _allTags();
    final List<Note> list = _visibleNotes();
    final int total = widget.store.items.length;
    final NoteFolder? folder = widget.store.folderById(_openFolderId);

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            // 进了文件夹就显示文件夹名，并且给一个返回根级的箭头 ——
            // 否则用户会不知道自己现在在哪一层
            title: folder?.name ?? '笔记',
            leading: folder == null
                ? null
                // **和根级那颗返回键长得一样。**
                //
                // 根级（`leading: null`）用的是 AppBar 自动生成的 Material 返回键；
                // 进文件夹后原来换成一颗 36px 的玻璃圆片 + 一圈内边距 —— 同一个位置、
                // 同一个动作，两颗按钮的尺寸、形状、触达区全都不一样，用户一眼就看出
                // "这个返回键不对劲"。而 AppBar 的 leading 槽位本来就是给
                // 标准图标按钮的（`AppHeader` 也明确不再是玻璃栏），
                // 塞玻璃圆片进去既不合位置也不合设计。
                : IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    iconSize: 22,
                    tooltip: '返回全部',
                    color: s.text,
                    onPressed: () => setState(() {
                      _openFolderId = null;
                      _activeTag = null;
                      _search.clear();
                    }),
                  ),
            subtitle: total == 0
                ? '还没有笔记'
                : _subtitle(folder, list.length, total),
            // 这排按钮的尺寸/间距全部来自 [_flatIconButton]：两颗之间不加
            // SizedBox，间距就是"方框直接相接"（见文件头那段注释）。
            actions: <Widget>[
              _flatIconButton(
                s,
                icon: _searching ? Icons.close_rounded : Icons.search_rounded,
                tooltip: '搜索',
                onTap: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _search.clear();
                }),
              ),
              // 在文件夹里「+」是新建笔记；在根级多一个建文件夹的入口。
              // 条件按钮直接省掉整个 Widget 而不是塞一个 SizedBox 占位 ——
              // 占位会让"根级三颗、文件夹里两颗"两排的右缘对不齐。
              if (folder == null)
                _flatIconButton(
                  s,
                  icon: Icons.create_new_folder_outlined,
                  tooltip: '新建文件夹',
                  onTap: _newFolder,
                ),
              _flatIconButton(
                s,
                icon: Icons.add_rounded,
                tooltip: '新建笔记',
                onTap: () => _edit(null),
              ),
            ],
            bottom: (tags.isEmpty && !_searching)
                ? null
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (_searching)
                        Container(
                          decoration: BoxDecoration(
                            color: s.surface,
                            borderRadius: BorderRadius.circular(
                              AppRadius.field,
                            ),
                            border: Border.all(color: s.border, width: 0.9),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 2,
                          ),
                          child: TextField(
                            controller: _search,
                            autofocus: true,
                            onChanged: (_) => setState(() {}),
                            style: AppFonts.body(size: 14.5, color: s.text),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 11,
                              ),
                              hintText: '搜索标题、正文或标签',
                              hintStyle: AppFonts.body(
                                size: 14,
                                color: s.muted,
                              ),
                            ),
                          ),
                        ),
                      // ---- 标签筛选 ----
                      //
                      // 横向滚动而不是换行：标签一多换行会把头部撑得很高，
                      // 正文可视区域被压缩。横向滚动的高度永远只有一行。
                      if (tags.isNotEmpty) ...<Widget>[
                        if (_searching) const SizedBox(height: 9),
                        SizedBox(
                          height: 32,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: EdgeInsets.zero,
                            children: <Widget>[
                              // 「全部」只在有筛选时才出现 ——
                              // 没筛选时它没有任何作用，白占一个位置
                              if (_activeTag != null) ...<Widget>[
                                _tagChip(s, '全部', null, count: _scopeCount()),
                                const SizedBox(width: 7),
                              ],
                              for (final String t in tags) ...<Widget>[
                                _tagChip(
                                  s,
                                  t,
                                  t,
                                  count: widget.store
                                      .filter(
                                        folderId: _atRoot
                                            ? null
                                            : _openFolderId,
                                        tag: t,
                                      )
                                      .length,
                                ),
                                const SizedBox(width: 7),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              children: <Widget>[
                // 根级先列文件夹，再列未归类的笔记。
                // **顺序很重要**：文件夹是"分类入口"，放在笔记上面才符合
                // "先选类别再看内容"的直觉。
                if (_atRoot && widget.store.folders.isNotEmpty) ...<Widget>[
                  for (final NoteFolder f in widget.store.folders)
                    _folderTile(s, f),
                  const SizedBox(height: 6),
                ],

                // 未归类那一栏的标题。只在**两种东西同时存在**时才显示 ——
                // 没有文件夹时这行标题毫无意义（所有笔记都未归类）
                if (_atRoot && widget.store.folders.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      '未归类 ${widget.store.unfiledCount} 条',
                      style: AppFonts.body(
                        size: 12.5,
                        weight: FontWeight.w600,
                        color: s.muted,
                        height: 1.2,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),

                if (list.isEmpty && widget.store.folders.isEmpty)
                  EmptyHint(
                    icon: Icons.sticky_note_2_outlined,
                    title: _search.text.trim().isEmpty ? '还没有笔记' : '没有匹配的笔记',
                    desc: _search.text.trim().isEmpty
                        ? '点右上角「+」新建。\n也可以直接对 Agent 说「记一下」，它会替你写进来。'
                        : '换个关键词试试。',
                  )
                else if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      _search.text.trim().isEmpty ? '这一层还没有笔记' : '没有匹配的笔记',
                      textAlign: TextAlign.center,
                      style: AppFonts.body(
                        size: 13,
                        color: s.muted,
                        height: 1.5,
                      ),
                    ),
                  )
                else
                  for (final Note n in list) _tile(s, n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 当前范围（文件夹或未归类）里的笔记总数，用于标签条的「全部」
  int _scopeCount() =>
      widget.store.filter(folderId: _atRoot ? null : _openFolderId).length;

  /// 头部副标题
  String _subtitle(NoteFolder? folder, int shown, int total) {
    if (folder == null) {
      final int unfiled = widget.store.unfiledCount;
      if (widget.store.folders.isEmpty) return '共 $total 条';
      return '${widget.store.folders.length} 个文件夹 · 未归类 $unfiled 条';
    }
    final String scope = '$shown 条';
    return _activeTag == null ? scope : '筛选「$_activeTag」· $scope';
  }

  /// 文件夹卡片。点进去，长按改名/删除。
  Widget _folderTile(AppSurface s, NoteFolder f) {
    final int n = widget.store.countInFolder(f.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        onTap: () => setState(() {
          _openFolderId = f.id;
          _activeTag = null;
          _search.clear();
          _searching = false;
        }),
        child: Row(
          children: <Widget>[
            // 34×34 的圆角图标块：和「工作空间」页的文件行同一规格，
            // 两处的"图标托底"看起来才像一套（见 workspace 页文件行）。
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.code),
              ),
              child: Icon(
                Icons.folder_rounded,
                size: 18,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                  size: 14.5,
                  weight: FontWeight.w600,
                  color: s.text,
                  height: 1.3,
                ),
              ),
            ),
            Text(
              '$n',
              textAlign: TextAlign.right,
              style: AppFonts.body(size: 11.5, color: s.muted, height: 1.2),
            ),
            const SizedBox(width: 4),
            // 长按不是好交互（没人会去试），所以给一个明确的「⋯」。
            // 用行内档（[_kRowActionTap]）而不是头部那档：这一行的高度由
            // 32 的文件夹图标和两行文字决定，44 的方框会把它撑高。
            _flatIconButton(
              s,
              icon: Icons.more_horiz_rounded,
              tooltip: '重命名 / 删除',
              inRow: true,
              onTap: () => _folderMenu(f),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件夹的重命名 / 删除
  Future<void> _folderMenu(NoteFolder f) async {
    final int n = widget.store.countInFolder(f.id);

    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 14),
              Text(
                f.name,
                style: AppFonts.body(
                  size: 16,
                  weight: FontWeight.w600,
                  color: s.text,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(
                  Icons.drive_file_rename_outline_rounded,
                  size: 20,
                ),
                title: const Text('重命名'),
                onTap: () => Navigator.of(ctx).pop('rename'),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: AppColors.danger,
                ),
                title: Text(
                  // **把后果写清楚**：这个数字是用户决定要不要删的关键依据，
                  // 藏起来的话他只能靠猜
                  n == 0 ? '删除文件夹' : '删除文件夹（$n 条笔记会变成未归类）',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (action == 'rename') {
      final TextEditingController c = TextEditingController(text: f.name);
      final String? name = await _promptText('重命名文件夹', c, '文件夹名');
      c.dispose();
      if (name != null && name.trim().isNotEmpty) {
        widget.store.renameFolder(f, name);
      }
    } else if (action == 'delete') {
      // 二次确认里**再次强调"笔记不会删"** ——
      // 这是用户最担心的事，不说清他会不敢删
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(
            '删除文件夹',
            style: AppFonts.body(
              size: 16.5,
              weight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          content: mdText(
            '「${f.name}」将被删除。\n\n'
            '里面的 $n 条笔记**不会被删除**，它们会变成「未归类」，'
            '仍然可以在根级看到。',
            style: AppFonts.body(size: 13.5, height: 1.65),
          ),
          actions: <Widget>[
            GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop()),
            GlassButton(
              label: '删除文件夹',
              danger: true,
              onTap: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (ok == true) widget.store.deleteFolder(f.id);
    }
  }

  Future<void> _newFolder() async {
    final TextEditingController c = TextEditingController();
    final String? name = await _promptText('新建文件夹', c, '文件夹名');
    c.dispose();
    if (name != null && name.trim().isNotEmpty) {
      widget.store.createFolder(name);
    }
  }

  /// 通用的单行文本输入弹窗
  Future<String?> _promptText(
    String title,
    TextEditingController c,
    String hint,
  ) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return AlertDialog(
          title: Text(
            title,
            style: AppFonts.body(
              size: 16.5,
              weight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          content: Container(
            decoration: ShapeDecoration(
              color: s.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.field),
                side: BorderSide(color: s.border, width: 1),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: c,
              autofocus: true,
              onSubmitted: (String v) => Navigator.of(ctx).pop(v),
              style: AppFonts.body(size: 14.5, color: s.text),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: hint,
                hintStyle: AppFonts.body(size: 14, color: s.muted),
              ),
            ),
          ),
          actions: <Widget>[
            GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop()),
            GlassButton(
              label: '确定',
              accent: true,
              onTap: () => Navigator.of(ctx).pop(c.text),
            ),
          ],
        );
      },
    );
  }

  /// 一个标签筛选按钮。
  ///
  /// [value] 为 null 表示「全部」。显示条数是因为筛选后最想知道的是
  /// "这个标签下有多少东西"，不给数字的话点进去可能是个空列表。
  ///
  /// 选中态**不靠整块染色**：底色仍是卡片面，只把文字和描边换成 accent。
  /// 一排小胶囊里有一块被涂成浅橙时，旁边的标签会显得"没被充满"，
  /// 扫一眼像是坏了一个；而同尺寸 + accent 描边的选中态既清楚又安静。
  Widget _tagChip(
    AppSurface s,
    String label,
    String? value, {
    required int count,
  }) {
    final bool active = _activeTag == value;
    final Color fg = active ? AppColors.accent : s.muted;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _activeTag = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(
            color: active ? AppColors.accent : s.border,
            width: active ? 1 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: AppFonts.body(
                size: 12.5,
                weight: active ? FontWeight.w600 : FontWeight.w500,
                color: fg,
                height: 1.2,
              ),
            ),
            const SizedBox(width: 5),
            Text('$count', style: AppFonts.code(size: 10.5, color: fg)),
          ],
        ),
      ),
    );
  }

  /// 一条笔记。
  ///
  /// 层级靠**字号**拉开，不靠分隔线：标题 14.5/w600 → 摘要 12.5/muted →
  /// 底部一行「标签在左、时间贴右」。时间之所以挪到整行最右而不是跟在
  /// 摘要下面，是因为列表扫读时人眼沿着右边那条竖线找"最近改过哪条"，
  /// 左对齐的时间会让每条的右侧边缘参差不齐。
  Widget _tile(AppSurface s, Note n) {
    return SurfaceCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      onTap: () => _edit(n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            n.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.body(
              size: 14.5,
              weight: FontWeight.w600,
              color: s.text,
              height: 1.35,
            ),
          ),
          if (n.body.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              n.body.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(size: 12.5, color: s.muted, height: 1.5),
            ),
          ],
          const SizedBox(height: 7),
          Row(
            children: <Widget>[
              if (n.tags.isNotEmpty)
                Flexible(
                  child: GlassChip(
                    label: n.tags.first,
                    dense: true,
                    color: AppColors.accent,
                  ),
                ),
              const Spacer(),
              Text(
                fmtDateTime(n.updatedAt),
                textAlign: TextAlign.right,
                style: AppFonts.body(size: 11.5, color: s.muted, height: 1.2),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 打开笔记编辑页。
  ///
  /// 改成**独立页面**而不是底部弹窗：写笔记是沉浸行为，
  /// 弹窗高度被键盘和屏幕挤压，写长内容很难受，误触遮罩还会丢内容。
  /// 编辑页自己在返回时保存。
  Future<void> _edit(Note? existing) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => NoteEditorPage(
          store: widget.store,
          note: existing,
          // 在某个文件夹里点「+」，新笔记直接落在那儿 ——
          // 否则用户还得建完再手动移一次
          initialFolderId: existing == null && !_atRoot ? _openFolderId : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }
}

/// 表单输入框（笔记和任务的编辑弹窗共用）。
///
/// 放在顶层而不是某个 State 里：两个页面都要用，
/// 挂在 NotesPage 上会让 TasksPage 依赖一个跟它无关的类，
/// 而且那种 `NotesPage._input` 的写法一旦有人重命名就会连带崩掉。
Widget _sheetInput(
  AppSurface s,
  TextEditingController c,
  String hint, {
  int maxLines = 1,
  double size = 14.5,
  bool mono = false,
}) {
  return Container(
    decoration: BoxDecoration(
      color: s.surface,
      borderRadius: BorderRadius.circular(AppRadius.code),
      border: Border.all(color: s.border, width: 0.9),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: TextField(
      controller: c,
      maxLines: maxLines,
      style: mono
          ? AppFonts.code(size: size, color: s.text)
          : AppFonts.body(size: size, color: s.text, height: 1.5),
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 11),
        hintText: hint,
        hintStyle: AppFonts.body(size: size - 1, color: s.muted),
      ),
    ),
  );
}

// ============================================================ 任务

class TasksPage extends StatefulWidget {
  const TasksPage({super.key, required this.store});

  final TaskStore store;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<TaskItem> pending = widget.store.pending;
    final List<TaskItem> done =
        widget.store.items.where((TaskItem t) => t.done).toList()..sort(
          (TaskItem a, TaskItem b) => (b.completedAt ?? b.createdAt).compareTo(
            a.completedAt ?? a.createdAt,
          ),
        );

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '任务',
            subtitle: _subtitle(pending),
            actions: <Widget>[
              _flatIconButton(
                s,
                icon: _showDone
                    ? Icons.visibility_off_outlined
                    : Icons.history_rounded,
                tooltip: _showDone ? '隐藏已完成' : '显示已完成',
                onTap: () => setState(() => _showDone = !_showDone),
              ),
              _flatIconButton(
                s,
                icon: Icons.add_rounded,
                tooltip: '新建任务',
                onTap: () => _edit(null),
              ),
            ],
          ),
          Expanded(
            child: pending.isEmpty && (!_showDone || done.isEmpty)
                ? EmptyHint(
                    icon: Icons.check_circle_outline_rounded,
                    title: '没有待办任务',
                    desc:
                        '点右上角「+」新建，并设定执行时间。\n'
                        '也可以直接对 Agent 说「提醒我明天下午三点交报告」。',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                    children: <Widget>[
                      if (pending.isNotEmpty) ...<Widget>[
                        _sectionLabel(s, '待办 ${pending.length}'),
                        ...pending.map((TaskItem t) => _tile(s, t)),
                      ],
                      if (_showDone && done.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 14),
                        _sectionLabel(s, '已完成 ${done.length}'),
                        ...done.map((TaskItem t) => _tile(s, t)),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  String _subtitle(List<TaskItem> pending) {
    final int over = widget.store.overdue.length;
    final int today = widget.store.dueToday.length;
    if (pending.isEmpty) return '全部完成';
    final List<String> parts = <String>['待办 ${pending.length}'];
    if (over > 0) parts.add('逾期 $over');
    if (today > 0) parts.add('今天 $today');
    return parts.join(' · ');
  }

  Widget _sectionLabel(AppSurface s, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 2),
      child: Text(
        text,
        style: AppFonts.body(
          size: 12.5,
          weight: FontWeight.w600,
          color: s.muted,
          height: 1.2,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _tile(AppSurface s, TaskItem t) {
    final Color dueColor = t.done
        ? s.muted
        : (t.overdue ? AppColors.danger : s.muted);

    final Widget card = SurfaceCard(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
      onTap: () => _edit(t),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 勾选完成：这是最高频操作，给足触摸面积
          GestureDetector(
            onTap: () => widget.store.toggle(t),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                t.done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: t.done ? AppColors.success : s.muted,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.title,
                  style:
                      AppFonts.body(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: t.done ? s.muted : s.text,
                        height: 1.35,
                      ).copyWith(
                        decoration: t.done ? TextDecoration.lineThrough : null,
                        decorationColor: s.muted,
                      ),
                ),
                if (t.detail.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    t.detail.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 12.5,
                      color: s.muted,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                // 时间贴右：和上面那条笔记列表用同一条右轨，翻两种列表时
                // 视线不用换位置找"什么时候到期"。
                Row(
                  children: <Widget>[
                    Icon(
                      t.dueAt == null
                          ? Icons.schedule_outlined
                          : t.overdue
                          ? Icons.warning_amber_rounded
                          : Icons.schedule_rounded,
                      size: 12.5,
                      color: dueColor,
                    ),
                    const Spacer(),
                    Text(
                      t.dueAt == null
                          ? '未设定执行时间'
                          : t.overdue
                          ? '逾期 · ${fmtDateTime(t.dueAt!)}'
                          : fmtDateTime(t.dueAt!),
                      textAlign: TextAlign.right,
                      style: AppFonts.body(
                        size: 11.5,
                        color: dueColor,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // 逾期的那条在卡片左缘压一道 3px 的竖条。
    //
    // 不做整卡染色：一整块淡红会把标题、摘要、时间全部泡进去，
    // 读起来像"这一条坏了"；左边一道细竖条只在扫视时提示"看这里"，
    // 展开读内容时它又退到边缘。
    if (!t.overdue || t.done) return card;
    return Stack(
      children: <Widget>[
        card,
        Positioned(
          left: 0,
          top: 10,
          bottom: 18,
          child: Container(
            width: 3,
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _edit(TaskItem? existing) async {
    final TextEditingController title = TextEditingController(
      text: existing?.title ?? '',
    );
    final TextEditingController detail = TextEditingController(
      text: existing?.detail ?? '',
    );
    DateTime? due = existing?.dueAt;
    final AppSurface s = AppSurface.of(context);

    final String? action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setSheet) {
          Future<void> pickDue() async {
            final DateTime now = DateTime.now();
            final DateTime? d = await showDatePicker(
              context: ctx,
              initialDate: due ?? now,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 5),
            );
            if (d == null || !ctx.mounted) return;
            final TimeOfDay? t = await showTimePicker(
              context: ctx,
              initialTime: TimeOfDay.fromDateTime(due ?? now),
            );
            if (!ctx.mounted) return;
            setSheet(() {
              due = DateTime(
                d.year,
                d.month,
                d.day,
                t?.hour ?? 9,
                t?.minute ?? 0,
              );
            });
          }

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Container(
              constraints: BoxConstraints(
                // 让出状态栏：内容变长时标题会和时间/电量叠在一起。
                maxHeight: sheetMaxHeight(ctx, 0.85),
              ),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          existing == null ? '新建任务' : '编辑任务',
                          style: AppFonts.body(
                            size: 17,
                            weight: FontWeight.w600,
                            color: s.text,
                            height: 1.2,
                          ),
                        ),
                      ),
                      if (existing != null)
                        _flatIconButton(
                          s,
                          icon: Icons.delete_outline_rounded,
                          tooltip: '删除',
                          color: AppColors.danger,
                          inRow: true,
                          onTap: () => Navigator.of(ctx).pop('delete'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView(
                      children: <Widget>[
                        _sheetInput(s, title, '任务标题', size: 16),
                        const SizedBox(height: 9),
                        _sheetInput(s, detail, '补充说明', maxLines: 4),
                        const SizedBox(height: 14),
                        Text(
                          '执行时间',
                          style: AppFonts.body(
                            size: 12.8,
                            color: s.muted,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: SurfaceCard(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                onTap: pickDue,
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.event_rounded,
                                      size: 16,
                                      color: due == null
                                          ? s.muted
                                          : AppColors.accent,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        due == null
                                            ? '点击选择日期和时间'
                                            : fmtDateTime(due!),
                                        style: AppFonts.body(
                                          size: 13.5,
                                          color: due == null ? s.muted : s.text,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (due != null) ...<Widget>[
                              const SizedBox(width: 8),
                              // 和左边那张日期卡片并排：行内档 36 的方框
                              // 正好落在卡片的垂直中线附近，44 会顶出去。
                              _flatIconButton(
                                s,
                                icon: Icons.close_rounded,
                                tooltip: '清除时间',
                                inRow: true,
                                onTap: () => setSheet(() => due = null),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 16),
                        GlassButton(
                          label: '保存',
                          accent: true,
                          expand: true,
                          onTap: () => Navigator.of(ctx).pop('save'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (action == 'delete' && existing != null) {
      widget.store.remove(existing.id);
    } else if (action == 'save') {
      if (existing == null) {
        widget.store.create(title: title.text, detail: detail.text, dueAt: due);
      } else {
        existing.title = title.text.trim().isEmpty
            ? existing.title
            : title.text.trim();
        existing.detail = detail.text;
        existing.dueAt = due;
        widget.store.update(existing);
      }
    }

    title.dispose();
    detail.dispose();
  }
}
