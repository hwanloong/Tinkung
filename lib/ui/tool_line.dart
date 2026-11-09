import 'dart:convert';

import 'package:flutter/material.dart';

import 'working_pulse.dart';

import '../core/file_diff.dart';
import '../core/models.dart';
import '../theme/app_theme.dart';

/// 工具调用的**显示元数据**：图标 + 名字。
///
/// ## 为什么单独一份表
///
/// 需要它的地方不止一处（消息里的工具行、以后的工具统计、终端页的标题），
/// 散在各处写 `switch (name)` 的话，加一个工具就得改好几处，
/// 而且必然漏掉一处（那处会显示成裸的工具名，看起来像 bug）。
///
/// ## 为什么图标要**按语义**挑，而不是每个工具一个花样
///
/// 图标的作用是"扫一眼就知道它动了什么"：
/// shell / python / termux 都是"执行代码"，但它们的**风险面**不同，
/// 所以给了不同的形状（终端、代码、命令行）以便区分；
/// 而文件、笔记、任务这些一眼能分。全都用同一个"扳手"就等于没有图标。
class ToolDisplay {
  const ToolDisplay._();

  /// 返回 (图标, 显示名)。
  static (IconData, String) of(String name) {
    // 自定义插件：名字是用户起的，没法预设图标，统一用扩展图标。
    if (name.startsWith('plugin_') || name.startsWith('mcp_')) {
      return (Icons.extension_outlined, name);
    }

    return switch (name) {
      'run_shell' => (Icons.terminal_rounded, 'shell'),
      'termux' => (Icons.code_rounded, 'termux'),
      'python' => (Icons.data_object_rounded, 'python'),
      'file_op' => (Icons.folder_outlined, '文件'),
      'filesearch' => (Icons.search_rounded, '找文件'),
      'reader' => (Icons.article_outlined, '读文件'),
      'writer' => (Icons.edit_note_rounded, '改文件'),
      'sheller' => (Icons.bolt_rounded, '脚本'),
      'geter' => (Icons.inventory_2_outlined, '对象池'),
      'app_manage' => (Icons.apps_rounded, '应用'),
      'system_settings' => (Icons.settings_outlined, '系统设置'),
      'screen_capture' => (Icons.screenshot_monitor_outlined, '截屏'),
      'web' => (Icons.travel_explore_rounded, '联网搜索'),
      'browser' => (Icons.public_rounded, '浏览器'),
      'read_image' => (Icons.image_outlined, '识图'),
      'generate_image' => (Icons.brush_outlined, '生图'),
      'open_file' => (Icons.open_in_new_rounded, '打开文件'),
      'get_location' => (Icons.my_location_rounded, '定位'),
      'notes' => (Icons.sticky_note_2_outlined, '笔记'),
      'tasks' => (Icons.checklist_rounded, '任务'),
      'memory' => (Icons.psychology_outlined, '记忆'),
      'recall' => (Icons.forum_outlined, '回忆其他对话'),
      'rules' => (Icons.rule_rounded, '规则'),
      // ---- 下面这些以前落到兜底分支，显示成一把扳手 + 裸英文名 ----
      // 「严格标识」的要求是：每个内置工具都有一个看得懂的名字，
      // 不能靠"名字看起来像什么"去猜。
      'ui_tree' => (Icons.account_tree_outlined, '控件树'),
      'ui_action' => (Icons.touch_app_outlined, '界面操作'),
      'draw_path' => (Icons.gesture_rounded, '画路径'),
      'interact' => (Icons.smart_button_outlined, '互动面板'),
      'change_think' => (Icons.auto_fix_high_outlined, '框选修改'),
      'knowledge' => (Icons.menu_book_outlined, '知识库'),
      'learn' => (Icons.school_outlined, '学习'),
      'plugin' => (Icons.extension_outlined, '插件'),
      'tool' => (Icons.handyman_outlined, '工具集'),
      'pc' => (Icons.computer_rounded, '电脑'),
      'workspace' => (Icons.work_outline_rounded, '工作空间'),
      'request_unlock' => (Icons.lock_open_rounded, '解锁验证'),
      'notify_user' => (Icons.notifications_active_outlined, '通知用户'),
      'model_manager' => (Icons.tune_rounded, '模型管理'),
      'mark' => (Icons.highlight_alt_rounded, '标记'),
      _ => (Icons.build_outlined, name),
    };
  }
}

/// 工具调用那一行的**固定行高**。
///
/// ## 为什么需要一个共享常量
///
/// 思考行（`_ThinkingCard`）和工具行**在聊天里上下相邻**，用户是一列扫过去的。
/// 之前两边各自写布局（思考行用默认 Row 高度，工具行另一个高度），
/// 于是两行的图标**不在同一条水平线上** —— 单独看每一行都正常，
/// 连着看就明显歪。
///
/// 钉死成同一个值之后，两行的居中基准完全一致，
/// 也不依赖字体度量（ascent/descent 差多少都不影响）。
const double kToolRowHeight = 26;

/// 图标相对文字中心的**下移补偿**，按字形分别标定（逻辑像素）。
///
/// ## 为什么不能只用一个常数
///
/// 同一个 `ToolRow`、同一个布局，图标和文字的**墨迹中心并不同高**：
/// 行高 26 里，文字的行盒只有 20 高（从 3 起），基线又落在行盒的
/// 76%~80% 处 —— 也就是整行字**往下沉**；而图标字形的墨迹在 15×15 的
/// 方框里是**居中**的。单独看图标、单独看文字都正常，摆在一行里就是
/// "图标比文字高"。
///
/// 高多少**取决于旁边那行字，不取决于图标**。实测（同一套样式、
/// 同一行高，只换标签）三个档位：
///
///   · 纯中文标签（终端 / 文件）      墨迹中心 **13.2**
///   · 小写拉丁标签（shell / browser） 墨迹中心 **14.3**
///   · 带下伸部的拉丁标签（python）    墨迹中心 **15.5**
///
/// 三者相差 2.3，比任何图标字形自身的偏移都大（见下一条）。所以这张表
/// 实质是"字形 → 它在 [ToolDisplay] 里对应的那个标签"的补偿：每个工具
/// 只对应一个标签，按字形查等价于按标签查。真按"家族统一值"给，就必然
/// 有一半的行是歪的（用户报的 python / termux 那两行就是）。
///
/// ## 这些数字怎么来的（逐个字形量的，不是估的）
///
/// 把每个字形单独放进**真实的 `ToolRow`**（白底黑字、`Icon(size: 15)`、
/// 旁边就是它真正的标签、`devicePixelRatio` 3）渲染出来，逐像素求
/// "图标墨迹包围盒中心"和"文字墨迹包围盒中心"的差值。两条结论：
///
///  · **图标这一侧几乎不用补**：24 个字形里 17 个的墨迹中心正好落在
///    方框中心（偏差 0.0），其余都在 ±0.33 以内，偏得最多的
///    `checklist_rounded` 也只有 0.33；
///  · **要补的是文字**：就是上面 13.2 / 14.3 / 15.5 那组数。
///
/// ## 复现时的一个坑：拉丁标签必须真的走 SF
///
/// 文字往下沉的根子是 SF 自己的 ascent/descent（1950 / -494，em 2048），
/// 基线因此落在行盒的 **79.8%**。`flutter test` 里 `sans-serif` 是替身
/// CJK 字体的族名（ascent 1.06 em，见 test/preview_fonts.dart），行盒被它
/// 撑高、**拉丁行整体上移约 1.0**（中文标签不受影响，它本来就全走 CJK 字体）。
/// 所以量之前得确认拉丁字形来自 SF，否则 python 这一档会少算 1.0
/// （1.5 而不是 2.5，就量不出用户看到的那 2px 歪）。
///
/// ## 和旧版（统一 1.3、其余兜底 0.5）差在哪
///
/// 旧值里**只有终端那一个数是量过的**，其余是从它身上套的。实测：
///  · `terminal_rounded` 配 `shell` 要 1.33 → **1.3 准，保留**；
///  · `code_rounded` 配 `termux` 要 1.67 → 旧值 **少 0.4**；
///  · `data_object_rounded` 配 `python` 要 **2.50** → 旧值 0.5 **少 2.0**，
///    这就是"python 的图标和文字没对齐"；termux 同理，只是差得少一半；
///  · `psychology_outlined`（记忆 / 思考）要 0.33 → 旧值 1.2 **多 0.9**，
///    那一行原来是图标偏低而不是偏高。
///
/// 没量过的字形用 [kToolIconNudgeUnknown]（0.5：比纯中文该有的 0.2 略多，
/// 在"新加了个工具但忘了量"时是最不容易离谱的一档）。
const double kToolIconNudgeUnknown = 0.5;

/// 量过的字形 → 下移补偿。查不到的字形用 [kToolIconNudgeUnknown]。
///
/// 每条后面的两个数是量到的**文字墨迹中心 / 图标墨迹中心**（逻辑像素，
/// 从行顶 0 开始算），差值就是表里的值，四舍五入到 0.1。
///
/// **不是 const**：`IconData.hashCode` 不能用常量求值（`const Map` 拿它
/// 当键会编译失败），所以退一步用 `final` —— 一样只建一次。
final Map<IconData, double> _kIconNudge = <IconData, double>{
  // ---- 终端家族：都是"执行代码"，但标签不同，补偿能差到 1.2 ----
  // 这一组正是"家族统一值"不成立的地方：三个字形自己的墨迹都在 13.00，
  // 差别全在标签上（shell 没有下伸部，termux 有一点点，python 有 p/y）。
  Icons.terminal_rounded: 1.3, // shell  14.33 / 13.00
  Icons.code_rounded: 1.7, // termux 14.67 / 13.00（旧值 1.3，少 0.4）
  Icons.data_object_rounded: 2.5, // python 15.50 / 13.00（旧值 0.5，少 2.0）
  // ---- 纯中文标签：中文墨迹在行盒里几乎是居中的，补 0.2 就够 ----
  Icons.folder_outlined: 0.2, // 文件    13.17 / 13.00
  Icons.apps_rounded: 0.2, // 应用    13.17 / 13.00
  Icons.settings_outlined: 0.2, // 系统设置 13.17 / 13.00
  Icons.travel_explore_rounded: 0.2, // 联网搜索 13.17 / 13.00（旧值 0.4）
  Icons.public_rounded: 0.2, // 浏览器  13.17 / 13.00（旧值 0.4）
  Icons.movie_outlined: 0.2, // 生视频  13.17 / 13.00
  Icons.my_location_rounded: 0.2, // 定位    13.17 / 13.00
  Icons.sticky_note_2_outlined: 0.2, // 笔记    13.00 / 12.83
  Icons.rule_rounded: 0.2, // 规则    13.17 / 13.00
  Icons.psychology: 0.2, // 记忆    13.17 / 13.00（实心脑，暂时没处用，量了备用）
  // ---- 系统层能力（filesearch / reader / sheller / geter）----
  // 标签都是纯中文，按上面的档位本该是 0.2；`search_rounded` 例外 ——
  // 它的字形自己墨迹偏上，要多补一点。
  Icons.search_rounded: 0.6, // 找文件
  Icons.article_outlined: 0.2, // 读文件
  Icons.edit_note_rounded: 0.2, // 改文件（字形墨迹居中，纯中文标签）
  Icons.inventory_2_outlined: 0.2, // 对象池
  // sheller 的标签是"脚本"（纯中文），和 run_shell 的 "shell" 不同档，
  // 所以**不能**复用 `terminal_rounded` —— 那张表是按"字形 + 标签"查的，
  // 同一个字形配两种标签就必须有一边是歪的。这里改用闪电，语义是"跑"。
  Icons.bolt_rounded: 0.2, // 脚本
  // ---- 中文标签，但字形自己的墨迹偏上 0.17~0.33，所以多补一点 ----
  Icons.screenshot_monitor_outlined: 0.3, // 截屏    13.17 / 12.83
  Icons.brush_outlined: 0.3, // 生图    13.33 / 13.00
  Icons.open_in_new_rounded: 0.3, // 打开文件 13.17 / 12.83
  Icons.image_outlined: 0.5, // 识图    13.33 / 12.83
  Icons.checklist_rounded: 0.5, // 任务    13.17 / 12.67（字形偏上最多的一枚）
  // 脑图标两个用法：工具行「记忆」文字中心 13.17；思考行「思考」13.33、
  // 「思考 · 摘要」13.00（字号 12.2 / w400 / 行距 1.3，行盒 18 高）。
  // 图标自己 12.83 → 该补 0.17~0.50，取中间 0.3，两个用法都不超过 0.2。
  Icons.psychology_outlined: 0.3, // 记忆 13.17、思考 13.00~13.33 / 12.83
  // ---- 标签是用户起的名字：plugin_* / mcp_* / 表里没有的工具 ----
  // 名字是工具名，小写 ASCII 且常带下划线（下伸部很长），墨迹中心被压到
  // 15.0 以上 —— 这是整张表里最大的一档，兜底给 0.5 会明显偏高。
  Icons.extension_outlined: 2.3, // plugin_x     15.50 / 13.17
  Icons.build_outlined: 2.0, // unknown_tool 15.00 / 13.00
  // ---- 工具组的组头 / 整场折叠行（见 tool_steps.dart）----
  // 文字是"执行了 3 步"这种中文 + 数字混排，行盒比纯中文高 1（21 对 20），
  // 墨迹中心因此落到 13.83。三个字形自己的墨迹都在 13.00。
  Icons.check_circle_outline_rounded: 0.8, // 13.83 / 13.00（旧值 0.5，少 0.3）
  Icons.error_outline_rounded: 0.8, // 13.83 / 13.00
  Icons.autorenew_rounded: 0.8, // 13.83 / 13.00
};

/// 查一次这个字形该下移多少。见 [kToolIconNudgeUnknown] 的说明。
double toolIconNudge(IconData icon) =>
    _kIconNudge[icon] ?? kToolIconNudgeUnknown;

/// 把图标和一行文字对齐好的 Row。
///
/// 聊天里**所有**"图标 + 文字 + 可选箭头"的行都用它：
/// 工具调用、思考摘要、以及以后的任何一行。共用同一个布局，
/// 列对齐才是必然的，而不是靠两边各自调参数调出来的。
class ToolRow extends StatelessWidget {
  const ToolRow({
    super.key,
    required this.icon,
    required this.child,
    this.trailing,
    this.iconGap = 7,
    this.iconNudge = kToolIconNudgeUnknown,
  });

  /// 左边的图标/指示器
  final Widget icon;

  /// 中间的内容（通常是 Text，也可以是带基线的 Row）
  final Widget child;

  /// 右边的箭头之类
  final Widget? trailing;

  final double iconGap;

  /// 图标要往下挪多少（见 [toolIconNudge]）。
  ///
  /// **由调用方按自己的字形查表传进来**，而不是在这里统一写死：
  /// 这个 Row 拿到的是 `Widget`（有时是转圈，不是图标），看不出是哪个字形。
  /// 传进来的不对齐，整列就会一高一低。
  final double iconNudge;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kToolRowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // 图标下移一点点，抵消它字形自身的上偏。
          // 数值由调用方查表给出（见 [toolIconNudge]）—— 都是量出来的。
          Transform.translate(offset: Offset(0, iconNudge), child: icon),
          SizedBox(width: iconGap),
          Expanded(child: child),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// 工具调用的一行式显示。
///
/// ## 结构（所有工具统一成这一种）
///
/// ```
/// [图标]  工具名  内容摘要 ………… ˅
/// ```
///
/// 三个元素的分工：
///  · **图标** = 一眼看出它动了什么（终端 / 文件 / 网络 / 应用…）；
///  · **工具名** = 到底调的是哪个（`python` 和 `termux` 都能执行代码，
///    但风险面不同，必须能分）；
///  · **摘要** = 这次具体干了什么（命令原文、查询词、文件路径）。
///
/// 展开符号固定在**最右边**：它是"这里可以点"的唯一提示，
/// 跟着文字跑的话，长短不一的摘要会让它每次都在不同位置，
/// 扫一列下来找不到规律。
///
/// ## 为什么默认折叠
///
/// 展开会显示参数 JSON 和完整输出，一次对话里几个工具调用就能占满屏幕，
/// 正文（模型真正说的话）反而被挤到看不见。而多数时候用户只想知道
/// "它干了什么"，不是"它的 JSON 长什么样"。
class ToolLine extends StatefulWidget {
  const ToolLine({super.key, required this.invocation});

  final ToolInvocation invocation;

  @override
  State<ToolLine> createState() => _ToolLineState();
}

class _ToolLineState extends State<ToolLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final ToolInvocation inv = widget.invocation;
    final AppSurface s = AppSurface.of(context);
    final (IconData icon, String label) = ToolDisplay.of(inv.name);

    return Padding(
      // 上下留白**必须对称**（各 5）。
      //
      // 原来是 `bottom: 5` 而展开时 `_detail` 又有 `top: 7, bottom: 9` ——
      // 三个数各不相同，于是相邻两条工具行之间、以及最后一条和下面的
      // 正文之间，间距全都不一样。用户看到的"没对齐"就是这么来的：
      // 单独看每一行都正常，连着几行就明显疏密不匀。
      //
      // 这里的 5 是"行间呼吸"，展开详情自己再补自己的上边距。
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            // 用共享的 [ToolRow]：和思考行同一套布局、同一个行高，
            // 两行的图标才会落在同一条水平线上。
            child: ToolRow(
              // 执行中的指示器现在就是**这个工具自己的图标**在呼吸，
              // 所以补偿和静止态一样按字形查表（原来传 0 是给转圈用的）。
              iconNudge: toolIconNudge(icon),
              icon: _icon(icon, inv),
              trailing: AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 17,
                  color: s.muted,
                ),
              ),
              // 名称 + 摘要在同一套基线里 —— 名称是粗体、摘要更淡，
              // 两者必须落在同一条基线上，否则"一样大的字却没对齐"
              // 会非常显眼。
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Text(
                    label,
                    style: AppFonts.body(
                      size: 13,
                      weight: FontWeight.w600,
                      color: AppColors.accent,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 摘要占满中间，长了自己省略
                  Expanded(
                    child: Text(
                      _ToolLineState.summaryOf(inv),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 13,
                        color: s.muted,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ---- writer 的改动片段 ----
          //
          // 直接画在工具行**下面**，不用点开。理由：思考链的作用是"看它
          // 到底动了什么"，而一次改文件最该被看见的就是那几行。
          // 换成"点开才看得到"之后，用户得先怀疑它改错了，才会去点 ——
          // 而发现改错的最佳时机是**它刚改完**。
          //
          // 只显示前几行：完整差异仍然是点开（_detail）或差异卡片里的，
          // 这里要的是"一眼看出改了哪儿"，不是一份 diff 报告。
          if (inv.name == 'writer' &&
              inv.status != InvocationStatus.running &&
              inv.changes.isNotEmpty)
            _writerDiff(context, inv),
          if (_open) _detail(context, inv),
        ],
      ),
    );
  }

  /// writer 改完之后贴在行下面的那几行增删。
  Widget _writerDiff(BuildContext context, ToolInvocation inv) {
    final AppSurface s = AppSurface.of(context);
    final FileChange change = inv.changes.first;

    // 只取有内容变化的行，跳过间隔标记
    final List<DiffLine> shown = change.lines
        .where((DiffLine l) => l.kind != DiffKind.skip)
        .toList();
    if (shown.isEmpty) return const SizedBox.shrink();

    const int cap = 8;
    final bool more = shown.length > cap;

    return Padding(
      // 左缩进 = 图标宽 15 + gap 7，让片段和**工具名**对齐 ——
      // 和图标对齐会让它看起来是另一行工具的图标，而不是这条的补充。
      padding: const EdgeInsets.only(left: 22, top: 2, bottom: 2),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        decoration: BoxDecoration(
          color: s.codeBg,
          borderRadius: BorderRadius.circular(AppRadius.code),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final DiffLine l in shown.take(cap))
              Text(
                '${switch (l.kind) {
                  DiffKind.added => '+',
                  DiffKind.removed => '-',
                  _ => ' ',
                }} ${l.text}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.code(
                  size: 11.5,
                  height: 1.45,
                  color: switch (l.kind) {
                    // 绿/红用 AppColors 里的语义色，但压到 0.9 透明度的
                    // 深色版：代码片段是小字，纯饱和色在上面读不清。
                    DiffKind.added => AppColors.success,
                    DiffKind.removed => AppColors.danger,
                    _ => s.muted,
                  },
                ),
              ),
            if (more)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '还有 ${shown.length - cap} 行改动，点这一行展开',
                  style: AppFonts.body(size: 11, color: s.muted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 图标 + 状态色。
  ///
  /// 六种状态要一眼可分：
  ///  · 呼吸 = 正在执行
  ///  · 红 = 失败 / 危险操作
  ///  · 灰 = 被拒绝
  ///  · 绿 / 琥珀 = 只读自动执行 / 需要确认
  ///
  /// **失败时用红色覆盖原本的安全色** —— 出错了还显示绿色会误导。
  Widget _icon(IconData icon, ToolInvocation inv) {
    if (inv.status == InvocationStatus.running) {
      // 用这个工具**自己的图标**呼吸：执行中和执行完是同一个形状，
      // 只有动画停下，比换成一个通用加载符号更容易跟住是哪一行在跑。
      return WorkingPulse(size: 15, icon: icon, color: AppColors.accent);
    }

    final Color color = switch (inv.status) {
      InvocationStatus.failed => AppColors.danger,
      InvocationStatus.rejected => AppColors.neutral,
      _ => switch (inv.risk.level) {
        RiskLevel.safe => AppColors.success,
        RiskLevel.caution => AppColors.warning,
        RiskLevel.dangerous => AppColors.danger,
      },
    };

    return Icon(icon, size: 15, color: color);
  }

  // ------------------------------------------------------------ 摘要文本

  /// 从参数里挑出最有信息量的那一项做摘要。
  ///
  /// 按优先级找，而不是把整个 JSON 打出来 ——
  /// 一行里能显示的字很少，`{"action":"search","query":"x","limit":5}`
  /// 这种原文对用户毫无意义。
  /// （实现见文件末尾的 [toolCallSummary]：极简状态行也要用同一套取法。）
  static String summaryOf(ToolInvocation inv) {
    final Map<String, dynamic> a = inv.args;
    String? pick(List<String> keys) {
      for (final String k in keys) {
        final dynamic v = a[k];
        if (v == null) continue;
        final String s = v.toString().trim();
        if (s.isNotEmpty && s != 'null') return s;
      }
      return null;
    }

    final String? action = pick(<String>['action']);
    final String? main = pick(<String>[
      'command',
      'query',
      'url',
      'path',
      'src',
      'title',
      'package',
      'keyword',
      'prompt',
      'id',
    ]);

    final StringBuffer sb = StringBuffer();
    if (action != null) sb.write('$action ');
    if (main != null) {
      sb.write(main);
    } else if (a.isNotEmpty) {
      // 兜底：所有值拼起来，但截断
      final String joined = a.values
          .map((dynamic v) => v.toString())
          .where((String s) => s.trim().isNotEmpty)
          .join(' ');
      sb.write(joined);
    }

    final String text = sb.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '（无参数）';
    return text.length > 160 ? text.substring(0, 160) : text;
  }

  // ------------------------------------------------------------ 展开详情

  Widget _detail(BuildContext context, ToolInvocation inv) {
    final AppSurface s = AppSurface.of(context);

    return Padding(
      // 左边距 = 图标宽 + 间距，让详情**和工具名对齐**（而不是和图标对齐）——
      // 缩进到图标下方会让详情看起来比标题低一级，读起来乱。
      padding: const EdgeInsets.only(top: 7, bottom: 9, left: 23),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 风险原因（只有需要确认/危险时才有内容）
          if (inv.risk.reasons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                inv.risk.reasons.join('；'),
                style: AppFonts.body(
                  size: 11.5,
                  color: inv.risk.level == RiskLevel.dangerous
                      ? AppColors.danger
                      : s.muted,
                  height: 1.5,
                ),
              ),
            ),

          // 完整参数
          _box(s, '参数', const JsonEncoder.withIndent('  ').convert(inv.args)),

          if (inv.output != null && inv.output!.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            _box(s, '输出', inv.output!),
          ],
        ],
      ),
    );
  }

  Widget _box(AppSurface s, String label, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: AppFonts.body(size: 10.5, color: s.muted, height: 1.3),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: ShapeDecoration(
            color: s.codeBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.code),
            ),
          ),
          // 可选中：工具输出经常要复制去别处用（报错、路径、ID）。
          child: SelectableText(
            text.length > 4000 ? text.substring(0, 4000) : text,
            style: AppFonts.code(size: 11.5, color: s.text, height: 1.5),
          ),
        ),
      ],
    );
  }
}

/// 一条工具调用的**一行式摘要**（没有 JSON、按优先级挑最像"它在干什么"的值）。
///
/// 公开出来是给「极简过程」那行状态用的：它只显示一句
/// 「正在调用工具 · 联网搜索『今天的汇率』」，不可能展开看参数，
/// 所以要的那一点点信息必须和工具行取的是**同一套** ——
/// 两处各写一份，迟早会出现"工具行写的是查询词、状态行写的是 action"。
String toolCallSummary(ToolInvocation inv) => _ToolLineState.summaryOf(inv);
