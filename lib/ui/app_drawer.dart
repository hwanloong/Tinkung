import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/app_info.dart';
import '../core/models.dart';
import '../core/notify_hub.dart';
import '../core/productivity.dart';
import '../core/store.dart';
import '../plugins/plugin.dart';
import '../shizuku/shizuku_service.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'browser_page.dart';
import 'greeting.dart';
import 'productivity_pages.dart';
import 'settings_sheet.dart';
import 'widgets.dart';

/// 「历史对话」那一排小图标的规格。
const double _kHistoryIconBox = 32;
const double _kHistoryIconGlyph = 17;
const double _kHistoryIconInset =
    16 - (_kHistoryIconBox - _kHistoryIconGlyph) / 2;

/// 侧边菜单：新对话 / 历史对话 / 计划 / 笔记 / 浏览器。
///
/// ## 这一版删掉了什么
///
/// 工作空间、群聊、常驻（AutoPilot）都已经从应用里移除：
/// 那些功能各自带一整套页面和后台调度，而实际用下来，用户要的
/// 几乎全是"接着聊"和"存一下"。删掉之后留下的是一个**列表 + 四个入口**，
/// 抽屉回到"找对话"这一个职责上。
///
/// ## 为什么不再全屏
///
/// 之前铺满整屏，拉开之后背后什么都看不见 —— 用户会以为"我跳到新页面了"。
/// 留一条窄边，能看见底下还是那个对话，就仍然是"抽屉"。
class AppDrawer extends StatefulWidget {
  const AppDrawer({
    super.key,
    required this.settings,
    required this.conversations,
    required this.plugins,
    required this.shizuku,
    required this.workDir,
    required this.notes,
    required this.tasks,
  });

  final Settings settings;
  final ConversationStore conversations;
  final PluginStore plugins;
  final ShizukuService shizuku;
  final String workDir;
  final NoteStore notes;
  final TaskStore tasks;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  final TextEditingController _search = TextEditingController();

  bool _editing = false;

  /// 搜索框是否展开。默认收起：抽屉一拉开应该是"头像 + 入口 + 历史"，
  /// 而不是先看到一条输入框。
  bool _searching = false;

  final FocusNode _searchFocus = FocusNode();
  final Set<String> _picked = <String>{};
  int _avatarStamp = 0;

  @override
  void initState() {
    super.initState();
    widget.conversations.addListener(_onChange);
    widget.notes.addListener(_onChange);
    widget.tasks.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.conversations.removeListener(_onChange);
    widget.notes.removeListener(_onChange);
    widget.tasks.removeListener(_onChange);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _close() => Navigator.of(context).maybePop();

  // ------------------------------------------------------------------ 动作

  void _newChat() {
    widget.conversations.createNew();
    _close();
  }

  void _openChat(String id) {
    unawaited(NotifyHub.instance.markRead(id));
    widget.conversations.select(id);
    _close();
  }

  Future<void> _openSettings() async {
    _close();
    await showSettingsSheet(
      context,
      settings: widget.settings,
      workDir: widget.workDir,
      plugins: widget.plugins,
      conversations: widget.conversations,
      notes: widget.notes,
      tasks: widget.tasks,
    );
  }

  void _openNotes() {
    _close();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => NotesPage(store: widget.notes),
      ),
    );
  }

  void _openTasks() {
    _close();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => TasksPage(store: widget.tasks),
      ),
    );
  }

  void _openBrowser() {
    _close();
    BrowserPage.open(
      context,
      url: browserHomeUrl(widget.settings.searchEngine),
    );
  }

  // ------------------------------------------------------------------ 视图

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<Conversation> history = widget.conversations.history;
    final List<Conversation> shown = _filter(history);

    return Drawer(
      // 侧边栏用**和页面同一层**的底色。
      //
      // iOS 的侧滑菜单不靠"比页面深一档"来分层 —— 它靠那条边缘阴影和
      // 0.86 的宽度把两页分开。给抽屉单独换一个底色，拉开时整块跳色，
      // 那是上一版暖色板留下的做法（sidebar 比正文纸深一档）。
      backgroundColor: s.pageBg,
      // 0.86 而不是 1.0：留一条窄边，能看见底下还是那个对话 ——
      // 铺满屏幕会让人以为"我跳到另一个页面了"。
      width: MediaQuery.of(context).size.width * 0.86,
      child: SafeArea(
        // ---- 三段式：标题栏 / 可滚动正文 / 底部用户条 ----
        //
        // 和参考图（元宝侧栏）一致：顶部一行是应用名 + 搜索，底部一条
        // 用户条钉在屏幕角上。中间那段自己滚 —— 横屏时可用高度只有
        // 300 出头，固定头尾之后中间仍有一百多像素，列表在里面滚，
        // 不会再把整页顶出屏幕（以前整页一个大 ListView 时溢出过 13px）。
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _titleBar(s),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  // ---- 新建对话：一条通栏的胶囊 ----
                  //
                  // 参考图里它是**最显眼的一行**：整条圆角底 + 左侧一个
                  // 圆圈加号。它比下面那三项重，因为这是这一屏唯一会
                  // **增加内容**的动作，其余三项都是"去别处"。
                  _newChatPill(s),
                  const SizedBox(height: 4),
                  _entryRow(s, Icons.folder_outlined, '工作文件', _openFiles),
                  _entryRow(
                    s,
                    Icons.checklist_rounded,
                    '笔记和计划',
                    _openNotesAndTasks,
                  ),
                  _entryRow(s, Icons.public_rounded, '浏览器', _openBrowser),
                  if (_searching) _searchBox(s),
                  const SizedBox(height: 6),
                  // ---- 历史区：**不铺底色，只压一条分隔线** ----
                  //
                  // 原来这里给整块刷了一层 55% 的白底，结果抽屉里出现
                  // 一条横贯的浅色带（"入口"和"历史"被切成两块牌子）。
                  // iOS 的列表分组只靠一条发丝线分界 —— 背景始终同一个颜色。
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: s.border, width: 0.6),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (_editing)
                          _editBar(s, shown)
                        else
                          _historyLabel(s, shown),
                        if (shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            child: Text(
                              history.isEmpty
                                  ? '还没有对话'
                                  : '没有匹配「${_search.text.trim()}」的对话',
                              style: AppFonts.body(size: 12.5, color: s.muted),
                            ),
                          )
                        else
                          // ---- 按时间分组 ----
                          //
                          // 历史一长，一列几乎相同的行很难扫：用户记得
                          // "是昨天那件事"，但在一串 14 号字里找不出来。
                          // 分成 置顶 / 今天 / 昨天 / 更早 几段，
                          // 定位靠段而不靠逐行读。
                          for (final _HistoryGroup g in _groupHistory(shown))
                            ...<Widget>[
                              if (g.label.isNotEmpty) _groupLabel(s, g.label),
                              for (final Conversation c in g.items)
                                _historyRow(s, c),
                            ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _userBar(s),
          ],
        ),
      ),
    );
  }

  /// 顶部标题栏：**应用名（左）+ 搜索（右）**。
  ///
  /// 参考图里就是这样：一行大标题，右边单独一颗放大镜。搜索框平时
  /// 收着 —— 点放大镜才展开成输入框（[_searchBox]），和以前一样。
  Widget _titleBar(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              kAppName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(
                size: 24,
                weight: FontWeight.w700,
                color: s.text,
                height: 1.2,
              ),
            ),
          ),
          IconButton(
            tooltip: _searching ? '收起搜索' : '搜索对话',
            onPressed: _toggleSearch,
            icon: Icon(
              _searching ? Icons.close_rounded : Icons.search_rounded,
              size: 22,
              color: s.text,
            ),
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  /// 「新建对话」：一条**通栏胶囊**（圆角底 + 左侧圆圈加号 + 文字）。
  Widget _newChatPill(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Material(
        color: s.chipBg,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: _newChat,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.add_circle_outline_rounded,
                  size: 21,
                  color: s.text,
                ),
                const SizedBox(width: 12),
                Text(
                  '新建对话',
                  style: AppFonts.body(
                    size: 15.5,
                    weight: FontWeight.w500,
                    color: s.text,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 底部用户条：**头像 + 名字**，整条是可点的（去设置 / 换头像）。
  ///
  /// tooltip 保留 `设置 / 换头像`：这是"设置"在侧栏里唯一的入口，
  /// 测试和无障碍都按它定位。
  Widget _userBar(AppSurface s) {
    final String? name = Greeting.userName();
    final File? avatar = _avatarFile();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Tooltip(
        message: '设置 / 换头像',
        child: InkWell(
          onTap: _avatarMenu,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
            decoration: BoxDecoration(
              color: s.chipBg,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: s.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: s.border, width: 0.8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: avatar == null
                      ? Center(
                          child: Icon(
                            Icons.person_outline_rounded,
                            size: 18,
                            color: s.text,
                          ),
                        )
                      : Image.file(
                          avatar,
                          fit: BoxFit.cover,
                          key: ValueKey(_avatarStamp),
                        ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    (name ?? '').trim().isEmpty ? '我' : name!.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 14.5,
                      weight: FontWeight.w500,
                      color: s.text,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 一行入口：**只有一个图标 + 文字**（按设计稿：不要圆形底板）。
  ///
  /// 之前图标外面套了一个 32 的圆底，四行并排时像四个按钮；
  /// 去掉底板之后它读起来就是一份菜单 —— 图标只是行首的记号。
  Widget _entryRow(
    AppSurface s,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    // ---- 四行入口**排紧** ----
    //
    // 每行纵向 11 → 7。四行加起来省掉 32，整组入口从 180 出头的
    // 高度收到 148 —— 这样"头像 + 四行入口 + 历史标题"在一屏里排完，
    // 历史列表能多露出两三条。
    //
    // 字号 14.5 → 14、图标 20 → 19、间距 14 → 12：行矮了之后，
    // 原来的字号会让行与行之间没有空隙，看起来像一坨字；一起收一点，
    // 密排但仍然是四行分得开的条目。
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 7, 16, 7),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 19, color: s.text),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(size: 14, color: s.text),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标题行右边的一颗小胶囊（图标 + 字）。
  Widget _headerPill(
    AppSurface s,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: s.chipBg,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13, color: s.text),
            const SizedBox(width: 4),
            Text(label, style: AppFonts.body(size: 12, color: s.text)),
          ],
        ),
      ),
    );
  }

  /// 展开 / 收起搜索框。收起时顺手清空关键词，避免列表停在过滤结果上。
  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchFocus.requestFocus();
      });
    } else {
      _search.clear();
    }
  }

  /// 「查看我的工作文件」：列出工作目录里的东西。
  ///
  /// 工作空间那一套（引用目录、文件树、在线编辑）已经删掉了；
  /// 这里只保留**看**：文件名 + 大小，点一下用系统应用打开。
  Future<void> _openFiles() async {
    _close();
    final Directory dir = Directory(widget.workDir);
    List<FileSystemEntity> items = <FileSystemEntity>[];
    try {
      if (await dir.exists()) items = await dir.list().toList();
    } catch (_) {}
    items.sort((FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path));
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: sheetMaxHeight(ctx, 0.7)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '工作文件',
                          style: AppFonts.body(
                            size: 16,
                            weight: FontWeight.w600,
                            color: s.text,
                          ),
                        ),
                      ),
                      Text(
                        dir.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(size: 10.5, color: s.muted),
                      ),
                    ],
                  ),
                ),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
                    child: Text(
                      '这个目录还是空的。让 agent 写点东西到这里，'
                      '或者用聊天里的「+」发文件。',
                      style: AppFonts.body(size: 12.5, color: s.muted, height: 1.6),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (BuildContext _, int i) {
                        final FileSystemEntity e = items[i];
                        final String name = e.path.split('/').last;
                        final bool isDir = e is Directory;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            isDir ? Icons.folder_outlined : Icons.description_outlined,
                            size: 19,
                            color: s.muted,
                          ),
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppFonts.body(size: 13.5, color: s.text),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 「笔记和计划」：两项放一张小面板里选，而不是在侧栏再占两行。
  Future<void> _openNotesAndTasks() async {
    final String? pick = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.sticky_note_2_outlined, color: s.text),
                title: const Text('笔记'),
                onTap: () => Navigator.of(ctx).pop('notes'),
              ),
              ListTile(
                leading: Icon(Icons.checklist_rounded, color: s.text),
                title: const Text('计划'),
                onTap: () => Navigator.of(ctx).pop('tasks'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || pick == null) return;
    if (pick == 'notes') {
      _openNotes();
    } else {
      _openTasks();
    }
  }

  List<Conversation> _filter(List<Conversation> all) {
    final String q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((Conversation c) {
      if (c.title.toLowerCase().contains(q)) return true;
      for (final ChatMessage m in c.messages) {
        if (m.hidden) continue;
        if (m.content.toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList();
  }


  Widget _searchBox(AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: _searchField(s),
    );
  }

  Widget _historyLabel(AppSurface s, List<Conversation> history) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, _kHistoryIconInset, 10),
      child: Row(
        children: <Widget>[
          Text(
            '历史对话',
            style: AppFonts.body(
              size: 11.5,
              weight: FontWeight.w600,
              color: s.muted,
              letterSpacing: 0.8,
              height: 1.2,
            ),
          ),
          if (history.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '${history.length}',
                style: AppFonts.body(size: 11.5, color: s.muted),
              ),
            ),
          const Spacer(),
          // ---- 只剩「编辑」 ----
          //
          // 「探索」胶囊删掉了：搜索已经搬到标题栏右边那颗放大镜
          // （见 [_titleBar]），这里再来一颗就是同一个动作两个入口。
          //
          // 和参考图一致：分组标题右边只有一颗"整理"的动作图标，
          // 搜索属于顶栏，不属于列表。
          if (history.isNotEmpty)
            _headerPill(s, Icons.checklist_rounded, '编辑', _startBulkEdit),
        ],
      ),
    );
  }

  void _startBulkEdit() {
    setState(() {
      _editing = true;
      _picked.clear();
      _search.clear();
    });
  }

  Widget _searchField(AppSurface s) {
    return Container(
      decoration: BoxDecoration(
        color: s.chipBg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: s.border, width: 0.8),
      ),
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
      child: Row(
        children: <Widget>[
          Icon(Icons.search_rounded, size: 16, color: s.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: (_) => setState(() {}),
              style: AppFonts.body(size: 13.5, color: s.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索对话',
                hintStyle: AppFonts.body(size: 13, color: s.muted),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          if (_search.text.isNotEmpty)
            _tinyIcon(
              s,
              icon: Icons.close_rounded,
              tooltip: '清空',
              onTap: () => setState(_search.clear),
            ),
        ],
      ),
    );
  }

  Widget _editBar(AppSurface s, List<Conversation> shown) {
    final int n = _picked.length;
    final bool all = shown.isNotEmpty && n == shown.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 8, 2),
      child: Row(
        children: <Widget>[
          Text(
            n == 0 ? '选择对话' : '已选 $n 条',
            style: AppFonts.body(
              size: 12.5,
              weight: FontWeight.w600,
              color: s.text,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              if (all) {
                _picked.clear();
              } else {
                _picked
                  ..clear()
                  ..addAll(shown.map((Conversation c) => c.id));
              }
            }),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(
              all ? '取消全选' : '全选',
              style: AppFonts.body(size: 12.5, color: AppColors.accent),
            ),
          ),
          _tinyIcon(
            s,
            icon: Icons.push_pin_outlined,
            tooltip: '置顶所选',
            onTap: n == 0
                ? null
                : () {
                    widget.conversations.setPinned(_picked.toList(), true);
                    setState(_picked.clear);
                  },
          ),
          _tinyIcon(
            s,
            icon: Icons.delete_outline_rounded,
            tooltip: '删除所选',
            color: n == 0 ? s.muted : AppColors.danger,
            onTap: n == 0 ? null : _deletePicked,
          ),
          TextButton(
            onPressed: () => setState(() {
              _editing = false;
              _picked.clear();
            }),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
            child: Text('完成', style: AppFonts.body(size: 12.5, color: s.text)),
          ),
        ],
      ),
    );
  }

  Future<void> _deletePicked() async {
    final int n = _picked.length;
    if (n == 0) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(
          '删除这 $n 条对话？',
          style: AppFonts.body(size: 16.5, weight: FontWeight.w600, height: 1.3),
        ),
        content: Text(
          '删除后无法恢复。\n（置顶的也会一起删掉。）',
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
    if (ok != true || !mounted) return;
    widget.conversations.removeMany(_picked.toList());
    if (widget.conversations.conversations.isEmpty) {
      widget.conversations.createNew();
    }
    setState(() {
      _picked.clear();
      _editing = false;
    });
  }

  Widget _tinyIcon(
    AppSurface s, {
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, size: _kHistoryIconGlyph),
      tooltip: tooltip,
      color: color ?? s.muted,
      onPressed: onTap,
      visualDensity: VisualDensity.standard,
      constraints: const BoxConstraints.tightFor(
        width: _kHistoryIconBox,
        height: _kHistoryIconBox,
      ),
      padding: EdgeInsets.zero,
    );
  }

  // ------------------------------------------------------------------ 身份区

  File? _avatarFile() {
    try {
      final Directory dir = Directory('${_docsPath()}/avatar');
      final File f = File('${dir.path}/avatar.png');
      return f.existsSync() ? f : null;
    } catch (_) {
      return null;
    }
  }

  static String _docsPath() => Directory.systemTemp.parent.path;

  Future<void> _pickAvatar() async {
    try {
      final XFile? picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null) return;
      final Directory dir = Directory('${_docsPath()}/avatar');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File target = File('${dir.path}/avatar.png');
      await File(picked.path).copy(target.path);
      if (!mounted) return;
      setState(() => _avatarStamp = DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('换头像失败：$e')));
    }
  }

  /// 头像菜单：**设置** / 换头像。
  ///
  /// 设置收进这里（用户明确要求"设置塞进头像里面"）：底栏少一颗图标，
  /// 而"设置"本来就是"关于我自己"的东西 —— 挂在头像下面语义也对。
  Future<void> _avatarMenu() async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: Icon(Icons.settings_outlined, color: s.text),
                title: const Text('设置'),
                subtitle: const Text('模型、权限、外观、高级选项'),
                onTap: () => Navigator.of(ctx).pop('settings'),
              ),
              ListTile(
                leading: Icon(Icons.photo_outlined, color: s.muted),
                title: const Text('更换头像'),
                onTap: () => Navigator.of(ctx).pop('avatar'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'settings':
        await _openSettings();
      case 'avatar':
        await _pickAvatar();
    }
  }

  // ------------------------------------------------------------------ 历史行

  Widget _historyRow(AppSurface s, Conversation c) {
    final bool active = c.id == widget.conversations.currentId;
    final String title = c.title.trim().isEmpty ? '新对话' : c.title;
    final bool picked = _picked.contains(c.id);

    return InkWell(
      onTap: () {
        if (!_editing) return _openChat(c.id);
        setState(() {
          if (!_picked.remove(c.id)) _picked.add(c.id);
        });
      },
      onLongPress: _editing ? null : () => _chatMenu(c),
      child: Padding(
        // ---- 两行：标题 + 最后一句 ----
        //
        // 单行标题的时代，抽屉里一列都是"查电量并清缓存""整理待办"这种
        // 四五个字的短标题，扫一眼全是同质的黑条，分不出哪条是哪条。
        // 加一行摘要（最后一条可见消息的开头）之后，每一行都自带一个
        // **线索**：用户是靠"我当时说了什么"来认对话的，不是靠标题。
        //
        // 行高 52 → 56：多出来的 4 给摘要那一行的行盒，
        // 而不是靠压缩标题的呼吸感。
        padding: const EdgeInsets.fromLTRB(16, 5, 4, 5),
        child: Row(
          children: <Widget>[
            // ---- 左侧那条**蓝色竖条**已经去掉 ----
            //
            // 它原来标"当前会话"，但（用户原话）"不要那个蓝色的勾" ——
            // 一条 3px 的亮蓝在灰阶列表里跳得太凶，而且下面每一行都
            // 是同一个形状，那一抹蓝把整列的节奏打断。
            //
            // 当前会话改由**标题加粗**表示（`w600` vs `w500`），
            // 安静但足够分辨 —— 这也是 iOS 侧栏的做法。
            if (_editing) ...<Widget>[
              Icon(
                picked ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 19,
                color: picked ? AppColors.accent : s.muted,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (c.pinned) ...<Widget>[
                        Icon(
                          Icons.push_pin_rounded,
                          size: 12,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 5),
                      ],
                      if (NotifyHub.instance.unread(c.id)) ...<Widget>[
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: AppColors.danger,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                      ],
                      // ---- 标题是 `Flexible`，不是 `Expanded` ----
                      //
                      // 这一处差一个字，效果差很远：
                      //  · `Expanded` 会**吃满**整行剩下的宽度，时间被顶到
                      //    最右边，和标题之间隔着一大段空白（用户的原话：
                      //    "时间排得太遥远了"）；
                      //  · `Flexible` 只占标题**实际需要**的宽度，
                      //    时间就贴在它右边几个像素。
                      //
                      // 标题特别长时 `Flexible` 会先被压到可用宽度，
                      // 省略号照常出现 —— 两全。
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.body(
                            size: 14,
                            weight: active ? FontWeight.w600 : FontWeight.w500,
                            // ---- 当前会话：**强调色 + 加粗** ----
                            //
                            // 用户的明确要求："这种聊天在侧边栏会用强调色
                            // 标出"。之前标它的是左边那条 3px 的蓝色竖条，
                            // 已经删掉（用户嫌它跳）；现在颜色直接落在
                            // 标题上 —— 比一条竖条更安静，也更像 iOS 里
                            // "当前项"的写法。
                            //
                            // 只染标题，不染摘要和时间：后者是注脚，
                            // 整行染色会让"当前"和"选中/可点"混为一谈。
                            color: active ? AppColors.accent : s.text,
                            height: 1.25,
                          ),
                        ),
                      ),
                      // ---- 时间：紧跟在标题后面 ----
                      //
                      // 10.5 号、比摘要还淡一档：它是注脚，不该在标题行
                      // 抢注意力。间距 6 是"同一句话里的停顿"，
                      // 不是"两个字段之间的分隔"。
                      const SizedBox(width: 6),
                      Text(
                        _timeText(c.updatedAt),
                        style: AppFonts.body(
                          size: 10.5,
                          color: s.muted,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _snippetOf(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 12,
                      color: s.muted,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            if (!_editing)
              _tinyIcon(
                s,
                icon: Icons.more_horiz_rounded,
                tooltip: '更多',
                onTap: () => _chatMenu(c),
              ),
          ],
        ),
      ),
    );
  }

  /// 时间：今天给 `HH:mm`，昨天给"昨天"，更早给 `MM-DD`。
  ///
  /// 分组标题已经把"昨天"这一层说清楚了，所以行内可以省掉；
  /// 但搜索/编辑态下分组标题会让位，行内那点信息仍然要在。
  static String _timeText(DateTime t) {
    final DateTime now = DateTime.now();
    final DateTime day = DateTime(t.year, t.month, t.day);
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int diff = today.difference(day).inDays;
    String two(int v) => v.toString().padLeft(2, '0');
    if (diff == 0) return '${two(t.hour)}:${two(t.minute)}';
    if (diff == 1) return '昨天';
    if (now.year == t.year) return '${two(t.month)}-${two(t.day)}';
    return '${t.year}';
  }

  Future<void> _chatMenu(Conversation c) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Text(
                  c.title.trim().isEmpty ? '新对话' : c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(size: 13, color: s.muted),
                ),
              ),
              ListTile(
                leading: Icon(Icons.drive_file_rename_outline_rounded,
                    color: s.text),
                title: const Text('重命名'),
                onTap: () => Navigator.of(ctx).pop('rename'),
              ),
              ListTile(
                leading: Icon(
                  c.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                  color: s.text,
                ),
                title: Text(c.pinned ? '取消置顶' : '置顶'),
                onTap: () => Navigator.of(ctx).pop('pin'),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: AppColors.danger),
                title: Text('删除',
                    style: TextStyle(color: AppColors.danger)),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _renameChat(c);
      case 'pin':
        widget.conversations.setPinned(<String>[c.id], !c.pinned);
      case 'delete':
        await _deleteChat(c);
    }
  }

  Future<void> _deleteChat(Conversation c) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除这个对话？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              c.title.trim().isEmpty ? '（未命名对话）' : c.title,
              style: AppFonts.body(size: 13.5, height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              '删除后无法恢复。',
              style: AppFonts.body(size: 12, height: 1.5),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    widget.conversations.remove(c.id);
    if (widget.conversations.current == null) {
      widget.conversations.createNew();
    }
    if (mounted) setState(() {});
  }

  Future<void> _renameChat(Conversation c) async {
    final String? name = await showRenameDialog(context, initial: c.title);
    if (name == null) return;
    widget.conversations.rename(c.id, name);
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------------ 数据

  /// 一条会话的**摘要**：最后一条可见消息的开头。
  ///
  /// 只取正文第一行、压掉换行和多余空格，再按字符数截断 —— 抽屉里
  /// 一行只有约 200px，中文大概 16 个字。截断用**字符**而不是 `maxLines`
  /// 加省略号：`TextOverflow.ellipsis` 在两端对齐的行里也能用，
  /// 但先截到 40 字能让测量更省（一长段代码不会每次都参与排版）。
  ///
  /// 优先用户自己说的话（`user`），没有才退到 AI 的 —— 用户是靠
  /// "我当时问了什么"认对话的。
  static String _snippetOf(Conversation c) {
    String pick(Role role) {
      for (int i = c.messages.length - 1; i >= 0; i--) {
        final ChatMessage m = c.messages[i];
        if (m.hidden || m.role != role) continue;
        final String t = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isNotEmpty) return t;
      }
      return '';
    }

    String text = pick(Role.user);
    if (text.isEmpty) text = pick(Role.assistant);
    if (text.isEmpty) {
      // 只有附件、没有文字的消息：说清楚它是什么，而不是留一行空白。
      final ChatMessage? last = c.messages.isEmpty ? null : c.messages.last;
      final int n = last?.attachments.length ?? 0;
      if (n > 0) return '[$n 个附件]';
      return '暂无内容';
    }
    // 40 个字符已经很宽（抽屉 0.86 屏，一行约 16 个汉字）——
    // 多留一些给 `ellipsis` 自己裁，字号偏小时也能填满。
    return text.length > 40 ? '${text.substring(0, 40)}…' : text;
  }

  /// 历史分组：置顶永远在最前，其余按"今天 / 昨天 / 更早"。
  ///
  /// 为什么不按"最近 7 天 / 30 天"分：这个抽屉是**短会话列表**，
  /// 三档已经够定位，段太多反而每一段只有一两条，像被切碎。
  List<_HistoryGroup> _groupHistory(List<Conversation> items) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final List<Conversation> pinned = <Conversation>[];
    final List<Conversation> todayList = <Conversation>[];
    final List<Conversation> yesterday = <Conversation>[];
    final List<Conversation> older = <Conversation>[];
    for (final Conversation c in items) {
      if (c.pinned) {
        pinned.add(c);
        continue;
      }
      final DateTime day = DateTime(
        c.updatedAt.year,
        c.updatedAt.month,
        c.updatedAt.day,
      );
      final int diff = today.difference(day).inDays;
      if (diff <= 0) {
        todayList.add(c);
      } else if (diff == 1) {
        yesterday.add(c);
      } else {
        older.add(c);
      }
    }
    return <_HistoryGroup>[
      if (pinned.isNotEmpty) _HistoryGroup('置顶', pinned),
      if (todayList.isNotEmpty) _HistoryGroup('今天', todayList),
      if (yesterday.isNotEmpty) _HistoryGroup('昨天', yesterday),
      if (older.isNotEmpty) _HistoryGroup('更早', older),
    ];
  }

  /// 分组小标题：比正文小一档、全大写式的字距，读起来是"分隔"不是"条目"。
  Widget _groupLabel(AppSurface s, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 10, 16, 4),
      child: Text(
        label,
        style: AppFonts.body(
          size: 11,
          weight: FontWeight.w600,
          color: s.muted.withValues(alpha: 0.85),
          letterSpacing: 0.4,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 历史列表里的一个分组（「置顶」「今天」…）。
class _HistoryGroup {
  const _HistoryGroup(this.label, this.items);
  final String label;
  final List<Conversation> items;
}
