import 'dart:convert';
import 'dart:io';

import 'package:dsh_agent/tools/visual_memo.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「看图点坐标之后记住这条路」的记忆测试。
///
/// 为什么值得单独测：这份记忆是**下一轮的定位依据**。它错的方式有两种，
/// 而且都很难在现场看出来：
///   · 记了但召不回（白记，用户感觉不到任何变化）；
///   · 召回了却是**别的东西**（点错 —— 比点不到更糟：点不到模型会换路，
///     点错了它以为已经成了）。
void main() {
  late Directory dir;
  late File f;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('priv_memo_');
    f = File('${dir.path}${Platform.pathSeparator}memo.json');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('页面身份只认主机 + 路径：翻页（查询串变了）不该把记忆甩掉', () {
    expect(
      VisualMemo.pageKeyOf('https://a.com/list?page=2'),
      VisualMemo.pageKeyOf('https://a.com/list?page=3'),
    );
    expect(
      VisualMemo.pageKeyOf('https://a.com/list?page=2'),
      isNot(VisualMemo.pageKeyOf('https://a.com/detail?id=9')),
    );
    // 解析不了的地址也不能崩。
    expect(VisualMemo.pageKeyOf(''), '');
    expect(VisualMemo.pageKeyOf('not a url'), isNotEmpty);
  });

  test('记一次、同一片位置能召回；差一格也算同一片', () {
    final VisualMemo m = VisualMemo(file: f, bucket: 40);
    // 文档坐标正好落在第 2 格（x 80~120）。
    m.note(
      'https://a.com/list',
      100,
      200,
      selector: '#next',
      text: '下一页',
      label: 'button「下一页」',
      atX: 110,
      atY: 205,
    );

    final Map<String, dynamic>? same = m.recall('https://a.com/list', 105, 205);
    expect(same, isNotNull);
    expect(same!['sel'], '#next');

    // 相邻一格（差 40 像素左右）仍然认 —— 手不会每次都落在同一格。
    expect(m.recall('https://a.com/list', 145, 205), isNotNull);

    // 差得远（隔了三四格）就不认了：再往外走就是别的按钮。
    expect(m.recall('https://a.com/list', 400, 205), isNull);
  });

  test('别的页面不串味', () {
    final VisualMemo m = VisualMemo(file: f);
    m.note(
      'https://a.com/list',
      100,
      200,
      selector: '#next',
      text: '',
      label: '',
    );
    expect(m.recall('https://b.com/list', 100, 200), isNull);
  });

  test('既没有选择器也没有文字 = 这条记忆没用，不占地方', () {
    final VisualMemo m = VisualMemo(file: f);
    m.note('https://a.com/x', 10, 10, selector: '  ', text: '', label: '');
    expect(m.length, 0);
  });

  test('记住了元素当时在哪：下次要能判断"它还在原来那一带吗"', () {
    final VisualMemo m = VisualMemo(file: f);
    m.note(
      'https://a.com/x',
      10,
      10,
      selector: '#a',
      text: '',
      label: '',
      atX: 33,
      atY: 44,
    );
    final Map<String, dynamic> e = m.recall('https://a.com/x', 10, 10)!;
    final Map<String, dynamic> at = e['at'] as Map<String, dynamic>;
    expect(at['x'], 33);
    expect(at['y'], 44);
  });

  test('召回失败要能删掉这条过期记忆', () {
    final VisualMemo m = VisualMemo(file: f);
    m.note('https://a.com/x', 10, 10, selector: '#old', text: '', label: '');
    final Map<String, dynamic> e = m.recall('https://a.com/x', 10, 10)!;
    expect(m.length, 1);
    m.forget((e['k'] ?? '').toString());
    expect(m.length, 0);
    expect(m.recall('https://a.com/x', 10, 10), isNull);
  });

  test('存盘再读回来，记得的东西一模一样', () async {
    final VisualMemo a = VisualMemo(file: f);
    a.note(
      'https://a.com/list',
      12,
      34,
      selector: '[aria-label="下一页"]',
      text: '下一页',
      label: 'a「下一页」',
      atX: 5,
      atY: 6,
    );
    await a.save();
    expect(await f.exists(), isTrue);

    final VisualMemo b = VisualMemo(file: f);
    await b.load();
    final Map<String, dynamic>? e = b.recall('https://a.com/list', 12, 34);
    expect(e, isNotNull);
    expect(e!['sel'], '[aria-label="下一页"]');
    expect((e['at'] as Map<String, dynamic>)['y'], 6);
  });

  test('文件坏了当没有记忆，不抛异常', () async {
    await f.writeAsString('这不是 JSON{{{');
    final VisualMemo m = VisualMemo(file: f);
    await m.load();
    expect(m.length, 0);
    expect(m.recall('https://a.com/x', 1, 1), isNull);
  });

  test('满了淘汰最旧的，不会无限长大', () {
    final VisualMemo m = VisualMemo(file: f, limit: 5);
    for (int i = 0; i < 12; i++) {
      m.note(
        'https://a.com/x',
        i * 500.0,
        10,
        selector: '#b$i',
        text: '',
        label: '',
      );
    }
    expect(m.length, 5);
    // 留下的是最近记的这几条。
    expect(m.recall('https://a.com/x', 11 * 500.0, 10), isNotNull);
    expect(m.recall('https://a.com/x', 0, 10), isNull);
  });

  test('落盘的 JSON 是带版本号的对象，方便以后换格式', () async {
    final VisualMemo m = VisualMemo(file: f);
    m.note('https://a.com/x', 10, 10, selector: '#a', text: '', label: '');
    await m.save();
    final dynamic decoded = jsonDecode(await f.readAsString());
    expect(decoded, isA<Map<String, dynamic>>());
    expect(decoded['v'], 1);
    expect(decoded['items'], isA<List<dynamic>>());
  });
}
