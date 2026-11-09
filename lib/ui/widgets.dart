import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/platform_files.dart';
import '../core/file_diff.dart';
import '../core/text_marks.dart';
import '../core/varbank.dart';
import '../tools/chat_alarm_tool.dart';
import '../tools/tool.dart' show ToolArgs;
import 'file_diff_sheet.dart';
import 'improved_prompt.dart';
import 'working_pulse.dart';
import 'shimmer.dart';
import 'image_viewer.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'browser_page.dart';
import 'markdown.dart';
import 'tool_line.dart';
import 'tool_steps.dart';

/// 底部面板的最大高度，**保证不顶到状态栏**。
///
/// ## 为什么需要它
///
/// `showModalBottomSheet(isScrollControlled: true)` 的面板最高能铺满整屏。
/// 内容一长，面板的**标题行就跑到状态栏底下**，和系统的时间、电量叠在一起 ——
/// 既看不清，那一块也点不到（点击会被状态栏吃掉）。
///
/// 这个问题在"列表 + 按钮"型的面板上特别容易犯：模型选择、附件添加、
/// 压缩确认都是这种。所以统一在这里算一次，各面板传自己的比例：
///
/// ```dart
/// maxHeight: sheetMaxHeight(context, 0.8),   // 想最多占八成屏
/// ```
///
/// 返回 `min(屏高 × fraction, 屏高 - 状态栏 - 12)`：
/// 前者是设计意图，后者是硬上限 —— 无论比例给多大，都不会压到状态栏。
double sheetMaxHeight(BuildContext context, double fraction) {
  final MediaQueryData mq = MediaQuery.of(context);
  final double safe = mq.size.height - mq.padding.top - 12;
  return (mq.size.height * fraction).clamp(0.0, safe);
}

/// 渲染一条消息。
///
/// 用户消息是蓝色气泡；**assistant 消息没有气泡**，Markdown 直接平铺在背景上。
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    this.onOpenLink,
    this.onQuote,
    this.onMark,
    this.onUnmark,
    this.onTapQuote,
    this.onRegenerate,
    this.onEdit,
    this.onDelete,
    this.animateIn = false,
    this.onBubbleAnimated,
    this.collapseToolSteps = true,
    this.showToolSteps = true,
    this.minimalProgress = false,
  });

  final ChatMessage message;
  final void Function(String url)? onOpenLink;

  /// 长按选中 → 「引用并回复」。参数是选中的原文。
  final void Function(ChatMessage from, String selected)? onQuote;

  /// 「重新生成」：把这条 AI 回复重跑一遍。
  ///
  /// 走的是**长按选区菜单**（不是自己做长按手势）—— 正文是可选中的文字，
  /// 外层长按识别器在手势竞技场里抢不过它，见 `MarkdownView.onRegenerate`。
  final void Function(ChatMessage from)? onRegenerate;

  /// 「修改」：把这条消息放回输入框，改完重发。
  final void Function(ChatMessage from)? onEdit;

  /// 「删除」：删掉这条消息（确认之后）。
  final void Function(ChatMessage from)? onDelete;

  /// 这条用户消息是不是**刚发出去**：刚发出的气泡做一次入场动画。
  /// 历史消息、滚动重建都不会再播放。
  final bool animateIn;

  /// 入场动画播完，通知页面把 `animateIn` 收回 false。
  final VoidCallback? onBubbleAnimated;

  /// 长按选中 → 某个底色的「标记」。
  final void Function(ChatMessage on, String selected, MarkColor color)? onMark;

  /// 长按选中 → 「取消这段的标记」。
  final void Function(ChatMessage on, String selected)? onUnmark;

  /// 点一下消息顶部那条引用，跳到被引用的原文。
  final void Function(MessageQuote quote)? onTapQuote;

  /// 工具步骤是否折叠成一行。由「性能 → 工具步骤过程」控制。
  final bool collapseToolSteps;

  /// 这条消息下面的**工具过程**要不要画。
  ///
  /// 关掉用在"整场对话的工具调用已经汇总成一行了"的时候（见
  /// [ToolFoldAllRow]）：那一行代表的就是这些东西，这里再画一遍就是重复。
  ///
  /// 注意它和 [collapseToolSteps] 是两件事：后者是"怎么画"（收成一行还是
  /// 逐步平铺），这个是"画不画"。
  final bool showToolSteps;

  /// **极简过程**（「性能 → 极简过程」）。
  ///
  /// 打开后，思考和工具调用**合并成一行状态**：只写「正在思考…」或
  /// 「正在调用工具…」，没有可点的东西、也没有能展开的细节；
  /// 回答结束之后连这一行都不留。
  ///
  /// 和 [collapseToolSteps] 的区别就在这里：折叠仍然保留"点开看"的入口，
  /// 极简是**把入口本身拿掉** —— 想要"只要结果"的人要的是这个。
  final bool minimalProgress;

  @override
  Widget build(BuildContext context) {
    if (message.role == Role.user) {
      return _userBubble(context);
    }
    return _assistantBlock(context);
  }

  /// 消息顶部那条**引用**（"回复了哪句话"）。
  ///
  /// 用户消息和 AI 消息共用 —— AI 目前不会主动引用，但类型上不限制，
  /// 以后让它带引用不用改这里。
  /// 消息顶部那条**引用**（"回复了哪句话"）。
  ///
  /// ## 为什么不是气泡
  ///
  /// 这里一开始做成了带底色的圆角块，和用户消息的气泡在视觉上是同一个
  /// 层级 —— 结果读起来像"两条消息"。但引用**不是**一条消息，
  /// 它是**消息的一个前缀**（"我在回应这句话"）。
  ///
  /// 现在改成"左侧一道竖线 + 平面文字"：这是引文的通用写法，
  /// 层级上明确低于气泡，而且和 markdown 里的 `>` 引用块是同一套语言 ——
  /// 用户已经在正文里见过这种样子，不用重新学。
  ///
  /// 用户消息和 AI 消息共用。
  Widget _quoteCard(BuildContext context, AppSurface s, bool onRight) {
    final MessageQuote q = message.quote!;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(
        top: 6,
        left: onRight ? 44 : 0,
        right: onRight ? 0 : 44,
      ),
      child: GestureDetector(
        onTap: onTapQuote == null ? null : () => onTapQuote!(q),
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 3, 4, 3),
          decoration: BoxDecoration(
            // 竖线的颜色取标记底色 —— 和原文那道虚线锚点是同一个色相，
            // 用户能对上号（"我引的是那段被划线的"）。
            border: Border(
              left: BorderSide(color: q.color.background(dark: dark), width: 3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.format_quote_rounded, size: 13, color: s.muted),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  q.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12.2,
                    color: s.muted,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 气泡正文的左右内距。
  static const double _bubblePadH = 14;

  /// 气泡正文的上下内距。
  ///
  /// 上下**相等**是对的前提 —— 但只有在行盒里的汉字也居中时才成立。
  /// 见 [_bubbleStyle] 和 [_caretReserve]。
  static const double _bubblePadV = 11;

  /// `SelectableText`（内部是 `EditableText`）在文字**右侧**固定预留的空白。
  ///
  /// `RenderEditable` 的宽度是"文字宽度 + `_caretMargin`"，而
  /// `_caretMargin = _kCaretGap(1) + cursorWidth(2) = 3`。这块地方是给
  /// 光标用的 —— 而气泡里的 SelectableText 是只读的，**那 3 像素什么都不画**。
  ///
  /// 后果很具体（dpr=3 逐像素量过）：同一个 14 的内距，左边的墨迹距气泡边
  /// 14.9，右边是 18.7 —— 短气泡上就是"字偏左、右边空着一条"，
  /// 用户说的"字没对齐"有一半是这个。
  ///
  /// 修法只能是**从右边内距里把它扣掉**：这个值算在 `RenderEditable` 内部，
  /// 没有任何参数能让 `SelectableText` 不预留它。`cursorWidth` 是一个能改的
  /// 旋钮（改成 0 就没有这 2 像素），但它同时是光标本身和选区把手的宽度 ——
  /// 为了 3 像素的对齐去改控件的交互几何，是拿行为换外观。
  static const double _caretReserve = 3;

  /// 气泡正文的样式。
  ///
  /// ## 为什么单独抽出来，还要显式写 `leadingDistribution`
  ///
  /// 字号 15 + 行高 1.6（`AppFonts` 还会再乘一次全局行距 1.14，实际 1.824）
  /// 意味着行盒比字形高出很多，多出来的那部分叫 leading。Flutter 默认按
  /// **上下的字体度量比例**分配它（`proportional`），而这个字体的上沿度量
  /// 比下沿大得多（约 1.16 : 0.31 em）—— 于是 leading 里 4/5 落在了字的上面。
  ///
  /// 实测（dpr=3，`好的`）：行盒 28 高，墨迹上方 9.67、下方 4.67，
  /// 也就是**字在行盒里比中线低 2.5 像素**。气泡的上下内距又是对称的，
  /// 于是整句话在气泡里明显偏下 —— 上面空一条、下面贴着边。
  /// 这就是"气泡里的字没有对齐"的另一半。
  ///
  /// `TextLeadingDistribution.even` 把 leading **对半分**（上下各 6.67），
  /// 墨迹正好落回行盒中线（实测 skew 从 2.50 变成 0.00）。
  ///
  /// 为什么不用"把上内距减 2.5、下内距加 2.5"去凑：那个 2.5 是按当前字号
  /// 和当前行高算出来的，用户把字号滑杆动一格它就错了（要跟着字号缩放），
  /// 而 `even` 是排版层面的**定义**，任何字号、任何行高都成立。
  static TextStyle _bubbleStyle(AppSurface s) => AppFonts.body(
    size: 15,
    // 淡底 → 深字。跟着 `onAccent` 走会变白，糊在浅底上看不见。
    color: s.text,
    height: 1.6,
  ).copyWith(leadingDistribution: TextLeadingDistribution.even);

  Widget _userBubble(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6, left: 44),
      child: Align(
        alignment: Alignment.centerRight,
        child: _BubbleEntrance(
          animate: animateIn,
          onDone: onBubbleAnimated,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (message.quote != null) _quoteCard(context, s, true),
              if (message.attachments.isNotEmpty &&
                  message.content.trim().isNotEmpty)
                const SizedBox(height: 2),
              if (message.content.trim().isNotEmpty)
                if (message.varRefs.isNotEmpty)
                  _VarBankBubble(message: message, s: s, onDelete: onDelete)
                else
                  Container(
                    decoration: BoxDecoration(
                      // **淡色气泡。**
                      //
                      // 这里原来是 `AppColors.accent`。当年 accent 是灰色时
                      // 它看着是个温和的深灰块；改成 iOS 之后 accent 变成
                      // 近黑 `#1C1C1E` —— 同样一行代码，在屏幕上成了一整块
                      // 纯黑，又重又压，而且长消息就是一大片黑底。
                      //
                      // iOS 的对话气泡本来就是**浅填充**（iMessage 的灰泡），
                      // 所以改用容器色：浅色模式下是 #EFEFF4，深色模式下是
                      // #2C2C2E，两种亮度下都只是"比底色深一档"，不抢文字。
                      color: s.bubbleBg,
                      // **四边等圆角，没有描边。**
                      //
                      // 参考图里气泡就是一块纯色的圆角块 —— 没有边框。
                      // 有边框时它读起来像"一张卡片"，而气泡要的是
                      // "我打的这段话"，边界靠底色差就够（页面 `#1A1A1A`
                      // 对气泡 `#2E2E2E`，差 20 级，一眼分得开）。
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    // 左边 14、右边 14 - 3：右内距里那 3 像素是 SelectableText
                    // 留给光标的死区（见 [_caretReserve]）。扣掉之后，
                    // 两侧墨迹到气泡边的距离都是 15（差 0.8，是字形本身的侧边距）。
                    padding: const EdgeInsets.fromLTRB(
                      _bubblePadH,
                      _bubblePadV,
                      _bubblePadH - _caretReserve,
                      _bubblePadV,
                    ),
                    child: onDelete == null
                        ? SelectableText(
                            message.content,
                            style: _bubbleStyle(s),
                          )
                        : SelectableText(
                            message.content,
                            style: _bubbleStyle(s),
                            // 用户气泡原本用的是 SelectableText 的默认菜单。
                            // 这里只在**默认项后面**加一条「删除这条消息」，
                            // 复制/全选仍然原样保留。
                            contextMenuBuilder:
                                (BuildContext ctx, EditableTextState state) {
                                  // 自己列菜单项，而不是 `...state.contextMenuButtonItems`：
                                  // 系统默认还带「分享」，四项在窄屏上会翻到第二页，
                                  // 删除就藏到 offstage 里了（用户点不到）。只保留
                                  // 复制 / 全选 / 删除，一屏放得下。
                                  final List<ContextMenuButtonItem> items =
                                      <ContextMenuButtonItem>[
                                        ContextMenuButtonItem(
                                          onPressed: () => state.copySelection(
                                            SelectionChangedCause.toolbar,
                                          ),
                                          label: '复制',
                                        ),
                                        ContextMenuButtonItem(
                                          onPressed: () => state.selectAll(
                                            SelectionChangedCause.toolbar,
                                          ),
                                          label: '全选',
                                        ),
                                        ContextMenuButtonItem(
                                          onPressed: () {
                                            state.hideToolbar();
                                            onDelete!(message);
                                          },
                                          label: '删除',
                                        ),
                                      ];
                                  return AdaptiveTextSelectionToolbar.buttonItems(
                                    anchors: state.contextMenuAnchors,
                                    buttonItems: items,
                                  );
                                },
                          ),
                  ),
              if (message.attachments.isNotEmpty) _attachmentStrip(context, s),
              // 「描述改进」改写过的话，在**原话下面**折叠显示改进版。
              //
              // 为什么折叠而不是直接铺开：用户最关心的是自己说了什么
              // （原话必须在最显眼的位置），而改进版是**实际发给模型的那一段**，
              // 需要时能核对就够。铺开会让每条消息都变长一倍。
              if ((message.improvedPrompt ?? '').trim().isNotEmpty)
                ImprovedPromptBlock(
                  improved: message.improvedPrompt!,
                  original: message.content,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 用户消息里的附件：**一排小胶囊，水平和换行铺开**。
  ///
  /// ## 为什么不再是 150×150 的大图 + 竖排文件行
  ///
  /// 之前图片是一个 150 的缩略图网格（最多 6 张 + "还有 N 张"），文件是
  /// 每行一个的竖排条。问题是"一条消息"里附件只是**注脚** —— 正文才是
  /// 用户要读的东西，而一块 150 的图会把气泡撑得很高，竖排的几行文件
  /// 更是把正文挤到了要滚动的程度。
  ///
  /// 现在和输入框上方那排（待发附件）用**同一个组件**：28 的缩略图 +
  /// 一行文件名，`Wrap` 水平排、放不下就换行。一屏里能塞十几个，
  /// 而且两边长得一样 —— 发出去前后视觉上是连续的，不会"发出去就变样"。
  ///
  /// 图片点开仍是大图（缩略图看不清），这点没变。
  /// 这条消息里**最后一条成功的** `chat_alarm` 调用。
  ///
  /// 取最后一条而不是第一条：模型偶尔会调两次（先挂一条，补充完又调
  /// 一次），后面那次才是它最终想说的。成功的过滤掉失败/被拒的 ——
  /// 用户点了拒绝的那个警告不该显示。
  static ToolInvocation? _latestAlarm(ChatMessage m) {
    for (int i = m.tools.length - 1; i >= 0; i--) {
      final ToolInvocation t = m.tools[i];
      if (t.name != ChatAlarmTool.toolName) continue;
      if (t.status != InvocationStatus.success) continue;
      if (t.args.str('text').trim().isEmpty) continue;
      return t;
    }
    return null;
  }

  /// 风险告示条：**正文下面单独一块**。
  ///
  /// ## 为什么是一个"条"而不是卡片
  ///
  /// 它和正文是**同一个动作的两半**（说了什么 + 要注意什么），所以视觉上
  /// 不能像一个独立的内容块（那会让人以为又是一条消息）。做法是：
  ///  · 左侧一道 3px 的色带 + 浅底 —— 读起来像"给上面那段话加了个边注"；
  ///  · 圆角只用 10，比卡片的 14 小一档，明确低于正文卡片的层级；
  ///  · 没有阴影、没有玻璃。
  ///
  /// ## 三档颜色
  ///
  /// `info` 中性灰、`warning` 橙、`danger` 红。**只有 danger 用红** ——
  /// 医疗提示十有八九是"注意事项"级别，满屏红色会让用户对红色脱敏，
  /// 真正危险的那次就压不住了。
  Widget _alarmCard(BuildContext context, ToolInvocation t) {
    final AppSurface s = AppSurface.of(context);
    final String level = t.args.str('level').trim().toLowerCase();
    final String text = t.args.str('text').trim();
    final String title = t.args.str('title').trim();

    final (Color color, IconData icon, String defaultTitle) = switch (level) {
      'info' => (s.muted, Icons.info_outline_rounded, '提示'),
      'danger' => (AppColors.danger, Icons.dangerous_outlined, '危险'),
      _ => (AppColors.warning, Icons.warning_amber_rounded, '注意'),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: s.isDark ? 0.10 : 0.07),
          borderRadius: BorderRadius.circular(AppRadius.code),
          border: Border(
            left: BorderSide(color: color, width: 3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (title.isNotEmpty || defaultTitle.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        title.isEmpty ? defaultTitle : title,
                        style: AppFonts.body(
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: color,
                          height: 1.3,
                        ),
                      ),
                    ),
                  Text(
                    text,
                    style: AppFonts.body(
                      size: 13,
                      color: s.text,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _attachmentStrip(BuildContext context, AppSurface s) {
    final List<Attachment> web = message.attachments
        .where((Attachment a) => a.isWeb)
        .toList();
    final List<Attachment> rest = message.attachments
        .where((Attachment a) => !a.isWeb)
        .toList();

    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          // 网页附件保留**卡片**：它带抓到的正文预览，那是一块内容，
          // 不是"一个文件"——压成一行名字等于把预览丢了。
          for (final Attachment a in web) _webCard(context, s, a),
          if (rest.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Wrap(
                // 靠右对齐：用户气泡本身贴在右边，附件也跟着那条边。
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final Attachment a in rest)
                    AttachmentChip(
                      attachment: a,
                      onTap: a.isImage
                          ? () => showImageViewer(
                              context,
                              path: a.path,
                              title: a.name,
                            )
                          : null,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 网页附件卡片：标题 + 域名 + 内容预览，可展开、可在内置浏览器打开
  Widget _webCard(BuildContext context, AppSurface s, Attachment a) {
    final int len = a.content.trim().length;
    final String host = _hostOf(a.path);
    final String preview = a.content.trim().isEmpty
        ? '（没有抓到内容，只有链接）'
        : (len > 420 ? a.content.trim().substring(0, 420) : a.content.trim());

    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: SurfaceCard(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.public_rounded, size: 15, color: AppColors.accent),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      a.name.isEmpty ? host : a.name,
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
                ],
              ),
              const SizedBox(height: 3),
              Text(
                host,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.code(size: 11, color: s.muted),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 260),
                decoration: BoxDecoration(
                  color: s.codeBg,
                  borderRadius: BorderRadius.circular(AppRadius.code),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: SingleChildScrollView(
                  child: Text(
                    preview,
                    style: AppFonts.code(size: 11.5, color: s.text),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  if (len > 0)
                    GlassChip(label: '$len 字符', dense: true, color: s.muted),
                  const Spacer(),
                  GlassButton(
                    label: '内嵌预览',
                    icon: Icons.open_in_browser_rounded,
                    fontSize: 12,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    onTap: () =>
                        BrowserPage.open(context, url: a.path, title: a.name),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hostOf(String url) {
    final Uri? u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    return u.host;
  }

  /// 这条回复是不是**还在执行中**（有工具在跑 / 还在思考）。
  ///
  /// 判据：
  ///  · 消息还是 pending，**并且**
  ///  · 有工具调用还没结束（running），或者正文还没出现
  ///
  /// 为什么第二种情况也算：模型先思考、还没开始写正文时，
  /// 屏幕上只该有"思考中"，不该有一块空的正文区。
  static bool _isExecuting(ChatMessage m) {
    if (!m.pending) return false;
    final bool toolRunning = m.tools.any(
      (ToolInvocation t) => t.status == InvocationStatus.running,
    );
    return toolRunning || m.content.trim().isEmpty;
  }

  Widget _assistantBlock(BuildContext context) {
    final List<Widget> children = <Widget>[];
    final List<FileChange> changes = <FileChange>[
      for (final ToolInvocation t in message.tools) ...t.changes,
    ];

    // ---- 思考卡片 ----
    //
    // 两种时机都要它：
    //  · **正在思考**（`pending` 且正文还空着）→ 显示转圈 + "思考中…"；
    //  · **已经想完**（有 reasoning 内容）→ 显示"已思考 12.3 秒 · 深度 深"。
    //
    // ⚠️ 这里曾经出过一个 bug：加了这个卡片，却**没有删掉下面原来那段**
    // "思考中…" 的兜底，于是思考的时候同一条消息上出现两行"思考中…"。
    // 所以下面那段已经被删除，思考状态的显示**只有这一个来源**。
    if (!minimalProgress &&
        (message.reasoning.trim().isNotEmpty ||
            (message.pending && message.content.trim().isEmpty))) {
      children.add(_ThinkingCard(message: message));
    }

    // ---- 正文 ----
    //
    // ## 运行中不显示正文，只显示"当前在干什么"
    //
    // 用户的原话：运行时把所有工具调用、AI 说的"我遇到什么问题"、思考
    // **全部折叠**，只显示当前进程；输出最后结论时才显示正文。
    //
    // 为什么这样对：模型在执行阶段说的东西大多是**过程话**——
    // "我先查一下…""刚才那个命令失败了，我换个方式…"。它们对排查有用，
    // 但对"我想知道结果"是噪音，而且会把真正结论挤到屏幕外面去。
    //
    // 判断条件用 `pending`：它就是"这条回复还没结束"。
    // 结束之后（无论成功还是报错）正文照常显示，一个字符都没丢 ——
    // 只是**晚一点出现**。
    //
    // 例外：如果模型已经给出了正文、而工具还在跑（`pending` 且有内容），
    // 那说明它是一边写一边调工具，这时正文就是结论本身，应该显示。
    final bool showBody =
        message.content.trim().isNotEmpty && !_isExecuting(message);

    if (showBody) {
      // ---- 流式期间**也**渲染 markdown ----
      //
      // 以前这里有个"还在生成且很长（或含公式）就先显示纯文本"的分支。
      // 那个做法的代价正是用户抱怨的：正文先是一堆 `**` `#` `-`，
      // 滚到结尾才突然变成排版好的样子。
      //
      // 真正贵的不是"渲染 markdown"，而是**每帧重排所有块**。
      // 现在 `MarkdownView` 做了**块级 widget 复用**（见那里的
      // `_blockCache`）：流式是追加的，前面已完成的块内容不变，
      // 直接交回同一个 widget 实例，Flutter 会整棵子树跳过更新；
      // 每帧只重新排版**最后一块**。所以这里直接渲染 markdown 即可。
      //
      // 唯一保留的例外是**卡片**：`InAppWebView` 的 `initialData` 只读一次，
      // 流式中途建出来的 WebView 会一直显示半截 HTML，所以流式期间
      // 仍把 `card:` 代码块当普通代码块显示，结束后再切成卡片。
      children.add(
        Padding(
          // 上下留白按"段落"给：AI 正文是平铺的（不是气泡），
          // 它和上一条之间的距离就是阅读节奏。8/4 太挤，14/10
          // 在手机上又会让一屏少显示两句。
          padding: const EdgeInsets.only(top: 12, bottom: 10),
          child: MarkdownView(
            text: message.content,
            baseSize: 15,
            onOpenLink: onOpenLink,
            // 流式期间不渲染卡片。InAppWebView 的 initialData **只在创建时读一次**，
            // 所以流式中途创建的 WebView 拿到的是半截 HTML，之后又不会重载 ——
            // 表现为"卡片不显示，重启应用才出现"。
            // 关掉后，未完成的卡片先显示成代码块，流式结束才切成卡片，
            // 那时 WebView 才第一次创建，拿到的就是完整内容。
            enableCards: !message.pending,
            // 流式期间给最后一块正文加扫光；同时让代码块 / 表格 / 图片
            // 这些"卡片类"块先不渲染，等整条消息结束再一次性出现。
            streaming: message.pending,
            // 标记和引用锚点都盖在这条消息的正文上。
            marks: message.marks,
            onQuote: onQuote == null
                ? null
                : (String sel) => onQuote!(message, sel),
            onMark: onMark == null
                ? null
                : (String sel, MarkColor c) => onMark!(message, sel, c),
            onUnmark: onUnmark == null
                ? null
                : (String sel) => onUnmark!(message, sel),
            // 「重新生成」只对 AI 回复出现 —— 用户消息没有"重跑"的语义。
            // 「修改」反过来只对用户消息出现。
            onRegenerate: onRegenerate == null || message.role != Role.assistant
                ? null
                : () => onRegenerate!(message),
            onEdit: onEdit == null || message.role != Role.user
                ? null
                : () => onEdit!(message),
            onDelete: onDelete == null ? null : () => onDelete!(message),
          ),
        ),
      );

      // 复制按钮。
      //
      // 现在正文**本身可以长按选中**了（`MarkdownView` 内部包了
      // `SelectionArea`），这个按钮仍然留着，因为它解决的是另一个需求：
      // 一键拿到**整段 markdown 源码**。
      //
      // 为什么"选中"和"复制源码"要并存：
      //  · 想引用其中一句话 → 长按选中；
      //  · 想把整段贴到别处继续用 → 要的是**源码**（保留 `##`、`-`、
      //    代码围栏），而选中复制拿到的是渲染后的纯文本，结构全丢了。
      //
      // 流式输出中不显示：复制一段还在增长的内容没有意义。
      if (!message.pending) {
        children.add(_CopyButton(text: message.content));
      }

      // ---- 不再显示"来源"那一行域名 ----
      //
      // 用户明确要求：**聊天页底部不显示网址**。回复里正文本身该怎么写
      // 由模型决定（它想引用哪条来源就在正文里带上），但界面不再在
      // 每条回复下面追加一排灰色域名 —— 那一行既不像正文、又占了
      // 每屏最底下的位置，读起来像"附注"，实际扫一眼又记不住。
      //
      // `message.sources` 字段仍然保留（性能面板按工具调用列出过哪些
      // 网页），只是不再渲染在这里。

      // （署名「图标 + AI Content, Please Double check」**不在这里**：
      //   它由对话页挂在整场对话的末尾，见 ChatPage._messageList。
      //   每条回复后面都盖一个会变成正文之外的一层噪音。）
      // 正文里出现网址时，在下面补一排卡片 ——
      // 一眼能看出是网页还是 API，也能直接点开。
      // 执行中就先把"碰到哪些文件"放出来：用户不用等整轮结束才知道
      // AI 在改什么；路径会随着工具调用逐步补全。
      if (!minimalProgress && message.pending && message.tools.isNotEmpty) {
        final String liveText = <String>[
          for (final ToolInvocation t in message.tools)
            '${t.argumentsJson}\n${t.output ?? ''}',
        ].join('\n');
        children.add(
          GeneratedFiles(text: liveText, live: true, changes: changes),
        );
      }

      if (!message.pending) {
        // 正文里的网址**不再补卡片**：用户要求聊天页底部不要网址。
        // 正文里如果真写了链接，markdown 渲染会把它显示成可点的文字 ——
        // 那属于内容本身，不是界面追加的一块。
        // （LinkCards 类仍保留给别处/将来复用，这里只是不再挂载。）
        // 正文 + 工具调用里提到的**本地文件**收进一张可展开的卡片。
        //
        // 只看正文不够：改文件的是 Python / termux / change_think，
        // 它们产出的路径常常只出现在工具参数或输出里，模型最后一句
        // 未必复述。三种来源合起来，用户才不会"改完找不到文件"。
        final String fileText = <String>[
          message.content,
          for (final ToolInvocation t in message.tools)
            '${t.argumentsJson}\n${t.output ?? ''}',
        ].join('\n');
        if (!minimalProgress) {
          children.add(GeneratedFiles(text: fileText, changes: changes));
        }
      }
    }

    // ---- 工具步骤 ----
    //
    // 整组交给 [ToolStepGroup]：它按「性能 → 工具步骤过程」决定
    // 是收成一行还是平铺。这里不再自己遍历。
    //
    // ## 执行中只给"当前那一步"
    //
    // 用户要的是"只显示当前进程"。执行中如果把已经跑完的七八步也列出来，
    // 屏幕上就是一份越来越长的历史 —— 而此刻他关心的是"现在在干什么"。
    //
    // 所以执行中只把**还在跑**的那一步交给 ToolStepGroup（单条它就不折叠，
    // 直接显示成一行）；等回复结束再把完整列表给回去，历史一条不少。
    if (minimalProgress) {
      // ---- 极简：过程不画在消息里 ----
      //
      // 状态行 + 历史工具调用 + 文件改动统一挪到输入框上方的
      // 「过程」折叠条（ChatPage._processStrip）：
      //  · 外面只有一句「正在研究如何… / 正在获取…」；
      //  · 点开才看得到全部历史工具调用和文件修改；
      //  · 回答结束后折叠条仍然留着，随时能回看。
      // 所以这里什么都不加 —— 既不加状态行，也不加文件卡片。
    } else if (message.tools.isNotEmpty && showToolSteps) {
      // `chat_alarm` **不进工具步骤列表**：它的产物就是下面那条告示条，
      // 再在步骤里列一行"风险告示 ✓"等于同一个东西说两遍，而且那行
      // 折叠在"查看过程"里面 —— 用户看不到，告示就白挂了。
      final List<ToolInvocation> steps = message.tools
          .where((ToolInvocation t) => t.name != ChatAlarmTool.toolName)
          .toList();
      final List<ToolInvocation> shown = _isExecuting(message)
          ? steps
                .where(
                  (ToolInvocation t) => t.status == InvocationStatus.running,
                )
                .toList()
          : steps;
      // 执行中但此刻没有工具在跑（在等模型出下一句）→ 不显示工具行，
      // 屏幕上只留思考卡片，这才是"当前进程"该有的样子。
      if (shown.isNotEmpty) {
        children.add(ToolStepGroup(tools: shown, collapse: collapseToolSteps));
      }
    }

    // ---- 风险告示：正文**下面**单独一条 ----
    //
    // 位置有三个候选：正文上面（会被当"前言"跳过）、工具步骤里面
    // （折叠起来看不见）、正文下面单独一条。这里选第三种 ——
    // 用户读完方法和剂量、正要动手的时候，那一块颜色正好在视线落脚的
    // 位置；而它是正文之外的一块，所以不会被当正文的一部分扫过去。
    //
    // 只在回复**结束之后**出现：流式期间模型常常先挂告示再写正文，
    // 一个提前跳出来的红条会让人以为"出错了"。
    if (!message.pending) {
      final ToolInvocation? alarm = _latestAlarm(message);
      if (alarm != null) children.add(_alarmCard(context, alarm));
    }

    if (message.error != null && message.error!.trim().isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SurfaceCard(
            // 只要**红边 + 红字**，不要红底（用户要求）。
            //
            // 之前这里还给了一层 `danger.withValues(alpha: 0.08)` 的浅红填充，
            // 本意是"很淡的一层"，但卡片改成不模糊之后填充被抬到 0.97，
            // 整块就变成了实心红 —— 用户看到的是"报错卡片怎么全红了"。
            // 现在底色跟普通卡片一致，靠描边和文字表达"这是错误"。
            borderColor: AppColors.danger.withValues(alpha: 0.45),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.error_outline_rounded,
                  size: 17,
                  color: AppColors.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    message.error!,
                    style: AppFonts.body(
                      size: 13.5,
                      color: AppColors.danger,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 思考中的指示**只由 `_ThinkingCard` 负责**，这里不再画第二个 ——
    // 两处都画的时候，思考期间同一条消息上会并排出现两行"思考中…"。

    if (children.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// 一枚附件胶囊：**28 的缩略图 + 一行名字**。
///
/// ## 为什么消息里和输入框上方共用同一个组件
///
/// 同一份东西在两个地方长得不一样，用户会以为"发出去之后被转成了
/// 别的东西"。共用之后，选完文件 → 点了发送 → 那几枚胶囊**原地没变**，
/// 只是从输入框上方挪进了气泡里。
///
/// ## 缩略图的坑
///
/// `Image.file` 默认按原图分辨率解码：一张 4000×3000 的照片解出来是
/// 48MB 位图，十来张叠在一起，低内存机型会被直接杀掉。
/// 这里按 `28 × 屏幕倍率` 解码，视觉上看不出差别，内存降两个数量级。
class AttachmentChip extends StatelessWidget {
  const AttachmentChip({
    super.key,
    required this.attachment,
    this.onTap,
    this.onRemove,
    this.maxWidth = 168,
  });

  final Attachment attachment;

  /// 点缩略图的动作（图片 → 看大图）。
  final VoidCallback? onTap;

  /// 传了才画末尾那颗 ×（待发区用；发出之后的附件不能再删）。
  final VoidCallback? onRemove;

  final double maxWidth;

  /// 按扩展名给一个**类型图标**。
  ///
  /// 不追求覆盖所有格式：认得出的给专属图标，认不出统一给
  /// `insert_drive_file_outlined`。价值在"扫一眼知道是图/表/文档/代码"，
  /// 不是"精确到 MIME 类型"。
  static IconData glyphOf(String name) {
    final int dot = name.lastIndexOf('.');
    final String ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'webp' || 'gif' || 'bmp' ||
      'heic' => Icons.image_outlined,
      'pdf' => Icons.picture_as_pdf_outlined,
      'doc' || 'docx' || 'rtf' => Icons.description_outlined,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart_outlined,
      'ppt' || 'pptx' => Icons.slideshow_outlined,
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => Icons.folder_zip_outlined,
      'mp3' || 'wav' || 'm4a' || 'flac' => Icons.audiotrack_rounded,
      'mp4' || 'mov' || 'mkv' || 'webm' => Icons.movie_outlined,
      'dart' || 'py' || 'js' || 'ts' || 'kt' || 'java' || 'json' ||
      'yaml' || 'yml' || 'sh' => Icons.code_rounded,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  static String _label(Attachment a) {
    if (!a.isWeb) return a.name;
    final Uri? u = Uri.tryParse(a.path);
    return (u == null || u.host.isEmpty) ? a.path : u.host;
  }

  Widget _glyph(BuildContext context, AppSurface s, IconData icon) =>
      Center(child: Icon(icon, size: 15, color: s.muted));

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final double dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;

    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: EdgeInsets.fromLTRB(4, 0, onRemove == null ? 10 : 2, 0),
      decoration: BoxDecoration(
        color: s.chipBg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: s.border, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 28,
                height: 28,
                child: switch (attachment.kind) {
                  AttachmentKind.image => Image.file(
                    File(attachment.path),
                    fit: BoxFit.cover,
                    cacheWidth: (28 * dpr).round(),
                    cacheHeight: (28 * dpr).round(),
                    errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                        _glyph(context, s, Icons.broken_image_outlined),
                  ),
                  AttachmentKind.web => Container(
                    color: s.surface,
                    child: _glyph(context, s, Icons.public_rounded),
                  ),
                  AttachmentKind.file => Container(
                    color: s.surface,
                    child: _glyph(context, s, glyphOf(attachment.name)),
                  ),
                },
              ),
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              _label(attachment),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(
                size: 12,
                color: s.text,
                height: 1.2,
                letterSpacing: 0,
              ),
            ),
          ),
          if (onRemove != null)
            SizedBox(
              width: 22,
              height: 22,
              child: IconButton(
                icon: const Icon(Icons.close_rounded),
                iconSize: 13,
                tooltip: '移除',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: onRemove,
                style: IconButton.styleFrom(
                  foregroundColor: s.muted,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 用户气泡的入场动画：轻微放大 + 上浮 + 淡入。
///
/// 只在**刚发出**的那条消息上播放一次；历史消息、滚动回看都不播。
/// 用固定时长的 `AnimationController`（不是无限循环），播完通过
/// [onDone] 通知页面收回标记，避免列表重建时又演一遍。
class _BubbleEntrance extends StatefulWidget {
  const _BubbleEntrance({
    required this.child,
    required this.animate,
    this.onDone,
  });

  final Widget child;
  final bool animate;
  final VoidCallback? onDone;

  @override
  State<_BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<_BubbleEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: widget.animate ? 0 : 1,
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 0.92,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.06),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _c.addStatusListener(_onStatus);
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(covariant _BubbleEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.animate && widget.animate) {
      _c
        ..value = 0
        ..addStatusListener(_onStatus)
        ..forward();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _c.removeStatusListener(_onStatus);
    widget.onDone?.call();
  }

  @override
  void dispose() {
    _c
      ..removeStatusListener(_onStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ScaleTransition(
          scale: _scale,
          alignment: Alignment.centerRight,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 「思考」卡片：一行摘要（**耗时 + 深度**），点开看完整思维链。
///
/// ## 为什么耗时值得显示
///
/// 思维链可能几千字，但用户扫一眼想知道的是**代价**："这次想了 12 秒"
/// 直接决定他下次要不要把思考深度调低。这个数以前根本不存在 ——
/// 只有一个转圈，转完就没了，谁也不知道它到底想了一秒还是半分钟。
///
/// ## 为什么默认折叠
///
/// 展开的思维链会把正文挤到屏幕外。用户看的是**回答**，思维链是
/// 出问题时才回看的证据。所以折叠行上把最有用的两个数写出来，
/// 内容按需展开。
class _ThinkingCard extends StatefulWidget {
  const _ThinkingCard({required this.message});

  final ChatMessage message;

  @override
  State<_ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<_ThinkingCard> {
  bool _open = false;

  /// 毫秒 → 人话。
  ///
  /// 不足 1 秒就说"不到 1 秒"而不是"0.4 秒"：这个数的精度本来就不值得
  /// 那么细，而且 0.4 看起来像测量误差。
  static String _humanMs(int ms) {
    if (ms <= 0) return '';
    if (ms < 1000) return '不到 1 秒';
    final double sec = ms / 1000.0;
    if (sec < 60) return '${sec.toStringAsFixed(sec < 10 ? 1 : 0)} 秒';
    final int m = ms ~/ 60000;
    final int r = (ms % 60000) ~/ 1000;
    return r == 0 ? '$m 分' : '$m 分 $r 秒';
  }

  /// 这条消息**从发出到现在**过去了多久。
  ///
  /// 用它而不是 `reasoningMs`：后者要等流结束才有值，而"等首字"这段
  /// 恰恰是最需要给反馈的时间。这里按 `createdAt` 现算，配合外层每
  /// 50~160ms 的重建，数字会自己往上走。
  static String _liveSeconds(ChatMessage m) {
    final int ms = DateTime.now().difference(m.createdAt).inMilliseconds;
    if (ms < 1000) return '刚刚';
    final int s = ms ~/ 1000;
    if (s < 60) return '$s 秒';
    return '${s ~/ 60} 分 ${s % 60} 秒';
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final ChatMessage m = widget.message;

    // "正在想" 还是 "想完了"。
    //
    // 用 `pending` 判：流结束（或开始出正文）时它会被置回 false。
    // 注意不能只看 reasoning 是否为空 —— 想完的第一帧 reasoning 已经
    // 有内容了，但那时还没开始出正文，状态仍然算"正在想"。
    final bool thinking = m.pending && m.content.trim().isEmpty;
    final String time = _humanMs(m.reasoningMs);

    // 摘要行的措辞：
    //  · 正在想  → `思考中…`
    //  · 想完了  → `已思考 12.3 秒`（**不是**"思考 12.3 秒" ——
    //    那个读起来像"还需要 12.3 秒"，而它其实是已经花掉的时间）
    final List<String> bits = <String>[
      if (thinking)
        // 正在想 → 「工作中 · 12 秒」
        //
        // 用"工作中"而不是"思考中"：模型这一步不只在想，也可能在准备
        // 工具参数。用户看到的是一个**进程**，不该被拆成"想/做"两种词。
        //
        // ⚠️ **必须带上已经过去的秒数**。只写"工作中"的话，等首字的那
        // 十几秒里界面一动不动，用户的感觉是"死了"（原话：模型连接感觉
        // 像死了一样）。有一个在跳的秒数，至少能确认它还在跑。
        '工作中 · ${_liveSeconds(m)}',
      if (!thinking && time.isNotEmpty) '已思考 $time',
      // 深度只在**确实开了思考**时才有意义，否则那条模型本来就没想
      if (!thinking && m.reasoningLevel.isNotEmpty) '深度 ${m.reasoningLevel}',
      if (!thinking && m.reasoning.trim().isNotEmpty)
        '${m.reasoning.characters.length} 字',
    ];

    // 状态行的文字。思考中给它套一层扫光：秒数虽然会跳，但整行是静止的，
    // 扫光让"它还在跑"这件事一眼可见；想完之后扫光停掉，只剩静态摘要。
    final Widget label = Text(
      bits.isEmpty ? '思考' : bits.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppFonts.body(size: 12.2, color: s.muted, height: 1.3),
    );

    return Padding(
      // ---- 间距必须和工具行一致 ----
      //
      // 实测过（tools/measure_rows.py）：思考行图标中心到第一条工具行
      // 图标中心是 **76px**（设备像素，3x），而工具行彼此之间是 **93px**。
      // 也就是说思考行和下面那条工具行**贴得比工具行之间更近** ——
      // 在一列左对齐的图标里，这种"忽宽忽窄"看起来就是没对齐。
      //
      // 工具行之间的 93px 由三部分构成：
      //   ToolRow 高 26 + 工具行自己的 `bottom: 5` + 思考卡片的 `top: 8`
      // 所以这里只加 **bottom: 5**，让"最后一条工具行 → 思考行"的间距
      // 和"工具行 → 工具行"完全一样。
      // 上边距**归零**：上一行（工具行或工具组）自己已经带了 `bottom: 5`，
      // 这里再加 8 就变成 13 —— 比"工具行之间"的 5 宽了一倍多，
      // 一列扫下来那两行之间明显空一大块（用户的原话是"中间太宽了"）。
      // 现在每一对相邻的行之间都是 5，间距只有一个来源。
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: m.reasoning.trim().isEmpty
                ? null
                : () => setState(() => _open = !_open),
            // 用和工具行**同一套** ToolRow：同一个行高、同一套居中规则。
            // 两行在聊天里上下相邻，各写一套布局的话图标永远对不齐
            // （用户看到的就是"思考那行和 python 那行歪了"）。
            child: ToolRow(
              iconGap: 7,
              // 图标列的对齐基准和静止态同一个字形、同一个尺寸，
              // 所以补偿也查同一张表（传 0 会整整差 0.3）。
              iconNudge: toolIconNudge(Icons.psychology_outlined),
              icon: thinking
                  ? WorkingPulse(
                      size: 15,
                      icon: Icons.psychology_outlined,
                      color: s.muted,
                    )
                  : Icon(Icons.psychology_outlined, size: 15, color: s.muted),
              trailing: m.reasoning.trim().isNotEmpty
                  ? Icon(
                      _open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: s.muted,
                    )
                  : null,
              child: thinking
                  ? ShimmerMask(
                      base: s.muted,
                      highlight: Color.lerp(s.muted, AppColors.accent, 0.55)!,
                      child: label,
                    )
                  : label,
            ),
          ),
          if (_open && m.reasoning.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: s.codeBg,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                // 硬上限 + 内部滚动：思维链可能几千字，不能让一次
                // "展开思考"把整页聊天顶走。
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: (MediaQuery.sizeOf(context).height * 0.38).clamp(
                      160.0,
                      360.0,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectionArea(
                      child: Text(
                        m.reasoning.trim(),
                        style: AppFonts.read(
                          size: 12.6,
                          color: s.muted,
                          height: 1.7,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 正文里出现的**本地文件路径** → 一排可点开的卡片。
///
/// ## 为什么这个部件是必需的
///
/// 生成出来的图片、视频落在**应用私有目录**（`getFilesDir()`）里。
/// 那个目录：
///  · 文件管理器**看不到**（不是 `/sdcard`，没有权限也列不出来）；
///  · 模型只会回一句"已保存到 /data/user/0/…/images/gen_123.png"，
///    用户照着这个路径去任何地方找都找不到。
///
/// 所以在聊天里把路径识别出来、变成能点开的东西，是用户**唯一**
/// 能真正看到那些文件的途径。少了它，生图和生视频等于白做。
///
/// ## 识别策略
///
/// 只认**明确像文件路径**的串：绝对路径且带已知扩展名。
/// 不用"任意含 `/` 的词"是因为 `/chat/completions`、`/v1/models`
/// 这类接口路径会被误判成文件，给出一排点了报错的卡片。
class GeneratedFiles extends StatefulWidget {
  const GeneratedFiles({
    super.key,
    required this.text,
    this.live = false,
    this.plain = false,
    this.changes = const <FileChange>[],
  });

  final String text;

  /// 正在执行中：标题用「正在处理的文件」，让用户知道文件还会变。
  final bool live;

  /// 极简过程折叠条里用：**不套卡片、不要背景**，只列文件行。
  final bool plain;

  /// 这次任务里记录到的文件改动（见 [FileChange]）。
  ///
  /// 路径对得上的那些行会显示改动行数和「查看修改」，点开就是红删绿增的
  /// 行级差异；没有记录的路径仍然按原来的方式用系统应用打开。
  final List<FileChange> changes;

  /// 认识的扩展名。**故意只列媒体、文档和常见归档** ——
  /// 认得的类型越多，误判成文件的机会也越大。
  static const List<String> _mediaExts = <String>[
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'svg',
    'mp4',
    'webm',
    'mkv',
    'mov',
    'avi',
    '3gp',
    'mp3',
    'wav',
    'm4a',
    'ogg',
    'flac',
    'pdf',
    'txt',
    'log',
    'md',
    'json',
    'csv',
    'zip',
    '7z',
    'rar',
    'tar',
    'gz',
    'epub',
    'apk',
    'pptx',
    'ppt',
    'pptm',
    'potx',
    'docx',
    'doc',
    'docm',
    'xlsx',
    'xls',
    'xlsm',
    // 代码/脚本：AI 改文件后要能从卡片点开「查看修改」，所以这些扩展名
    // 也必须被认成文件。只认**绝对路径 + 明确扩展名**，误判面很小。
    'py',
    'dart',
    'js',
    'mjs',
    'ts',
    'tsx',
    'jsx',
    'html',
    'htm',
    'css',
    'scss',
    'xml',
    'yaml',
    'yml',
    'toml',
    'ini',
    'sh',
    'bash',
    'kt',
    'kts',
    'java',
    'c',
    'h',
    'cpp',
    'hpp',
    'cs',
    'go',
    'rs',
    'rb',
    'php',
    'sql',
    'vue',
    'svelte',
  ];

  /// 从正文里挑出候选文件路径。
  ///
  /// 要求**绝对路径**（以 `/` 开头）并且扩展名在白名单里。
  ///
  /// ## 正则为什么长这样（踩了三次坑才写对）
  ///
  /// 1. **方括号必须转义成 `\[\]`。** 直觉上 `[^][…]`（把 `]` 放最前面）
  ///    是合法的，PCRE 也认 —— 但 **Dart 的 RegExp 不认**，
  ///    它会匹配不到任何东西（不是报错，是静默失效）。
  /// 2. 固定部分用 **raw string**，可变部分（扩展名表）单独拼。
  ///    `\\.` 写在普通字符串里会变成"反斜杠 + 任意字符"，
  ///    看起来像转义了点号，其实没有。
  /// 3. 反过来，`\]` 写在 raw string 里又会**提前结束** raw string。
  ///    拼成 `r'…\[\]…'` 两个问题都不存在。
  /// 4. 开头的 `(?<![\w~])` 是**必需**的：没有它，`images/a.png`
  ///    （相对路径）会因为"里面含 `/a.png`"而被当成绝对路径匹配中，
  ///    给出一张点了必然报错的卡片。
  /// 5. `/` 写成 `~?/`：这样 `~/files/a.png`（家目录，也是绝对路径）
  ///    能整体匹配到。把它漏掉的话，那个 `~` 会被字符类吃掉，
  ///    最后给出一个**少了开头的错误路径**。
  static List<String> extract(String text) {
    final RegExp re = RegExp(
      r'(?<![\/\w~])(~?/(?!/)[^\[\]()<>"，。；：、）】\s]+\.(' +
          _mediaExts.join('|') +
          r'))',
      caseSensitive: false,
    );
    final List<String> out = <String>[];
    for (final RegExpMatch m in re.allMatches(text)) {
      // 去掉结尾可能粘上的标点
      final String clean = m.group(1)!.replaceAll(RegExp(r'[.,;:!?]+$'), '');
      if (clean.length < 5) continue;
      if (!out.contains(clean)) out.add(clean);
    }
    return out;
  }

  @override
  State<GeneratedFiles> createState() => _GeneratedFilesState();
}

/// 聊天里的「本次文件改动」卡片：默认展开，只有文件很多时才收起。
/// 点标题展开收起，点文件直接打开。
class _GeneratedFilesState extends State<GeneratedFiles> {
  bool? _expanded;
  bool _hidden = false;
  final Map<String, String> _sizes = <String, String>{};

  /// 图片不算"文件"。
  ///
  /// 用户一次选好几张图时，附件路径会被拼进消息正文（模型需要路径来读图），
  /// 而这张卡片是按路径提取的 —— 于是**图片也被算成文件**，数量一多就
  /// 触发"默认收起"，看起来像"传了几张图就被自动折叠了"。
  ///
  /// 图片本来就有缩略图，在这里再列一遍没有意义。
  static const Set<String> _imageExt = <String>{
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  };

  static bool _isImagePath(String p) {
    final int dot = p.lastIndexOf('.');
    if (dot < 0 || dot == p.length - 1) return false;
    return _imageExt.contains(p.substring(dot + 1).toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final List<String> paths = GeneratedFiles.extract(widget.text)
        .where((String p) => !_isImagePath(p))
        .toList();
    if (paths.isEmpty || _hidden) return const SizedBox.shrink();
    final AppSurface s = AppSurface.of(context);
    // 阈值从 2 放宽到 5：用户明确抱怨过"文件一多就自动折叠"。
    final bool expanded = _expanded ?? paths.length <= 5;
    final double bodyCap = (MediaQuery.sizeOf(context).height * 0.30).clamp(
      120.0,
      280.0,
    );
    final Map<String, FileChange> changes = <String, FileChange>{
      for (final FileChange c in widget.changes) c.pathKey: c,
    };
    if (widget.plain) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < paths.length; i++)
            _row(
              context,
              s,
              paths[i],
              last: i == paths.length - 1,
              change: changes[FileChange.normalizePath(paths[i])],
            ),
        ],
      );
    }
    final List<String> names = paths
        .map((String p) => p.split('/').last)
        .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            InkWell(
              onTap: () => setState(() => _expanded = !expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.folder_outlined,
                      size: 16,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.live
                                ? '正在处理的文件 · ${paths.length}'
                                : '本次涉及的文件 · ${paths.length}',
                            style: AppFonts.body(
                              size: 12.5,
                              weight: FontWeight.w600,
                              color: s.text,
                            ),
                          ),
                          if (!expanded && names.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(
                              names.take(2).join('、') +
                                  (names.length > 2 ? ' 等' : ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppFonts.body(
                                size: 11,
                                color: s.muted,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 19,
                      color: s.muted,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 15),
                      tooltip: '收起这张卡片',
                      color: s.muted,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _hidden = true),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              alignment: Alignment.topCenter,
              child: !expanded
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      children: <Widget>[
                        Divider(height: 0.6, color: s.border),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: bodyCap),
                          child: SingleChildScrollView(
                            child: Column(
                              children: <Widget>[
                                for (int i = 0; i < paths.length; i++)
                                  _row(
                                    context,
                                    s,
                                    paths[i],
                                    last: i == paths.length - 1,
                                    change:
                                        changes[FileChange.normalizePath(
                                          paths[i],
                                        )],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AppSurface s,
    String path, {
    required bool last,
    FileChange? change,
  }) {
    final String name = path.split('/').last;
    final String size = _sizeOf(path);
    final bool hasDiff = change != null && change.hasChanges;
    return InkWell(
      onTap: hasDiff
          ? () => showFileDiffSheet(
              context,
              change: change,
              onOpenFile: () => _open(context, path),
            )
          : () => _open(context, path),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        decoration: BoxDecoration(
          border: last
              ? null
              : Border(bottom: BorderSide(color: s.border, width: 0.5)),
        ),
        child: Row(
          children: <Widget>[
            Icon(_iconFor(path), size: 17, color: AppColors.accent),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(
                      size: 12.5,
                      weight: FontWeight.w600,
                      color: s.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    size.isEmpty ? path : '$path · $size',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(size: 10.5, color: s.muted),
                  ),
                ],
              ),
            ),
            if (hasDiff) ...<Widget>[
              const SizedBox(width: 6),
              Text(
                '+${change.additions}',
                style: AppFonts.code(
                  size: 10.5,
                  weight: FontWeight.w600,
                  color: AppColors.success,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '-${change.deletions}',
                style: AppFonts.code(
                  size: 10.5,
                  weight: FontWeight.w600,
                  color: AppColors.danger,
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.difference_outlined, size: 15, color: s.muted),
            ] else ...<Widget>[
              const SizedBox(width: 6),
              Icon(Icons.open_in_new_rounded, size: 14, color: s.muted),
            ],
          ],
        ),
      ),
    );
  }

  String _sizeOf(String path) {
    final String? cached = _sizes[path];
    if (cached != null) return cached;
    String value = '';
    try {
      final int len = File(path).lengthSync();
      if (len < 1024) {
        value = '$len B';
      } else if (len < 1024 * 1024) {
        value = '${(len / 1024).toStringAsFixed(1)} KB';
      } else {
        value = '${(len / 1024 / 1024).toStringAsFixed(1)} MB';
      }
    } catch (_) {
      value = '';
    }
    _sizes[path] = value;
    return value;
  }

  static IconData _iconFor(String path) {
    final String ext = path.split('.').last.toLowerCase();
    if (<String>[
      'png',
      'jpg',
      'jpeg',
      'gif',
      'webp',
      'bmp',
      'heic',
      'svg',
    ].contains(ext)) {
      return Icons.image_outlined;
    }
    if (<String>['mp4', 'webm', 'mkv', 'mov', 'avi', '3gp'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if (<String>['mp3', 'wav', 'm4a', 'ogg', 'flac'].contains(ext)) {
      return Icons.audiotrack_outlined;
    }
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (<String>['ppt', 'pptx', 'pptm', 'potx'].contains(ext)) {
      return Icons.slideshow_outlined;
    }
    if (<String>['xls', 'xlsx', 'xlsm', 'csv'].contains(ext)) {
      return Icons.table_chart_outlined;
    }
    if (<String>['doc', 'docx', 'docm'].contains(ext)) {
      return Icons.article_outlined;
    }
    if (<String>['zip', '7z', 'rar', 'tar', 'gz', 'apk'].contains(ext)) {
      return Icons.folder_zip_outlined;
    }
    return Icons.description_outlined;
  }

  /// 打开并给出反馈。
  ///
  /// 失败时**必须把原因说出来**：这类失败的常见原因差别很大
  /// （文件被清理掉了 / 没装能打开这种类型的应用 / 路径不在可分享范围），
  /// 一句"打开失败"用户完全没法处理。
  static Future<void> _open(BuildContext context, String path) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );

    // 先解析成真实路径：`/shared/...` 在 Android 上并不存在，它对应
    // `filesDir/shared/...`；`/sdcard` 也可能是重定向路径。少了这一步，
    // 卡片上明明有文件，点开却总说“找不到”。
    final String? resolved = await PlatformFiles.resolve(path, search: true);
    if (resolved == null) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('文件不在设备上（可能已被移动或删除）：$path'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    final String? err = await PlatformFiles.open(resolved);
    if (err == null) return;
    messenger?.showSnackBar(
      SnackBar(content: Text(err), duration: const Duration(seconds: 4)),
    );
  }
}

/// 复制 AI 回复的原文（Markdown 源码，不是渲染后的纯文本）。
///
/// 复制**原文**而不是渲染结果：用户复制多半是要粘到别处继续用，
/// 这时保留 `##`、`-`、代码围栏才是有用的；渲染后的纯文本会丢掉结构。
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _done = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _done = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _done = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _copy,
        child: Padding(
          // 触摸区要够大：文字只有 11px，不给内边距点不中
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                _done ? Icons.check_rounded : Icons.copy_rounded,
                size: 13,
                color: _done ? AppColors.success : s.muted,
              ),
              const SizedBox(width: 5),
              Text(
                _done ? '已复制' : '复制',
                style: AppFonts.body(
                  size: 11.5,
                  color: _done ? AppColors.success : s.muted,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 改会话名字的输入框。返回新名字；取消返回 null。
///
/// 抽出来共用是因为**两个入口都要它** —— 对话头部点标题、侧边菜单里的
/// 「重命名」。它们必须长得一模一样：同一件事出现两套界面时，用户会
/// 怀疑是不是两套逻辑（"我在那边改了名字，这边没变？"）。
///
/// 「新对话」是**占位名**，不是用户起的名字，所以进输入框时清空 ——
/// 让他在"新对话"上改，很容易改出"新对话2"这种谁都不认识的名字。
Future<String?> showRenameDialog(
  BuildContext context, {
  required String initial,
  String hint = '例如：修电池掉电问题',
}) async {
  // 用 `TextFormField(initialValue:)` 而不是 `TextField(controller:)`，
  // 这样**没有 controller 要管**。有 controller 就得在关闭后 dispose，
  // 而对话框关闭有一段退场动画，那期间 TextField 还挂在树上 ——
  // 那一刻 dispose 会直接抛 "used after being disposed"。
  // 为了省一个几乎无成本的字符串对象去踩这个坑不值得。
  String text = initial.trim() == '新对话' ? '' : initial.trim();

  final String? name = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) {
      void submit() => Navigator.of(ctx).pop(text);
      return AlertDialog(
        title: Text(
          '改个名字',
          style: AppFonts.body(
            size: 16.5,
            weight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        content: TextFormField(
          initialValue: text,
          autofocus: true,
          maxLength: 30,
          textInputAction: TextInputAction.done,
          onChanged: (String v) => text = v,
          onFieldSubmitted: (_) => submit(),
          decoration: InputDecoration(hintText: hint),
        ),
        actions: <Widget>[
          GlassButton(label: '取消', onTap: () => Navigator.of(ctx).pop()),
          GlassButton(label: '保存', accent: true, onTap: submit),
        ],
      );
    },
  );

  return name;
}

/// 危险操作确认弹窗。
///
/// 三个出路（[ConfirmDecision]）：拒绝 / 执行这一次 / **全部运行**。
///
/// 「全部运行」是为长任务加的：一次任务里可能要跑十几二十个工具
/// （搜索、读文件、写文件、跑脚本……），每个都弹一次确认，用户会变成
/// 一个点确认的机器，而**认真看**这件事本身反而被磨掉了。
/// 让他一次说清"这些我都同意"，比逼他点十次更有意义。
///
/// 代价是它**连危险命令一起放行**，所以：解释写在按钮上方，
/// 并且打开之后输入框旁边会一直挂着一个感叹号（见 chat_page），
/// 随时能暂停。不能让它变成一个用户忘了自己开过的开关。
Future<ConfirmDecision> showRiskConfirmDialog(
  BuildContext context, {
  required ToolInvocation invocation,
  required String toolTitle,
}) async {
  final AppSurface s = AppSurface.of(context);
  final bool dangerous = invocation.risk.isDangerous;

  final ConfirmDecision? result = await showDialog<ConfirmDecision>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext ctx) {
      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 22),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
        title: Row(
          children: <Widget>[
            Icon(
              dangerous
                  ? Icons.warning_amber_rounded
                  : Icons.help_outline_rounded,
              color: dangerous ? AppColors.danger : AppColors.warning,
              size: 21,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                dangerous ? '危险操作确认' : '操作确认',
                style: AppFonts.body(
                  size: 16.5,
                  weight: FontWeight.w600,
                  color: s.text,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '$toolTitle 请求执行以下内容：',
                style: AppFonts.body(size: 12.8, color: s.muted, height: 1.55),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: s.codeBg,
                  borderRadius: BorderRadius.circular(AppRadius.code),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 9,
                ),
                child: SelectableText(
                  invocation.args['command']?.toString() ??
                      invocation.argumentsJson,
                  style: AppFonts.code(size: 12.4, color: s.text),
                ),
              ),
              if (invocation.risk.reasons.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                ...invocation.risk.reasons.map(
                  (String r) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.circle,
                            size: 5,
                            color: dangerous
                                ? AppColors.danger
                                : AppColors.warning,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            r,
                            style: AppFonts.body(
                              size: 12.6,
                              color: s.text,
                              height: 1.55,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '该内容由 AI 自动生成，不是你自己输入的。请核对后再决定。',
                style: AppFonts.body(size: 12, color: s.muted, height: 1.5),
              ),
              const SizedBox(height: 10),
              Text(
                '下面的「全部运行」会**停止询问本次任务里的所有工具**，'
                '包括危险命令；发消息的输入框旁边会出现一个感叹号，'
                '点它就能随时暂停。',
                style: AppFonts.body(size: 11.5, color: s.muted, height: 1.5),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: GlassButton(
                      label: '拒绝',
                      expand: true,
                      onTap: () => Navigator.of(ctx).pop(ConfirmDecision.deny),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: GlassButton(
                      label: dangerous ? '仍然执行' : '执行',
                      expand: true,
                      danger: dangerous,
                      accent: !dangerous,
                      onTap: () => Navigator.of(ctx).pop(ConfirmDecision.allow),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              GlassButton(
                label: '全部运行（之后不再询问）',
                expand: true,
                onTap: () => Navigator.of(ctx).pop(ConfirmDecision.allowAll),
              ),
            ],
          ),
        ],
      );
    },
  );

  // 点遮罩关掉/系统返回都当成拒绝：非 barrierDismissible + 没给取消路径，
  // 走到这里说明是异常关闭，**不能默认放行**。
  return result ?? ConfirmDecision.deny;
}

/// **整场对话末尾**的署名：应用图标 + 一句提醒。
///
/// 由对话页把它挂在消息列表的**最后一格**（见 `ChatPage._messageList`），
/// 不是挂在每条回复后面 —— 它是这场对话的落款，一条就够；
/// 每条回复都盖一个，就变成正文之外的一层噪音。
class AiSignature extends StatelessWidget {
  const AiSignature({super.key});

  /// 图标相对文字中心的**下移补偿**（逻辑像素）。
  ///
  /// 和工具行那几个图标是同一类问题：图片的墨迹等于它的盒子，但**文字**的
  /// 墨迹在行盒里不是上下对称的（行盒替西文的降部留了空间，中文用不上），
  /// 所以"盒子各自居中"看起来就是图标偏高。数值从渲染图里量出来。
  static const double iconNudge = 0.6;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      // 只留一句提醒，**不要图标**（用户要求）：
      // 之前是应用图标 + 英文 "AI-generated contents, Please double check."，
      // 小尺寸下图标比字还抢眼，而这句话本身才是要看的。
      child: Text(
        '注意验证内容准确性',
        style: AppFonts.body(size: 12, color: s.muted, height: 1.35),
      ),
    );
  }
}

/// 用户气泡里「这段长文本已经存进变量库」的样子。
///
/// ## 为什么用户气泡要分两种长相
///
/// 普通消息是**一句话**，直接铺开最自然。而粘进来的几万字是**一份材料**，
/// 铺开有三个后果：
///  · 气泡占满好几屏，把其他消息全推出视野；
///  · 每个字都参与 markdown / 选区的排版，滚动明显发涩；
///  · 用户自己也得分半天才能确认"我到底发了什么"。
///
/// 所以这里把它收成一张小卡：一行说清"存了什么、多大"，点一下原地展开。
/// 展开用 [SelectableText] —— 能选中复制，但默认不占版面。
class _VarBankBubble extends StatefulWidget {
  const _VarBankBubble({required this.message, required this.s, this.onDelete});

  final ChatMessage message;
  final AppSurface s;
  final void Function(ChatMessage from)? onDelete;

  @override
  State<_VarBankBubble> createState() => _VarBankBubbleState();
}

class _VarBankBubbleState extends State<_VarBankBubble> {
  bool _open = false;

  /// 展示用的变量名（多个时只显示第一个 + "等 N 个"）。
  String get _label {
    final List<String> refs = widget.message.varRefs;
    if (refs.isEmpty) return '变量库';
    if (refs.length == 1) return refs.first;
    return '${refs.first} 等 ${refs.length} 个';
  }

  /// 行数与体积。变量被删掉时说清"已删除"，而不是显示 0 行。
  String get _meta {
    final VarBankStore bank = VarBankStore.instance;
    int lines = 0;
    int bytes = 0;
    for (final String name in widget.message.varRefs) {
      final Variable? v = bank.get(name);
      if (v == null) continue;
      lines += v.lines;
      bytes += v.bytes;
    }
    if (lines == 0) return '变量已删除';
    return '$lines 行 · ${humanBytes(bytes)}';
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = widget.s;

    // 展开时显示**变量当前的正文**，而不是消息里那份快照。
    // 变量可以被更新（用户后来补过内容），他点开时想看的是"它现在是什么"。
    final String body = widget.message.varRefs
        .map((String n) => VarBankStore.instance.get(n)?.text ?? '')
        .where((String t) => t.isNotEmpty)
        .join('\n\n');

    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      decoration: BoxDecoration(
        color: s.bubbleBg,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: s.border, width: 0.9),
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ---- 一行摘要 ----
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.inventory_2_outlined, size: 15, color: s.muted),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  '已存入变量库 · $_label',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: s.text,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          // ---- 下面一行小字：大小 + 点击查看 ----
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _meta,
                style: AppFonts.body(size: 11.5, color: s.muted, height: 1.3),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: body.isEmpty
                    ? null
                    : () => setState(() => _open = !_open),
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _open ? '收起' : '点击查看',
                        style: AppFonts.body(
                          size: 11.5,
                          weight: FontWeight.w600,
                          color: AppColors.accent,
                          height: 1.3,
                        ),
                      ),
                      Icon(
                        _open
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 14,
                        color: AppColors.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // ---- 展开：原文 ----
          if (_open && body.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 420),
              decoration: BoxDecoration(
                color: s.chipBg,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: SingleChildScrollView(
                child: SelectableText(
                  body,
                  style: AppFonts.body(size: 13.5, color: s.text, height: 1.55),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
