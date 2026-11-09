// 会话的**置顶**与**改名**。
//
// 这两件事各有一个容易搞反的地方，而且都很安静：
//  · 置顶会顺带改排序 —— 如果 `load()` 还用"列表第一条"当当前会话，
//    打开应用就会落在被钉住的那条上（那不是置顶该有的副作用）；
//  · 改名如果跟着 `updatedAt` 走，给一条三个月前的会话改名会把它顶到
//    最上面 —— 用户看到的顺序会和他刚做的事对不上。
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({ConversationStore store, File file})> _freshStore() async {
  final Directory tmp = await Directory.systemTemp.createTemp('dsh_conv');
  final File f = File('${tmp.path}/conversations.json');
  return (store: ConversationStore(f), file: f);
}

void main() {
  test('置顶的排在最前，哪怕它最久没动过', () async {
    final r = await _freshStore();
    final Conversation old = r.store.createNew()
      ..title = '老会话'
      ..updatedAt = DateTime(2026, 1, 1);
    final Conversation fresh = r.store.createNew()
      ..title = '刚聊过'
      ..updatedAt = DateTime(2026, 10, 14);

    // 不置顶时：按时间，新的在前。
    expect(r.store.sorted.map((Conversation c) => c.title).toList(), <String>[
      '刚聊过',
      '老会话',
    ]);

    r.store.togglePin(old.id);
    expect(r.store.sorted.map((Conversation c) => c.title).toList(), <String>[
      '老会话',
      '刚聊过',
    ], reason: '置顶的意思就是"别让时间把它冲下去"');

    // 取消置顶后回到时间序
    r.store.togglePin(old.id);
    expect(r.store.sorted.first.title, '刚聊过');
    expect(fresh.pinned, isFalse);
  });

  test('置顶和改名都能存下来；空名字回退成「新对话」', () async {
    final r = await _freshStore();
    final Conversation c = r.store.createNew();
    r.store.rename(c.id, '修电池掉电');
    r.store.togglePin(c.id);
    await r.store.save();

    final ConversationStore again = ConversationStore(r.file);
    await again.load();
    final Conversation? back = again.current;
    expect(back?.title, '修电池掉电');
    expect(back?.pinned, isTrue);

    again.rename(c.id, '   ');
    expect(
      again.current?.title,
      '新对话',
      reason: '空名字会让历史里出现一行完全空白 —— 看着像数据坏了，还点不着',
    );
  });

  test('改名不动 updatedAt（它是整理，不是"聊了"）', () async {
    final r = await _freshStore();
    final Conversation c = r.store.createNew();
    final DateTime before = c.updatedAt;

    await Future<void>.delayed(const Duration(milliseconds: 5));
    r.store.rename(c.id, '新名字');
    expect(c.updatedAt, before, reason: '跟着时间戳走的话，给旧会话改名会把它顶到列表最上面');
  });

  test('用户起的名字不会被首条消息覆盖', () async {
    final r = await _freshStore();
    final Conversation c = r.store.createNew();
    r.store.rename(c.id, '我自己起的');
    c.messages.add(
      ChatMessage(id: 'm1', role: Role.user, content: '这条消息很长很长，长到足够被拿去做标题用'),
    );

    r.store.touch(c);
    expect(c.title, '我自己起的', reason: '自动起名只该发生在还叫「新对话」的时候');
  });

  test('自动起名仍然管用（没改过名的会话）', () async {
    final r = await _freshStore();
    final Conversation c = r.store.createNew();
    c.messages.add(ChatMessage(id: 'm1', role: Role.user, content: '查一下电量'));
    r.store.touch(c);
    expect(c.title, '查一下电量');
  });

  test('打开应用落在**最近聊过**的那条上，而不是置顶那条', () async {
    final r = await _freshStore();
    final Conversation pinned = r.store.createNew()
      ..title = '钉住的'
      ..updatedAt = DateTime(2026, 1, 1);
    r.store.togglePin(pinned.id);
    final Conversation recent = r.store.createNew()
      ..title = '最近聊的'
      ..updatedAt = DateTime(2026, 10, 14);
    await r.store.save();

    final ConversationStore again = ConversationStore(r.file);
    await again.load();
    expect(again.currentId, recent.id, reason: '置顶只影响列表顺序，不该让应用每次启动都跳到那条会话上');
  });
}
