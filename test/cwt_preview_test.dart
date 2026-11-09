// PPT 多页预览 + 互动实时接口。
//
// PPT 之前只按"文字行"预览且只显示前 120 行，用户看不到完整内容；
// 现在按幻灯片分页，位置取自 PPT 自己的 xfrm/off/ext。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_agent/cwt/pptx_preview.dart';
import 'package:dsh_agent/interaction/interaction_hub.dart';
import 'package:dsh_agent/interaction/templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PPTX 预览', () {
    test('按幻灯片解析位置、文字、字号', () async {
      final Directory tmp = await Directory.systemTemp.createTemp('dsh_pptx');
      addTearDown(() => tmp.delete(recursive: true));
      final File f = File('${tmp.path}/a.pptx');

      final Archive archive = Archive();
      archive.add(
        ArchiveFile.string(
          'ppt/presentation.xml',
          '<?xml version="1.0"?>'
              '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      archive.add(
        ArchiveFile.string(
          'ppt/slides/slide1.xml',
          '<?xml version="1.0"?>'
              '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:spTree><p:sp><p:spPr><a:xfrm>'
              '<a:off x="1219200" y="685800"/><a:ext cx="6096000" cy="1371600"/>'
              '</a:xfrm></p:spPr><p:txBody><a:p><a:r><a:rPr sz="2400" b="1"/>'
              '<a:t>季度汇报</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );
      archive.add(
        ArchiveFile.string(
          'ppt/slides/slide2.xml',
          '<?xml version="1.0"?>'
              '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:spTree><p:sp><p:spPr><a:xfrm>'
              '<a:off x="0" y="0"/><a:ext cx="12192000" cy="6858000"/>'
              '</a:xfrm></p:spPr><p:txBody><a:p><a:r><a:t>第二页</a:t></a:r></a:p>'
              '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );
      await f.writeAsBytes(ZipEncoder().encode(archive));

      final List<PptxSlide> slides = parsePptxPreview(f.path);
      expect(slides, hasLength(2), reason: '多页要全部解析出来');
      expect(slides[0].aspect, closeTo(16 / 9, 0.01));
      expect(slides[0].shapes.first.text, '季度汇报');
      expect(slides[0].shapes.first.fontSize, 24);
      expect(slides[0].shapes.first.bold, isTrue);
      expect(slides[0].shapes.first.rect.left, closeTo(0.1, 0.001));
      expect(slides[0].shapes.first.rect.top, closeTo(0.1, 0.001));
      expect(slides[0].shapes.first.rect.width, closeTo(0.5, 0.001));
      expect(slides[1].shapes.first.text, '第二页');
    });
  });

  group('互动实时接口', () {
    test('用户事件会实时回调；auto_react=false 时不回调', () {
      final InteractionHub hub = InteractionHub.instance;
      Map<String, dynamic>? got;
      hub.onEvent = (InteractionSession s, Map<String, dynamic> e) {
        got = e;
      };
      addTearDown(() => hub.onEvent = null);

      final InteractionSession live = hub.open(
        convId: 'c-live',
        title: '下棋',
        html: '<html></html>',
      );
      expect(live.autoReact, isTrue);
      hub.recordEvent(live.id, <String, dynamic>{'move': 'B2'});
      expect(got?['move'], 'B2');

      hub.close(live.id);
      got = null;
      final InteractionSession form = hub.open(
        convId: 'c-form',
        title: '问卷',
        html: '<html></html>',
        autoReact: false,
      );
      hub.recordEvent(form.id, <String, dynamic>{'field': 'name'});
      expect(got, isNull, reason: '一次性表单不该每填一格就叫模型');
      expect(form.events, hasLength(1), reason: '事件本身仍然要记录');
      hub.close(form.id);
    });

    test('四个高频模板都自带事件接口和 AI 操作接口', () {
      for (final String game in InteractionTemplates.games) {
        final String html = InteractionTemplates.html(game);
        expect(html, contains('App.send'), reason: '$game 要把用户操作发回来');
        expect(html, contains('window.'), reason: '$game 要暴露 AI 可调用的接口');
        expect(InteractionTemplates.apiHint(game), isNotEmpty);
      }
      expect(InteractionTemplates.html('go'), contains('window.goBoard'));
      expect(InteractionTemplates.html('tictactoe'), contains('window.ttt'));
      expect(InteractionTemplates.html('xiangqi'), contains('window.xiangqi'));
      expect(InteractionTemplates.html('muyu'), contains('window.muyu'));
    });

    test('选择面板默认自动关闭，游戏/自定义不自动关', () {
      final InteractionHub hub = InteractionHub.instance;
      final InteractionSession ask = hub.open(
        convId: 'c-ask',
        title: '选一个',
        html: '<html></html>',
        kind: 'ask',
        autoCloseOnChoice: true,
      );
      expect(ask.kind, 'ask');
      expect(ask.autoCloseOnChoice, isTrue);
      hub.close(ask.id);

      final InteractionSession game = hub.open(
        convId: 'c-game',
        title: '下棋',
        html: '<html></html>',
        kind: 'play',
      );
      expect(game.autoCloseOnChoice, isFalse, reason: '棋盘不要因为一步棋就自己关掉');
      hub.close(game.id);
    });

    test('关闭摘要包含用户操作', () {
      final InteractionHub hub = InteractionHub.instance;
      final InteractionSession s = hub.open(
        convId: 'c-sum',
        title: '选择',
        html: '<html></html>',
      );
      hub.recordEvent(s.id, <String, dynamic>{'choice': '方案 A'});
      hub.close(s.id, byUser: true);
      final String summary = hub.summary(s.id);
      expect(summary, contains('方案 A'));
      expect(summary, contains('继续下一步'));
    });
  });
}
