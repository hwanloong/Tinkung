// **空白页不参与历史记录。**
//
// 用户报的 bug 是"新开的空白页会不断记到历史记录里"：每点一次「新对话」
// 就多一条「新对话」，真正的历史被一路挤下去，而那些条目一条消息都没有。
//
// 这条规矩有三个面，缺一个都会漏回来：
//  1. **内存**：别堆出同一个空白页的多份副本（`createNew` 回到已有的那条）；
//  2. **磁盘**：空白页不写进 `conversations.json`，读存档时老垃圾也丢掉；
//  3. **列表**：历史列表里不显示空白页。
//
// 同时必须钉住反面：**改过名或置顶过的空会话算数** —— 那是用户明确的
// 动作，把它当空白页丢掉就是丢数据。
import 'dart:convert';
import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({ConversationStore store, File file})> _freshStore() async {
  final Directory tmp = await Directory.systemTemp.createTemp('dsh_blank');
  final File f = File('${tmp.path}/conversations.json');
  return (store: ConversationStore(f), file: f);
}

ChatMessage _msg(String text) =>
    ChatMessage(id: 'm_$text', role: Role.user, content: text);

void main() {
  test('连着开空白页只会有一条草稿，而不是每点一次多一条', () async {
    final r = await _freshStore();
    final Conversation a = r.store.createNew();
    final Conversation b = r.store.createNew();
    final Conversation c = r.store.createNew();

    expect(b.id, a.id, reason: '已经有一条空白页时，新建就是回到它');
    expect(c.id, a.id);
    expect(r.store.conversations.length, 1);
    expect(r.store.currentId, a.id, reason: '当前会话要落在这一条上');
  });

  test('写过字之后再点「新对话」才真的开一条新的', () async {
    final r = await _freshStore();
    final Conversation first = r.store.createNew();
    first.messages.add(_msg('查一下电量'));
    r.store.touch(first);

    final Conversation second = r.store.createNew();
    expect(second.id, isNot(first.id));
    expect(r.store.conversations.length, 2);
    expect(r.store.currentId, second.id, reason: '新开的那条才是当前会话');
  });

  test('空白页不落盘；写过字之后才进文件', () async {
    final r = await _freshStore();
    final Conversation c = r.store.createNew();
    await r.store.save();

    expect(
      await r.file.readAsString(),
      isNot(contains('新对话')),
      reason: '空白页连文件都不该进 —— 这是这条 bug 的根治点',
    );

    c.messages.add(_msg('帮我看看这个报错'));
    r.store.touch(c);
    await r.store.save();

    final List<dynamic> saved =
        jsonDecode(await r.file.readAsString()) as List<dynamic>;
    expect(saved.length, 1);
    expect(saved.first['title'], '帮我看看这个报错');
  });

  test('读存档时丢掉老的空白页（升级上来的那一串「新对话」）', () async {
    final r = await _freshStore();
    final Conversation real = Conversation(id: 'k1', title: '聊过的')
      ..messages.add(_msg('你好'));
    final Conversation junk = Conversation(id: 'j1', title: '新对话');
    await r.file.writeAsString(
      jsonEncode(<dynamic>[junk.toJson(), real.toJson()]),
    );

    final ConversationStore again = ConversationStore(r.file);
    await again.load();

    expect(again.conversations.map((Conversation c) => c.id).toList(), <String>[
      'k1',
    ], reason: '老存档里堆的空白页不该等用户手动清一遍');
    expect(again.currentId, 'k1');
  });

  test('历史列表里没有空白页', () async {
    final r = await _freshStore();
    final Conversation real = r.store.createNew()
      ..messages.add(_msg('第一条'))
      ..title = '有内容的';
    final Conversation blank = r.store.createNew()
      ..updatedAt = DateTime(2030); // 就算它"最新"，也不该出现在历史里

    expect(r.store.history.map((Conversation c) => c.id).toList(), <String>[
      real.id,
    ]);
    expect(blank.isBlank, isTrue);
  });

  test('改过名或置顶过的空会话**算数**，不能被丢掉', () async {
    final r = await _freshStore();
    final Conversation renamed = r.store.createNew();
    r.store.rename(renamed.id, '待办草稿');
    final Conversation pinned = r.store.createNew();
    r.store.togglePin(pinned.id);

    expect(renamed.isBlank, isFalse, reason: '改过名 = 用户故意留着它');
    expect(pinned.isBlank, isFalse, reason: '置顶是明确的"我要它在这儿"');

    await r.store.save();
    final List<dynamic> saved =
        jsonDecode(await r.file.readAsString()) as List<dynamic>;
    expect(saved.length, 2, reason: '这两条都该存下来');
    expect(r.store.history.length, 2);
  });
}
