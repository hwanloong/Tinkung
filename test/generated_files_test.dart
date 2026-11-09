// 「打开生成的文件」的路径识别测试。
//
// 为什么值得测：识别得太宽会把接口路径（`/v1/models`、`/chat/completions`）
// 当成文件，给出一排点了就报错的卡片；识别得太窄则用户仍然看不到
// 自己生成的东西 —— 而那些文件在应用私有目录里，**这是唯一入口**。
import 'package:dsh_agent/core/file_diff.dart';
import 'package:dsh_agent/theme/app_theme.dart';
import 'package:dsh_agent/theme/glass.dart';
import 'package:dsh_agent/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GeneratedFiles.extract', () {
    test('认得出常见的生成物路径', () {
      const String text =
          '已生成图片并保存到：'
          '/data/user/0/com.dsh.dsh_agent/files/images/gen_1700000000.png'
          '（320 KB）';
      expect(GeneratedFiles.extract(text), <String>[
        '/data/user/0/com.dsh.dsh_agent/files/images/gen_1700000000.png',
      ]);
    });

    test('视频也算', () {
      const String t = '已生成视频并保存到：/data/user/0/x/files/videos/a.mp4';
      expect(GeneratedFiles.extract(t), <String>[
        '/data/user/0/x/files/videos/a.mp4',
      ]);
    });

    test('**不能**把接口路径误判成文件', () {
      // 这是最容易出错的一类：接口路径也以 / 开头，
      // 但它们的"扩展名"是未知的（completions、models、generations），
      // 不在白名单里，所以会被正确地忽略。
      const String t =
          '请求 https://api.deepseek.com/chat/completions 和 /v1/models 都返回 200';
      expect(GeneratedFiles.extract(t), isEmpty);
    });

    test('中文标点紧跟着路径时能切干净', () {
      const String t = '图片在 /data/x/a.png，你可以点开看看。';
      expect(GeneratedFiles.extract(t), <String>['/data/x/a.png']);
    });

    test('句末英文句点不会粘进扩展名', () {
      const String t = '保存在 /sdcard/pic.jpg.';
      expect(GeneratedFiles.extract(t), <String>['/sdcard/pic.jpg']);
    });

    test('同一路径重复出现只给一个卡片', () {
      const String t = '/data/a.png 和 /data/a.png 是同一个文件';
      expect(GeneratedFiles.extract(t), <String>['/data/a.png']);
    });

    test('多个不同路径都认出来', () {
      const String t = '/data/a.png 和 /data/b.mp4';
      expect(GeneratedFiles.extract(t), <String>['/data/a.png', '/data/b.mp4']);
    });

    test('相对路径不认（无从判断相对谁）', () {
      // `images/a.png` 里虽然含 `/a.png`，但它是相对路径 ——
      // 不锚定的话会匹配中，给出一张点了必然报错的卡片。
      expect(GeneratedFiles.extract('在 images/a.png 里'), isEmpty);
      expect(GeneratedFiles.extract('见 v1/data/a.png'), isEmpty);
    });

    test('`~` 开头的家目录路径要认（它是绝对的）', () {
      expect(GeneratedFiles.extract('在 ~/files/a.png'), <String>[
        '~/files/a.png',
      ]);
    });

    test('没有路径时返回空', () {
      expect(GeneratedFiles.extract('纯文字，没有任何路径'), isEmpty);
      expect(GeneratedFiles.extract(''), isEmpty);
    });

    test('Office / 压缩包也算文件', () {
      const String t =
          '/sdcard/Download/方案.pptx /sdcard/Download/报表.xlsx '
          '/sdcard/Download/说明.docx /sdcard/Download/包.zip';
      expect(GeneratedFiles.extract(t), <String>[
        '/sdcard/Download/方案.pptx',
        '/sdcard/Download/报表.xlsx',
        '/sdcard/Download/说明.docx',
        '/sdcard/Download/包.zip',
      ]);
    });

    test('URL 里的 .pdf 不会被当成文件', () {
      expect(
        GeneratedFiles.extract('见 https://example.com/files/a.pdf'),
        isEmpty,
      );
    });
  });

  group('文件卡片', () {
    testWidgets('可以展开、收起和关掉', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: GeneratedFiles(text: '/sdcard/Download/方案.pptx'),
          ),
        ),
      );
      expect(find.textContaining('本次涉及的文件'), findsOneWidget);
      expect(find.textContaining('/sdcard/Download/方案.pptx'), findsOneWidget);

      // 一个文件默认展开；点标题收起后路径隐藏
      await tester.tap(find.textContaining('本次涉及的文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('/sdcard/Download/方案.pptx'), findsNothing);
      expect(find.text('方案.pptx'), findsOneWidget);

      // 再展开
      await tester.tap(find.textContaining('本次涉及的文件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('/sdcard/Download/方案.pptx'), findsOneWidget);

      // 点 × 整张卡片消失
      await tester.tap(find.byTooltip('收起这张卡片'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次涉及的文件'), findsNothing);
    });

    testWidgets('有差异的文件点开是红删绿增的行级修改', (WidgetTester tester) async {
      final FileChange change = FileDiff.compute(
        '/sdcard/Download/方案.txt',
        '第一行\n旧内容\n第三行\n',
        '第一行\n新内容\n第三行\n',
      )!;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: GeneratedFiles(
              text: '/sdcard/Download/方案.txt',
              plain: true,
              changes: <FileChange>[change],
            ),
          ),
        ),
      );

      // 极简过程里的文件行：没有卡片背景，也没有「本次涉及的文件」标题。
      expect(find.byType(SurfaceCard), findsNothing);
      expect(find.textContaining('本次涉及的文件'), findsNothing);
      expect(find.text('+1'), findsOneWidget);
      expect(find.text('-1'), findsOneWidget);

      await tester.tap(find.text('方案.txt'));
      await tester.pumpAndSettle();

      expect(find.textContaining('/sdcard/Download/方案.txt'), findsWidgets);
      expect(find.text('旧内容'), findsOneWidget);
      expect(find.text('新内容'), findsOneWidget);
      expect(find.text('原行'), findsOneWidget);
      expect(find.text('新行'), findsOneWidget);
    });
  });
}
