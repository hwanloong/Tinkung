import 'package:flutter/material.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import 'tool_line.dart';

/// **工具步骤过程**：把一轮里的多次工具调用收成一组。
///
/// ## 为什么需要它
///
/// agent 干一件稍复杂的事会连着调十几个工具（读文件、跑命令、再读、再跑…）。
/// 每一步都直接铺在聊天里的话，正文会被推到很远的地方 ——
/// 用户要滚好几屏才能看到"所以结论是什么"，而中间那十几行
/// 他其实**只关心有没有出错**。
///
/// 折叠之后那一轮显示成一行：
///
/// ```
/// ⚙ 执行了 12 步 · 1 个失败                    ▸
/// ```
///
/// 一行就把"做了多少、有没有问题"说完了。要追细节再点开。
///
/// ## 为什么**单步也折叠**（2026-10-15 改的）
///
/// 原来只调一次时直接平铺那一行，理由是"折叠反而多一次点击"。
/// 但用户看到的是一列**忽高忽低**的东西：有的轮次是一行工具行、
/// 有的轮次是一行「执行了 N 步」，两者的图标、缩进、行高都不一样 ——
/// 扫下来就是"没对齐"。他要的是**所有工具过程都被收起来**，
/// 于是现在只要开关开着，一步也收成「执行了 1 步」。
///
/// 那一次多的点击换来的是：整场对话里"工具过程"永远只有一种形态，
/// 正文的位置稳定可预期。
///
/// ## 折叠状态存在组件里，不进数据模型
///
/// 展开/收起是纯粹的**看**的状态，和会话内容无关。
/// 存进 `ChatMessage` 的话，导出/分享会话会带上"这条当时是展开的"
/// 这种毫无意义的字段；而且每次流式更新重建列表时，
/// 重建出来的组件会把它重置掉 —— 用户正在看细节时被强行收起来。
/// 放在 `State` 里，重建时它就还在。
/// 一行步骤 + 左边的树状连接线。
///
/// 画法（不是用 Unicode 的 `├ └ │`，而是自绘）：
///
/// ```
///  │                ← 竖干（不是最后一项时一直画到底）
///  ├─  [工具行]     ← 横枝接在**第一行文字的中线**上
///  └─  [工具行]     ← 最后一项：竖干画到中线就拐弯
/// ```
///
/// ## 为什么自绘而不是打字符
///
/// `├ └ │` 这些框线字符在**不同系统字体里宽高都不一样**（有的 1em，
/// 有的 0.6em，垂直位置也各不相同），而这一列的竖线必须**上下对齐**
/// 才能连成一条。用 `Text` 画的话，换个 ROM、换个字号就断成几截。
/// `CustomPainter` 画 1px 的线，任何环境下都是齐的。
///
/// 横枝的高度取 [kTreeTickY]：工具行自己的上内边距 5 + 行高 26 的一半。
/// 改 [ToolLine] 的内边距时要同步改它，否则横枝会插到文字的腰上。
class _TreeStep extends StatelessWidget {
  const _TreeStep({
    required this.child,
    required this.isLast,
    required this.color,
  });

  final Widget child;

  /// 是不是最后一项（最后一项的竖干要拐弯，不能画到底）。
  final bool isLast;

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // 连接线铺满整行，但只画左边 14px 那一窄条。
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _TreePainter(isLast: isLast, color: color),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: _treeGutter),
          child: child,
        ),
      ],
    );
  }
}

/// 竖干所在的 x（距这一行左边缘）。
const double _treeStemX = 4;

/// 横枝从竖干伸出的长度。
const double _treeTickLen = 9;

/// 给竖干 + 横枝留出的左边距。
const double _treeGutter = 16;

/// 横枝的 y：工具行上内边距 5 + `kToolRowHeight` 的一半。
///
/// 和 [ToolLine] 的 `padding(top: 5)`、[kToolRowHeight] 是**配套数字**。
const double kTreeTickY = 5 + kToolRowHeight / 2;

class _TreePainter extends CustomPainter {
  const _TreePainter({required this.isLast, required this.color});

  final bool isLast;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 竖干：最后一项画到横枝就停（形成 └），否则贯穿整行。
    canvas.drawLine(
      Offset(_treeStemX, 0),
      Offset(_treeStemX, isLast ? kTreeTickY : size.height),
      p,
    );
    // 横枝：从竖干伸向文字。
    canvas.drawLine(
      Offset(_treeStemX, kTreeTickY),
      Offset(_treeStemX + _treeTickLen, kTreeTickY),
      p,
    );
  }

  @override
  bool shouldRepaint(_TreePainter old) =>
      old.isLast != isLast || old.color != color;
}

class ToolStepGroup extends StatefulWidget {
  const ToolStepGroup({super.key, required this.tools, this.collapse = true});

  final List<ToolInvocation> tools;

  /// 是否允许折叠。由「性能 → 工具步骤过程」控制。
  final bool collapse;

  @override
  State<ToolStepGroup> createState() => _ToolStepGroupState();
}

class _ToolStepGroupState extends State<ToolStepGroup> {
  bool _open = false;

  /// 有几步是失败的（含被拒、出错）。
  int get _failed => widget.tools
      .where(
        (ToolInvocation t) =>
            t.status == InvocationStatus.failed ||
            t.status == InvocationStatus.rejected,
      )
      .length;

  /// 还在跑的步数。跑着的时候不该让用户以为"做完了"。
  int get _running => widget.tools
      .where((ToolInvocation t) => t.status == InvocationStatus.running)
      .length;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<ToolInvocation> tools = widget.tools;
    if (tools.isEmpty) return const SizedBox.shrink();

    // 关了折叠 → 直接平铺（用户的明确选择）。
    // 开着就**一步也收**：见文件头那段"为什么单步也折叠"。
    if (!widget.collapse) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (int i = 0; i < tools.length; i++)
            _TreeStep(
              isLast: i == tools.length - 1,
              color: s.muted.withValues(alpha: 0.45),
              child: ToolLine(invocation: tools[i]),
            ),
        ],
      );
    }

    // 组头那个图标跟着整体状态走：折叠起来之后用户看不到每一步的颜色了，
    // 所以这一行必须自己把"有没有出问题"表达出来。
    final IconData headIcon = _failed > 0
        ? Icons.error_outline_rounded
        : (_running > 0
              ? Icons.autorenew_rounded
              : Icons.check_circle_outline_rounded);
    final Color headColor = _failed > 0
        ? AppColors.danger
        : (_running > 0 ? AppColors.accent : s.muted);

    return Padding(
      // 组的尾部间距 = 工具行自己的 `bottom: 5`。
      // 原来是 2，于是"折叠组 → 下一个东西"比"工具行 → 工具行"紧一档。
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: ToolRow(
              iconNudge: toolIconNudge(headIcon),
              icon: Icon(headIcon, size: 15, color: headColor),
              trailing: AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 17,
                  color: s.muted,
                ),
              ),
              child: Text(
                _summary(tools),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.body(
                  size: 13,
                  weight: FontWeight.w600,
                  // 出错时整行用危险色：折叠状态下这是**唯一的**
                  // 异常信号，不能只靠一个小图标（一列扫过去会漏）。
                  color: _failed > 0 ? AppColors.danger : s.text,
                  height: 1.35,
                ),
              ),
            ),
          ),
          if (_open)
            Padding(
              // 展开的内容往右缩一点，形成层次：
              // 一眼能看出这些步骤属于上面那一行。
              //
              // `top` 必须是 **5**，和每条工具行自己的 `bottom: 5` 对齐 ——
              // 原来是 2，于是"组头 → 第一条"比"工具行 → 工具行"近 3px，
              // 一列扫下来就是"上下间距不一"（用户配的那张图里，
              // 量出来正好是 28 : 31 : 31）。
              padding: const EdgeInsets.only(left: 22, top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // ---- 树状连接线（用户指定的样子）----
                  //
                  //     │
                  //     ├─ websearch
                  //     ├─ think
                  //     └─ termux
                  //
                  // 比原来"一行行平铺"多用了 16px 的左边距，但换来的
                  // 是**一眼看出这些步骤属于同一组** —— 平铺的行和正文
                  // 混在一起时，用户很难分清哪几行是一次任务的过程。
                  for (int i = 0; i < tools.length; i++)
                    _TreeStep(
                      isLast: i == tools.length - 1,
                      color: s.muted.withValues(alpha: 0.45),
                      child: ToolLine(invocation: tools[i]),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 一句话说清"做了多少、有没有问题"。
  String _summary(List<ToolInvocation> tools) {
    final StringBuffer sb = StringBuffer();
    if (_running > 0) {
      sb.write('正在执行第 ${tools.length} 步');
    } else {
      sb.write('执行了 ${tools.length} 步');
    }
    if (_failed > 0) sb.write(' · $_failed 个失败');
    return sb.toString();
  }
}

/// **整场对话**的工具调用收成的一行：`共 46 次工具调用 ˅`。
///
/// ## 为什么在 [ToolStepGroup] 之外还要有它
///
/// [ToolStepGroup] 收的是**一轮**（一条 assistant 回复）里的步骤。但 agent
/// 干一件稍微复杂的事就会连着跑十几轮，每轮各留一行「执行了 N 步」——
/// 十几行折叠组叠起来，本身又变成一屏噪音，用户要的"只看结论"还是没实现。
///
/// 所以再加一层：整场对话的工具调用**合计成一行**，默认合上（一轮
/// 一次都不画）。点开就回到按轮分组的样子，每一轮仍然能各自展开看细节。
///
/// ## 这一行本身也是一个开关
///
/// 合上时它是"这里有多少次调用"的**报告**，点开之后它变成"收起"的按钮
/// （箭头翻上去）—— 同一行同时承担两个方向，用户不需要去设置里找。
/// 展开/合上的状态存在页面里（见 ChatPage），不进数据模型：它和聊了什么
/// 无关，导出会话也不该带上"这条当时是展开的"。
class ToolFoldAllRow extends StatelessWidget {
  const ToolFoldAllRow({
    super.key,
    required this.total,
    required this.failed,
    required this.running,
    required this.folded,
    required this.onTap,
  });

  /// 整场对话里的工具调用次数（合计数）。
  final int total;

  /// 其中失败/被拒的次数。合上时这是**唯一**的异常信号，见下面那行文字。
  final int failed;

  /// 还在跑的步数。
  final int running;

  /// 现在是合上的吗（合上 = 只显示这一行）。
  final bool folded;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    if (total <= 0) return const SizedBox.shrink();

    // 图标跟着整体状态走：合上之后用户看不到每一步的颜色了，
    // 所以这一行必须自己把"有没有出问题、还在不在跑"表达出来。
    final IconData headIcon = failed > 0
        ? Icons.error_outline_rounded
        : (running > 0
              ? Icons.autorenew_rounded
              : Icons.check_circle_outline_rounded);
    final Color headColor = failed > 0
        ? AppColors.danger
        : (running > 0 ? AppColors.accent : s.muted);

    return Padding(
      // 和 [ToolStepGroup] 一样给 5：两种"工具行"在聊天流里的行距必须一致，
      // 否则一列扫下来就是疏密不匀。
      padding: const EdgeInsets.only(bottom: 5),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Tooltip(
          message: folded ? '展开全部工具调用' : '收起全部工具调用',
          child: ToolRow(
            iconNudge: toolIconNudge(headIcon),
            icon: Icon(headIcon, size: 15, color: headColor),
            trailing: AnimatedRotation(
              // 合上时箭头朝下（"下面收着东西"），点开之后翻上去。
              turns: folded ? 0 : 0.5,
              duration: const Duration(milliseconds: 160),
              child: Icon(Icons.expand_more_rounded, size: 17, color: s.muted),
            ),
            child: Text(
              _label(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.body(
                size: 13,
                weight: FontWeight.w600,
                // 有失败就整行用危险色：合上时这是唯一的异常提示，
                // 只靠一个小图标在一列里会被漏掉。
                // 展开之后它退回"次要文字"：这一行的主角已经换成了下面
                // 那些按轮分组的工具行，它自己只是那个"收起"的开关。
                color: failed > 0
                    ? AppColors.danger
                    : (folded ? s.text : s.muted),
                height: 1.35,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一行把"一共多少次、出了几个问题、还在不在跑"说完。
  ///
  /// 合上时它是**报告**（"这里收着 46 次调用"），展开时换成**动作**
  /// （"收起全部"）—— 展开状态下旁边已经有一列按轮分组的工具行，
  /// 这一行再说一遍"共 46 次"就是两条几乎一样的字叠在一起。
  String _label() {
    if (!folded) return '收起全部工具调用';
    final StringBuffer sb = StringBuffer('共 $total 次工具调用');
    if (failed > 0) sb.write(' · $failed 个失败');
    if (running > 0) sb.write(' · 进行中');
    return sb.toString();
  }
}
