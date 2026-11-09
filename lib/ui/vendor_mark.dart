import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/model_profile.dart';

/// 模型厂商。
///
/// ## 为什么按**地址 + 模型名**猜，而不是让用户选
///
/// 用户绑一个模型时填的是「地址 + key + 模型名」，厂商是这三样推出来的
/// 事实，不是第四个要填的字段 —— 多一个下拉框，用户就得为同一件事
/// 再回答一遍，而答错还会让图标和真身对不上。
///
/// 判据的顺序是 **模型名优先于地址**：中转站（OpenRouter、硅基流动…）
/// 的地址里看不出背后是谁，但模型名里带着（`anthropic/claude-…`、
/// `Qwen/…`）。地址只在模型名认不出来时兜底。
///
/// ## 认不出来就不画
///
/// 未知厂商返回 [VendorMark.unknown]，界面上画一个中性的圆点。
/// 猜一个错的图标比不画更糟：用户靠图标认模型，画错等于认错人。
enum ModelVendor {
  anthropic,
  openai,
  google,
  deepseek,
  moonshot,
  zhipu,
  alibaba,
  meta,
  mistral,
  xai,

  /// 认不出来（中转站的自有模型、未收录的厂商…）
  unknown,
}

/// 从模型档案推断厂商。
ModelVendor vendorOf(ModelProfile? p) {
  if (p == null) return ModelVendor.unknown;
  // 先看模型名，再看地址 —— 见 [ModelVendor] 的说明。
  final String hay = '${p.model} ${p.baseUrl}'.toLowerCase();

  // ---- 模型名里的厂商前缀 / 关键字 ----
  //
  // 顺序有讲究：`claude` / `gpt` / `gemini` 这些词**只**属于一家，
  // 放最前面最不容易被中转站域名误伤。
  if (_has(hay, <String>['claude', 'anthropic', 'fable', 'opus', 'sonnet', 'haiku'])) {
    return ModelVendor.anthropic;
  }
  if (_has(hay, <String>['gpt', 'openai', 'o1-', 'o3-', 'o4-', 'chatgpt'])) {
    return ModelVendor.openai;
  }
  if (_has(hay, <String>['gemini', 'google', 'palm', 'vertex'])) {
    return ModelVendor.google;
  }
  if (_has(hay, <String>['deepseek'])) return ModelVendor.deepseek;
  if (_has(hay, <String>['moonshot', 'kimi'])) return ModelVendor.moonshot;
  if (_has(hay, <String>['glm', 'zhipu', 'bigmodel', 'chatglm'])) {
    return ModelVendor.zhipu;
  }
  if (_has(hay, <String>['qwen', 'tongyi', 'alibaba', 'dashscope', 'qwq'])) {
    return ModelVendor.alibaba;
  }
  if (_has(hay, <String>['llama', 'meta-llama'])) return ModelVendor.meta;
  if (_has(hay, <String>['mistral', 'mixtral', 'codestral'])) {
    return ModelVendor.mistral;
  }
  if (_has(hay, <String>['grok', 'xai'])) return ModelVendor.xai;
  return ModelVendor.unknown;
}

bool _has(String hay, List<String> needles) =>
    needles.any((String n) => hay.contains(n));

/// 厂商图标：**单色线条图形**，跟着文字的前景色走。
///
/// ## 为什么自己画而不是放各家 logo
///
/// 各家 logo 是**注册商标**，随包里分发需要遵守各自的品牌规范
/// （不能改色、不能改比例、要有最小留白…），而这些图标在这里只有
/// 14 像素高、还要跟着深浅色变 —— 两个要求正面冲突。
///
/// 所以这里画的是**几何印象**：让人一眼能把"这是 Claude 还是 GPT"
/// 分开，但它不是任何一家的官方标识。认不出的厂商画一个中性圆点。
class VendorMark extends StatelessWidget {
  const VendorMark({
    super.key,
    required this.vendor,
    this.size = 14,
    this.color,
  });

  /// 直接给厂商。
  final ModelVendor vendor;

  final double size;
  final Color? color;

  /// 从档案推断，省得调用点各处写 `vendorOf(...)`。
  VendorMark.of(ModelProfile? profile, {super.key, this.size = 14, this.color})
    : vendor = vendorOf(profile);

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _VendorPainter(vendor, c)),
    );
  }
}

class _VendorPainter extends CustomPainter {
  _VendorPainter(this.vendor, this.color);

  final ModelVendor vendor;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.11
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Paint fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = s * 0.4;

    switch (vendor) {
      // ---- Claude：几道放射状的短线，像个星芒 ----
      case ModelVendor.anthropic:
        for (int i = 0; i < 8; i++) {
          final double a = i * math.pi / 4 + 0.18;
          final double len = i.isEven ? r : r * 0.62;
          canvas.drawLine(
            c + Offset(math.cos(a), math.sin(a)) * (r * 0.16),
            c + Offset(math.cos(a), math.sin(a)) * len,
            stroke,
          );
        }

      // ---- OpenAI：六边形，里面再套一个错开 30° 的 ----
      case ModelVendor.openai:
        _polygon(canvas, c, r, 6, -math.pi / 2, stroke);
        _polygon(canvas, c, r * 0.52, 6, -math.pi / 2 + math.pi / 6, stroke);

      // ---- Google：四角星 ----
      case ModelVendor.google:
        final Path p = Path();
        for (int i = 0; i < 8; i++) {
          final double a = i * math.pi / 4 - math.pi / 2;
          final double rad = i.isEven ? r : r * 0.34;
          final Offset pt = c + Offset(math.cos(a), math.sin(a)) * rad;
          if (i == 0) {
            p.moveTo(pt.dx, pt.dy);
          } else {
            p.lineTo(pt.dx, pt.dy);
          }
        }
        p.close();
        canvas.drawPath(p, fill);

      // ---- DeepSeek：两段波浪 ----
      case ModelVendor.deepseek:
        for (int row = 0; row < 2; row++) {
          final double y = c.dy + (row == 0 ? -r * 0.38 : r * 0.38);
          final Path p = Path()..moveTo(c.dx - r, y);
          p.quadraticBezierTo(c.dx - r * 0.5, y - r * 0.55, c.dx, y);
          p.quadraticBezierTo(c.dx + r * 0.5, y + r * 0.55, c.dx + r, y);
          canvas.drawPath(p, stroke);
        }

      // ---- Kimi：月牙（一个大圆挖掉一个偏右上的圆） ----
      case ModelVendor.moonshot:
        final Path disc = Path()
          ..addOval(Rect.fromCircle(center: c, radius: r));
        final Path bite = Path()
          ..addOval(
            Rect.fromCircle(
              center: c + Offset(r * 0.62, -r * 0.45),
              radius: r * 0.9,
            ),
          );
        canvas.drawPath(
          Path.combine(PathOperation.difference, disc, bite),
          fill,
        );

      // ---- 智谱：一个 Z ----
      case ModelVendor.zhipu:
        canvas.drawLine(
          c + Offset(-r * 0.7, -r * 0.6),
          c + Offset(r * 0.7, -r * 0.6),
          stroke,
        );
        canvas.drawLine(
          c + Offset(r * 0.7, -r * 0.6),
          c + Offset(-r * 0.7, r * 0.6),
          stroke,
        );
        canvas.drawLine(
          c + Offset(-r * 0.7, r * 0.6),
          c + Offset(r * 0.7, r * 0.6),
          stroke,
        );

      // ---- 通义：三道斜线 ----
      case ModelVendor.alibaba:
        for (int i = -1; i <= 1; i++) {
          final double x = i * r * 0.55;
          canvas.drawLine(
            c + Offset(x - r * 0.3, r * 0.7),
            c + Offset(x + r * 0.3, -r * 0.7),
            stroke,
          );
        }

      // ---- Meta：两个交叠的圆 ----
      case ModelVendor.meta:
        canvas.drawCircle(c + Offset(-r * 0.34, 0), r * 0.66, stroke);
        canvas.drawCircle(c + Offset(r * 0.34, 0), r * 0.66, stroke);

      // ---- Mistral：三道横线，上长下短 ----
      case ModelVendor.mistral:
        final List<double> widths = <double>[1.0, 0.72, 0.44];
        for (int i = 0; i < widths.length; i++) {
          final double y = c.dy + (i - 1) * r * 0.5;
          final double half = r * widths[i];
          canvas.drawLine(
            Offset(c.dx - half, y),
            Offset(c.dx + half, y),
            stroke,
          );
        }

      // ---- xAI：交叉的 X ----
      case ModelVendor.xai:
        canvas.drawLine(c + Offset(-r * 0.7, -r * 0.7), c + Offset(r * 0.7, r * 0.7), stroke);
        canvas.drawLine(c + Offset(r * 0.7, -r * 0.7), c + Offset(-r * 0.7, r * 0.7), stroke);

      // ---- 认不出来：一个中性圆点 ----
      case ModelVendor.unknown:
        canvas.drawCircle(c, r * 0.32, fill);
    }
  }

  void _polygon(
    Canvas canvas,
    Offset c,
    double r,
    int sides,
    double startAngle,
    Paint paint,
  ) {
    final Path p = Path();
    for (int i = 0; i < sides; i++) {
      final double a = startAngle + i * 2 * math.pi / sides;
      final Offset pt = c + Offset(math.cos(a), math.sin(a)) * r;
      if (i == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    p.close();
    canvas.drawPath(p, paint);
  }

  @override
  bool shouldRepaint(covariant _VendorPainter old) =>
      old.vendor != vendor || old.color != color;
}
