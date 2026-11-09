// 浏览器工具这一轮新加的东西：**短代码**、保活页的操作入口、以及那些
// 一眼看不出对错的纯函数（base64 分块、参数读取、注入脚本的完整性）。
//
// 真机上的点击/等页面在这里测不了（那要 Android + WebView），
// 但有三类东西**必须**在这里钉住：
//  1. 失败必须带短代码 —— 模型据此换路，退化成一句自由文本它就只会重试；
//  2. 没有页面时的报错必须是 PAGE_CLOSED（而不是"未知错误"）；
//  3. 注入脚本/参数解析这类"截断一个字符就全废"的东西。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_agent/core/models.dart';
import 'package:dsh_agent/core/productivity.dart';
import 'package:dsh_agent/core/store.dart';
import 'package:dsh_agent/shizuku/shizuku_service.dart';
import 'package:dsh_agent/tools/browser_tool.dart';
import 'package:dsh_agent/tools/tool.dart';
import 'package:dsh_agent/tools/web_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_plugins.dart';

ToolContext _ctx(Settings settings) => ToolContext(
  settings: settings,
  shizuku: ShizukuService(),
  conversation: Conversation(id: 'c1', title: '测试'),
  workDir: '/tmp/dsh-test',
  searchApiKey: '',
  visionBaseUrl: '',
  visionApiKey: '',
  visionModel: '',
  mainApiKey: '',
  mainBaseUrl: '',
  mainModel: '',
  modelSeesImages: false,
  modelGeneratesImages: false,
  imageGen: null,
  searchEngine: 'bing',
  webSearchMode: 'builtin',
  selfHostedSearchUrl: '',
  notes: NoteStore(File('${Directory.systemTemp.path}/notes_ops_test.json')),
  tasks: TaskStore(File('${Directory.systemTemp.path}/tasks_ops_test.json')),
  plugins: testPluginStore(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('失败带短代码', () {
    test('失败渲染成 "CODE — 人话"，成功就是正文', () {
      const StepResult bad = StepResult.fail(BrowserCode.noElement, '没找到那个按钮。');
      expect(bad.ok, isFalse);
      expect(bad.render, startsWith('NO_ELEMENT — '));
      expect(bad.render, contains('没找到那个按钮'));

      const StepResult good = StepResult.ok('已点击：<button>');
      expect(good.render, '已点击：<button>');
    });

    test('没有页面时是 PAGE_CLOSED，而不是"未知错误"', () {
      // 这一条最关键：模型看到 PAGE_CLOSED 会去 `open`，
      // 看到一句含糊的失败只会把同一个动作重试一遍。
      expect(StepResult.closed.render, startsWith('PAGE_CLOSED — '));
      expect(StepResult.closed.render, contains('open'));
    });
  });

  group('没有页面时，操作类动作回 PAGE_CLOSED', () {
    late Settings settings;
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'apiKey': 'sk-x',
      });
      settings = await Settings.load();
    });

    test('click 没有页面 → PAGE_CLOSED（测试环境起不了 WebView）', () async {
      final String out = await const BrowserTool().run(
        _ctx(settings),
        <String, dynamic>{'action': 'click', 'selector': '#submit'},
      );
      expect(out, startsWith('PAGE_CLOSED'));
    });

    test('type 也是', () async {
      final String out = await const BrowserTool().run(
        _ctx(settings),
        <String, dynamic>{
          'action': 'type',
          'selector': 'input[name=q]',
          'text': '你好',
        },
      );
      expect(out, startsWith('PAGE_CLOSED'));
    });

    test('fetch 也是（它要的是"那一页的上下文"）', () async {
      final String out = await const BrowserTool().run(
        _ctx(settings),
        <String, dynamic>{'action': 'fetch', 'url': 'https://example.com/api'},
      );
      expect(out, startsWith('PAGE_CLOSED'));
    });
  });

  group('参数不对时先挡住，不去碰页面', () {
    late Settings settings;
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'apiKey': 'sk-x',
      });
      settings = await Settings.load();
    });

    Future<String> call(Map<String, dynamic> args) =>
        const BrowserTool().run(_ctx(settings), args);

    test('click 既没选择器也没文字 → BAD_ARG', () async {
      expect(
        await call(<String, dynamic>{'action': 'click'}),
        startsWith('BAD_ARG'),
      );
    });

    test('wait_for 一个条件都不给 → BAD_ARG', () async {
      expect(
        await call(<String, dynamic>{'action': 'wait_for'}),
        startsWith('BAD_ARG'),
      );
    });

    test('open 不给 url → BAD_ARG', () async {
      expect(
        await call(<String, dynamic>{'action': 'open'}),
        startsWith('BAD_ARG'),
      );
    });

    test('open 给了不合法的地址 → BAD_ARG（不发请求）', () async {
      // 注意：合法地址也不会真的打开（测试环境没有 WebView），
      // 但那一层是 UNSUPPORTED；这里要钉的是**参数校验在最前面**。
      expect(
        await call(<String, dynamic>{'action': 'open', 'url': '不是网址'}),
        startsWith('BAD_ARG'),
      );
    });

    test('dialog answer 不给答案 → BAD_ARG', () async {
      expect(
        await call(<String, dynamic>{'action': 'dialog', 'op': 'answer'}),
        startsWith('BAD_ARG'),
      );
    });

    test('upload 文件不存在 → NO_ELEMENT（说清是哪个文件）', () async {
      final String out = await call(<String, dynamic>{
        'action': 'upload',
        'selector': 'input[type=file]',
        'paths': <String>['/tmp/绝对不存在的文件.fit'],
      });
      expect(out, startsWith('NO_ELEMENT'));
      expect(out, contains('绝对不存在的文件.fit'));
    });
  });

  group('纯函数', () {
    test('asMap 认 JSON 对象、认被包了一层的字符串，垃圾返回空', () {
      expect(asMap('{"a":1}')['a'], 1);
      // evaluateJavascript 在部分平台会把结果再包一层引号并转义
      expect(asMap(jsonEncode('{"a":2}'))['a'], 2);
      expect(asMap('<html>'), isEmpty);
      expect(asMap(''), isEmpty);
    });

    test('base64 分块和一次性编码结果一致（含跨块的尾巴）', () {
      // 12288 是块大小，这里故意取不整除的长度
      for (final int n in <int>[0, 1, 2, 3, 12287, 12288, 12289, 30000]) {
        final List<int> bytes = List<int>.generate(n, (int i) => i % 251);
        expect(
          bytesToBase64Chunked(bytes),
          base64Encode(bytes),
          reason: '长度 $n 时两种编码必须一模一样（差一个字符都解不出来）',
        );
      }
    });

    test('ToolArgs：数组照收，单个字符串也收，空的不进列表', () {
      expect(
        <String, dynamic>{
          'paths': <String>['/a.fit', '/b.fit'],
        }.listVal('paths'),
        <String>['/a.fit', '/b.fit'],
      );
      expect(<String, dynamic>{'paths': '/a.fit'}.listVal('paths'), <String>[
        '/a.fit',
      ]);
      expect(
        <String, dynamic>{
          'paths': <String>['', '  '],
        }.listVal('paths'),
        isEmpty,
      );
      expect(<String, dynamic>{}.listVal('paths'), isEmpty);
    });

    test('ToolArgs.mapVal：对象照收，别的当空', () {
      expect(
        <String, dynamic>{
          'headers': <String, dynamic>{'X-CSRF': 'abc'},
        }.mapVal('headers')['X-CSRF'],
        'abc',
      );
      expect(<String, dynamic>{'headers': 'abc'}.mapVal('headers'), isEmpty);
    });
  });

  group('注入脚本不能缺零件', () {
    // 这几个名字是 Dart 侧**按名字调用**的。少一个，页面上就是
    // "点击没反应 / 网络抓不到"，而且不会报错 —— 只能在真机上发现。
    const List<String> hooks = <String>[
      'netList',
      'netDetail',
      'netReset',
      'pxFetch',
      'find',
      'click',
      'type',
      'select',
      'press',
      'scroll',
      'setFiles',
      'probe',
    ];

    test('引导脚本（保活页 + 用户页共用）', () {
      for (final String h in hooks) {
        expect(
          kSessionBootstrapJs,
          contains('$h: function'),
          reason: '注入脚本里少了 $h：Dart 侧调它的时候会静默失败',
        );
      }
      expect(kSessionBootstrapJs, contains('window.__dsh ='));
      // fetch / XHR 两个包装都要在
      expect(kSessionBootstrapJs, contains('window.fetch ='));
      expect(kSessionBootstrapJs, contains('XMLHttpRequest.prototype.send ='));
    });

    test('结构化读取脚本：带"可见性"和 iframe 穿透', () {
      expect(BrowserTool.kPageReadJs, contains('visible'));
      expect(BrowserTool.kPageReadJs, contains('frames'));
      expect(BrowserTool.kPageReadJs, contains('crossOrigin'));
      expect(BrowserTool.kPageReadJs, contains('scrollY'));
    });

    test('网络副本有总预算（长会话不会把页面内存撑爆）', () {
      expect(kSessionBootstrapJs, contains('keepBody'));
      expect(kSessionBootstrapJs, contains('BODY_BUDGET'));
      expect(kSessionBootstrapJs, contains('trimmed'));
    });
  });

  // 视觉方案（看图点坐标 + 滑）。
  //
  // 这两块的真机行为在这测不了，但**它们生成的那段 JS** 能测：
  // 拼错一个字符、少一个引号，在真机上只会表现成"点了一下没反应"
  // —— 而那是最难查的一类问题（既不报错，也看不出哪一步错了）。
  group('视觉方案', () {
    test('定位脚本三件套都在：挑稳定定位 / 只认看得见 / 文档坐标', () {
      // 稳定定位的"挑法"是一个顺序：优先 id，其次几个语义属性，最后才是 CSS 路径。
      expect(kLocatorJs, contains('CSS.escape'));
      expect(kLocatorJs, contains('data-testid'));
      expect(kLocatorJs, contains('aria-label'));
      expect(kLocatorJs, contains('nth-of-type'));
      // 看得见的才算命中：隐藏的同一个按钮到处都是。
      expect(kLocatorJs, contains('visibility'));
      // 位置要用**文档坐标**：用视口坐标记，页面滚一屏就全错位。
      expect(kLocatorJs, contains('window.scrollX'));
      expect(kLocatorJs, contains('window.scrollY'));
    });

    test('坐标点击带回执：点到了什么 + 能记住的定位 + 那个元素在哪', () {
      final String js = kPointAtJs(100, 200, click: true);
      // 看的是**叠着的那几层**：只看最上面一层，就永远发现不了
      // "它下面其实压着真正的输入框"（百度首页那个假占位层就是这么来的）。
      expect(js, contains('elementsFromPoint'));
      expect(js, contains('hit.target.click()'));
      expect(js, contains('domChanged'));
      expect(js, contains('docRect'));
      // 有外层 <a> 就记 <a>：人手指点在链接里的图标上，浏览器把这次点击交给 <a>。
      expect(js, contains('closest("a")'));
      // 坐标原样传进去（截图上的像素）。
      expect(js, contains('(100, 200)'));
    });

    test('遮挡穿透：两层清单都在（真控件优先，label 次之）', () {
      final String js = kPointAtJs(100, 200, click: true);
      expect(js, contains('TIER1'));
      expect(js, contains('TIER2'));
      expect(js, contains('input,textarea,select,button'));
      expect(js, contains('pick('));
    });

    test('真实触摸前先"读"一眼：同一段 JS，但不点', () {
      final String js = kPointAtJs(11, 22, click: false);
      expect(js, contains('elementsFromPoint'));
      expect(
        js,
        isNot(contains('.click()')),
        reason: '读这一趟不该顺手点下去 —— 真正点的是原生触摸',
      );
      expect(js, contains('memo'));
    });

    test('swipe 少给坐标就报 BAD_ARG，不偷偷滑一下', () async {
      final StepResult r = await WebSession.instance.swipe(
        fromX: 10,
        fromY: 20,
      );
      expect(r.ok, isFalse);
      expect(r.render, startsWith('BAD_ARG — '));
      expect(r.render, contains('from_x'));
    });

    // 拖动序列这一段不能只测"函数返回了"：
    //  · **至少 5 个中间点** —— 只有起点和终点的"拖动"会被手势库当瞬移忽略；
    //  · **pointer 和 touch 各一套** —— 老库只听 touch，新库只听 pointer；
    //  · **绝不出现 scrollBy** —— 那是上一版的兜底，把"拖滑块/拖地图"
    //    悄悄换成"滚一下页面"，于是报成功而控件没动；
    //  · **带回读**（滚动/矩形/value/transform/scrollLeft + MutationObserver）。
    test('拖动脚本：完整事件序列 + 分步 + 回读 + 不偷换成整页滚动', () {
      final String js = kSwipeDragJs(197, 215, 197, 92, 300, 6);
      for (final String kind in <String>[
        'pointerdown',
        'pointermove',
        'pointerup',
        'touchstart',
        'touchmove',
        'touchend',
      ]) {
        expect(js, contains('"$kind"'), reason: '少了 $kind：页面收不到完整手势');
      }
      expect(js, contains('MutationObserver'), reason: '没有 DOM 变化计数');
      expect(js, contains('changedBy'));
      // 分步：6 步就该有 6 次循环移动
      expect(js, contains('for (var i = 1; i <= n; i++)'));
      expect(
        js,
        isNot(contains('scrollBy')),
        reason: 'swipe 只负责拖控件；翻页交给 scroll/js',
      );
      // 起点/终点坐标确实进了脚本
      expect(js, contains('197'));
      expect(js, contains('215'));
      expect(js, contains('92'));
    });
  });

  // 坐标点击那次线上崩溃的回归。
  //
  // 事故：`asMap()` 是**解析 JSON 字符串**的，而坐标点击里把**已经解析好的
  // Map** 传了进去 —— 隐式向下转型，报 `type '_Map<String, dynamic>' is not
  // a subtype of type 'String'`。四种参数组合全炸，视觉点击整条链路作废，
  // 而 agent 拿到的是 Dart 原生异常：它看不懂，只能反复重试同一个调用。
  //
  // 这几条把"派发阶段不许抛异常"和"缺参数要回 BAD_ARG 且点名缺谁"钉住。
  group('坐标派发（线上崩溃的回归）', () {
    test('只给 x：BAD_ARG 并点名缺 y（不是静默走别的分支）', () async {
      final StepResult r = await WebSession.instance.click(
        atX: 527,
        selector: '#kw',
      );
      expect(r.ok, isFalse);
      expect(r.render, startsWith('BAD_ARG — '));
      expect(r.render, contains('缺 y'));
    });

    test('只给 y：BAD_ARG 并点名缺 x', () async {
      final StepResult r = await WebSession.instance.click(atY: 537);
      expect(r.ok, isFalse);
      expect(r.render, startsWith('BAD_ARG — '));
      expect(r.render, contains('缺 x'));
    });

    test('什么都没给：BAD_ARG，且不碰页面', () async {
      final StepResult r = await WebSession.instance.click();
      expect(r.ok, isFalse);
      expect(r.render, startsWith('BAD_ARG — '));
      // 没开页面时说清"要先 open"，而不是含糊的"未知错误"
      expect(r.render, contains('selector'));
    });

    test('hit_test 少给坐标：BAD_ARG', () async {
      final StepResult r = await WebSession.instance.hitTest(x: 12);
      expect(r.ok, isFalse);
      expect(r.render, startsWith('BAD_ARG — '));
      expect(r.render, contains('x 和 y'));
    });

    test('带坐标的 click 在没有页面时是 PAGE_CLOSED，不是类型错误', () async {
      final StepResult r = await WebSession.instance.click(atX: 527, atY: 537);
      expect(r.ok, isFalse);
      // 关键：**不能**是 Dart 原生类型异常
      expect(r.render, isNot(contains('is not a subtype of type')));
      expect(r.render, startsWith('PAGE_CLOSED — '));
    });
  });

  // 「每次带 url 都重新加载页面」那次事故的回归。
  //
  // 事故现场：测试页把 load 次数记在 localStorage 里，**每次调用 +1**
  // （9 → 10 → 11…）—— 滚动位置、填了一半的表单、页面里的 JS 状态
  // 全部归零，多步链路根本串不起来，而每一步看起来都成功了。
  //
  // 修法是：只有"真的换了页面"才导航。判定看**主机 + 路径**，
  // 查询串和 hash 不参与（它们在 SPA 里常常是同一页内的状态）。
  group('页面身份（不再重复导航）', () {
    test('同一个页面：只差查询串 / hash / 斜杠 / 协议 —— 都算同一页', () {
      expect(
        BrowserTool.samePage('https://a.com/list', 'https://a.com/list'),
        isTrue,
      );
      expect(
        BrowserTool.samePage('https://a.com/list?page=2', 'https://a.com/list'),
        isTrue,
        reason: '翻页不该重新加载 —— 那是同一页内的状态',
      );
      expect(
        BrowserTool.samePage('https://a.com/list#top', 'https://a.com/list'),
        isTrue,
      );
      expect(
        BrowserTool.samePage('https://a.com', 'https://a.com/'),
        isTrue,
        reason: '空路径和 `/` 是同一页',
      );
      expect(
        BrowserTool.samePage('https://a.com/x', 'http://a.com/x'),
        isTrue,
        reason: '站点把 http 跳到 https 是常事，不该因此重载',
      );
    });

    test('不同的页面：换路径 / 换站 —— 该导航就得导航', () {
      expect(
        BrowserTool.samePage('https://a.com/list', 'https://a.com/detail'),
        isFalse,
      );
      expect(
        BrowserTool.samePage('https://a.com/x', 'https://b.com/x'),
        isFalse,
      );
      expect(
        BrowserTool.samePage('', 'https://a.com/x'),
        isFalse,
        reason: '还没有页面时当然要导航',
      );
    });
  });

  // 「动作报成功、页面没反应」那次事故的回归。
  //
  // 现在所有"应该让页面动一下"的动作都要**回读**：页面收到的 click/keydown
  // 计数、scrollY、输入框的值有没有变。没变就回 NO_EFFECT，不静默成功。
  group('动作回读（不再静默假成功）', () {
    test('NO_EFFECT 是一个独立的短代码', () {
      expect(BrowserCode.noEffect, 'NO_EFFECT');
      const StepResult r = StepResult.fail(BrowserCode.noEffect, '页面没收到');
      expect(r.render, startsWith('NO_EFFECT — '));
    });

    test('注入脚本里有事件计数器（回读靠它）', () {
      expect(kSessionBootstrapJs, contains('__dshSeen'));
      expect(kSessionBootstrapJs, contains("addEventListener('click'"));
      expect(kSessionBootstrapJs, contains("addEventListener('keydown'"));
      // 两个计数器都必须落在"只加一"的监听器里 —— 别顺手去拦事件
      // （拦了就把页面自己的行为改掉了，那是另一种"工具改变事实"）。
      expect(kSessionBootstrapJs, contains('SEEN.clicks++'));
      expect(kSessionBootstrapJs, contains('SEEN.keys++'));
    });
  });

  // 参数读数工具：模型给的东西不可信，类型和缺失都要兜住。
  group('参数读数（宽松）', () {
    test('numOf：数字 / 字符串数字 / 数字字符串都能读，垃圾给 null', () {
      expect(numOf(527), 527);
      expect(numOf(527.5), 527.5);
      expect(numOf('527'), 527);
      expect(numOf(' 537 '), 537);
      expect(numOf('abc'), isNull);
      expect(numOf(null), isNull);
      // 对象（模型偶尔把坐标写成 {"x":527}）读不出来就是 null ——
      // 由调用方回 BAD_ARG，绝不 `as num` 抛原生异常。
      expect(numOf(<String, dynamic>{'x': 527}), isNull);
    });

    test('mapOf：Map 照收，别的给空 Map（不是崩）', () {
      expect(mapOf(<String, dynamic>{'x': 1})['x'], 1);
      expect(mapOf('不是 map'), isEmpty);
      expect(mapOf(null), isEmpty);
    });

    test('rectText：四个数都有才排出来，空的不硬编', () {
      expect(
        rectText(<String, dynamic>{'x': 15, 'y': 150, 'w': 195, 'h': 47}),
        '(15,150 195×47)',
      );
      expect(rectText(null), '');
      expect(rectText(<String, dynamic>{}), '');
    });

    test('PNG 像素尺寸读的是 IHDR 头（视觉自检的锚点）', () {
      // 造一个只带头部的 PNG：签名 + 长度 + IHDR + 1080×2400
      final List<int> head = <int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // 签名
        0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, // 长度 + "IHDR"
        (1080 >> 24) & 0xFF,
        (1080 >> 16) & 0xFF,
        (1080 >> 8) & 0xFF,
        1080 & 0xFF,
        (2400 >> 24) & 0xFF,
        (2400 >> 16) & 0xFF,
        (2400 >> 8) & 0xFF,
        2400 & 0xFF,
      ];
      final ({int w, int h}) s = BrowserTool.pngSize(Uint8List.fromList(head));
      expect(s.w, 1080);
      expect(s.h, 2400);
      // 太短的数据不能抛，只能给 0（截图失败那条路已经先兜了）
      expect(BrowserTool.pngSize(Uint8List.fromList(<int>[1, 2, 3])).w, 0);
    });
  });
}
