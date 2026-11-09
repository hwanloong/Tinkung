import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/folder_tool.dart';
import '../core/platform_files.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';
import 'ios_switch.dart';
import 'widgets.dart';

/// **工具图标的唯一尺寸**：22。
///
/// ## 为什么必须是一个常量，而不是各处自己写
///
/// 图标有两种形态：`tool.icon` 解码出来的**图片**，和默认的**文件夹字形**。
/// 两者的尺寸来源完全不同（图片按容器裁，字形按字号画）。不给一个共同的
/// 正方形框，一行的行高就会随"这个工具有没有图标"变来变去 ——
/// 列表往下滚的时候整排上下抖，很难看，而且很难归因。
///
/// 22 是这里的最优解：列表行的字号是 14.5/12.2，22 的图标正好和两行文字
/// 的视觉高度相称；再大（24+）行会显得胖，再小（18）图标就看不清细节。
const double kToolIconSize = 22;

/// 工具的图标：有 `tool.icon` 就显示它，没有（或读不出来）就是默认文件夹字形。
///
/// ## 为什么做成一个公共组件
///
/// 图标出现在**列表行、详情页、`@` 面板**三处。三处各写一遍的话，
/// "图片盒"和"字形盒"的尺寸迟早会写岔，表现就是某处的行高比别处高 2px
/// —— 那种 2px 最难查也最刺眼。统一走这里，尺寸只有 [kToolIconSize] 一个来源。
///
/// ## 坏图标不能变成红叉
///
/// `tool.icon` 是用户/agent 手动放进文件夹的文件：可能是空文件、可能是改了
/// 扩展名的东西、也可能是拷到一半中断的文件。`Image.file` 解码失败时会调
/// [errorBuilder]，那里直接回退到**同一个**默认字形 —— 界面上看起来就是
/// "这个工具没有图标"，不会出现红叉或者一块报错文本，更不会抛异常炸掉整页。
class ToolIcon extends StatelessWidget {
  const ToolIcon({
    super.key,
    required this.tool,
    this.size = kToolIconSize,
    this.color,
  });

  final FolderTool tool;

  /// 边长。默认 [kToolIconSize]，**别处不要传别的值**。
  final double size;

  /// 默认字形的颜色。不给就按"启用 = 强调色、停用 = 次要文字"。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final Color tint = color ?? (tool.enabled ? AppColors.accent : s.muted);
    final Widget fallback = Icon(
      Icons.folder_outlined,
      size: size,
      color: tint,
    );

    // 两个分支的盒子**完全一样**（边长为 size 的正方形）—— 行不抖全靠这一点。
    return SizedBox(
      width: size,
      height: size,
      child: tool.hasIcon
          ? ClipRRect(
              // 22 的方图配 5（= AppRadius.code 的一半）：再圆就成头像了
              borderRadius: BorderRadius.circular(AppRadius.code / 2),
              child: Image.file(
                File(tool.iconPath),
                width: size,
                height: size,
                fit: BoxFit.cover,
                // 只在**解码阶段**把图缩到盒子的 3 倍（够 3x 屏用）。
                // 不写这两行的话，一张 2000×2000 的图标会被整张解码成
                // 16 MB 的位图，只为了画 22pt —— 列表里几个工具就是上百 MB。
                cacheWidth: (size * 3).round(),
                cacheHeight: (size * 3).round(),
                // 解码失败 → 同一个字形，不抛红错
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    fallback,
                // 图标是磁盘上的小图，不需要淡入动画
                gaplessPlayback: true,
              ),
            )
          : fallback,
    );
  }
}

/// **工具（Tool）列表** —— 文件夹式浏览的第一级。
///
/// ## 为什么做成文件夹的样子
///
/// 一个 Tool 就是磁盘上的一个文件夹：`tool.md` 是主体（做法说明），
/// 旁边可以有脚本、模板、参考文件。做成"列表 + 详情 + 编辑器"
/// 三层，是为了让用户**看得见里面到底有什么** ——
/// 一个只有一段说明的抽象"技能"，用户没法判断它靠不靠谱；
/// 而看到 `scripts/extract.py` 就大概知道它真能跑。
///
/// ## 为什么允许直接在这里改
///
/// 因为这些东西只有用户自己知道该怎么写。做成只读的话，
/// 用户想调一个步骤还得自己去文件管理器里找那个目录
/// —— 而那目录在应用私有空间里，他根本进不去。
class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key});

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final FolderToolStore _store = FolderToolStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
    _store.load();
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<FolderTool> list = _store.tools;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '工具',
            subtitle: '文件夹式的成套做法，模型按需取用',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                tooltip: '新建工具',
                onPressed: () => _create(context),
              ),
              const SizedBox(width: 4),
            ],
          ),
          Expanded(
            // ---- 内置工具排在最前，且**永远存在** ----
            //
            // 它和下面的「文件夹工具」不是同一类东西：
            //  · 由 Dart 实现、随应用走，没有文件夹、没有 tool.md；
            //  · **不能被删除、不能停用**（删了模型就没法请求验证了）；
            //  · **不能被 @ 提及** —— @ 面板只列 FolderToolStore.enabled，
            //    它不在那个集合里，这是结构上的保证，不是靠过滤。
            //
            // 所以列表从 `ListView.separated` 改成显式 children：内置项
            // 要固定在最上面，而不是混进可删除的列表里。
            child: ListView(
              // 左右 16 一条线到底；卡片之间 8；分组之间 14。
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
              children: <Widget>[
                _groupLabel(s, '固定工具'),
                _builtinCard(s),
                const SizedBox(height: 8),
                _notifyCard(s),
                const SizedBox(height: 14),
                _groupLabel(s, '文件夹工具'),
                if (list.isEmpty)
                  _empty(s)
                else
                  for (int i = 0; i < list.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 8),
                    _tile(s, list[i]),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// **固定内置工具**的卡片。
  ///
  /// 三处和下面的文件夹工具刻意不同：
  ///  · 没有开关 —— 关掉它等于把"请求用户验证"这条路堵死；
  ///  · 没有删除 —— 它是应用的一部分，不是用户数据；
  ///  · 带「固定」角标 —— 让人一眼看出"这条不是我能改的"。
  Widget _builtinCard(AppSurface s) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      onTap: () => _showBuiltinInfo(s),
      child: Row(
        children: <Widget>[
          _iconBlock(
            Icon(Icons.lock_outline_rounded, size: 19, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        '请求验证',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 14.5,
                          weight: FontWeight.w600,
                          color: s.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: s.surface,
                        borderRadius: BorderRadius.circular(AppRadius.code / 2),
                        border: Border.all(color: s.border, width: 0.8),
                      ),
                      child: Text(
                        '固定',
                        style: AppFonts.body(size: 10, color: s.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '模型遇到危险操作时，弹出密码 / 指纹验证。'
                  '不支持 @ 提及，也不能删除。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12.5,
                    color: s.muted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'request_unlock · 内置',
                  style: AppFonts.code(size: 10.5, color: s.muted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: s.muted),
        ],
      ),
    );
  }

  /// 内置工具的说明弹窗：为什么不可删、为什么 at 不出来。
  void _showBuiltinInfo(AppSurface s) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: s.pageBg,
        title: Text(
          '请求验证（内置）',
          style: AppFonts.body(
            size: 16,
            weight: FontWeight.w600,
            color: s.text,
          ),
        ),
        content: SingleChildScrollView(
          child: Text(
            '模型判断某一步危险时，会调用 `request_unlock`，'
            '弹出密码 / 指纹 / 面部验证。通过才继续，拒绝就停下。\n\n'
            '• 不能删除：它是应用的一部分，删掉等于堵死"让用户点头"这条路。\n'
            '• 不能 @ 提及：@ 面板只列文件夹工具；这个由模型自己按需调用。\n'
            '• 不能停用：没有开关，因为它不是可选能力。\n\n'
            '它属于**协作式**保险：模型可以不调它。真正的强制在权限系统里'
            '（风险确认 / 全部权限开关），那条不依赖模型是否老实。\n\n'
            '要调整的是「密码与安全」里的保护范围，而不是这里。',
            style: AppFonts.body(size: 13, color: s.text, height: 1.7),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 第二个固定工具：提醒用户。
  ///
  /// 用户把它叫作「插件」：它确实更像插件（往系统里塞一条通知），但实现上
  /// 必须是**内置工具** —— 插件只是提示词片段，模型没法「调用」它。
  /// 所以它和 request_unlock 并排放在固定区。
  Widget _notifyCard(AppSurface s) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      onTap: () => showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          backgroundColor: s.pageBg,
          title: Text(
            '提醒用户（固定）',
            style: AppFonts.body(
              size: 16,
              weight: FontWeight.w600,
              color: s.text,
            ),
          ),
          content: Text(
            '模型调用 `notify_user` 把一条重要提醒推给用户。\n\n'
            '前台 / 后台由系统判断，不是模型猜：\n'
            '• 前台 → 内容进当前会话 + 历史列表红点，不发通知（多余）；\n'
            '• 后台 → 额外发一条系统通知，否则用户根本不知道。\n\n'
            '固定 = 删不掉、@ 不出来、也没有开关。',
            style: AppFonts.body(size: 13, color: s.text, height: 1.7),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      ),
      child: Row(
        children: <Widget>[
          _iconBlock(
            Icon(
              Icons.notifications_active_outlined,
              size: 19,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '提醒用户',
                      style: AppFonts.body(
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: s.text,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: s.surface,
                        borderRadius: BorderRadius.circular(AppRadius.code / 2),
                        border: Border.all(color: s.border, width: 0.8),
                      ),
                      child: Text(
                        '固定',
                        style: AppFonts.body(size: 10, color: s.muted),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '后台发系统通知，会话列表标红点。前台不打扰。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12.5,
                    color: s.muted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'notify_user · 内置',
                  style: AppFonts.code(size: 10.5, color: s.muted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: s.muted),
        ],
      ),
    );
  }

  /// 分组小标题：小号、拉宽字距、只用 `muted` 一个色。
  /// 上下留白比卡片间距（8）明显一档，扫下来就是"这是一组"。
  Widget _groupLabel(AppSurface s, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 8),
      child: Text(
        text,
        style: AppFonts.body(
          size: 11.5,
          weight: FontWeight.w600,
          color: s.muted,
          letterSpacing: 0.8,
          height: 1.2,
        ),
      ),
    );
  }

  /// 卡片左侧的图标块：34×34，accent 14% 底，圆角 [AppRadius.code]。
  ///
  /// 三种卡片（内置 / 提醒 / 文件夹工具）共用一块，尺寸只在这里定义一次 ——
  /// 各写各的话，图标一样大而盒子不一样大，一列扫下来会"抖"。
  Widget _iconBlock(Widget icon) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Center(child: icon),
    );
  }

  Widget _empty(AppSurface s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.folder_copy_outlined, size: 34, color: s.muted),
            const SizedBox(height: 14),
            Text(
              '还没有工具',
              style: AppFonts.body(
                size: 15,
                weight: FontWeight.w600,
                color: s.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '一个工具就是一个文件夹：里面放一个 `tool.md` 写"这件事怎么做"，'
              '旁边可以放脚本、模板、参考文件。\n\n'
              '和「规则」不同 —— 规则是永远生效的约束；'
              '工具是模型觉得相关时才去读的做法。',
              textAlign: TextAlign.center,
              style: AppFonts.body(size: 12.5, color: s.muted, height: 1.7),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => _create(context),
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('新建工具'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(AppSurface s, FolderTool t) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => ToolDetailPage(toolId: t.id),
        ),
      ),
      child: Row(
        children: <Widget>[
          // 尺寸和默认字形由 ToolIcon 统一管，见 [kToolIconSize]；
          // 外面再套一块和内置工具同规格的 34 图标块。
          _iconBlock(ToolIcon(tool: t)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 14.5,
                          weight: FontWeight.w600,
                          color: s.text,
                        ),
                      ),
                    ),
                    if (!t.enabled) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        '已停用',
                        style: AppFonts.body(size: 11, color: s.muted),
                      ),
                    ],
                  ],
                ),
                if (t.description.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    t.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 12.5,
                      color: s.muted,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${t.files.isEmpty ? '1' : t.files.length + 1} 个文件'
                  ' · ${t.id}',
                  style: AppFonts.code(size: 10.5, color: s.muted),
                ),
              ],
            ),
          ),
          IosSwitch(
            value: t.enabled,
            onChanged: (bool v) => _store.setEnabled(t.id, v),
          ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context) async {
    final String? name = await _askText(
      context,
      title: '新建工具',
      hint: '英文名，会成为文件夹名',
      note: '只能用字母、数字、下划线、连字符。',
    );
    if (name == null || name.trim().isEmpty) return;
    final String? err = await _store.create(name.trim());
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(this.context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }
}

/// **工具详情** —— 第二级：这个文件夹里有哪些文件。
class ToolDetailPage extends StatefulWidget {
  const ToolDetailPage({super.key, required this.toolId});

  final String toolId;

  @override
  State<ToolDetailPage> createState() => _ToolDetailPageState();
}

class _ToolDetailPageState extends State<ToolDetailPage> {
  final FolderToolStore _store = FolderToolStore.instance;

  /// 每个附件的大小和"能不能当文本编辑"。
  ///
  /// 为什么缓存而不是在 `build` 里现算：判定文本性要**读文件头**（IO），
  /// 把它放进渲染路径等于每一帧都去碰一次磁盘。这里在页面进来时算一遍，
  /// 文件增删（导入/删除/新建）后由 store 的通知触发重算。
  Map<String, ToolFileStat> _stats = <String, ToolFileStat>{};

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChange);
    _refreshStats();
  }

  @override
  void dispose() {
    _store.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _refreshStats();
  }

  Future<void> _refreshStats() async {
    final FolderTool? t = _store.byId(widget.toolId);
    if (t == null) return;
    final Map<String, ToolFileStat> m = await _store.statFiles(
      t,
      _store.filesOf(t),
    );
    if (!mounted) return;
    setState(() => _stats = m);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final FolderTool? t = _store.byId(widget.toolId);

    if (t == null) {
      return Scaffold(
        backgroundColor: s.pageBg,
        body: Column(
          children: <Widget>[
            AppHeader(
              title: '工具',
              leading: BackButton(
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            const Expanded(child: Center(child: Text('这个工具已经不在了'))),
          ],
        ),
      );
    }

    final List<String> files = _store.filesOf(t);

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: t.title,
            subtitle: t.id,
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.drive_file_rename_outline),
                tooltip: '改名',
                onPressed: () => _rename(t),
              ),
              IconButton(
                icon: const Icon(Icons.note_add_outlined),
                tooltip: '新建文件',
                onPressed: () => _newFile(t),
              ),
              // 和"新建文件"并列，因为它们是同一件事的两种来路：
              // 一个是从空白开始敲，一个是从外面拿进来（脚本/模板/图片）。
              IconButton(
                icon: const Icon(Icons.upload_file_outlined),
                tooltip: '导入文件',
                onPressed: () => _importFile(t),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: '删除工具',
                onPressed: () => _delete(t),
              ),
              const SizedBox(width: 4),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 28),
              children: <Widget>[
                // ---- 身份条：图标 + 到底有多少文件 + 文件夹在哪 ----
                //
                // `AppHeader` 的标题槽只吃字符串，塞不进图标；自己拼一个
                // AppBar 又会让这一页和别的页长歪。所以图标放在头部**正下方** ——
                // 视觉上仍然属于这一屏的头部，而且这一条能同时放下
                // 图标、文件数、真实路径三样东西，比挤在标题行里更宽松。
                //
                // 尺寸走 [kToolIconSize]：和列表行、`@` 面板完全一致，
                // 从列表点进来时图标不会"跳一下变大"。
                SurfaceCard(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: <Widget>[
                      ToolIcon(tool: t),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${files.length} 个文件 · ${t.id}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.code(size: 11.5, color: s.muted),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              t.folderPath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.code(size: 10.5, color: s.muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (t.description.isNotEmpty) ...<Widget>[
                  SurfaceCard(
                    padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
                    child: Text(
                      t.description,
                      style: AppFonts.body(
                        size: 12.5,
                        color: s.muted,
                        height: 1.55,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                // ---- 备注（intro.md）----
                //
                // 单独一块而且是**可点编辑**的：备注是给自己看的，
                // 内容随时会变（踩了新坑、换了依赖），不该逼用户
                // 先在一堆文件里找到 intro.md。
                SurfaceCard(
                  padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
                  onTap: () => _editIntro(t),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.sticky_note_2_outlined,
                            size: 15,
                            color: s.muted,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '备注',
                              style: AppFonts.body(
                                size: 12.5,
                                weight: FontWeight.w600,
                                color: s.text,
                              ),
                            ),
                          ),
                          Text(
                            t.intro.trim().isEmpty ? '写一条' : '编辑',
                            style: AppFonts.body(
                              size: 11.5,
                              color: AppColors.accent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        t.intro.trim().isEmpty
                            ? '这个文件（intro.md）只给你自己看，模型不会读它。'
                                  '写下它从哪来、有哪些坑。'
                            : t.intro.trim(),
                        maxLines: t.intro.trim().isEmpty ? 3 : 6,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 12,
                          color: s.muted,
                          height: 1.55,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                for (final String f in files) ...<Widget>[
                  _fileTile(
                    s,
                    t,
                    f,
                    isManifest: f == FolderToolStore.manifestName,
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileTile(
    AppSurface s,
    FolderTool t,
    String file, {
    required bool isManifest,
  }) {
    final ToolFileStat? st = _stats[file];
    final bool binary = st != null && !st.isText;
    // 非文本文件标出来，用户才明白"点它不会打开编辑器"不是坏了。
    final String sub = isManifest
        ? '主说明文件（正文就是"怎么做"）'
        : st == null || !st.exists
        ? ''
        : binary
        ? '${FolderToolStore.humanSize(st.size)} · 非文本'
        : FolderToolStore.humanSize(st.size);

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
      onTap: () => _openFile(t, file),
      child: Row(
        children: <Widget>[
          Icon(
            isManifest
                ? Icons.description_outlined
                : binary
                ? Icons.data_object
                : Icons.insert_drive_file_outlined,
            size: 18,
            color: isManifest ? AppColors.accent : s.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(file, style: AppFonts.code(size: 12.5, color: s.text)),
                if (sub.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(sub, style: AppFonts.body(size: 11, color: s.muted)),
                ],
              ],
            ),
          ),
          if (!isManifest)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              tooltip: '删除文件',
              onPressed: () async {
                final String? err = await _store.deleteFile(t, file);
                if (!mounted) return;
                if (err != null) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(err)));
                }
              },
            ),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ],
      ),
    );
  }

  /// 打开一个文件：**文本进编辑器，非文本进信息面板**。
  ///
  /// ## 为什么不能一律进编辑器
  ///
  /// 导入进来的可能是任意类型（图片、`tar.gz`、编译好的二进制、字体）。
  /// 编辑器会把整份内容当 UTF-8 读进来，用户看到的是一屏乱码；更糟的是
  /// 他只要按一次"保存"，`writeFile` 就把那份乱码原样写回去 —— 文件就毁了。
  ///
  /// 所以打开前先问**内容**（[FolderToolStore.statFile] 读文件头判断），
  /// 非文本一律换成信息面板。注意这里**不能**只看列表里缓存的 [_stats]：
  /// 列表可能是几分钟前算的，文件在此期间可能已经被换掉了。
  Future<void> _openFile(FolderTool t, String file) async {
    final ToolFileStat st = await _store.statFile(t, file);
    if (!mounted) return;
    if (!st.isText) {
      await _showFileInfo(t, file, st);
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) =>
            ToolFileEditorPage(toolId: t.id, file: file),
      ),
    );
  }

  /// 非文本文件的**信息面板** —— 名字、大小、路径，以及"怎么打开"。
  ///
  /// 为什么不直接把内容显示出来：这里是给用户一个交代，不是浏览器。
  /// 他要的是"这文件是什么、多大、在哪、能拿它怎么办"。
  Future<void> _showFileInfo(FolderTool t, String file, ToolFileStat st) {
    final String path = '${t.folderPath}/$file';
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) {
        final AppSurface s = AppSurface.of(ctx);
        return Container(
          constraints: BoxConstraints(maxHeight: sheetMaxHeight(ctx, 0.7)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 拖动条 + 标题：和应用里其它面板保持一致
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 10),
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
                      '文件信息',
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
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 图片类给一个 44 的小预览。**不**做大图展示：
                          // 这一页是"这文件是什么"，不是看图 —— 何况整张大图
                          // 解码进内存只为看一眼，代价太大（cacheWidth 限住）。
                          if (_looksImage(file)) ...<Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(
                                AppRadius.code,
                              ),
                              child: Image.file(
                                File(path),
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                cacheWidth: 132,
                                errorBuilder:
                                    (BuildContext _, Object _, StackTrace? _) =>
                                        Container(
                                          width: 44,
                                          height: 44,
                                          color: s.codeBg,
                                          child: Icon(
                                            Icons.broken_image_outlined,
                                            size: 18,
                                            color: s.muted,
                                          ),
                                        ),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  file,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppFonts.code(size: 14, color: s.text),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${FolderToolStore.humanSize(st.size)} · 非文本文件',
                                  style: AppFonts.body(
                                    size: 11.5,
                                    color: s.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        path,
                        style: AppFonts.code(size: 10.5, color: s.muted),
                      ),
                      const SizedBox(height: 14),
                      // 说清楚"为什么点开不是编辑器"，否则这页看起来像功能缺失
                      Text(
                        '这个文件不是文本，用编辑器打开只会看到乱码；'
                        '而且一旦保存，乱码会被写回去，原内容就没了。\n\n'
                        '要编辑它，请用「打开方式」交给能处理这种格式的应用；'
                        '要替换它，用右上角的「导入文件」重新导入一个同名文件。',
                        style: AppFonts.body(
                          size: 12,
                          color: s.muted,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final String? err = await PlatformFiles.open(
                                  path,
                                );
                                if (err == null || !ctx.mounted) return;
                                ScaffoldMessenger.of(ctx)
                                    .showSnackBar(SnackBar(content: Text(err)));
                              },
                              child: const Text('打开方式'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Text('知道了'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 这个名字看起来是不是图片（决定信息面板要不要试预览）。
  ///
  /// 只看名字、并且**敢猜**：猜错了 `Image.file` 的 `errorBuilder` 会兜住，
  /// 代价只是面板里多一个坏图占位符；猜错的反面（该预览却不预览）
  /// 是"图标文件看不到长什么样"，那个更让人困惑。
  static bool _looksImage(String name) {
    final String lower = name.toLowerCase();
    // `tool.icon` 没有扩展名，但格式由内容决定，值得一律试一次预览
    if (lower == FolderToolStore.iconName) return true;
    return <String>[
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
      'bmp',
      'svg',
    ].any((String e) => lower.endsWith('.$e'));
  }

  /// **改名**：一次改两样东西 —— 显示名称和标识名。
  ///
  /// ## 为什么放在同一个对话框里
  ///
  /// `title`（显示名，如"合并 PDF"）和 `id`（文件夹名，`@tool:pdf_merge`）
  /// 是同一个东西的两个面向，用户想"改个名字"时通常两样都想动。
  /// 分成两个入口的话，他改完显示名发现 `@` 里还是老名字，还得再找一次。
  ///
  /// ## 为什么标识名要单独警告
  ///
  /// 标识是引用的锚点。改完之后**历史消息里的 `@tool:旧名` 会失效**，
  /// 而那种失效是静默的（解析不到就跳过）。不提示的话，
  /// 用户会以为"引用功能坏了"。
  Future<void> _rename(FolderTool t) async {
    final TextEditingController titleCtl = TextEditingController(text: t.title);
    final TextEditingController idCtl = TextEditingController(text: t.id);

    final bool? ok =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) {
            final AppSurface s = AppSurface.of(ctx);
            return AlertDialog(
              title: const Text('改名'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('显示名称', style: AppFonts.body(size: 12, color: s.muted)),
                  TextField(
                    controller: titleCtl,
                    autofocus: true,
                    style: AppFonts.body(size: 14, color: s.text),
                    decoration: const InputDecoration(hintText: '列表里看到的名称'),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '标识（文件夹名，@ 引用用的那个）',
                    style: AppFonts.body(size: 12, color: s.muted),
                  ),
                  TextField(
                    controller: idCtl,
                    style: AppFonts.code(size: 13.5, color: s.text),
                    decoration: const InputDecoration(hintText: 'pdf_merge'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '改标识**不会**改写历史消息：以前发过的 `@tool:${t.id}` '
                    '会失效（引用不到就跳过）。显示名称随便改，没有副作用。',
                    style: AppFonts.body(size: 11, color: s.muted, height: 1.5),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        ).whenComplete(() {
          titleCtl.dispose();
          idCtl.dispose();
        });

    if (ok != true) return;

    // 先改标识（它可能失败：重名/非法字符），成功再改标题 ——
    // 顺序反了的话，标识失败时标题已经改了，用户会看到"只成功一半"。
    final String newTitle = titleCtl.text.trim();
    final String newId = idCtl.text.trim();

    String? err;
    if (newId != t.id) {
      err = await _store.renameId(t.id, newId);
      if (err != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
        return;
      }
    }

    // 标识改了之后，要用**新的 id** 找工具
    final String effectiveId = newId == t.id ? t.id : newId;
    if (newTitle.isNotEmpty && newTitle != t.title) {
      err = await _store.setTitle(effectiveId, newTitle);
      if (err != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
        return;
      }
    }

    if (!mounted) return;
    setState(() {});
  }

  /// 打开备注编辑器（必要时先创建 `intro.md`）。
  Future<void> _editIntro(FolderTool t) async {
    try {
      await _store.ensureIntro(t);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建备注失败：$e')));
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) =>
            ToolFileEditorPage(toolId: t.id, file: FolderToolStore.introName),
      ),
    );
  }

  /// **导入外来文件** —— 脚本、模板、图片、二进制，什么都能进来。
  ///
  /// ## 为什么用 `file_selector` 的 `openFile()` 而不限类型
  ///
  /// 这个功能存在的理由就是"工具文件夹里常常要放一个从别处拿来的东西"，
  /// 类型事先说不清（可能是 `.sh`、`.xlsx`、`.onnx`、一张参考图）。
  /// 限类型等于把"什么算合法附件"的判断推给用户去猜。
  ///
  /// ## 文件名沿用**原始名字**
  ///
  /// 不生成 `imported_1.bin` 这类名字：工具是给人看、给模型读的文件夹，
  /// 名字本身就是信息（`extract.py` 一看就知道是什么）。重名不静默改名，
  /// 而是先问要不要覆盖 —— 悄悄变成 `extract (1).py` 会让模型引用错文件。
  Future<void> _importFile(FolderTool t) async {
    XFile? picked;
    try {
      picked = await openFile();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开文件选择器失败：$e')));
      return;
    }
    if (picked == null) return; // 用户取消

    // `XFile.name` 是选择器给的**显示名**（不是完整路径）。空名字兜一个底，
    // 否则会撞上"文件名不能为空"。
    final String name = picked.name.trim().isEmpty
        ? 'imported_file'
        : picked.name;

    // 先看大小再读内容：几十上百 MB 的文件不该先整个读进内存再被拒。
    try {
      final int len = await picked.length();
      if (len > FolderToolStore.maxImportBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '文件太大（${FolderToolStore.humanSize(len)}），'
              '单个文件上限 ${FolderToolStore.humanSize(FolderToolStore.maxImportBytes)}。'
              '更大的文件请用文件管理器直接拷进这个文件夹。',
            ),
          ),
        );
        return;
      }
    } catch (_) {
      // 拿不到大小不算失败（有些 provider 不支持），交给下面的读取去报真正的原因
    }

    // 重名**先问**。不能等写的时候再失败：那时用户已经选完文件了，
    // 弹出"已经有同名文件"却不给覆盖的机会，等于让他重来一遍。
    bool overwrite = false;
    if (_store.hasFile(t, name)) {
      if (!mounted) return;
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text('已经有「$name」了'),
          content: Text(
            '替换它之后原来的内容就没了，不能撤销。\n\n'
            '不想覆盖的话点「取消」，然后用「新建文件」建一个别的名字。',
            style: AppFonts.body(
              size: 12.5,
              color: AppSurface.of(ctx).muted,
              height: 1.6,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      overwrite = true;
    }

    final Uint8List bytes;
    try {
      bytes = await picked.readAsBytes();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取文件失败：$e')));
      return;
    }

    final String? err = await _store.importBytes(
      t,
      name,
      bytes,
      overwrite: overwrite,
    );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$err')));
      return;
    }

    // 换掉的如果正好是图标，得清一次图片缓存：`Image.file` 的缓存键**只有路径**，
    // 同名文件换了内容它还会拿旧的解码结果 —— 表现是"导入新图标没反应"。
    if (name.toLowerCase().startsWith(FolderToolStore.iconName)) {
      try {
        await FileImage(File('${t.folderPath}/$name')).evict();
      } catch (_) {}
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          name.toLowerCase().startsWith(FolderToolStore.iconName)
              ? '已导入 $name，它现在是这个工具的图标'
              : '已导入 $name',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _newFile(FolderTool t) async {
    final String? name = await _askText(
      context,
      title: '新建文件',
      hint: '例如 scripts/run.sh',
      note: '只能是工具文件夹内的相对路径，可以用 / 建子目录。',
    );
    if (name == null || name.trim().isEmpty) return;
    final String? err = await _store.createFile(t, name.trim());
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _delete(FolderTool t) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除「${t.title}」？'),
        content: const Text('整个文件夹会被删掉，里面的文件都会没。这个操作不能撤销。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final String? err = await _store.remove(t.id);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      Navigator.of(context).maybePop();
    }
  }
}

/// **文件编辑器** —— 第三级：改某个文件的内容。
///
/// 用等宽字体、保留原始内容：`tool.md` 的 frontmatter 也是可编辑的文本，
/// 格式化或折行都会让它变坏（比如把 `---` 前后的空行吃掉）。
class ToolFileEditorPage extends StatefulWidget {
  const ToolFileEditorPage({
    super.key,
    required this.toolId,
    required this.file,
  });

  final String toolId;
  final String file;

  @override
  State<ToolFileEditorPage> createState() => _ToolFileEditorPageState();
}

class _ToolFileEditorPageState extends State<ToolFileEditorPage> {
  final FolderToolStore _store = FolderToolStore.instance;
  final TextEditingController _text = TextEditingController();

  bool _loading = true;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final FolderTool? t = _store.byId(widget.toolId);
    if (t == null) {
      setState(() {
        _loading = false;
        _error = '工具不存在了';
      });
      return;
    }
    // 兜住"文件在打开前一刻被换成二进制"这种窗口：编辑器一旦显示乱码，
    // 用户按保存就会把乱码写回去 —— 这里干脆不给他进这一页。
    // （正常路径上详情页已经先判过一次，见 `_openFile`。）
    final ToolFileStat stat = await _store.statFile(t, widget.file);
    if (!mounted) return;
    if (!stat.isText) {
      setState(() {
        _loading = false;
        _error =
            '这个文件不是文本，不能在编辑器里改。'
            '回到上一页点它，用「打开方式」交给别的应用。';
      });
      return;
    }
    try {
      final String content = await _store.readFile(t, widget.file);
      if (!mounted) return;
      _text.text = content;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    final FolderTool? t = _store.byId(widget.toolId);
    if (t == null) return;
    try {
      await _store.writeFile(t, widget.file, _text.text);
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool isManifest = widget.file == FolderToolStore.manifestName;

    return PopScope(
      // 有未保存改动时拦一下。文件是用户手写的东西，
      // 误返回丢掉一屏改动比多点一次确认烦人得多。
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        final bool? leave = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: const Text('放弃未保存的修改？'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('继续编辑'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('放弃'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: s.pageBg,
        body: Column(
          children: <Widget>[
            AppHeader(
              title: widget.file,
              subtitle: widget.toolId,
              leading: BackButton(
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: _dirty ? _save : null,
                  child: const Text('保存'),
                ),
                const SizedBox(width: 6),
              ],
            ),
            if (isManifest)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: Text(
                  '上半部分 `---` 包住的是元信息（标题、说明、什么时候用），'
                  '下面是给模型看的"怎么做"。',
                  style: AppFonts.body(size: 11.5, color: s.muted, height: 1.5),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: AppFonts.body(size: 12.5, color: AppColors.danger),
                ),
              ),
            if (_loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            // 读失败/不是文本时**不给编辑器**：留一个空输入框在那儿，
            // 用户随手敲两个字再保存，就把原文件覆盖成那两个字的乱码了。
            else if (_error != null)
              const Expanded(child: SizedBox.shrink())
            else
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 28),
                  child: TextField(
                    controller: _text,
                    maxLines: null,
                    minLines: 18,
                    keyboardType: TextInputType.multiline,
                    onChanged: (_) {
                      if (!_dirty) setState(() => _dirty = true);
                    },
                    style: AppFonts.code(size: 12.5, color: s.text),
                    decoration: InputDecoration(
                      // 代码/说明是**原样文本**，不要边框也不要计数器
                      border: InputBorder.none,
                      isDense: true,
                      hintText: isManifest ? '写"这件事怎么做"' : '文件内容',
                      hintStyle: AppFonts.body(size: 12.5, color: s.muted),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 一个简单的单行输入对话框（新建工具/文件用）。
Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String hint,
  String note = '',
}) {
  final TextEditingController ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) {
      final AppSurface s = AppSurface.of(ctx);
      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: ctl,
              autofocus: true,
              style: AppFonts.code(size: 13.5, color: s.text),
              decoration: InputDecoration(hintText: hint),
              onSubmitted: (String v) => Navigator.of(ctx).pop(v),
            ),
            if (note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                note,
                style: AppFonts.body(size: 11.5, color: s.muted, height: 1.5),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctl.text),
            child: const Text('确定'),
          ),
        ],
      );
    },
  ).whenComplete(ctl.dispose);
}
