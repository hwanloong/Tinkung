import 'dart:io';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'each bound device gets a named conversation without changing selection',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'garmin_chat',
      );
      addTearDown(() => temp.delete(recursive: true));
      final ConversationStore store = ConversationStore(
        File('${temp.path}/conversations.json'),
      );
      final Conversation home = store.createNew();

      final Conversation first = store.conversationForDevice(
        '101',
        'Instinct 2 Solar',
        select: false,
      );
      final Conversation second = store.conversationForDevice(
        '202',
        'Instinct 2X',
        select: false,
      );

      expect(first.title, 'Instinct 2 Solar');
      expect(second.title, 'Instinct 2X');
      expect(first.id, isNot(second.id));
      expect(store.currentId, home.id);
      expect(
        store.conversationForDevice('101', 'Renamed device', select: false).id,
        first.id,
      );
      expect(
        store.conversations.where((Conversation c) => c.deviceId != null),
        hasLength(2),
      );
    },
  );

  test('old Instinct titles are migrated to 佳明设备 on load', () async {
    final Directory temp = await Directory.systemTemp.createTemp('garmin_chat');
    // `load()` 迁移旧标题之后会 `unawaitedSave()` —— 那次写入是后台的，
    // Windows 上文件句柄可能还没释放就开始删目录，直接报
    // 「目录不是空的」。给事件循环一点时间并有限重试，等它写完。
    addTearDown(() async {
      for (int i = 0; i < 6; i++) {
        try {
          await temp.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });
    final File file = File('${temp.path}/conversations.json');

    final ConversationStore first = ConversationStore(file);
    first.conversationForDevice('101', 'Instinct 2 Solar', select: false);
    await first.save();

    final ConversationStore second = ConversationStore(file);
    await second.load();

    final Conversation device = second.conversations.singleWhere(
      (Conversation c) => c.deviceId == '101',
    );
    expect(device.title, '佳明设备');
  });
}
