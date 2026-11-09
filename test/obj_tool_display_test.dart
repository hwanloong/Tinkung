// 新工具在界面上必须"认得出来"。
//
// 两个失败模式都会让用户觉得"工具坏了"：
//  · 注册了工具但 `ToolDisplay.of` 没加映射 → 工具行显示成裸的英文名，
//    和旁边"终端 / 文件"那种中文标签排在一起，像漏翻；
//  · 加了映射但没量 `iconNudge` → 图标比文字高一两像素，
//    单独看每一行都正常，一列扫下来就是歪的（用户报过"歪了"）。
import 'package:dsh_agent/ui/tool_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('显示元数据', () {
    const List<(String, String)> newTools = <(String, String)>[
      ('filesearch', '找文件'),
      ('reader', '读文件'),
      ('sheller', '脚本'),
      ('geter', '对象池'),
    ];

    test('四个新工具都有中文标签，不成裸英文名', () {
      for (final (String name, String label) in newTools) {
        final (IconData icon, String text) = ToolDisplay.of(name);
        expect(text, label, reason: '$name 的显示名必须是中文');
        expect(icon, isNotNull);
      }
    });

    test('每个都量过 iconNudge，不落到兜底值', () {
      for (final (String name, String _) in newTools) {
        final (IconData icon, String _) = ToolDisplay.of(name);
        final double nudge = toolIconNudge(icon);
        expect(
          nudge,
          isNot(kToolIconNudgeUnknown),
          reason: '$name 用的 $icon 没量过补偿，图标会比文字偏上一截',
        );
      }
    });
  });

  group('同一个字形不能被两种标签共用', () {
    test('sheller 和 run_shell 的图标必须不同', () {
      final (IconData a, String _) = ToolDisplay.of('sheller');
      final (IconData b, String _) = ToolDisplay.of('run_shell');
      expect(
        a,
        isNot(b),
        reason: '补偿是按"字形 + 标签"查的，一个字形配两种标签必然有一边是歪的',
      );
    });
  });
}
