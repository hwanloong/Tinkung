import 'package:flutter/material.dart';

import '../core/file_diff.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// 打开一个文件的「逐行修改」面板。
///
/// 删除行红底、添加行绿底，左边两列分别是**原行号 / 新行号**。
/// 文件卡片里点一行修改过的文件时走这里；没记录到差异的文件仍然走系统
/// 打开方式（见 `_GeneratedFilesState._open`）。
Future<void> showFileDiffSheet(
  BuildContext context, {
  required FileChange change,
  Future<void> Function()? onOpenFile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) =>
        _FileDiffSheet(change: change, onOpenFile: onOpenFile),
  );
}

class _FileDiffSheet extends StatelessWidget {
  const _FileDiffSheet({required this.change, this.onOpenFile});

  final FileChange change;
  final Future<void> Function()? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final MediaQueryData mq = MediaQuery.of(context);
    final double upper = mq.size.height - mq.padding.top - 12;
    final double maxH = (mq.size.height * 0.86).clamp(
      200.0,
      upper > 200 ? upper : 200.0,
    );

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        // 底部弹层：玻璃的 floating 档，顶部圆角。
        // 圆角不能用 `SurfaceCard`（它是四角都圆的），所以这里直接用
        // 玻璃基元的 radius，只画顶部两角 —— 但玻璃形状只支持四角同半径，
        // 这里保留四角圆，贴底那两角被 SafeArea 推到屏幕外，视觉上等价。
        child: SurfaceCard(
          role: GlassRole.floating,
          radius: AppRadius.sheet,
          padding: EdgeInsets.zero,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(context, s),
            Divider(height: 0.6, color: s.border),
            _legend(s),
            Flexible(
              child: SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: change.lines.length,
                  itemBuilder: (BuildContext context, int i) =>
                      _line(context, s, change.lines[i]),
                ),
              ),
            ),
            if (onOpenFile != null) _footer(context, s),
          ],
        ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, AppSurface s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
      child: Row(
        children: <Widget>[
          // 和存储 / 插件那几页的列表行同一种图标块：34×34、code 圆角、
          // 强调色 12% 底。同一个应用里"这类行"应该是同一个样子。
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.code),
            ),
            child: Icon(
              Icons.difference_outlined,
              size: 18,
              color: AppColors.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  change.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.body(
                    size: 14.5,
                    weight: FontWeight.w600,
                    color: s.text,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    change.isNew ? '新增文件' : '修改文件',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(size: 12.5, color: s.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _stat(
            s,
            '+${change.additions}',
            AppColors.success,
            '新增 ${change.additions} 行',
          ),
          const SizedBox(width: 6),
          _stat(
            s,
            '-${change.deletions}',
            AppColors.danger,
            '删除 ${change.deletions} 行',
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close_rounded, size: 19),
            color: s.muted,
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _stat(AppSurface s, String text, Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: s.isDark ? 0.18 : 0.10),
          // 增减计数是个小色标，用胶囊档 —— 内缩到 12 的话在 22 高的
          // chip 上会变成一块圆得没道理的方块。
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          text,
          style: AppFonts.code(size: 11, weight: FontWeight.w600, color: color),
        ),
      ),
    );
  }

  Widget _legend(AppSurface s) {
    // 列名用 muted 11.5/w600 —— 和存储、插件页的分组标题同一档，
    // 这样它读起来是"一列的标签"，而不是又一行正文。
    final TextStyle label = AppFonts.body(
      size: 11.5,
      weight: FontWeight.w600,
      color: s.muted,
      height: 1.3,
    );
    return Container(
      color: s.chipBg,
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 34,
            child: Text('原行', textAlign: TextAlign.right, style: label),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 34,
            child: Text('新行', textAlign: TextAlign.right, style: label),
          ),
          const SizedBox(width: 14),
          Text('内容', style: label),
          const Spacer(),
          if (change.truncated) Text('改动较多，已折叠部分', style: label),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, AppSurface s, DiffLine line) {
    if (line.kind == DiffKind.skip) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        child: Text(
          line.text,
          style: AppFonts.body(size: 10.8, color: s.muted, height: 1.35),
        ),
      );
    }

    final bool added = line.kind == DiffKind.added;
    final bool removed = line.kind == DiffKind.removed;
    final Color? bg = added
        ? AppColors.success.withValues(alpha: s.isDark ? 0.14 : 0.09)
        : removed
        ? AppColors.danger.withValues(alpha: s.isDark ? 0.15 : 0.08)
        : null;
    // 增删色直接用主题的语义色：同一套暖调里已经调过深浅两档，
    // 这里再写一套 iOS 绿/红会和整页的配色打架。
    final Color textColor = added
        ? AppColors.success
        : removed
        ? AppColors.danger
        : s.text;
    final String prefix = added
        ? '+'
        : removed
        ? '-'
        : ' ';
    final Color oldLineColor = removed ? textColor : s.muted;
    final Color newLineColor = added ? textColor : s.muted;

    return Container(
      color: bg,
      padding: const EdgeInsets.fromLTRB(10, 3, 10, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 34,
            child: Text(
              line.oldLine?.toString() ?? '',
              textAlign: TextAlign.right,
              style: AppFonts.code(
                size: 10.8,
                weight: removed ? FontWeight.w600 : FontWeight.w400,
                color: oldLineColor,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 34,
            child: Text(
              line.newLine?.toString() ?? '',
              textAlign: TextAlign.right,
              style: AppFonts.code(
                size: 10.8,
                weight: added ? FontWeight.w600 : FontWeight.w400,
                color: newLineColor,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 10,
            child: Text(
              prefix,
              style: AppFonts.code(
                size: 11.5,
                weight: FontWeight.w600,
                color: textColor,
                height: 1.45,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              line.text.isEmpty ? ' ' : line.text,
              style: AppFonts.code(size: 11.5, color: textColor, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context, AppSurface s) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: s.border, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '红色为删除，绿色为新增；左侧两列是原行号与新行号。',
              style: AppFonts.body(size: 11.5, color: s.muted, height: 1.35),
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              await onOpenFile!();
              if (context.mounted) Navigator.of(context).maybePop();
            },
            icon: const Icon(Icons.open_in_new_rounded, size: 15),
            label: const Text('打开文件'),
          ),
        ],
      ),
    );
  }
}
