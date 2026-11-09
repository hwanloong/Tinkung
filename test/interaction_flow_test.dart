// 互动面板的"静默工作流"约定：
//
//  · 实时回合不进聊天记录（ChatMessage.hidden）；
//  · 相同页面重复 open 不重建 session（否则 WebView 重新加载、棋子清零）；
//  · 敲木鱼不逐下触发模型，只在关闭时给一次汇总。
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/interaction/interaction_hub.dart';
import 'package:dsh_agent/interaction/templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('静默消息', () {
    test('hidden 能持久化，普通消息默认不隐藏', () {
      final ChatMessage m = ChatMessage(
        id: 'u1',
        role: Role.user,
        content: '【互动面板·实时】…',
        hidden: true,
      );
      final ChatMessage back = ChatMessage.fromJson(m.toJson());
      expect(back.hidden, isTrue);
      expect(back.content, contains('互动面板'));

      final ChatMessage normal = ChatMessage(
        id: 'u2',
        role: Role.user,
        content: '你好',
      );
      expect(normal.hidden, isFalse);
      expect(ChatMessage.fromJson(normal.toJson()).hidden, isFalse);
    });

    test('老存档没有 hidden 字段 = 可见', () {
      final ChatMessage old = ChatMessage.fromJson(<String, dynamic>{
        'id': 'u3',
        'role': 'user',
        'content': '旧消息',
      });
      expect(old.hidden, isFalse);
    });
  });

  group('面板不重建', () {
    test('同一份 HTML 再 open 返回同一个 session', () {
      final InteractionHub hub = InteractionHub.instance;
      final InteractionSession a = hub.open(
        convId: 'c-same',
        title: '下棋',
        html: '<html><body>A</body></html>',
        kind: 'play',
      );
      final InteractionSession b = hub.open(
        convId: 'c-same',
        title: '下棋',
        html: '<html><body>A</body></html>',
        kind: 'play',
      );
      expect(identical(a, b), isTrue, reason: '同内容重开不能换 id');
      expect(b.closed, isFalse);
      hub.close(a.id);
    });

    test('换页面才关旧开新', () {
      final InteractionHub hub = InteractionHub.instance;
      final InteractionSession a = hub.open(
        convId: 'c-diff',
        title: '下棋',
        html: '<html><body>A</body></html>',
        kind: 'play',
      );
      final InteractionSession b = hub.open(
        convId: 'c-diff',
        title: '换个玩法',
        html: '<html><body>B</body></html>',
        kind: 'play',
      );
      expect(b.id, isNot(a.id));
      expect(a.closed, isTrue);
      hub.close(b.id);
    });

    test('新 session 的实时事件仍然走同一套回调', () {
      final InteractionHub hub = InteractionHub.instance;
      Map<String, dynamic>? got;
      hub.onEvent = (InteractionSession s, Map<String, dynamic> e) => got = e;
      addTearDown(() => hub.onEvent = null);

      final InteractionSession s = hub.open(
        convId: 'c-event',
        title: '井字棋',
        html: '<html></html>',
        kind: 'play',
      );
      hub.recordEvent(s.id, <String, dynamic>{'cell': 4});
      expect(got?['cell'], 4);
      hub.close(s.id);
    });
  });

  group('抽奖', () {
    test('模板自带抽奖按钮、自动回传结果、AI 可改奖项', () {
      expect(InteractionTemplates.games, contains('lottery'));
      expect(InteractionTemplates.defaultAutoReact('lottery'), isTrue);
      final String html = InteractionTemplates.html('lottery');
      expect(html, contains('App.send'));
      expect(html, contains('window.lottery'));
      expect(html, contains('setPrizes'));
      expect(html, contains('抽一次'));
      final String hint = InteractionTemplates.apiHint('lottery');
      expect(hint, contains('不需要让用户再打字'));
      expect(hint, contains('setPrizes'));
    });
  });

  group('敲木鱼不逐下反馈', () {
    test('默认不开实时回合', () {
      expect(InteractionTemplates.defaultAutoReact('muyu'), isFalse);
      for (final String game in <String>['tictactoe', 'go', 'xiangqi']) {
        expect(
          InteractionTemplates.defaultAutoReact(game),
          isTrue,
          reason: '$game 需要一步一回',
        );
      }
    });

    test('接口说明写的是"关闭时汇总"', () {
      final String hint = InteractionTemplates.apiHint('muyu');
      expect(hint, contains('关闭'));
      expect(hint, contains('不逐下'));
      expect(hint, isNot(contains('每敲一下')));
      // 页面上也不再承诺"每一下都告诉 AI"
      expect(InteractionTemplates.html('muyu'), contains('关掉时 AI 会回你一句'));
    });
  });
}
