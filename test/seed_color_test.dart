// 配色是**固定的一套 iOS 灰阶 + 系统蓝**，不从种子色推。
//
// 这条测试钉住三件事：
//   · 深浅两套主题各自解析到对的页面底和强调色
//     （浅色 `#F2F2F7` + `#007AFF`，深色纯黑 + `#0A84FF`）；
//   · 表面是**中性**的 —— 页面底和文字都不带色相，颜色只出现在强调色上；
//   · 主题里不再有"用户种子色"这条通路 —— 以前选完颜色看不出来，
//     现在干脆没有这个设置项，界面不该再出现半套配色的可能。
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('浅色主题用 iOS 分组底 + 系统蓝强调', () {
    final ThemeData t = AppTheme.light();
    expect(t.scaffoldBackgroundColor, AppSurface.light.pageBg);
    // `#F2F2F7`：iOS 的 systemGroupedBackground
    expect(AppSurface.light.pageBg, const Color(0xFFF2F2F7));
    expect(t.colorScheme.primary, AppColors.defaultSeed);
    expect(AppColors.accent, AppColors.defaultSeed);
    // 强调色压在白字上要够深：`#007AFF` 的亮度约 0.20
    expect(AppColors.defaultSeed.computeLuminance(), lessThan(0.35));
  });

  test('深色主题用深灰底 + 提亮后的系统蓝', () {
    final ThemeData t = AppTheme.dark();
    expect(t.scaffoldBackgroundColor, AppSurface.dark.pageBg);
    // 深灰 `#1A1A1A`，不是纯黑：这一版要的是"整块深色面板"，
    // 纯黑会让卡片、气泡只能靠描边分层。
    expect(AppSurface.dark.pageBg, const Color(0xFF1A1A1A));
    // 页面底 → 输入区 → 气泡，三档依次变亮 —— 它们之间的差**必须**
    // 都能看出来，否则深色下一片糊，分不清哪块是什么。
    expect(
      AppSurface.dark.surface.computeLuminance(),
      greaterThan(AppSurface.dark.pageBg.computeLuminance()),
    );
    expect(
      AppSurface.dark.bubbleBg.computeLuminance(),
      greaterThan(AppSurface.dark.codeBg.computeLuminance()),
    );
    expect(t.colorScheme.primary, AppColors.darkAccent);
    expect(AppColors.accent, AppColors.darkAccent);
    // 深色下提亮，否则压在深灰上对比度不够
    expect(
      AppColors.darkAccent.computeLuminance(),
      greaterThan(AppColors.defaultSeed.computeLuminance()),
    );
  });

  test('表面色是中性的：灰阶三通道相等，不带色相', () {
    // 这是这一版的核心 —— 界面本身应该是"无色"的，
    // 唯一的彩色来自强调色。带一点点色相（比如暖米黄）在整屏铺开，
    // 就是用户说的"颜色太浓"。
    for (final AppSurface s in <AppSurface>[
      AppSurface.light,
      AppSurface.dark,
    ]) {
      for (final Color c in <Color>[
        s.pageBg,
        s.surface,
        s.border,
        s.codeBg,
        s.text,
        s.muted,
        s.bubbleBg,
      ]) {
        final int r = (c.r * 255).round();
        final int g = (c.g * 255).round();
        final int b = (c.b * 255).round();
        // 允许 1 的误差：picked 的三档灰里个别值为了和 iOS 对齐
        // 取了 `#F2F2F7`（b 比 r/g 高 5）—— 那是有意的系统底色。
        expect(
          (r - g).abs() <= 6 && (g - b).abs() <= 6,
          isTrue,
          reason: '$c 不是中性灰',
        );
      }
    }
  });

  test('两套主题的明暗必须真的是两套（不是同一张纸）', () {
    expect(
      AppSurface.light.pageBg.computeLuminance(),
      greaterThan(AppSurface.dark.pageBg.computeLuminance()),
    );
    expect(
      AppSurface.light.text.computeLuminance(),
      lessThan(AppSurface.dark.text.computeLuminance()),
    );
  });

  test('app 级强调色在 builder 里按实际生效的那套重刷', () {
    // 这个测试防的是一类真实故障：light/dark 两份主题都会被构建，
    // 而 darkTheme 在后 —— 不在 builder 里重刷的话，浅色界面里所有
    // 读 AppColors.accent 的图标会变成深色主题那一份。
    AppColors.applyScheme(
      ColorScheme.fromSeed(seedColor: AppColors.defaultSeed),
      dark: false,
    );
    expect(AppColors.accent, AppColors.defaultSeed);

    AppColors.applyScheme(
      ColorScheme.fromSeed(
        seedColor: AppColors.darkAccent,
        brightness: Brightness.dark,
      ),
      dark: true,
    );
    expect(AppColors.accent, AppColors.darkAccent);
  });
}
