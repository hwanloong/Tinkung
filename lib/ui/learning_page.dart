import 'package:flutter/material.dart';

import '../core/learning.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import 'home_shell.dart';

/// 「自学习笔记」管理页。
///
/// ## 为什么用户不能添加
///
/// 这不是"设置"，而是 agent 的**复盘本**：
///  · 用户写 = 变成第二个「自定义规则」，agent 会分不清哪条是自己踩出来的坑；
///  · 用户改 = 这条经验就不再是"真实发生过的事"了。
///
/// 所以这里**只有删除**（和清空）。添加、编辑的入口一个都不给 ——
/// 页面上也明说，免得用户找"加号"找半天。
///
/// ## 为什么单独一页
///
/// 和记忆同一个理由：它会累积。攒到几十条之后需要一个能滚动、
/// 能逐条删的完整页面；塞进设置面板会变成一个谁也翻不完的列表。
class LearningPage extends StatefulWidget {
  const LearningPage({super.key, required this.store});

  final LearningStore store;

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
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
    final List<LearningNote> notes = widget.store.notes;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          AppHeader(
            title: '自学习',
            subtitle: notes.isEmpty
                ? 'AI 还没有写下任何经验'
                : '${notes.length} 条 · AI 自己写，你只能删',
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            actions: <Widget>[
              if (notes.isNotEmpty)
                GlassIconButton(
                  icon: Icons.delete_sweep_outlined,
                  tooltip: '清空全部',
                  size: 38,
                  iconSize: 18,
                  onTap: () => _confirmClear(context),
                ),
            ],
          ),
          Expanded(
            child: notes.isEmpty
                ? const EmptyHint(
                    icon: Icons.school_outlined,
                    title: '还没有自学习笔记',
                    desc:
                        'AI 在任务里走过弯路、犯了错、或者学会一个新技能时，'
                        '会自己写一条经验到这儿。\n'
                        '这些经验每轮对话都会带上，帮它下次别重复踩坑。\n\n'
                        '你只能查看和删除 —— 添加是 AI 自己的事。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                    itemCount: notes.length,
                    itemBuilder: (BuildContext context, int i) =>
                        _tile(s, notes[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(AppSurface s, LearningNote n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      _kindChip(s, n.kind),
                      const SizedBox(width: 8),
                      Text(
                        _fmtDate(n.createdAt),
                        style: AppFonts.body(
                          size: 12.5,
                          color: s.muted,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    n.text,
                    style: AppFonts.body(
                      size: 13,
                      color: s.text,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            GlassIconButton(
              icon: Icons.close_rounded,
              tooltip: '删掉这条',
              size: 32,
              iconSize: 16,
              color: AppColors.danger,
              onTap: () => widget.store.remove(n.id),
            ),
          ],
        ),
      ),
    );
  }

  /// 分类小标签。四类用同一套配色 —— 这是"给用户扫一眼"的辅助信息，
  /// 用四种颜色只会让列表更吵。
  Widget _kindChip(AppSurface s, String kind) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: s.chipBg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: s.border, width: 0.8),
      ),
      child: Text(
        LearningStore.kindLabel(kind),
        style: AppFonts.body(
          size: 10.5,
          weight: FontWeight.w600,
          color: s.muted,
          height: 1.2,
        ),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _fmtDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

  Future<void> _confirmClear(BuildContext context) async {
    final int n = widget.store.notes.length;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('清空自学习笔记？'),
        content: Text(
          '$n 条经验会被永久删除，**没有回收站**。\n'
          'AI 之后遇到类似情况会重新学一遍 —— 这不会影响对话记录和记忆。',
          style: AppFonts.body(size: 14, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok == true) widget.store.clear();
  }
}
