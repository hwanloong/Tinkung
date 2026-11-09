import 'package:flutter/material.dart';

import '../core/models.dart';
import '../theme/app_theme.dart';
import 'tool_line.dart';

/// 横屏右侧的工具调用表，也给性能页复用。
///
/// 颜色不是装饰：成功绿、失败红、运行中黄。排障时先扫颜色，
/// 再读具体是哪一步。
class ToolCallTable extends StatelessWidget {
  const ToolCallTable({
    super.key,
    required this.tools,
    // 横屏工具表要铺满右栏：默认不留外边距，列宽直接贴板块边缘。
    this.padding = EdgeInsets.zero,
    this.emptyText = '还没有工具调用',
    this.onOpen,
  });

  final List<ToolInvocation> tools;
  final EdgeInsetsGeometry padding;
  final String emptyText;
  final ValueChanged<ToolInvocation>? onOpen;

  static const double _timeWidth = 56;
  static const double _toolWidth = 82;
  static const double _stateWidth = 54;

  /// 行高：表头与数据行用同一档，扫一列时基线不会跳。
  static const double _rowHeight = 44;
  static const double _headHeight = 36;

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final List<ToolInvocation> list = tools.reversed.toList();
    if (list.isEmpty) {
      return Padding(
        padding: padding,
        child: Center(
          child: Text(
            emptyText,
            style: AppFonts.body(size: 13, color: s.muted),
          ),
        ),
      );
    }

    // 整张表收进一个圆角卡片：表头与数据行各自只画分隔线，
    // 外框统一由这里给 —— 否则方角表格浮在圆角页面里很违和。
    return Padding(
      padding: padding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          decoration: BoxDecoration(
            color: s.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: s.border, width: 0.6),
          ),
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              _head(context, s, list.length),
              for (int i = 0; i < list.length; i++)
                _row(context, s, list[i], last: i == list.length - 1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _head(BuildContext context, AppSurface s, int total) {
    return Container(
      height: _headHeight,
      decoration: BoxDecoration(
        color: s.chipBg,
        border: Border(bottom: BorderSide(color: s.border, width: 0.6)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          _cell('时间', _timeWidth, s, bold: true),
          _cell('工具', _toolWidth, s, bold: true),
          Expanded(child: _cell('内容（共 $total 次）', null, s, bold: true)),
          _cell('状态', _stateWidth, s, bold: true),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AppSurface s,
    ToolInvocation inv, {
    bool last = false,
  }) {
    final (IconData icon, String label) = ToolDisplay.of(inv.name);
    final _StateStyle state = _styleOf(inv.status);
    final String content = _argSummary(inv);
    final String time = _clockText(inv.startedAt);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen == null ? null : () => onOpen!(inv),
        child: Container(
          height: _rowHeight,
          decoration: BoxDecoration(
            // 状态色只做一层极薄的底：整行铺色会让表格变成色块拼贴，
            // 而扫读靠的是左侧图标与状态列那一点颜色。
            color: state.tint,
            border: last
                ? null
                : Border(bottom: BorderSide(color: s.border, width: 0.6)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              _cell(time, _timeWidth, s, mono: true),
              SizedBox(
                width: _toolWidth,
                child: Row(
                  children: <Widget>[
                    Icon(icon, size: 14, color: state.color),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 12,
                          color: s.text,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  content.isEmpty ? '（没有参数）' : content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.code(size: 11.2, color: s.text, height: 1.35),
                ),
              ),
              SizedBox(
                width: _stateWidth,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    Icon(state.icon, size: 13, color: state.color),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        state.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.body(
                          size: 10.5,
                          weight: FontWeight.w600,
                          color: state.color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(
    String text,
    double? width,
    AppSurface s, {
    bool bold = false,
    bool mono = false,
  }) {
    final Widget child = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: mono
          ? AppFonts.code(size: 10.8, color: s.muted)
          : AppFonts.body(
              size: 11,
              weight: bold ? FontWeight.w600 : FontWeight.w500,
              color: bold ? s.text : s.muted,
              height: 1.3,
            ),
    );
    return width == null ? child : SizedBox(width: width, child: child);
  }

  static String _clockText(DateTime? t) {
    if (t == null) return '—';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _argSummary(ToolInvocation inv) {
    for (final String k in <String>['command', 'query', 'path', 'url']) {
      final String v = inv.args[k]?.toString().trim() ?? '';
      if (v.isNotEmpty) return v.replaceAll(RegExp(r'\s+'), ' ');
    }
    final String raw = inv.argumentsJson.trim();
    if (raw.isEmpty || raw == '{}') return '';
    return raw.replaceAll(RegExp(r'\s+'), ' ');
  }

  static _StateStyle _styleOf(InvocationStatus status) {
    switch (status) {
      // ---- 行的底色一律**透明**，状态只靠左边那颗小字和图标 ----
      //
      // 原来成功行铺了一层 7.5% 的绿。在暖米黄底上它还很淡，
      // 换成中性的灰底之后，同一层绿会显成一块**明显的浅绿横条** ——
      // 一整张表里几行绿的、几行红的，就是用户说的"颜色太浓"。
      //
      // iOS 的列表行没有状态底色：状态是那个绿色的对勾 + 灰色文字，
      // 底色始终是页面本身。所以这里只保留 `color`（用于图标和文字），
      // tint 全部留空。
      case InvocationStatus.success:
        return _StateStyle(
          label: '成功',
          color: AppColors.success,
          tint: Colors.transparent,
          icon: Icons.check_circle_outline_rounded,
        );
      case InvocationStatus.failed:
        return _StateStyle(
          label: '失败',
          color: AppColors.danger,
          tint: Colors.transparent,
          icon: Icons.error_outline_rounded,
        );
      case InvocationStatus.rejected:
        return _StateStyle(
          label: '拒绝',
          color: AppColors.danger,
          tint: Colors.transparent,
          icon: Icons.block_rounded,
        );
      // 「进行中 / 等确认」也不铺底色，理由同上。
      // 这两个状态本身会**动**（转圈、待确认的图标），那已经足够醒目，
      // 再加一层橙底只会让整张表在运行期间一闪一闪地发黄。
      case InvocationStatus.running:
        return _StateStyle(
          label: '进行中',
          color: AppColors.warning,
          tint: Colors.transparent,
          icon: Icons.autorenew_rounded,
        );
      case InvocationStatus.awaitingConfirm:
        return _StateStyle(
          label: '等确认',
          color: AppColors.warning,
          tint: Colors.transparent,
          icon: Icons.pending_outlined,
        );
    }
  }
}

class _StateStyle {
  const _StateStyle({
    required this.label,
    required this.color,
    required this.tint,
    required this.icon,
  });

  final String label;
  final Color color;
  final Color tint;
  final IconData icon;
}
