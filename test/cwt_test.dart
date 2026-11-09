// ChangeWhatYouThink 的交接格式：框选位置必须**精确、可核对**，
// 否则 AI 改错地方比不改更糟。
import 'dart:ui';

import 'package:dsh_agent/cwt/cwt_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('修改请求包含文件、归一化坐标、描述与出处', () {
    final CwtResult r = CwtResult(
      path: r'D:\work\季度汇报.pptx',
      boxes: <CwtBox>[
        const CwtBox(
          rect: Rect.fromLTWH(0.1, 0.2, 0.3, 0.4),
          description: '标题改短一点',
          selectedText: '2026 年第三季度经营分析报告',
        ),
        const CwtBox(
          rect: Rect.fromLTWH(0.5, 0.6, 0.2, 0.2),
          page: 2,
          description: '换成新版 logo',
          cropPath: '/tmp/crop.png',
        ),
      ],
    );

    final String p = r.toPrompt();
    expect(p, contains('ChangeWhatYouThink'));
    expect(p, contains(r'D:\work\季度汇报.pptx'));
    expect(p, contains('x=10.0% y=20.0% w=30.0% h=40.0%'));
    expect(p, contains('标题改短一点'));
    expect(p, contains('2026 年第三季度经营分析报告'));
    expect(p, contains('第 3 页'), reason: 'page 是 0 基，展示要 +1');
    expect(p, contains('/tmp/crop.png'));
    expect(p, contains('只改选框覆盖的范围/内容'));
  });

  test('空描述/空内容不会编造字段', () {
    final CwtResult r = CwtResult(
      path: '/a.png',
      boxes: <CwtBox>[
        const CwtBox(rect: Rect.fromLTWH(0, 0, 1, 1), description: '整张调亮'),
      ],
    );
    final String p = r.toPrompt();
    expect(p, contains('整张调亮'));
    expect(p, isNot(contains('选中的原文')));
    expect(p, isNot(contains('局部截图')));
  });
}
