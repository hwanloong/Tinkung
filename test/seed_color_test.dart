// 全局 Material You：种子色决定**整套**配色，不是只换一个强调色。
//
// 旧版本这里钉的是"配色固定成一套 iOS 灰阶 + 系统蓝、表面必须中性、
// 种子色通路已被移除"。那一版已经被"设置里可选种子色"推翻：现在
// ColorScheme.fromSeed 推出的表面色必须一路下发到 Material 组件、
// AppSurface 扩展和全局静态 AppColors，三处同源才算全局生效。
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const Color blue = Color(0xFF2196F3);
  const Color green = Color(0xFF4CAF50);

  AppSurface surfaceOf(ThemeData t) => t.extension<AppSurface>()!;

  test('不同种子色推出不同的 primary', () {
    expect(
      AppTheme.light(seed: blue).colorScheme.primary,
      isNot(AppTheme.light(seed: green).colorScheme.primary),
    );
  });

  test('表面色整套来自 ColorScheme 的 tonal 阶梯，不再是写死的灰', () {
    final ThemeData t = AppTheme.light(seed: blue);
    final AppSurface s = surfaceOf(t);
    expect(s.pageBg, t.colorScheme.surface);
    expect(s.surface, t.colorScheme.surfaceContainerLow);
    expect(s.codeBg, t.colorScheme.surfaceContainerHighest);
    expect(s.chipBg, t.colorScheme.surfaceContainerHigh);
    expect(s.bubbleBg, t.colorScheme.surfaceContainerHigh);
    expect(s.text, t.colorScheme.onSurface);
    expect(s.muted, t.colorScheme.onSurfaceVariant);
    expect(s.border, t.colorScheme.outlineVariant);
    expect(t.scaffoldBackgroundColor, s.pageBg);
    // 旧实现把表面钉死在这一档 iOS 灰上，换种子色完全看不出来。
    expect(s.pageBg, isNot(AppSurface.light.pageBg));
  });

  test('换种子色时自定义组件读到的表面也跟着换', () {
    final AppSurface a = surfaceOf(AppTheme.light(seed: blue));
    final AppSurface b = surfaceOf(AppTheme.light(seed: green));
    expect(a.pageBg, isNot(b.pageBg));
    expect(a.bubbleBg, isNot(b.bubbleBg));
  });

  test('跟随系统壁纸时直接用系统给的 ColorScheme', () {
    final ColorScheme system = ColorScheme.fromSeed(
      seedColor: green,
      brightness: Brightness.light,
    );
    final ThemeData t = AppTheme.light(seed: blue, fromSystem: system);
    expect(t.colorScheme, system);
    expect(t.colorScheme.primary, system.primary);
    expect(surfaceOf(t).pageBg, system.surface);
  });

  test('全局静态强调色按当前 scheme 刷新，不再是写死的陶土橙', () {
    final ColorScheme scheme = ColorScheme.fromSeed(seedColor: blue);
    AppColors.applyScheme(scheme, dark: false);
    expect(AppColors.accent, scheme.primary);
    expect(AppColors.onAccent, scheme.onPrimary);
    expect(AppColors.lightBg, scheme.surface);
    expect(AppColors.research, scheme.primary);
    // 语义色不跟主题换色相：红 = 出错这条直觉要保住。
    expect(AppColors.danger, const Color(0xFFFF3B30));
  });

  test('不传种子色时用默认陶土橙', () {
    expect(
      AppTheme.light().colorScheme.primary,
      AppTheme.light(seed: AppColors.defaultSeed).colorScheme.primary,
    );
  });

  test('同一支种子色在明暗两套下仍真的是两套', () {
    final ThemeData l = AppTheme.light(seed: blue);
    final ThemeData d = AppTheme.dark(seed: blue);
    final AppSurface ls = surfaceOf(l);
    final AppSurface ds = surfaceOf(d);
    expect(
      ls.pageBg.computeLuminance(),
      greaterThan(ds.pageBg.computeLuminance()),
    );
    expect(ls.text.computeLuminance(), lessThan(ds.text.computeLuminance()));
    expect(l.colorScheme.primary, isNot(d.colorScheme.primary));
  });
}
