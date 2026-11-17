// 字体选项的纯函数测试。
//
// 这些逻辑不涉及界面，但错一次全应用都会"字体看起来不对"：
//  · 中文必须出现在**兜底链**里（否则中文变成空心方块）；
//  · 代码字体必须保留等宽兜底（否则代码块对不齐）；
//  · 存档里存着已下线的 id 时必须能回落到第一个选项（否则设置页打不开）。
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/theme/font_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    // 静态字段是全局的：每个用例结束后恢复默认，避免影响别的测试文件。
    AppFonts.applyFonts(
      latinFamily: 'Inter',
      cjkFamily: '',
      codeFamily: 'monospace',
    );
  });

  test('resolveFont 找不到 id 时回落到第一项', () {
    expect(resolveFont(kLatinFonts, 'does-not-exist').id, 'inter');
    expect(resolveFont(kCjkFonts, 'nope').id, 'system');
    expect(resolveFont(kCodeFonts, 'nope').id, 'monospace');
  });

  test('记住的选项能原样取回', () {
    expect(resolveFont(kLatinFonts, 'serif').family, 'serif');
    expect(resolveFont(kCjkFonts, 'mono').family, 'monospace');
    expect(resolveFont(kCodeFonts, 'sans').family, 'sans-serif');
  });

  test('applyFonts：中文进兜底链，且 sans-serif 总在最后', () {
    AppFonts.applyFonts(
      latinFamily: 'Inter',
      cjkFamily: 'serif',
      codeFamily: 'monospace',
    );
    expect(AppFonts.uiFamily, 'Inter');
    expect(AppFonts.bodyFallback, <String>['serif', 'sans-serif']);

    // 不选中文字体时仍要有 sans-serif 兜底（否则中文是方块）
    AppFonts.applyFonts(
      latinFamily: 'serif',
      cjkFamily: '',
      codeFamily: 'monospace',
    );
    expect(AppFonts.bodyFallback, <String>['sans-serif']);
    expect(AppFonts.uiFamily, 'serif');
  });

  test('applyFonts：代码字体保留等宽兜底', () {
    AppFonts.applyFonts(
      latinFamily: 'Inter',
      cjkFamily: 'system',
      codeFamily: 'serif',
      codeFallback: <String>['serif', 'monospace'],
    );
    expect(AppFonts.mono, 'serif');
    expect(AppFonts.monoFallback.first, 'serif');
    expect(AppFonts.monoFallback, contains('monospace'));
  });

  test('applyFonts：空族名 = 交给平台默认', () {
    AppFonts.applyFonts(
      latinFamily: '',
      cjkFamily: '',
      codeFamily: '',
    );
    expect(AppFonts.uiFamily, '');
    // 代码空族名仍然回落到 monospace，不能变成"无字体"
    expect(AppFonts.mono, 'monospace');
  });
}
