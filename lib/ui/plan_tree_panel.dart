import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tools/plan_tool.dart';
import 'working_pulse.dart';

/// 对话底部的**计划树进度表**。
///
/// ## 它解决什么问题
///
/// `plan` 工具把一件大活拆成带依赖的节点之后，计划只存在于两处：
///  · 磁盘上的 `plans/<convId>.json`；
///  · 系统提示词里那一段（模型自己看）。
///
/// 用户这边**什么都没有** —— 他只能从模型零散的过程话里猜"现在做到哪了、
/// 还剩几步、卡住的是哪个"。而这个面板把整棵树立在聊天最底端：
/// 一眼扫过去，绿色的勾是做完的，转着的是正在跑的，空心圈是还没动的。
///
/// ## 为什么钉在底部，而不是塞进消息列表
///
/// 计划是**当前状态**，不是一条历史消息。塞进列表的话，用户往上翻两屏
/// 就看不见它了，而恰恰是长任务最需要"随时能瞄一眼进度"。所以由聊天页
/// 用 `Positioned` 把它压在输入框上方，消息列表的底部内边距会为它让位，
/// 内容不会被盖住。
///
/// ## 状态从哪来
///
/// 只认 `PlanNode.status`（`todo` / `doing` / `done` / `blocked`）：
///  · `done`   → 已完成（绿勾，标题变浅）
///  · `doing`  → 正在运行（呼吸的播放图标）
///  · `blocked`→ 已阻塞（红叹号）
///  · `todo`   → 未运行（空心圈，若依赖未完成再补一行"依赖 …"）
///
/// **不猜**"模型现在大概在做哪个"：计划树是模型自己记账的东西，
/// 界面擅自把某个 `todo` 画成"正在运行"会和它的回填对不上，
/// 用户看到的就是"明明在做 A，界面说在做 B"。
class PlanTreePanel extends StatefulWidget {
  const PlanTreePanel({super.key, required this.nodes});

  final List<PlanNode> nodes;

  @override
  State<PlanTreePanel> createState() => _PlanTreePanelState();
}

class _PlanTreePanelState extends State<PlanTreePanel> {
  /// 默认展开：计划表存在的意义就是"不用点也能看到进度"。
  /// 节点特别多时用户仍可收起来，只留一行进度摘要。
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<PlanNode> nodes = widget.nodes;
    if (nodes.isEmpty) return const SizedBox.shrink();

    final int done = nodes.where((PlanNode n) => n.done).length;
    final int doing = nodes.where((PlanNode n) => n.status == 'doing').length;
    final int blocked = nodes
        .where((PlanNode n) => n.status == 'blocked')
        .length;

    return Container(
      decoration: BoxDecoration(
        color: s.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.border, width: 0.8),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: s.isDark ? 0.28 : 0.06),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(s, done: done, total: nodes.length, doing: doing),
            if (_open)
              ConstrainedBox(
                // 计划可能有二三十个节点：给一个硬上限 + 内部滚动，
                // 不能让"看一眼进度"把半屏聊天顶走。
                constraints: BoxConstraints(
                  maxHeight: (MediaQuery.sizeOf(context).height * 0.32).clamp(
                    120.0,
                    320.0,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (int i = 0; i < nodes.length; i++)
                        _nodeRow(s, nodes[i], last: i == nodes.length - 1),
                    ],
                  ),
                ),
              ),
            if (!_open && blocked > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 9),
                child: Text(
                  '$blocked 个节点卡住了',
                  style: AppFonts.body(
                    size: 11.5,
                    color: AppColors.danger,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(
    AppSurface s, {
    required int done,
    required int total,
    required int doing,
  }) {
    return InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                // 用户给这张表起的名字就是 plantree。
                'plantree',
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
            const SizedBox(width: 8),
            Text(
              '$done/$total'
              '${doing > 0 ? ' · $doing RUNNING' : ''}',
              maxLines: 1,
              style: AppFonts.body(
                size: 10.8,
                weight: FontWeight.w600,
                color: doing > 0 ? AppColors.accent : s.muted,
                height: 1.3,
              ),
            ),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 160),
              child: Icon(Icons.expand_more_rounded, size: 18, color: s.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nodeRow(AppSurface s, PlanNode n, {required bool last}) {
    final _NodeStyle style = _styleOf(n, s);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(
                top: BorderSide(
                  color: s.border.withValues(alpha: 0.55),
                  width: 0.6,
                ),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(width: 15, height: 18, child: Center(child: style.icon)),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  n.title.trim().isEmpty ? n.id : n.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 12.6,
                    weight: n.status == 'doing'
                        ? FontWeight.w600
                        : FontWeight.w500,
                    color: n.done ? s.muted : s.text,
                    height: 1.35,
                  ),
                ),
                if (n.note.trim().isNotEmpty && !n.done)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      n.note.trim().replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 11.2,
                        color: s.muted,
                        height: 1.35,
                      ),
                    ),
                  ),
                if (!n.done && n.after.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '依赖 ${n.after.join('、')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.body(
                        size: 10.8,
                        color: s.muted.withValues(alpha: 0.8),
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              style.label,
              maxLines: 1,
              style: AppFonts.body(
                size: 10.6,
                weight: FontWeight.w600,
                color: style.color,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  _NodeStyle _styleOf(PlanNode n, AppSurface s) {
    switch (n.status) {
      case 'done':
        return _NodeStyle(
          label: 'DONE',
          color: AppColors.success,
          icon: Icon(
            Icons.check_circle_rounded,
            size: 14,
            color: AppColors.success,
          ),
        );
      case 'doing':
        return _NodeStyle(
          label: 'RUNNING',
          color: AppColors.accent,
          // 和聊天里其他地方一样：执行中不是转圈，而是**这个节点自己的
          // 形状在原地呼吸**。停下之后还是同一个图标，不换形。
          icon: WorkingPulse(
            size: 14,
            icon: Icons.play_circle_fill_rounded,
            color: AppColors.accent,
          ),
        );
      case 'blocked':
        return _NodeStyle(
          label: 'BLOCKED',
          color: AppColors.danger,
          icon: Icon(Icons.error_rounded, size: 14, color: AppColors.danger),
        );
      default:
        return _NodeStyle(
          label: 'WAIT',
          color: s.muted,
          icon: Icon(
            Icons.radio_button_unchecked_rounded,
            size: 14,
            color: s.muted.withValues(alpha: 0.65),
          ),
        );
    }
  }
}

class _NodeStyle {
  const _NodeStyle({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final Widget icon;
}
