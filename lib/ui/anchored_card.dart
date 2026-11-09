import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// 卡片水平方向贴锚点的哪条边。
///
/// 输入框上的弹层用 [CardAlign.left]：卡片左沿和输入框左沿对齐，看起来是
/// "从输入框里长出来的一张卡"。右上角菜单用 [CardAlign.right]：右沿和按钮对齐。
enum CardAlign { left, center, right }

/// 锚定在某个矩形旁边弹出的**模糊玻璃小卡片**。
///
/// ## 为什么不用 showModalBottomSheet
///
/// 底部弹层是"半个屏幕从底下抬起来"，和我们要的小卡片是两种东西：
/// 它不知道按钮在哪，只能贴底。这里反过来，卡片**从锚点长出来**：
/// 锚点在输入框上，卡片就在输入框上方；锚点在右上角，卡片就在右上角下方。
/// 放不下就翻到另一侧，永远不超出屏幕。
///
/// ## 为什么要 [anchorBuilder] 而不是一个固定矩形
///
/// 传进来的矩形是**打开那一刻**量的。可输入框会动：
///  · 点按钮时 `showGeneralDialog` 会抢走输入框的焦点 → 输入法收起 →
///    输入框整体下移几十像素；
///  · 多行输入、挂了附件、出现 `@` 面板时，输入框自己也会变高。
///
/// 只量一次的话，卡片会停在"输入框刚才的位置"，和它之间裂开一条缝 ——
/// 用户的原话是"不会贴紧输入框"。
///
/// 所以真正的锚点是一个**函数**：`_CardFollower` 每帧重新取一次，
/// 变化了就重建位置。卡片于是始终贴在输入框上沿，跟着它一起动。
///
/// 另外 `requestFocus: false` 让弹层**不抢焦点**：输入法不收起，
/// 卡片和输入框都不会动，看起来就是"从输入框上方长出来"。
///
/// ## 关闭
///
/// 点卡片外面任意一处就关（透明遮罩），不需要专门的关闭按钮。
Future<T?> showAnchoredCard<T>(
  BuildContext context, {
  Rect? anchor,
  Rect Function()? anchorBuilder,
  required Widget Function(BuildContext ctx) builder,
  double width = 220,
  double gap = 8,
  bool preferAbove = true,
  CardAlign align = CardAlign.right,
  EdgeInsetsGeometry cardPadding = const EdgeInsets.symmetric(vertical: 6),
}) {
  assert(
    anchor != null || anchorBuilder != null,
    'anchor 或 anchorBuilder 至少给一个',
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    // 不抢焦点：输入法保持打开，输入框就不会在弹层出现的瞬间往下掉。
    requestFocus: false,
    pageBuilder: (BuildContext ctx, Animation<double> a1, Animation<double> a2) {
      return _CardFollower(
        rectOf: () => anchorBuilder?.call() ?? anchor!,
        cardBuilder: (BuildContext fctx, Rect box) {
          final Size screen = MediaQuery.sizeOf(fctx);
          final EdgeInsets pad = MediaQuery.paddingOf(fctx);
          // 宽度不超过屏幕，左右各留 8。
          final double w = width.clamp(0, screen.width - 16).toDouble();

          final double rawLeft = switch (align) {
            CardAlign.left => box.left,
            CardAlign.center => box.center.dx - w / 2,
            CardAlign.right => box.right - w,
          };
          final double left =
              rawLeft.clamp(8.0, screen.width - w - 8).toDouble();

          // 优先放在锚点上方；上方放不下就翻到下方。
          final double maxH = screen.height * 0.6;
          final double spaceAbove = box.top - pad.top - gap - 8;
          final double spaceBelow =
              screen.height - box.bottom - pad.bottom - gap - 8;
          final bool above = preferAbove
              ? spaceAbove >= 160 || spaceAbove >= spaceBelow
              : spaceBelow < 160 && spaceAbove > spaceBelow;

          // 卡片高度不能超过它那一侧剩下的空间 —— 否则锚点靠下时
          // （输入框上的弹层全是这种）卡片会长到屏幕外面去。
          final double limit = above ? spaceAbove : spaceBelow;
          final double height = math.min(maxH, math.max(0.0, limit));

          final Widget card = Material(
            color: Colors.transparent,
            child: SizedBox(
              width: w,
              child: SurfaceCard(
                role: GlassRole.floating,
                radius: AppRadius.card,
                padding: cardPadding,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height),
                  child: SingleChildScrollView(child: builder(fctx)),
                ),
              ),
            ),
          );

          return Stack(
            children: <Widget>[
              Positioned(
                left: left,
                width: w,
                top: above ? null : box.bottom + gap,
                bottom: above ? screen.height - box.top + gap : null,
                child: card,
              ),
            ],
          );
        },
      );
    },
    transitionBuilder:
        (BuildContext tctx, Animation<double> anim, Animation<double> _, Widget child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
          ),
          alignment: switch (align) {
            CardAlign.left => Alignment.bottomLeft,
            CardAlign.center => Alignment.bottomCenter,
            CardAlign.right => Alignment.bottomRight,
          },
          child: child,
        ),
      );
    },
  );
}

/// 跟一次锚点：位置变了就重建。
///
/// ## 为什么不是"每帧都跟"
///
/// 每帧都跑一个 ticker 会让 `pumpAndSettle` 永远等不到静止（测试直接超时），
/// 真机上也在白白耗电。实际上输入框只在三种时刻移动：
///  · 键盘弹出 / 收起（窗口 metrics 变化 → [didChangeMetrics]）；
///  · 输入框变高（换行、挂附件）—— 都发生在打开弹层之后的一小段时间内；
///  · 页面转屏（同样是 metrics 变化）。
///
/// 所以这里只做两件事：监听 metrics 变化，再在打开后的 600ms 内**补量几次**，
/// 覆盖"弹层出现 → 键盘动画结束"这段窗口。之后彻底静止。
class _CardFollower extends StatefulWidget {
  const _CardFollower({required this.rectOf, required this.cardBuilder});

  final Rect Function() rectOf;
  final Widget Function(BuildContext ctx, Rect anchor) cardBuilder;

  @override
  State<_CardFollower> createState() => _CardFollowerState();
}

class _CardFollowerState extends State<_CardFollower>
    with WidgetsBindingObserver {
  late Rect _rect;
  final List<Timer> _checks = <Timer>[];

  @override
  void initState() {
    super.initState();
    _rect = widget.rectOf();
    WidgetsBinding.instance.addObserver(this);
    // 键盘收起 / 旋转都会改 metrics；这里再补几次，覆盖动画期间量到的
    // "中间位置"（动画没结束时 localToGlobal 拿到的是过渡值）。
    for (final int ms in <int>[60, 140, 240, 360, 520]) {
      _checks.add(Timer(Duration(milliseconds: ms), _remeasure));
    }
  }

  void _remeasure() {
    if (!mounted) return;
    final Rect next = widget.rectOf();
    if (next != _rect) setState(() => _rect = next);
  }

  @override
  void didChangeMetrics() {
    // 键盘 / 导航栏 / 转屏：输入框会跟着动，重新贴一次。
    _remeasure();
  }

  @override
  void dispose() {
    for (final Timer t in _checks) {
      t.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.cardBuilder(context, _rect);
}

/// 取一个 widget 在屏幕上的矩形；取不到返回 null。
Rect? rectOfKey(GlobalKey key, {BuildContext? ancestor}) {
  final RenderBox? box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  final Offset topLeft = box.localToGlobal(Offset.zero);
  return topLeft & box.size;
}
