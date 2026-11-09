// 附件图片的**本地路径**必须发给模型。
//
// 为什么值得钉住：图片是作为 `image_url` 发过去的，模型看得见画面内容，
// 但**看不到它在磁盘上的哪里** —— 而"改这张图"要的正是路径
// （`generate_image` 的 `edit_from`）。少了这一段，用户发一张照片说
// "把背景换成海边"，模型只能丢掉他的图重新画、或者瞎编一个路径。
// 用户反馈的原话就是"改不了上传的图片"，而它坏掉时**没有任何报错** ——
// 只是模型的行为悄悄退化了，这种回归最难发现。
import 'dart:io';
import 'dart:convert';

import 'package:dsh_agent/ai/agent.dart';
import 'package:dsh_agent/core/learning.dart';
import 'package:dsh_agent/core/memory.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/rules.dart';
import 'package:flutter_test/flutter_test.dart';

Attachment _img(String path, String name) =>
    Attachment(kind: AttachmentKind.image, path: path, name: name);

void main() {
  // `buildApiMessages` 会在系统提示词里读这两个单例（main() 里正常也会配）。
  // 不配的话它会抛一句"还没初始化"，而那是环境问题、不是被断言的行为。
  setUpAll(() async {
    final Directory tmp = await Directory.systemTemp.createTemp('dsh_attach');
    await MemoryStore.configure(File('${tmp.path}/memory.json'));
    await RuleStore.configure(File('${tmp.path}/rules.json'));
    await LearningStore.configure(File('${tmp.path}/learning.json'));
  });

  group('附图片的路径说明', () {
    test('单张图片：名字、完整路径、以及该填哪个参数都在', () {
      final String note = imagePathNotes(<Attachment>[
        _img(
          '/data/user/0/com.dsh.dsh_agent/files/attachments/1739.jpg',
          'IMG_2034.jpg',
        ),
      ]);

      expect(note, contains('IMG_2034.jpg'), reason: '要能对上用户说的是哪张');
      expect(
        note,
        contains('/data/user/0/com.dsh.dsh_agent/files/attachments/1739.jpg'),
        reason:
            '**完整绝对路径** —— 这是整段话存在的唯一理由。'
            '只给文件名的话，工具在磁盘上找不到它',
      );
      expect(
        note,
        contains('edit_from'),
        reason: '必须指名参数：只说"你可以改这张图"模型不知道该传什么',
      );
      expect(
        note,
        contains('不要重新画一张'),
        reason:
            '这是最容易犯的错 —— 丢掉用户给的图从头画一张，'
            '在他眼里等于"它没看我的图"',
      );
    });

    test('多张图片各自带编号和自己的路径', () {
      final String note = imagePathNotes(<Attachment>[
        _img('/tmp/a.png', 'a.png'),
        _img('/tmp/b.jpg', 'b.jpg'),
      ]);

      expect(note, contains('附图片 1'));
      expect(note, contains('附图片 2'));
      expect(note, contains('/tmp/a.png'));
      expect(note, contains('/tmp/b.jpg'));
    });

    test('两张以上时**额外**说清"要一起填进去、顺序是图1图2"', () {
      // 每张图下面那句"改这张图就填这个路径"单看都对，合起来却会误导：
      // 模型会只填一张，然后在提示词里写"把图二的衣服 P 到图一上"——
      // 而生图模型只收到一张图，看不到"图二"，只能凭空编。
      // （2026-10-16 用户报的就是这个。）
      final String note = imagePathNotes(<Attachment>[
        _img('/tmp/a.png', 'a.png'),
        _img('/tmp/b.jpg', 'b.jpg'),
      ]);

      expect(note, contains('都填进去'), reason: '要说清不是二选一，是两张一起给');
      expect(
        note,
        contains('不要写"图二"'),
        reason:
            '生图模型只看得到图，看不到编号 —— '
            '提示词里必须写成"第一张/第二张"',
      );
    });

    test('只有一张时不出现那段多图说明（省上下文，也别让它以为有两张）', () {
      final String note = imagePathNotes(<Attachment>[
        _img('/tmp/only.png', 'only.png'),
      ]);
      expect(note, isNot(contains('都填进去')));
    });

    test('名字为空时不出现"附图片 ："这种半截怪字符串', () {
      final String note = imagePathNotes(<Attachment>[_img('/tmp/x.png', '')]);
      expect(note, contains('附图片 1：图片'));
      expect(note, contains('/tmp/x.png'));
    });

    test('没有图片时是**空串**，不凭空塞一段', () {
      // 每一条普通消息都套一层"附图片"会白占上下文，
      // 也让模型以为那是某种特殊结构。
      expect(imagePathNotes(<Attachment>[]), isEmpty);
      expect(
        imagePathNotes(<Attachment>[
          Attachment(
            kind: AttachmentKind.file,
            path: '/tmp/a.txt',
            name: 'a.txt',
          ),
          Attachment(kind: AttachmentKind.web, path: 'https://x.com', name: ''),
        ]),
        isEmpty,
        reason: '文本文件和网页不是图片，走的是另一条路',
      );
    });
  });

  test('这一段真的会拼进用户消息里（不是造了没人用）', () async {
    final Conversation conv = Conversation(id: 'c1', title: '改图');
    conv.messages.add(
      ChatMessage(
        id: 'm1',
        role: Role.user,
        content: '把背景换成海边',
        attachments: <Attachment>[_img('/tmp/pic.png', 'pic.png')],
      ),
    );

    final List<Map<String, dynamic>> msgs = await buildApiMessages(
      conv,
      shizukuReady: false,
    );

    final Map<String, dynamic> user = msgs.last;
    expect(user['role'], 'user');

    final String text = (user['content'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .where((Map<String, dynamic> b) => b['type'] == 'text')
        .map((Map<String, dynamic> b) => b['text'] as String)
        .join('\n');

    expect(text, contains('把背景换成海边'), reason: '用户原话不能丢');
    expect(text, contains('/tmp/pic.png'), reason: '路径要进文本块');
    expect(text, contains('edit_from'), reason: '要指名参数');
  });

  test('历史图片只保留最近两条，早期图片换成路径提示', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('img_trim');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File f = File('${tmp.path}/pic.png');
    await f.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
        '/x8AAwMCAO+jX0sAAAAASUVORK5CYII=',
      ),
    );

    final Conversation conv = Conversation(id: 'c2', title: '多轮改图');
    for (int i = 0; i < 3; i++) {
      conv.messages.add(
        ChatMessage(
          id: 'm$i',
          role: Role.user,
          content: '第 $i 张',
          attachments: <Attachment>[_img(f.path, 'pic$i.png')],
        ),
      );
    }

    final List<Map<String, dynamic>> msgs = await buildApiMessages(
      conv,
      shizukuReady: false,
    );
    final List<Map<String, dynamic>> users = msgs
        .where((Map<String, dynamic> m) => m['role'] == 'user')
        .toList();
    expect(users.length, 3);

    // 最老的那条不再带 image_url，但保留了路径和 read_image 提示。
    expect(users[0]['content'], isA<String>());
    final String old = users[0]['content'] as String;
    expect(old, contains('已从上下文移除'));
    expect(old, contains(f.path));
    expect(old, contains('read_image'));

    // 最近两条仍然带图。
    for (final Map<String, dynamic> u in users.sublist(1)) {
      final List<dynamic> blocks = u['content'] as List<dynamic>;
      expect(
        blocks.where(
          (dynamic b) => (b as Map<String, dynamic>)['type'] == 'image_url',
        ),
        isNotEmpty,
      );
    }
  });

  test('dataUrlFor 按文件头判断 mime，不看扩展名', () async {
    // 落盘压缩会把 PNG 改写成 `.jpg`（字节是 JPEG），但反过来也可能有
    // 扩展名骗人的文件。按扩展名猜会让服务端收到"标着 jpeg 的 png"，
    // 部分服务端直接 400 —— 一张图毁掉整个多图请求。
    final Directory tmp = await Directory.systemTemp.createTemp('img_mime');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File f = File('${tmp.path}/actually_png.jpg');
    await f.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
        '/x8AAwMCAO+jX0sAAAAASUVORK5CYII=',
      ),
    );

    final String? url = await ImageDataCache().dataUrlFor(
      _img(f.path, 'actually_png.jpg'),
    );
    expect(url, startsWith('data:image/png;base64,'));
  });

  test('一次 30 张图只内联预算内的数量，其余留路径提示', () async {
    // 这条钉住的是"20 个以上闪退"的最后一道防线：即使 UI 允许一次选 30 张，
    // 请求体也不能真的塞 30 份 base64。超出的图**不能丢** —— 路径已经在
    // 文本里，模型可以按路径 `read_image`。
    final Directory tmp = await Directory.systemTemp.createTemp('img_budget');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File f = File('${tmp.path}/pic.png');
    await f.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
        '/x8AAwMCAO+jX0sAAAAASUVORK5CYII=',
      ),
    );

    final Conversation conv = Conversation(id: 'c3', title: '一次很多图');
    conv.messages.add(
      ChatMessage(
        id: 'm1',
        role: Role.user,
        content: '帮我看看这些',
        attachments: List<Attachment>.generate(
          30,
          (int i) => _img(f.path, 'pic$i.png'),
        ),
      ),
    );

    final List<Map<String, dynamic>> msgs = await buildApiMessages(
      conv,
      shizukuReady: false,
    );
    final List<dynamic> blocks = msgs.last['content'] as List<dynamic>;
    final int images = blocks
        .where(
          (dynamic b) => (b as Map<String, dynamic>)['type'] == 'image_url',
        )
        .length;
    expect(images, 24, reason: '单条消息的内联张数上限');

    final String text = blocks
        .where((dynamic b) => (b as Map<String, dynamic>)['type'] == 'text')
        .map((dynamic b) => (b as Map<String, dynamic>)['text'] as String)
        .join('\n');
    expect(text, contains('另有 6 张图'));
    expect(text, contains('read_image'));
    // 30 个路径都要在，模型才知道被跳过的图在哪。
    expect(RegExp(r'pic\d+\.png').allMatches(text).length, 30);
  });
}
