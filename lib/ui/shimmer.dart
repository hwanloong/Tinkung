import 'package:flutter/material.dart';

/// 给任意子树套一层**会扫过去的渐变**。
///
/// 用途只有两处：
///  · 模型思考时「工作中 · 12 秒」那一行 —— 数字在跳，但整行是静的，
///    扫光负责告诉用户"它还在跑"；
///  · 流式输出时正文的最后一块 —— 新字是一个一个蹦出来的，
///    扫光让"正在长出来的这一块"和上面已经定稿的块区分开。
///
/// ## 为什么是 `ShaderMask` 而不是 `AnimatedDefaultTextStyle`
///
/// 颜色渐变没法用单个 `TextStyle.color` 表达。`ShaderMask` + `srcIn`
/// 会把渐变**当成文字本身的颜色**：字形外面是透明的，所以只染到字，
/// 不会在段落背景上留下一条光带。
///
/// ## 为什么动画放在 `AnimatedBuilder` 里、child 传进去
///
/// `ShaderMask` 每帧都要重建 shader，但 [child] 不需要重建 ——
/// 流式时正文每帧都在变，如果这里再整块重建一次就是双倍排版。
/// 把 child 固定在 builder 外面，动画帧只重绘画布。
///
/// ## 参数
///
/// [base] 是文字平时的颜色，[highlight] 是扫过时的高光色。
/// 渐变两侧都收敛到 [base]，所以扫光之外的文字颜色完全不变。
class ShimmerMask extends StatefulWidget {
  const ShimmerMask({
    super.key,
    required this.child,
    required this.base,
    required this.highlight,
    this.duration = const Duration(milliseconds: 1600),
    this.band = 0.55,
  });

  final Widget child;

  /// 平时颜色（通常是正文色 / 次要文字色）。
  final Color base;

  /// 扫光高光色。
  final Color highlight;

  /// 扫过一整遍的时间。
  final Duration duration;

  /// 高光带宽度（相对控件宽度的比例，0~1）。
  ///
  /// 0.55 大约覆盖半行字：太窄像一条细线扫过去，太宽整行一直在亮，
  /// 反而看不出方向。
  final double band;

  @override
  State<ShimmerMask> createState() => _ShimmerMaskState();
}

class _ShimmerMaskState extends State<ShimmerMask>
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
    return AnimatedBuilder(
      animation: _c,
      // child 只建一次，动画帧里复用同一个实例。
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        // 从 -1.2 扫到 1.2：两端各留一点余量，让高光完整离开画面后
        // 再从头开始，避免"刚出去一半就折返"的突兀感。
        final double x = -1.2 + 2.4 * _c.value;
        return ShaderMask(
          // srcIn：只在 child 不透明的地方显示渐变 —— 也就是只在字上。
          blendMode: BlendMode.srcIn,
          shaderCallback: (Rect bounds) {
            return LinearGradient(
              begin: Alignment(x - widget.band, 0),
              end: Alignment(x + widget.band, 0),
              colors: <Color>[
                widget.base,
                widget.highlight,
                widget.base,
              ],
              stops: const <double>[0.0, 0.5, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
    );
  }
}
