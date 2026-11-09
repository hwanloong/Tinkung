import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 「正在思考 / 正在工作」的指示器：**一枚会呼吸的图标**。
///
/// ## 为什么不是三个点、不是转圈
///
/// 两个都用过，都被否掉：
///
/// · **三个点（`…`）** 是"打字中"的符号，在聊天里一天出现几十次，
///   用户明确要求"所有三点都去掉"——它确实太像省略号，会跟正文里的
///   标点混在一起。
/// · **转圈**是加载器的通用符号，但它有"进度未知、可能需要很久"的意味，
///   而这里大多数时候只是 300ms 的工具调用。转圈一闪而过反而更吵。
/// · **会滑动的光带 / 竖条**试过一版：16dp 下宽 16、高 3，
///   看起来就是一截右端亮一点的灰条 —— 不是"在动"，是"画坏了"。
///
/// ## 为什么是"图标呼吸"
///
/// 思考行静止后本来就显示 `Icons.psychology_outlined`（15dp、灰）。
/// 让**同一枚图标**在原地呼吸，有三个好处：
///
/// 1. **列对齐是必然的**：同一个字形、同一个尺寸、同一个居中规则，
///    正在思考和"已思考 3.2 秒"两行的图标**逐像素重合**。
///    换任何别的形状（环、点、弧）都要重新标定一次基线补偿。
/// 2. **语义连续**：从"思考中"过渡到"已思考"，图标不换形，
///    只有动画停下，读起来是"想完了"，而不是"换了个东西"。
/// 3. **不会撞车**：没有方向、没有轨道、没有点数，
///    不会被读成省略号 / 进度条 / 单选按钮。
///
/// ## 参数怎么定的
///
/// 透明度 0.45 → 1.0（α 太低会像禁用态，太高看不出在变），
/// 背后一圈很淡的柔光同步呼吸（半径 0.34→0.48 倍、α 0.10→0.24）。
/// 柔光负责"这一行活着"，但又淡到不会成为一个视觉焦点。
///
/// **不做缩放**：缩放会让每帧的墨迹边缘重新采样，小尺寸下会抖；
/// 而且图标列里一涨一缩，扫视时像在闪。透明度 + 柔光已经够了。
///
/// 尺寸与静止态一致（默认 15），不额外撑高行；[ToolRow] 的
/// `iconNudge` 直接复用 `toolIconNudge(icon)`，和静止态同一张表。
class WorkingPulse extends StatefulWidget {
  const WorkingPulse({
    super.key,
    this.size = 15,
    this.icon = Icons.psychology_outlined,
    this.color,
    this.duration = const Duration(milliseconds: 1300),
  });

  /// 图标边长。和它静止时的 `Icon(size:)` 保持一致，否则两行会一高一低。
  final double size;

  /// 呼吸的那枚图标。工具行里传工具自己的图标，
  /// 这样"执行中"和"已完成"是同一个形状，只是动画停了。
  final IconData icon;

  final Color? color;

  /// 一次完整的呼吸（亮→暗→亮）。
  final Duration duration;

  @override
  State<WorkingPulse> createState() => _WorkingPulseState();
}

class _WorkingPulseState extends State<WorkingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color base =
        widget.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final double d = widget.size;

    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // 只重绘这一层：柔光每帧都在变，图标本身不用重建。
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _c,
              builder: (BuildContext context, Widget? child) {
                final double e = _ease(_c.value);
                return CustomPaint(
                  painter: _HaloPainter(
                    center: Offset(d / 2, d / 2),
                    radius: d * (0.34 + 0.14 * e),
                    color: base,
                    alpha: 0.10 + 0.14 * e,
                  ),
                );
              },
            ),
          ),
          AnimatedBuilder(
            animation: _c,
            builder: (BuildContext context, Widget? child) {
              final double e = _ease(_c.value);
              return Opacity(opacity: 0.45 + 0.55 * e, child: child);
            },
            // 图标只在 State 初始化时建一次，动画帧里复用同一个 child。
            child: Icon(widget.icon, size: d, color: base),
          ),
        ],
      ),
    );
  }

  /// 余弦缓动：两端都停得住，中段快 —— 像呼吸，不像闪烁。
  static double _ease(double t) => 0.5 - 0.5 * math.cos(t * 2 * math.pi);
}

/// 一圈没有硬边的径向柔光。
///
/// 用渐变而不是 `stroke` 的圆：16dp 下 1px 的环会被抗锯齿糊成一圈灰边，
/// 看着像"画歪了的单选按钮"；柔光的边界是渐隐的，不会被读成某个控件的轮廓。
class _HaloPainter extends CustomPainter {
  _HaloPainter({
    required this.center,
    required this.radius,
    required this.color,
    required this.alpha,
  });

  final Offset center;
  final double radius;
  final Color color;
  final double alpha;

  @override
  void paint(Canvas canvas, Size size) {
    // α 归零就直接不画：省一次渐变着色器的构建。
    if (alpha <= 0.001 || radius <= 0) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.radius != radius || old.alpha != alpha || old.color != color;
}
