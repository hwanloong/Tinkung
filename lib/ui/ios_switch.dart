import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 一枚开关。全应用所有"开 / 关"都用它。
///
/// 名字还叫 `IosSwitch` 是**历史遗留**：做 iOS 观感时它包的是
/// `CupertinoSwitch`。整套 UI 回到 M3 Expressive 之后，内部已经换成
/// Material 3 的 `Switch`（滑块会拉伸回弹，那才是 Android 16 的手感），
/// 但公开接口没变，所以 11 个调用点一处都没改。
///
/// 改名会牵动 11 个文件却没有任何行为收益，所以留着这个名字，
/// 由这段注释负责说明它现在到底是什么。
/// · 本应用的 Material 开关是 **M2** 的（`useMaterial3: false`）：33×14 的
///   细轨道 + 直径 20 的圆点，看着是"一个点在轨道里滑"；
/// · iOS 的是 51×31 的胶囊 + 直径 28 的拇指，几乎顶满轨道，位移等于整个
///   内宽 —— 看着是"一整块把轨道推过去"。
///
/// 这个比例写在 `Switch` 自己的绘制代码里，`SwitchThemeData` 只能改颜色
/// 和尺寸（改尺寸还是等比缩放，比例不变）—— 所以之前在
/// `app_theme.dart` 里加的那套 `switchTheme` 注定没用，只能换成真的
/// `CupertinoSwitch`。那段主题配置就留给还用着 Material 开关的地方
/// （比如系统弹出的菜单），不必删。
///
/// ## 尺寸：为什么外面还要套一层 `SizedBox(59, 44)`
///
/// `CupertinoSwitch` 自己只占 **51×31**，这两个数写死在 Cupertino 的度量里
/// （`_kTrackWidth` / `_kTrackHeight`），改不了。
///
/// 被它替换掉的 Material 开关实际占的是 **59×40** —— 这个数不是猜的，
/// 也不是 M3 的 60×48：本应用 `useMaterial3: false`（M2），且
/// `switchTheme` 里把 `materialTapTargetSize` 设成了 `shrinkWrap`，
/// 于是高度停在 40 而不是 48；宽度 59 是 M2 自己算出来的
/// （轨道 33 − 轨道高 14 + 最小尺寸 40，用来给直径 20 的圆点留出外沿）。
///
/// 所以：
/// · **宽 59**：和原来一样（M2 的开关自己就是 59 宽，没有额外内边距）。
///   开关那一行的右侧因此不多不少，换完之后文字、图标的位置不动。
/// · **高 44**：这是 iOS HIG 的最小可点尺寸，比原来的 40 高 4。
///   40 能让每行行高纹丝不动，但那样点击区仍然低于 44 ——
///   宁可多这 4px，也不要一个"看着像 iOS、按起来还是难按"的开关。
///   代价写在下面的「行高影响」里。
///
/// ## 行高影响（实测）
///
/// 可见的开关是**变大**了：M2 的轨道只有 14 高（圆点 20），iOS 的是 31。
/// 但外框只从 40 变成 44，所以只有当一行里其它内容**不足 44 高**时行高
/// 才会变。实测会 +4px 的只有这几处「单行 + 开关」的紧凑卡片：
/// 规则列表的每一行、插件卡片、工具卡片；
/// 设置里那种「标题 + 一段说明」的行本来就比 44 高，完全不变。
///
/// ## 触控：为什么外面还要一层 `GestureDetector`
///
/// `CupertinoSwitch` 的点击区就是它那 51×31，高度 31 **不足 44**，
/// 直接换过来会比原来的 Material 开关更难按。外层 `GestureDetector`
/// 把外框里空出来的那一圈也接过来（4px 的横向 + 6.5px 的纵向余量）。
///
/// 不会切两次：点在开关本体上时，内层 `CupertinoSwitch` 自己的点击识别器
/// 在命中路径里更深、先进手势竞技场，因此赢下这一下 —— 外层的 `onTap`
/// 不会跟着触发。而"切两次"等于没切，是最容易踩的坑，所以这里刻意
/// 只在外层再挂一次同样的取反，而不是去猜内层有没有处理。
/// （这条已经用 widget test 实测过：本体、下缘、右缘各点一次，各只 +1。）
class IosSwitch extends StatelessWidget {
  const IosSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  /// 当前是开还是关。
  final bool value;

  /// 用户拨动时回调。**传 null 就是禁用**（Cupertino 自己会画成半透明）。
  final ValueChanged<bool>? onChanged;

  /// "开"态的轨道色。
  ///
  /// 默认是 [AppColors.accent]，但这里只能写成可空 + 在 build 里兜底：
  /// 默认参数必须是编译期常量，而 `AppColors.accent` 是**可变**的
  /// （换配色方案时会被 `applyScheme` 改写）。写成 `const` 默认值的话，
  /// 开关会在换主题后永远停在打开应用时那个颜色。
  final Color? activeColor;

  /// 触控 / 布局外框。取值见类注释：宽度对齐被替换掉的 Material 开关，
  /// 高度取 HIG 的 44 下限。
  static const Size boxSize = Size(59, 44);

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final bool enabled = onChanged != null;

    return SizedBox(
      width: boxSize.width,
      height: boxSize.height,
      child: GestureDetector(
        // opaque：外框里没有子组件的那一圈也算命中，否则只有中间
        // 那条轨道能点，等于白套了一层。
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Center(
          // ---- 用 **Material 3 的开关**，不是 Cupertino 的 ----
          //
          // 这个组件最初叫 `IosSwitch`，做 iOS 观感时包的是
          // `CupertinoSwitch`。后来整套 UI 回到 M3 Expressive，
          // 它就成了唯一还留着 iOS 手感的地方 —— 而且 iOS 开关的滑块
          // 只是平移、几乎没有动画，用户反馈"打开关闭没有动画"。
          //
          // M3 开关的滑块在切换时会**拉伸再回弹**，那正是 Android 16
          // 的手感。公开接口（value / onChanged / activeColor / boxSize）
          // 一个都没变，所以 11 个调用点不用改。
          child: Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.onAccent,
            activeTrackColor: activeColor ?? AppColors.accent,
            // 关态也走主题：硬编码纯白/纯黑在暖纸底上会显得发冷
            //（白得像系统控件，黑得像脏点）。关态的轨道用描边色，
            // 滑块用卡片面。
            inactiveThumbColor: s.surface,
            inactiveTrackColor: s.border.withValues(alpha: 0.55),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}
