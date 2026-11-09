import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show Cookie, CookieManager, InAppWebViewController, WebUri;
import 'package:flutter/widgets.dart' show NavigatorState;

import '../core/models.dart';
import '../core/app_nav.dart';
import '../core/overlay.dart';
import '../ui/browser_page.dart';
import 'tool.dart';
import 'web_session.dart';
import 'webview_loader.dart';

/// 搜索引擎定义
class SearchEngine {
  const SearchEngine(this.id, this.label, this.urlTemplate);

  final String id;
  final String label;

  /// `%s` 会被替换成 URL 编码后的关键词
  final String urlTemplate;

  static const List<SearchEngine> all = <SearchEngine>[
    SearchEngine('bing', 'Bing', 'https://www.bing.com/search?q=%s'),
    SearchEngine('baidu', '百度', 'https://www.baidu.com/s?wd=%s'),
    SearchEngine('duckduckgo', 'DuckDuckGo', 'https://duckduckgo.com/?q=%s'),
    SearchEngine('google', 'Google', 'https://www.google.com/search?q=%s'),
  ];

  static SearchEngine byId(String id) {
    for (final SearchEngine e in all) {
      if (e.id == id) return e;
    }
    return all.first;
  }
}

/// 一次抓取的完整结果，含诊断信息
class _Extract {
  const _Extract({
    required this.items,
    required this.title,
    required this.url,
    required this.textLen,
    required this.counts,
    required this.hints,
    required this.sample,
  });

  final List<Map<String, dynamic>> items;
  final String title;
  final String url;
  final int textLen;
  final Map<String, int> counts;
  final List<String> hints;

  /// 页面可见文本的开头，用于判断到底加载出了什么
  final String sample;

  /// 把「为什么没取到结果」讲清楚，而不是甩一句猜测
  String diagnose() {
    final StringBuffer sb = StringBuffer();
    if (url.isNotEmpty) sb.writeln('  最终地址：$url');
    if (title.isNotEmpty) sb.writeln('  页面标题：$title');
    sb.writeln('  可见文本长度：$textLen');

    if (counts.isNotEmpty) {
      final String c = counts.entries
          .map((MapEntry<String, int> e) => '${e.key}=${e.value}')
          .join(', ');
      sb.writeln('  选择器命中：$c');
    }

    if (hints.contains('captcha')) {
      sb.writeln('  疑似：触发了人机验证');
    } else if (hints.contains('empty')) {
      sb.writeln('  疑似：页面没渲染出内容（可能被拦截或加载未完成）');
    } else if (hints.contains('consent')) {
      sb.writeln('  疑似：被 Cookie/同意页挡住');
    } else if (counts.isNotEmpty && counts.values.every((int v) => v == 0)) {
      sb.writeln('  疑似：页面结构变了，所有选择器都没命中');
    } else {
      sb.writeln('  疑似：命中了元素但没解析出有效链接');
    }

    if (sample.trim().isNotEmpty) {
      final String s = sample.length > 220
          ? '${sample.substring(0, 220)}…'
          : sample;
      sb.writeln('  页面开头：$s');
    }
    return sb.toString().trimRight();
  }
}

/// 通过**内置浏览器（WebView）**抓取网页或搜索结果。
///
/// 为什么不用普通 HTTP 请求：服务端抓取很容易被反爬识别——
/// 没有 JS 执行、没有 Cookie、没有真实浏览器指纹，DuckDuckGo 会直接返回
/// anomaly 拦截页（实测 HTTP 202 + 零结果）。而 WebView 是真浏览器环境：
/// 真实 UA、执行 JS、带 Cookie、走手机的家庭 IP。
///
/// 两个关键设计：
///  1. **轮询而非等固定时间**：见 [WebViewLoader.load]。
///  2. **失败要有诊断**：一个引擎没结果时自动换下一个，并返回每个引擎的
///     真实情况（最终地址、页面标题、选择器命中数、页面文本开头）。
///     只回一句「关键词太偏」等于什么都没说。
class BrowserTool extends AgentTool {
  const BrowserTool();

  /// 从 URL 取主机名，给聊天里那行状态用（完整网址太长，一行放不下）。
  static String _hostOf(String url) {
    try {
      final Uri u = Uri.parse(url);
      return u.host.isEmpty ? url : u.host;
    } catch (_) {
      return url;
    }
  }

  @override
  String get name => 'browser';

  @override
  String get title => '浏览器';

  @override
  String get description =>
      '用内置浏览器打开网页并读取内容。因为是真实浏览器环境，'
      '能拿到需要 JS 渲染的页面，也不容易被反爬拦截。'
      '\n**这一页是"活的"**：open 之后它一直留着（跨工具调用保活），'
      '所以"打开 → 填写 → 点击 → 等接口 → 存下来"是**同一页上的五步**，'
      '登录态、填过的表单、跳转都接着上一步 —— 这也是它和普通抓取的区别。\n'
      '动作分四类：\n'
      '· **读**：search（搜索，多引擎自动重试）、open（打开网址取正文）、'
      'dom（页面结构：标题/正文/链接/输入框/表单/iframe）、js（执行 JS）、'
      'screenshot（截图）、cookies（登录态，可导出成 curl 用的 cookies.txt）；\n'
      '· **动手**：click（点击，选择器或文字都行）、type（填写）、'
      'select（下拉）、press（按键）、scroll（滚动，懒加载列表要它）、'
      'swipe（按坐标滑：拖滑块、拖地图、横向列表）、'
      'wait_for（等元素/文字/地址/某个请求跑完）、'
      'upload（把 /shared 里的文件放进文件框）；\n'
      '· **看图操作（视觉方案）**：选择器会随改版失效、文字可能对上好几个，'
      '所以还有最后一条路 —— `screenshot` 拿图，然后 `click(x:, y:)` 按图上'
      '坐标点、`swipe(from_x:…)` 按坐标划。坐标是**截图上的像素**，'
      '不用自己换算。而且**点过就记住**：同一片位置下次会先用记下来的'
      '选择器/文字点（结果里会说明这次用的是哪条路），'
      '页面重排到记的位置对不上时会自动退回坐标。\n'
      '· **数据**：network（这一页发出的请求和响应体 —— '
      '**接口地址不用猜，从这儿认**）、fetch（在**页面里**发请求：'
      '带 cookie 和 csrf，curl 会 302/403 的接口它能通）、download（接住下载）；\n'
      '· **交给人**：ask（要登录 / 验证码 / 选一项时把这一页推给用户）。\n'
      '抓取和操作都比普通请求慢：用 `wait_for` 等**具体的东西**，'
      '别用固定秒数去赌。失败信息以**短代码**开头'
      '（PAGE_CLOSED / NO_ELEMENT / BLOCKED_TRUSTED / TIMEOUT / HTTP_ERROR / '
      'BAD_ARG / **NO_EFFECT**），按它换路，不要重试同一步。\n'
      '**NO_EFFECT** 的意思是"动作执行了，但页面没有任何反应"'
      '（回读：事件计数、滚动位置、地址都没变）—— 注入的输入事件'
      '被这一页丢掉了。换路：`js` 里直接调元素的 `click()`，'
      '或者 `ask` 把这一页交给用户后用 `trusted: true`。\n'
      '**选中一页就只用一页**：`open` 之后，其他动作即使带 url，'
      '只要主机和路径没变就**不会重新加载**（滚动位置、填了一半的表单、'
      '页面里的 JS 状态都还在）。真要换页请用 `open`。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'search',
          'open',
          'dom',
          'js',
          'click',
          'hit_test',
          'type',
          'select',
          'press',
          'scroll',
          'swipe',
          'wait_for',
          'network',
          'fetch',
          'download',
          'upload',
          'dialog',
          'status',
          'cookies',
          'screenshot',
          'ask',
          'set_cookies',
        ],
        'description':
            'search＝按关键词搜；open＝打开网址取正文；'
            'dom＝取页面结构；js＝执行 JS 取结果；'
            'click / type / select / press / scroll / wait_for＝操作页面；'
            'hit_test＝只回报那个坐标上是什么、**不点**（试坐标用，'
            '没有副作用）；'
            'swipe＝按坐标**拖动**（拖滑块、拖地图、横向列表；'
            '默认在页内合成 pointer+touch 序列，执行后回读验证。'
            '**翻页请用 `scroll`**，swipe 不做整页滚动）；'
            'network＝看请求与响应体；fetch＝在页面里发请求；'
            'download＝接住下载；upload＝填文件框；'
            'dialog＝看/预设弹窗答案；status＝这一页现在什么状态；'
            'cookies＝取登录态（可导出成 curl 能用的 cookies.txt）；'
            'js＝在页面里执行一段 JS 并拿回结果；screenshot＝给页面截图存成图片；'
            '**ask＝需要用户动手时（登录、验证码、选一项）把浏览器打开给他**；'
            'set_cookies＝把 cookie **写进**浏览器（登录态迁移 / 恢复会话）。',
      },
      'selector': <String, dynamic>{
        'type': 'string',
        'description':
            'CSS 选择器（click / type / select / upload / '
            'wait_for 用）。click 可以不给它，改用 text 按可见文字找。',
      },
      'text': <String, dynamic>{
        'type': 'string',
        'description':
            'click：按**可见文字**找元素（比选择器稳，'
            '页面的 class 经常变）；type：要写入的内容；'
            'wait_for：等这段文字出现在正文里。',
      },
      'index': <String, dynamic>{
        'type': 'integer',
        'description': '命中多个时取第几个（从 0 开始），默认 0',
      },
      'x': <String, dynamic>{
        'type': 'number',
        'description':
            '**坐标点击**：截图上的横坐标（配合 y）。'
            '选择器会随改版失效、文字可能对上多个，'
            '而"看着截图点这个位置"是最后一条永远可用的路 —— '
            '先 `screenshot` 拿到图，再按图上的位置点。\n'
            '**x 和 y 必须成对给**（只给一个会回 BAD_ARG）。\n'
            '不确定那个坐标上是什么，可以先 `hit_test(x:, y:)` —— '
            '它只读不点，没有副作用。\n'
            '点过一次之后**这一片会记住**：下次同一个位置会先用'
            '记下来的选择器/文字点，不用再看截图。',
      },
      'y': <String, dynamic>{
        'type': 'number',
        'description':
            '坐标点击的纵坐标（配合 x）。单位是**截图上的像素**，'
            '不用自己换算 devicePixelRatio（页面里会换）。'
            '漏了它 click 会明确说"缺 y"，而不是猜。',
      },
      'from_x': <String, dynamic>{
        'type': 'number',
        'description': 'swipe 的起点横坐标（截图上的像素，配合 from_y）',
      },
      'from_y': <String, dynamic>{
        'type': 'number',
        'description': 'swipe 的起点纵坐标（截图上的像素）',
      },
      'to_x': <String, dynamic>{
        'type': 'number',
        'description': 'swipe 的终点横坐标（截图上的像素）',
      },
      'to_y': <String, dynamic>{
        'type': 'number',
        'description': 'swipe 的终点纵坐标（截图上的像素）',
      },
      'ms': <String, dynamic>{
        'type': 'integer',
        'description':
            'swipe 划多久（毫秒），默认 350。'
            '划得太快页面会当成"轻扫"（惯性滚动），慢一点更像手拖。',
      },
      'grid': <String, dynamic>{
        'type': 'boolean',
        'description':
            'screenshot 用：在页面上临时铺一层**坐标网格**再截，'
            '网格上的数字就是截图上的像素（和 click 的 x/y 同一套单位）。'
            '要按坐标点、又怕肉眼估不准时打开它；截完会自动撤掉。',
      },
      'trusted': <String, dynamic>{
        'type': 'boolean',
        'description':
            'click / press / scroll / swipe 用**真实触摸 / 真实按键**'
            '（默认 false = 走 JS）。有些站点会查 `event.isTrusted`，'
            '脚本点上去它当没点 —— 只有那种情况才需要它，'
            '代价是要求用户的浏览器页开着。'
            'swipe 也默认 false：默认走**页内合成的 pointer+touch 拖动**'
            '（分步派发、可回读），它在 headless 页上就能用；'
            '只有控件明确只认真实触摸时才传 `trusted: true`，'
            '那时用户那一页必须开着并且就是同一页。',
      },
      'key': <String, dynamic>{
        'type': 'string',
        'description':
            'press 的按键名：Enter / Escape / Tab / Backspace / '
            'ArrowDown / ArrowUp / ArrowLeft / ArrowRight / Space',
      },
      'to': <String, dynamic>{
        'type': 'string',
        'enum': <String>['down', 'up', 'top', 'bottom'],
        'description': 'scroll 往哪儿滚，默认 down',
      },
      'times': <String, dynamic>{
        'type': 'integer',
        'description': 'scroll 滚几次（懒加载列表往往要连滚几次），默认 1',
      },
      'timeout': <String, dynamic>{
        'type': 'integer',
        'description': 'wait_for 最多等多少**秒**，默认 20',
      },
      'url_contains': <String, dynamic>{
        'type': 'string',
        'description': 'wait_for：等地址里出现这一段（判断跳转完成）',
      },
      'network_contains': <String, dynamic>{
        'type': 'string',
        'description':
            'wait_for：等**某个请求跑完**（按地址片段匹配）—— '
            '页面加载完不等于数据到了，这条才是"数据到了"。',
      },
      'op': <String, dynamic>{
        'type': 'string',
        'description':
            'network：list（默认）/ detail / reset；'
            'dialog：list（默认）/ answer / clear',
      },
      'id': <String, dynamic>{
        'type': 'integer',
        'description': 'network op=detail 时，要看哪个请求（list 里的编号）',
      },
      'method': <String, dynamic>{
        'type': 'string',
        'description': 'fetch 的 HTTP 方法，默认 GET',
      },
      'body': <String, dynamic>{
        'type': 'string',
        'description': 'fetch 的请求体（POST/PUT 时给：JSON 字符串或纯文本）',
      },
      'headers': <String, dynamic>{
        'type': 'object',
        'description':
            'fetch 额外要带的请求头（例如 {"X-CSRF-Token":"…"}）。'
            '**download 也用它**：有些站点的下载接口必须带自家头'
            '（Garmin 的 NK / Connect-Csrf-Token 就是），不带就 403。'
            'cookie 不用写：页内请求会自己带上。',
      },
      'paths': <String, dynamic>{
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description': 'upload 要放进文件框的文件路径（通常来自 /shared）',
      },
      'answer': <String, dynamic>{
        'type': 'string',
        'enum': <String>['ok', 'cancel'],
        'description':
            'dialog op=answer：下一个弹窗答"确定"还是"取消"'
            '（默认一律取消 —— 替用户点"确定"是不可接受的）。'
            '带 prompt_text 时，prompt 框就填它。',
      },
      'prompt_text': <String, dynamic>{
        'type': 'string',
        'description': 'dialog：下一个 prompt 框里填什么',
      },
      'live': <String, dynamic>{
        'type': 'boolean',
        'description':
            'dom / js：读**用户正在看的那一页**（内置浏览器'
            '开着的那页），而不是 agent 自己那一页。默认 false。',
      },
      'cookies': <String, dynamic>{
        'type': 'string',
        'description':
            'action=set_cookies 时要写入的 cookie。'
            '三种写法都认：`a=1; b=2`（一行）、一行一个、'
            '或我们导出的 Netscape 格式（7 列制表符）。',
      },
      'query': <String, dynamic>{
        'type': 'string',
        'description': 'search 的关键词',
      },
      'url': <String, dynamic>{
        'type': 'string',
        'description':
            '要访问的完整网址。dom / cookies / js / screenshot '
            '**留空表示"用户当前正在看的那一页"**（读它不需要重新打开）。',
      },
      'js': <String, dynamic>{
        'type': 'string',
        'description':
            'action=js 时要执行的 JavaScript。'
            '用 `return` 交出结果，例如 '
            '`return document.querySelectorAll("a").length`。',
      },
      'save': <String, dynamic>{
        'type': 'boolean',
        'description':
            'true 时把结果**存成文件**并返回路径 —— '
            '拿到的内容要交给 python / termux / file_op 继续处理时用这个。'
            '（cookies 会按 curl 的 cookies.txt 格式存。）',
      },
      'hint': <String, dynamic>{
        'type': 'string',
        'description':
            'action=ask 时，告诉用户**具体要做什么**，'
            '例如"请登录你的 Garmin 账号，然后回来告诉我一声"。'
            '写清楚"做完之后怎么继续"（回一句什么）。',
      },
      'engine': <String, dynamic>{
        'type': 'string',
        'enum': <String>['bing', 'baidu', 'duckduckgo', 'google'],
        'description': '优先使用哪个引擎，默认取设置里的值',
      },
      'limit': <String, dynamic>{'type': 'integer', 'description': '返回条数，默认 6'},
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) {
    final String action = args.str('action');
    switch (action) {
      case 'ask':
        return '请用户操作 ${args.str('url')}';
      case 'set_cookies':
        return '写入 cookie ${_hostOf(args.str('url'))}';
      case 'search':
        return '搜索 ${args.str('query')}';
      case 'dom':
        return '读页面结构 ${args.str('url').isEmpty ? '（当前页）' : args.str('url')}';
      case 'cookies':
        return '读登录态 ${args.str('url').isEmpty ? '（当前页）' : args.str('url')}';
      case 'js':
        return '执行 JS ${clampOutput(args.str('js'), max: 40)}';
      case 'screenshot':
        return '页面截图 ${args.str('url').isEmpty ? '（当前页）' : args.str('url')}';
      case 'click':
        final String what = args.str('selector').trim().isNotEmpty
            ? args.str('selector')
            : (numOf(args['x']) != null && numOf(args['y']) != null
                  ? '坐标 ${numOf(args['x'])!.round()},${numOf(args['y'])!.round()}'
                  : '「${clampOutput(args.str('text'), max: 20)}」');
        return '点击 $what';
      case 'hit_test':
        return '试命中 ${numOf(args['x'])?.round() ?? '?'},'
            '${numOf(args['y'])?.round() ?? '?'}（不点）';
      case 'type':
        return '填写 ${args.str('selector')}';
      case 'select':
        return '选择 ${args.str('selector')}';
      case 'press':
        return '按键 ${args.str('key')}';
      case 'scroll':
        return '滚动 ${args.str('to').isEmpty ? 'down' : args.str('to')}';
      case 'swipe':
        final num? fx = args['from_x'] as num?;
        final num? fy = args['from_y'] as num?;
        final num? tx = args['to_x'] as num?;
        final num? ty = args['to_y'] as num?;
        return '滑动 '
            '(${fx?.round() ?? '?'},${fy?.round() ?? '?'}) → '
            '(${tx?.round() ?? '?'},${ty?.round() ?? '?'})';
      case 'wait_for':
        return '等待 ${_waitLabel(args)}';
      case 'network':
        return '看网络请求（${args.str('op').isEmpty ? 'list' : args.str('op')}）';
      case 'fetch':
        return '页内请求 ${clampOutput(args.str('url'), max: 60)}';
      case 'download':
        return '下载 ${_hostOf(args.str('url'))}';
      case 'upload':
        return '上传 ${args.listVal('paths').length} 个文件到 ${args.str('selector')}';
      case 'dialog':
        return '弹窗（${args.str('op').isEmpty ? 'list' : args.str('op')}）';
      case 'status':
        return '看这一页的状态';
      default:
        return '打开 ${args.str('url')}';
    }
  }

  /// `wait_for` 那一行摘要：把"在等什么"说清楚（它常常等十几秒）。
  static String _waitLabel(Map<String, dynamic> args) {
    if (args.str('selector').trim().isNotEmpty) return args.str('selector');
    if (args.str('text').trim().isNotEmpty) {
      return '文字「${clampOutput(args.str('text'), max: 16)}」';
    }
    if (args.str('network_contains').trim().isNotEmpty) {
      return '请求 ${clampOutput(args.str('network_contains'), max: 30)}';
    }
    if (args.str('url_contains').trim().isNotEmpty) {
      return '地址包含 ${clampOutput(args.str('url_contains'), max: 30)}';
    }
    return '条件';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    // 兜底：**任何**没预料到的 Dart 异常都在这里变成一句带短代码的话。
    //
    // 为什么必须兜：agent 拿到的是一句 `type '_Map<String, dynamic>' is not
    // a subtype of type 'String'` 时，它既看不懂也没法修 —— 只能反复重试
    // 同一个调用（那次实战里坐标点击就是这么废掉的）。一句话说清
    // "这是我们工具内部的缺陷"，它至少会停下来换路或者告诉用户。
    try {
      return await _run(ctx, args);
    } catch (e) {
      return '${BrowserCode.unsupported} — 浏览器工具内部出错：$e\n'
          '（这是工具自己的缺陷，不是页面问题；**不要原样重试**同一个调用，'
          '换一条路 —— 比如 `dom` 找选择器、或者 `ask` 交给用户。）';
    }
  }

  Future<String> _run(ToolContext ctx, Map<String, dynamic> args) async {
    final String action = args.str('action');

    // ---- 第一批：作用在**保活的那一页**上的动作 ----
    //
    // 这一批是新加的路（打开/读取/操作/网络/下载…），它们全部落在
    // [WebSession] 那一页上 —— 因为"点完之后页面变了，下一步要接着
    // 操作它"，只有保活的页才能做到。返回 null = 这个动作不归它管，
    // 继续走下面那些老动作（search / cookies / screenshot / ask / ...）。
    final StepResult? operated = await _operate(ctx, action, args);
    if (operated != null) return operated.render;

    // ---- 用户按了停止？----
    //
    // 每一步动作之前都查一次：用户可能在你上一步做完之后就按了停止键，
    // 这时**不能继续把后面的步骤做完** —— 他是看着屏幕发现不对才按的。
    // 工具如实告诉模型"是用户停的"，模型才会停下来问，而不是自己重试。
    if (WebViewLoader.consumeStop()) {
      return '用户已经按了停止键，这次操作中断了。\n'
          '**不要再自动重试**：先问用户下一步想怎么做。'
          '（他停下来的原因可能是"点错地方了"或"不用继续了"。）';
    }

    // ---- set_cookies：把 cookie **写进**浏览器 ----
    //
    // 为什么需要"写"：登录态迁移是最实用的一环 ——
    //  · 你在内置浏览器里登录好了，把 cookie 导出给 termux 的 curl；
    //  · 反过来，你在别处（比如电脑上、或另一台设备）拿到的会话 token，
    //    写进来就能在这一页直接用；
    //  · 调试接口时手动换一个 token 试效果。
    //
    // 写完之后**如果当前页就是那个域**，顺手刷新一下 ——
    // 不刷新的话新 cookie 要等下一次导航才生效，用户会觉得"写了没反应"。
    if (action == 'set_cookies') {
      final String raw = args.str('cookies').trim();
      if (raw.isEmpty) return '错误：action=set_cookies 时要给 cookies。';

      final String url = args.str('url').trim();
      final String target = url.isNotEmpty
          ? url
          : (WebViewLoader.liveUrl ?? '');
      if (target.isEmpty) {
        return '错误：要写 cookie 得知道写给哪个站。给一个 url，'
            '或者先在应用里打开内置浏览器停在那一页。';
      }
      final Uri? uri = Uri.tryParse(target);
      if (uri == null || !uri.hasScheme) return '错误：url 不合法 —— $target';

      final List<Cookie> list = WebViewLoader.parseCookieInput(
        raw,
        defaultDomain: uri.host,
      );
      if (list.isEmpty) {
        return '没有解析出任何 cookie。写法请用 `名字=值`（多个用 `;` 分隔或'
            '一行一个），或者我们导出的 Netscape 格式。';
      }

      int ok = 0;
      final List<String> failed = <String>[];
      for (final Cookie c in list) {
        try {
          // 注意这个 API 是**按字段**给的（不是塞一个 Cookie 对象进来）：
          // name/value/path/domain 各自一个具名参数。
          await CookieManager.instance().setCookie(
            url: WebUri(target),
            name: c.name,
            value: c.value,
            path: (c.path ?? '/').isEmpty ? '/' : c.path!,
            domain: (c.domain ?? '').isEmpty ? uri.host : c.domain,
            expiresDate: c.expiresDate,
          );
          ok++;
        } catch (e) {
          failed.add('${c.name}（$e）');
        }
      }

      // 当前页正好是那个站 → 刷新，让新 cookie 立刻生效。
      if (WebViewLoader.liveUrl != null &&
          WebViewLoader.liveUrl!.contains(uri.host)) {
        try {
          await WebViewLoader.liveController?.reload();
        } catch (_) {
          // 刷不动不影响"已经写进去了"这件事
        }
      }

      return '已写入 $ok/${list.length} 条 cookie 到 ${uri.host}。\n'
          '${failed.isEmpty ? '' : '失败：${failed.join('、')}\n'}'
          '名字：${list.map((Cookie c) => c.name).join(', ')}\n\n'
          '现在读这个站点（`dom` / `cookies`）就会带上它们。';
    }

    // ---- ask：需要用户动手（登录 / 验证码 / 选一项）----
    //
    // 模型没有手，只有用户有。所以这类页面的正确做法不是"让模型想办法绕过
    // 登录"，而是**把那一页推到用户面前**，他登完我们带着同一份 cookie 继续
    // （cookie 在平台的 cookie 库里，内置浏览器和 agent 共享同一份）。
    //
    // 这一轮到此为止：工具返回"已经打开了 + 请你告诉用户做什么"，
    // 模型把话转给用户，用户登完回一句 —— 下一轮模型就能直接读那一页了。
    // 不让它在这里死等：等待没有上限，而用户在浏览器里可能要输密码、
    // 收验证码，那是几分钟到几分钟的事。
    if (action == 'ask') {
      final String url = args.str('url').trim();
      if (url.isEmpty) return '错误：action=ask 时要给 url（要用户打开哪一页）。';
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return '错误：url 不合法 —— $url';

      // 在聊天里留一行"AI 打开了 xxx" —— 浏览器是**一整页**，
      // 不说一声用户会以为应用自己跳走了。
      WebViewLoader.beginActivity('AI 打开了 ${_hostOf(url)}');

      final NavigatorState? nav = appNavigatorKey.currentState;
      if (nav == null) {
        // 理论上到不了这里（应用一定在跑），但真到了就说实话，
        // 让模型知道"是应用这边没准备好"，而不是"用户不肯配合"。
        return '打不开浏览器：应用当前没有可用的导航状态。请让用户手动打开 $url。';
      }
      final String hint = args.str('hint').trim();
      // `nav.context` 是**应用根导航**的 context（`appNavigatorKey`），
      // 不是某个可能已经被销毁的页面的 —— 上面那几个 await 之后它照样有效。
      // ignore: use_build_context_synchronously
      unawaited(BrowserPage.open(nav.context, url: url, title: '需要你操作'));
      // **把应用拉回前台。** agent 常常是在后台跑任务时发现"这页要登录"的，
      // 那时把浏览器推上去用户根本看不见 —— 他的体验就是
      // "它说打开了浏览器，可我什么都没看到"。
      // 我们有前台服务 + 悬浮窗权限，所以后台启动 Activity 是被允许的。
      unawaited(OverlayService.bringToFront());

      return '已把内置浏览器打开到：$url\n'
          '${hint.isEmpty ? '' : '请让用户：$hint\n'}'
          '**现在把这件事告诉用户**，并明确说"完成后回我一句就行"，'
          '然后**结束这一轮**（不要在这里反复重试、也不要自己猜登录结果）。\n'
          '用户回复之后你就带着**已登录的 cookie** 继续：'
          '用 `dom` / `js` 读这一页，或 `cookies(save: true)` 导出给 '
          'termux / python 用。';
    }

    // ---- 读"里面"的内容：cookies / screenshot ----
    //
    // （dom / js / open 已经在上面那一批里，作用在**保活的那一页**上。）
    //
    // 这两个动作有个共同点：**url 留空 = 用户正在看的那一页**
    // （应用里那个内置浏览器打开着的页面）。截图尤其只能在那一页上做：
    // 它要的是"用户眼睛看到的东西"，而不是 agent 自己那一页。
    if (action == 'cookies' || action == 'screenshot') {
      final String url = args.str('url').trim();
      final bool onLive = url.isEmpty;
      // 状态行：让用户在聊天页上就知道"它正在读哪个站"。
      WebViewLoader.beginActivity(
        onLive ? 'AI 正在读取当前页面' : 'AI 正在读取 ${_hostOf(url)}',
      );
      // 读完了就把那一行收掉（`ask` 那条不一样：它要一直留着，
      // 因为用户是在**之后**才去登录的）。这里用 try/finally，
      // 中途任何一条 return 都能把状态清干净。
      try {
        if (onLive && WebViewLoader.liveController == null) {
          WebViewLoader.endActivity();
          return '没有正在打开的页面。请在应用里打开内置浏览器，或者给一个 url。';
        }

        // ---------------- 截图 ----------------
        if (action == 'screenshot') {
          // 截谁？用户的浏览器页 → agent 自己那一页 → 报错并说清两边都没有。
          //
          // 文档一直写着"url 留空 = 当前页"，但以前只认用户那页：agent 自己
          // 明明开着一页（而且是它一路点过来的现场），却回一句"没有正在打开
          // 的页面"——文档与实现不一致，模型只能困惑地换路。
          final InAppWebViewController? liveCtl = WebViewLoader.liveController;
          final WebSession session = WebSession.instance;
          final bool useLive = onLive && liveCtl != null;
          final bool useAgent = onLive && !useLive && session.alive;
          if (onLive && !useLive && !useAgent) {
            return '没有正在打开的页面。\n'
                '· agent 当前页：没有\n· 用户页：没有\n'
                '先 `open` 一个网址，或者给一个 url。';
          }

          // 网格要在**截之前**铺上、截完立刻撤掉（见 setGrid 的说明）。
          // 它显示的数字就是截图上的像素，和 click 收的坐标同一套单位。
          final bool wantGrid = args.boolVal('grid');
          if (wantGrid) {
            await session.setGrid(true, live: useLive);
            await Future<void>.delayed(const Duration(milliseconds: 120));
          }

          // **先等页面画完再截。** SPA 常常在 load 之后才把内容填进去 ——
          // 不等就会截到"加载中"或者一片空白，而 DOM 里内容其实是齐的
          // （"同一个页面一次截出加载中、一次截出全白"就是这么来的）。
          Uint8List? png;
          try {
            if (useLive) {
              await WebViewLoader.waitSettled(liveCtl);
              png = await WebViewLoader.captureLive();
            } else if (useAgent) {
              png = await session.captureSelf();
            } else {
              png = await WebViewLoader.capture(url);
            }
          } finally {
            if (wantGrid) await session.setGrid(false, live: useLive);
          }
          if (png == null || png.isEmpty) {
            return '截图失败：页面没加载完，或者这一页不允许截图。';
          }
          try {
            final String name = stampName('shot', 'png');
            final ({String path, String? shared, int bytes}) saved =
                await Artifacts.saveBytes(ctx.workDir, name, png);
            final String? display = await Artifacts.sharedAbsolute(name);

            // 几何元数据：把"图上的像素"和"页面坐标"的换算关系交出去。
            // 没有它，模型没法自证读出来的坐标和 click 收的坐标是同一套。
            final ({
              double dpr,
              double vw,
              double vh,
              double pw,
              double ph,
              double sx,
              double sy,
            })
            g = await session.pageGeometry(live: useLive);
            final ({int w, int h}) px = pngSize(png);
            final String where = useLive
                ? '用户那页（${WebViewLoader.liveUrl ?? ''}）'
                : (useAgent ? 'agent 那页（${session.url}）' : url);

            final StringBuffer sb = StringBuffer();
            sb.writeln(
              '截图完成 —— $where${wantGrid ? '（**带坐标网格**：'
                        '图上的红色刻度就是截图像素，直接照它读坐标）' : ''}',
            );
            sb.writeln(
              '· 图：${px.w}×${px.h} 像素（${(saved.bytes / 1024).round()} KB）',
            );
            sb.writeln(
              '· 页面：CSS 视口 ${g.vw.round()}×${g.vh.round()} · '
              'DPR ${g.dpr} · 文档 ${g.pw.round()}×${g.ph.round()}'
              '（当前滚到 ${g.sy.round()}）',
            );
            sb.writeln(
              '· 换算：`click(x:, y:)` 要的就是**这张图上的像素**'
              '（= CSS ${(px.w / (g.dpr <= 0 ? 1 : g.dpr)).round()} × DPR ${g.dpr}）'
              '${g.sy > 0 || g.sx > 0 ? '；这一页已经滚动过，读坐标时注意把滚动量算进去' : ''}',
            );
            sb.writeln('· 原始路径（给 python / termux 读写）：${saved.path}');
            if (display != null) {
              sb.writeln('· **正文可直接显示**：$display');
              sb.writeln(
                '（把这个路径写进回复，图就渲染出来了；'
                '`/shared/$name` 是它在内置 Linux 里的短名字，同一份文件。）',
              );
            } else {
              sb.writeln('· 这次没能复制到 shared 目录，正文里贴图可能会显示不出来。');
            }
            return sb.toString();
          } catch (e) {
            return '截图拿到了，但保存失败：$e';
          }
        }

        // ---------------- cookie ----------------
        //
        // 先走平台的 cookie 库（`CookieManager`）—— 它能读到 **httpOnly**
        // 的那些，而 `document.cookie` 读不到，可登录态恰恰常常在 httpOnly 里。
        // 读不到才退回 document.cookie，并把这件事说清楚。
        if (action == 'cookies') {
          final String target = onLive ? (WebViewLoader.liveUrl ?? '') : url;
          List<Cookie> cookies = const <Cookie>[];
          if (target.isNotEmpty) {
            try {
              cookies = await CookieManager.instance().getCookies(
                url: WebUri(target),
              );
            } catch (_) {
              cookies = const <Cookie>[];
            }
          }
          if (cookies.isEmpty) {
            final String? raw = onLive
                ? await WebViewLoader.evalLive('return document.cookie')
                : await WebViewLoader.load(
                    url: target,
                    js: 'return document.cookie',
                    attempts: 2,
                  );
            final String txt = WebViewLoader.unwrapJsString(raw ?? '').trim();
            if (txt.isEmpty) return '这一页没有可读的 cookie。';
            return 'cookie（只有 JS 能看到的那些，httpOnly 的读不到）：\n$txt';
          }

          final String netscape = WebViewLoader.netscapeCookies(cookies);
          final String names = cookies.map((Cookie c) => c.name).join(', ');
          if (args.boolVal('save')) {
            // 走 Artifacts：它同时写工作目录和 `/shared` 一份
            // （Linux 里那条短路径见 web_session.dart 的说明）。
            final ({String path, String? shared, int bytes}) saved =
                await Artifacts.saveText(ctx.workDir, 'cookies.txt', netscape);
            return '已导出 ${cookies.length} 条 cookie 到：${saved.path}\n'
                '${saved.shared == null ? '' : '在 termux / 内置 Linux 里：${saved.shared}\n'}'
                '可以直接用：`curl -b ${saved.shared ?? saved.path} <网址>`。\n'
                '名字：$names';
          }
          return '共 ${cookies.length} 条 cookie：$names\n\n'
              '（要给 curl / python 用，加 `save: true` 导出成 cookies.txt）\n\n'
              '${clampOutput(netscape, max: 1500)}';
        }

        return '错误：未知 action「$action」';
      } finally {
        WebViewLoader.endActivity();
      }
    }

    if (action != 'search') return '错误：未知 action「$action」';

    final String query = args.str('query').trim();
    if (query.isEmpty) return '错误：缺少 query';

    final String preferred = args.str('engine').trim().isNotEmpty
        ? args.str('engine').trim()
        : (ctx.searchEngine.trim().isEmpty ? 'bing' : ctx.searchEngine.trim());

    // 引擎顺序：**百度优先**，然后才是用户指定的那个，最后是其余。
    //
    // 为什么把百度提到最前：国内网络下 Bing 和 Google 要么连不上，
    // 要么对老旧的系统 WebView 返回「请升级浏览器」页面 —— 抓不到结果，
    // 却要**等满 15 秒超时**才换下一个。而每换一个引擎都要重建一次
    // Chromium 实例（又是十几秒）。
    //
    // 结果就是：每次搜索先白等二十多秒才轮到真正能用的那个。
    // 百度是国内站点，不受墙影响，对 WebView 版本也最宽容 ——
    // 它才是这台机器上最可能立刻成功的一条。
    final SearchEngine primary = SearchEngine.byId(preferred);
    final SearchEngine first = SearchEngine.byId('baidu');
    final List<SearchEngine> order = <SearchEngine>[
      if (first.id != primary.id) first,
      primary,
      ...SearchEngine.all.where(
        (SearchEngine e) => e.id != primary.id && e.id != first.id,
      ),
    ];

    final int limit = args.intVal('limit', fallback: 6).clamp(1, 15);
    final List<String> reports = <String>[];
    final String encoded = Uri.encodeComponent(query);

    // 总时间预算。
    // 不加这个的话，4 个引擎各自超时叠加起来能跑 2 分多钟，
    // 用户看到的就是「卡住了」——明明还活着，但没有任何进展提示。
    //
    // 收到 30 秒：这条通道是**最后的兜底**，走到这里说明前面几层都失败了，
    // 与其让用户干等，不如早点给出一份带诊断的失败说明。
    const int budgetSeconds = 30;
    final DateTime deadline = DateTime.now().add(
      const Duration(seconds: budgetSeconds),
    );

    for (final SearchEngine engine in order) {
      if (DateTime.now().isAfter(deadline)) {
        reports.add('【${engine.label}】已超出总时间预算（$budgetSeconds 秒），跳过');
        continue;
      }

      final String url = engine.urlTemplate.replaceFirst('%s', encoded);

      final String? raw = await WebViewLoader.load(
        url: url,
        js: _kSearchJs,
        isDone: _hasItems,
        // 自适应轮询下 5 次约 3.2 秒，够用；超时压到 15 秒，
        // 让「跑不通就快点报错」优先于「死等到最后一刻」。
        attempts: 5,
        timeout: const Duration(seconds: 15),
      );

      if (raw == null) {
        reports.add('【${engine.label}】页面加载超时或失败');
        continue;
      }

      final _Extract ex = _parse(raw);
      if (ex.items.isNotEmpty) {
        return _formatSearch(ex, engine, limit);
      }
      reports.add('【${engine.label}】没取到结果\n${ex.diagnose()}');
    }

    final String names = order.map((SearchEngine e) => e.label).join('、');
    return '依次试了 ${order.length} 个搜索引擎（$names），都没取到结果。'
        '以下是每个引擎的真实情况：\n\n'
        '${reports.join('\n\n')}\n\n'
        '如果每个引擎的「可见文本长度」都很小（几百以内），说明页面根本没加载出来，'
        '多半是网络问题；如果文本很长但选择器全为 0，是页面结构变了。';
  }

  // ------------------------------------------------------------ 解析与格式化

  // ------------------------------------------------------- 新一批：保活页上的动作

  /// 把这一批动作派到 [WebSession] 上。**不归它管的返回 null**。
  ///
  /// 返回 `StepResult` 而不是字符串：失败时带的是**短代码**，
  /// 模型据此换路（见 [BrowserCode]）。
  Future<StepResult?> _operate(
    ToolContext ctx,
    String action,
    Map<String, dynamic> args,
  ) async {
    final WebSession s = WebSession.instance;
    // 把工作目录告诉会话：坐标点击的"记忆"存在那下面。
    // 每次动作都传一遍是**故意**的 —— 不同任务的工作目录可能不一样，
    // 记忆必须跟着当前任务走，不能粘在上一个任务上。
    s.bindWorkDir(ctx.workDir);
    final String url = args.str('url').trim();

    // ---- 状态行：长期动作要让用户看见"它正在用浏览器" ----
    //
    // 浏览器是**一整页**，agent 在后台点它的时候用户停在聊天页上 ——
    // 不说一声他会以为应用自己跳走了。读类动作（dom/status/network）
    // 很快，不值得闪一行；操作和数据类会跑几秒到几十秒，必须有提示。
    final bool showStatus = const <String>{
      'open',
      'click',
      'type',
      'select',
      'press',
      'scroll',
      'swipe',
      'wait_for',
      'fetch',
      'download',
      'upload',
    }.contains(action);
    if (showStatus) {
      WebViewLoader.beginActivity(
        url.isEmpty
            ? 'AI 正在用浏览器：${_actionLabel(action)}'
            : 'AI 正在${_actionLabel(action)} ${_hostOf(url)}',
      );
    }
    try {
      return await _operateInner(ctx, s, action, args, url);
    } finally {
      if (showStatus) WebViewLoader.endActivity();
    }
  }

  /// 状态行里那句话的动词。
  static String _actionLabel(String action) => switch (action) {
    'open' => '打开',
    'click' => '点击页面',
    'hit_test' => '试坐标',
    'type' => '填写表单',
    'select' => '选下拉框',
    'press' => '按键',
    'scroll' => '滚动页面',
    'swipe' => '滑动页面',
    'wait_for' => '等页面回应',
    'fetch' => '取数据',
    'download' => '下载',
    'upload' => '上传文件',
    _ => '操作',
  };

  Future<StepResult?> _operateInner(
    ToolContext ctx,
    WebSession s,
    String action,
    Map<String, dynamic> args,
    String url,
  ) async {
    switch (action) {
      // ------------------------------------------------------------ 打开
      case 'open':
        if (url.isEmpty) {
          return const StepResult.fail(
            BrowserCode.badArg,
            'open 要给 url。要读用户正在看的那一页用 dom / js。',
          );
        }
        final int before = s.dialogs.length;
        final StepResult nav = await s.navigate(url);
        if (!nav.ok) return nav;
        // 打开之后**顺手把正文取回来**：模型十次有九次要的就是它，
        // 分两步（open 再看 dom）等于白烧一轮上下文和一次往返。
        final StepResult read = await s.eval(kPageReadJs);
        final Map<String, dynamic> m = asMap(read.text);
        final String text = (m['text'] ?? '').toString();
        if (text.trim().isEmpty) {
          return StepResult.ok(
            '${nav.text}'
            '这一页没有可读文本（可能是纯图片页，或者内容在 iframe 里）。\n'
            '可以用 `dom` 看结构、`screenshot` 看画面、'
            '或者 `ask` 让用户看一眼。',
          );
        }
        final String body = await _withinBudget(ctx.workDir, 'page', text);
        return StepResult.ok(
          '${nav.text}'
          '${(m['links'] as List<dynamic>?)?.isNotEmpty == true ? '页面链接：${(m['links'] as List<dynamic>).length} 个（要清单用 `dom`）\n' : ''}'
          '$body'
          '${s.dialogs.length > before ? '\n${s.dialogs.sublist(before).map((String d) => '· 弹窗 $d').join('\n')}\n' : ''}',
        );

      // ------------------------------------------------------------ 读结构
      case 'dom':
        final StepResult ready = await _focus(s, url, args.boolVal('live'));
        if (!ready.ok) return ready;
        final StepResult read = await s.eval(kPageReadJs);
        if (!read.ok) return read;
        return StepResult.ok(await _formatPageRead(ctx, read.text));

      // ------------------------------------------------------------ 执行 JS
      case 'js':
        final String js = args.str('js').trim();
        if (js.isEmpty) {
          return const StepResult.fail(BrowserCode.badArg, 'js 要给 js。');
        }
        if (args.boolVal('live')) {
          final String? raw = await WebViewLoader.evalLive(js);
          if (raw == null) {
            return const StepResult.fail(
              BrowserCode.pageClosed,
              '用户那一页没开着（`live: true` 只在浏览器页打开时有效）。',
            );
          }
          return StepResult.ok(clampOutput(WebViewLoader.unwrapJsString(raw)));
        }
        final StepResult ready = await _focus(s, url, false);
        if (!ready.ok) return ready;
        final StepResult r = await s.eval(js);
        if (!r.ok) return r;
        return StepResult.ok(await _withinBudget(ctx.workDir, 'js', r.text));

      // ------------------------------------------------------------ 动手
      case 'click':
        return s.click(
          selector: args.str('selector').trim(),
          text: args.str('text').trim(),
          index: args.intVal('index'),
          trusted: args.boolVal('trusted'),
          // 坐标点击（视觉方案的落脚点）：给的是**截图上的像素**，
          // 页面里会按 devicePixelRatio 换成 CSS 坐标。
          //
          // 用 numOf 松散读数、**绝不 `as num`**：模型把坐标写成
          // `"527"` 或给个对象都是常事，`as` 会把一句 Dart 原生异常
          // 直接甩给 agent（`type 'String' is not a subtype of type 'num'`），
          // 它既看不懂也修不了，只能反复重试同一个调用。
          // 读不出来就是"没给"，由 click 那边统一回 BAD_ARG。
          atX: numOf(args['x']),
          atY: numOf(args['y']),
        );

      // 「试一下」：只回报那个坐标上是什么，**不点**。
      case 'hit_test':
        return s.hitTest(x: numOf(args['x']) ?? -1, y: numOf(args['y']) ?? -1);

      case 'type':
        return s.typeText(
          selector: args.str('selector').trim(),
          text: args.str('text'),
          submit: args.boolVal('submit'),
        );

      case 'select':
        return s.selectOption(
          selector: args.str('selector').trim(),
          value: args.str('value').trim(),
          label: args.str('label').trim(),
          index: args.intVal('index', fallback: -1) < 0
              ? null
              : args.intVal('index'),
        );

      case 'press':
        return s.pressKey(
          key: args.str('key').trim(),
          trusted: args.boolVal('trusted'),
        );

      case 'scroll':
        return s.scroll(
          to: args.str('to').trim().isEmpty ? 'down' : args.str('to').trim(),
          times: args.intVal('times', fallback: 1),
          trusted: args.boolVal('trusted'),
        );

      // 按坐标滑动（视觉方案的另一半：有些界面只能靠"划"）。
      case 'swipe':
        final double nx = (args['from_x'] as num?)?.toDouble() ?? -1;
        final double ny = (args['from_y'] as num?)?.toDouble() ?? -1;
        final double ex = (args['to_x'] as num?)?.toDouble() ?? -1;
        final double ey = (args['to_y'] as num?)?.toDouble() ?? -1;
        return s.swipe(
          fromX: nx,
          fromY: ny,
          toX: ex,
          toY: ey,
          ms: args.intVal('ms', fallback: 350),
          // **默认走页内合成事件**（pointer + touch 两套，分步派发）。
          //
          // 以前默认 `trusted: true`：它会去打**用户那一页**，而 agent 读的
          // 是保活页 —— 手指落在 A 页、回读看的是 B 页，于是"注入成功"
          // 而 scrollY 一动不动（那次实战的 swipe 就废在这儿）。
          // 只有站点查 `event.isTrusted`、并且用户把这一页交出来了，
          // 才需要显式传 `trusted: true`。
          trusted: args.boolVal('trusted'),
        );

      case 'wait_for':
        return s.waitFor(
          selector: args.str('selector').trim(),
          text: args.str('text').trim(),
          js: args.str('js').trim(),
          urlContains: args.str('url_contains').trim(),
          networkContains: args.str('network_contains').trim(),
          timeout: Duration(
            seconds: args.intVal('timeout', fallback: 20).clamp(1, 180),
          ),
        );

      // ------------------------------------------------------------ 数据
      case 'network':
        final String op = args.str('op').trim().toLowerCase();
        if (op == 'reset' || op == 'clear') return s.networkReset();
        if (op == 'detail') {
          return s.networkDetail(
            id: args.intVal('id'),
            contains: args.str('network_contains').trim().isEmpty
                ? args.str('url_contains').trim()
                : args.str('network_contains').trim(),
          );
        }
        return s.networkList(
          args.str('network_contains').trim().isEmpty
              ? args.str('url_contains').trim()
              : args.str('network_contains').trim(),
        );

      case 'fetch':
        if (url.isEmpty) {
          return const StepResult.fail(BrowserCode.badArg, 'fetch 要给 url。');
        }
        return s.pageFetch(
          url: url,
          method: args.str('method').trim().isEmpty
              ? 'GET'
              : args.str('method').trim().toUpperCase(),
          body: args.str('body'),
          headers: args.mapVal('headers'),
          workDir: ctx.workDir,
          save: args.boolVal('save'),
        );

      case 'download':
        return s.download(
          url: url,
          workDir: ctx.workDir,
          name: args.str('name').trim(),
          // 自定义请求头（有些站点的下载接口必须带自家头，比如
          // Garmin 的 N K / Connect-Csrf-Token；不带就是 403）。
          headers: args.mapVal('headers'),
        );

      case 'upload':
        return s.upload(
          selector: args.str('selector').trim(),
          paths: args.listVal('paths'),
        );

      case 'dialog':
        final String op = args.str('op').trim().toLowerCase();
        if (op == 'clear') {
          s.clearDialogs();
          return const StepResult.ok('已清空弹窗记录。');
        }
        if (op == 'answer') {
          final String a = args.str('answer').trim();
          if (a.isEmpty) {
            return const StepResult.fail(
              BrowserCode.badArg,
              'dialog op=answer 要给 answer（ok / cancel）。',
            );
          }
          s.presetAnswer(a, promptText: args.str('prompt_text'));
          return StepResult.ok(
            '下一个弹窗会答：${a == 'ok' ? '确定' : '取消'}'
            '${args.str('prompt_text').isEmpty ? '' : '，prompt 里填「${args.str('prompt_text')}」'}。\n'
            '（只用一次。现在去做那个会弹框的动作。）',
          );
        }
        return StepResult.ok(s.dialogReport());

      case 'status':
        return StepResult.ok(
          'agent 那一页：${s.stateWord}'
          '${s.url.isEmpty ? '' : ' · ${s.title.isEmpty ? s.url : s.title}'}\n'
          '${s.url.isEmpty ? '' : '地址：${s.url}\n'}'
          '用户那一页：'
          '${WebViewLoader.liveController == null ? '没有打开' : (WebViewLoader.liveUrl ?? '已打开')}\n'
          '${s.lastDownload == null ? '' : '最近一次下载请求：${s.lastDownload!.url}\n'}'
          '${s.dialogs.isEmpty ? '' : '弹过的框：${s.dialogs.length} 条（`dialog` 看详情）\n'}'
          '${s.visualMemoSize == 0 ? '' : '坐标点击记住的位置：${s.visualMemoSize} 处'
                    '（同一片位置下次会先用记下的定位方式，不用再看截图）\n'}'
          '${s.lastError.isEmpty ? '' : '最近一次错误：${s.lastError}\n'}',
        );

      default:
        return null;
    }
  }

  /// 动作的目标页：`live: true` → 用户那页；否则 agent 那页。
  ///
  /// 给了 url 只在**真的换了页面**时才导航 —— 同一页（主域 + 路径相同）
  /// 直接复用，"多步操作串不起来"就是这么修的（见下面的说明）。
  Future<StepResult> _focus(WebSession s, String url, bool live) async {
    if (live) {
      if (WebViewLoader.liveController == null) {
        return const StepResult.fail(
          BrowserCode.pageClosed,
          '用户那一页没开着（`live: true` 只在浏览器页打开时有效）。',
        );
      }
      return const StepResult.ok('ready');
    }
    if (url.isEmpty) {
      // 没给地址也没给 live：必须已经有一页开着，否则说清楚怎么开
      if (!s.alive) {
        return const StepResult.fail(
          BrowserCode.pageClosed,
          'agent 这一页还没打开。先 `open` 一个网址'
          '（或者传 url；要读用户那一页用 `live: true`）。',
        );
      }
      return const StepResult.ok('ready');
    }
    // ---- 已经是这一页了？**绝对不要重载** ----
    //
    // 这条是实战里最伤的一条：以前这里无条件 `navigate`，于是**每次带 url
    // 的调用都把页面重新加载一遍**（测试页里 localStorage 的 loads 每次
    // 调用 +1：9 → 10 → 11…）。后果是滚动位置、填了一半的表单、页面里
    // 的 JS 状态全部归零 —— "打开 → 填写 → 点击 → 存下来"这条链
    // **根本串不起来**，而每一步看起来都成功了。
    //
    // 现在只有"真的换了页面"才导航。判定用 [samePage]：主域 + 路径，
    // 查询串和 hash 不参与（那两样在 SPA 里常常是**同一页内的状态**，
    // 为它们重载一次正是要避免的浪费）。
    if (!s.alive) return s.navigate(url);
    if (samePage(s.url, url)) return const StepResult.ok('ready');
    return s.navigate(url);
  }

  /// 两个地址是不是"同一页"。
  ///
  /// 不能直接 `==`：服务端会补斜杠、把 `http` 跳成 `https`、页面自己会写
  /// hash。所以只看**主机 + 路径** —— 查询串和 hash 变化（翻页、搜索词、
  /// 锚点）都当同一页，此时**不重载**，动作直接落在现在这页上。
  static bool samePage(String current, String wanted) {
    // 实现在 web_session 里：swipe 的 trusted 路径也要用它判断
    // "用户那一页是不是就是这一页"，两边必须是**同一份**判断。
    return samePageUrl(current, wanted);
  }

  /// PNG 的像素尺寸（读 IHDR 头，不依赖任何图像库）。
  ///
  /// 为什么要读它：截图回报里那句"图：1080×2400 像素"必须是真的 ——
  /// 它是视觉方案的**自检锚点**（图的宽 ÷ DPR 应当等于 CSS 视口宽）。
  /// 如果哪次对不上，说明读图那一步对图做了缩放，坐标会系统性偏移，
  /// 而那种偏移在整条链路上是看不见的。
  static ({int w, int h}) pngSize(Uint8List png) {
    // PNG：8 字节签名 + 4 字节长度 + "IHDR" + 宽 4 字节 + 高 4 字节（大端）。
    if (png.length < 24) return (w: 0, h: 0);
    int be(int at) =>
        (png[at] << 24) |
        (png[at + 1] << 16) |
        (png[at + 2] << 8) |
        png[at + 3];
    return (w: be(16), h: be(20));
  }

  /// 把结构化读取的结果排成人能读的一页清单。
  Future<String> _formatPageRead(ToolContext ctx, String raw) async {
    final Map<String, dynamic> m = asMap(raw);
    if (m.isEmpty) {
      return '页面结构读取失败（返回的不是 JSON）。可以试试 `js` 自己取。';
    }
    final StringBuffer sb = StringBuffer();
    sb.writeln('标题：${m['title'] ?? ''}');
    sb.writeln('地址：${m['url'] ?? ''}');

    final List<dynamic> links = (m['links'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> fields = (m['fields'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> frames = (m['frames'] as List<dynamic>?) ?? <dynamic>[];
    final int height = (m['height'] as num?)?.toInt() ?? 0;
    final int scrollY = (m['scrollY'] as num?)?.toInt() ?? 0;
    sb.writeln('页面高度：$height（当前滚到 $scrollY）');
    sb.writeln(
      '链接 ${links.length} 个 · 可交互元素 ${fields.length} 个'
      '${frames.isEmpty ? '' : ' · iframe ${frames.length} 个'}',
    );

    if (fields.isNotEmpty) {
      sb.writeln(
        '\n**可填 / 可点的元素**（写入用 selector；'
        '括号里是 **CSS 像素**的包围盒 x,y w×h —— 想按坐标点就乘上 DPR）：',
      );
      for (final dynamic e in fields.take(40)) {
        final Map<String, dynamic> f = Map<String, dynamic>.from(e as Map);
        final String tag = (f['tag'] ?? '').toString();
        final String type = (f['type'] ?? '').toString();
        final String id = (f['id'] ?? '').toString();
        final String name = (f['name'] ?? '').toString();
        final String ph = (f['placeholder'] ?? '').toString();
        final String txt = (f['text'] ?? '').toString();
        final bool vis = f['visible'] == true;
        // 优先用**页面自己算出来的唯一选择器**（`#id` / `[name=…]`），
        // 它在页面里验证过唯一性；退而求其次才是"标签名 + name"这种
        // 可能命中一堆的写法。
        final String exact = (f['sel'] ?? '').toString();
        final String sel = exact.isNotEmpty
            ? exact
            : (id.isNotEmpty
                  ? '#$id'
                  : (name.isNotEmpty ? '$tag[name="$name"]' : tag));
        final String rect = rectText(f['rect']);
        sb.writeln(
          '· `$sel`'
          '${type.isEmpty ? '' : '（$type）'}'
          '${vis ? '' : ' **不可见**'}'
          '${txt.isEmpty ? '' : ' 「$txt」'}'
          '${ph.isEmpty ? '' : ' 占位「$ph」'}'
          '${rect.isEmpty ? '' : ' $rect'}',
        );
      }
    }

    if (frames.isNotEmpty) {
      sb.writeln('\n**iframe**（登录框常常在这里面）：');
      for (final dynamic e in frames.take(6)) {
        final Map<String, dynamic> f = Map<String, dynamic>.from(e as Map);
        sb.writeln(
          '· ${f['src'] ?? ''}'
          '${f['crossOrigin'] == true ? '（**跨域**：读不到内容，'
                    '它的请求和输入框都不在主文档里）' : ''}'
          '${(f['fields'] as List<dynamic>?)?.isNotEmpty == true ? '（含 ${(f['fields'] as List<dynamic>).length} 个输入框）' : ''}',
        );
      }
    }

    if (links.isNotEmpty) {
      sb.writeln('\n**链接**：');
      for (final dynamic e in links.take(30)) {
        final Map<String, dynamic> l = Map<String, dynamic>.from(e as Map);
        sb.writeln('· ${l['text']} → ${l['href']}');
      }
      if (links.length > 30) {
        sb.writeln(
          '…（还有 ${links.length - 30} 个，要全部就用 `js` 取 `document.links`）',
        );
      }
    }

    final String text = (m['text'] ?? '').toString();
    if (text.trim().isNotEmpty) {
      sb.writeln(
        '\n**正文**：\n${await _withinBudget(ctx.workDir, 'page', text)}',
      );
    }
    return sb.toString();
  }

  /// 结果预算：**超了就落盘**，只回摘要和路径。
  ///
  /// 为什么这是必须的：一次 9 万字符的 HTML 塞进上下文，后面几轮
  /// 都没法聊了；而落盘之后模型只需要拿路径交给 python / termux，
  /// 正文留在磁盘上（这也是那份建议里"超长自动落盘"那一条）。
  static Future<String> _withinBudget(
    String workDir,
    String prefix,
    String text,
  ) async {
    if (text.length <= kResultBudget) return text;
    final ({String path, String? shared, int bytes}) saved =
        await Artifacts.saveText(workDir, stampName(prefix), text);
    return '（内容 ${text.length} 字符，超过一轮能带的量，已存成文件）\n'
        '文件：${saved.path}\n'
        '${saved.shared == null ? '' : '在 termux / 内置 Linux 里：${saved.shared}\n'}'
        '\n开头一段：\n${text.substring(0, 1200)}';
  }

  /// 页面结构读取脚本：一次给全"这一页有什么"。
  ///
  /// 和"只回正文 + 前 40 个链接"的老读法比，多了三样**能不能操作**的
  /// 关键信息：
  ///  · `fields` 带 `visible` —— 页面上常有一堆隐藏的同名节点
  ///    （手机/桌面各一份），点到隐藏的那个等于没点；
  ///  · `frames` 穿透 iframe —— 登录框十有八九在 iframe 里，
  ///    只读主文档会得出"这一页没有输入框"的错误结论；
  ///  · `height` / `scrollY` —— 懒加载列表要滚到底才有全部内容。
  static const String kPageReadJs = r'''
(function () {
  function clean(s) {
    return String(s || '').replace(/[ \t\u00A0]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
  }
  function vis(el) {
    try {
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      var st = window.getComputedStyle ? window.getComputedStyle(el) : null;
      if (st && (st.visibility === 'hidden' || st.display === 'none')) return false;
      return true;
    } catch (e) { return false; }
  }
  function fieldOf(el) {
    var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
    var sel = '';
    try {
      if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
        sel = '#' + CSS.escape(el.id);
      } else if (el.getAttribute && el.getAttribute('name')) {
        var cand = el.tagName.toLowerCase() +
          '[name="' + el.getAttribute('name').replace(/"/g, '\\"') + '"]';
        if (document.querySelectorAll(cand).length === 1) sel = cand;
      }
    } catch (e) {}
    return {
      tag: el.tagName ? el.tagName.toLowerCase() : '',
      type: (el.getAttribute && el.getAttribute('type')) || '',
      name: (el.getAttribute && el.getAttribute('name')) || '',
      id: el.id || '',
      placeholder: (el.getAttribute && el.getAttribute('placeholder')) || '',
      text: clean(el.innerText || el.value || '').slice(0, 60),
      visible: vis(el),
      // **CSS 像素**的包围盒。有它就不必动视觉：
      // 模型能直接算出"这个元素在截图的哪个位置"（× dpr），
      // 或者干脆用选择器点 —— 视觉只留作最后兜底。
      rect: r ? { x: Math.round(r.left), y: Math.round(r.top),
        w: Math.round(r.width), h: Math.round(r.height) } : null,
      // 能唯一定位的就给出选择器，省掉模型自己拼
      sel: sel
    };
  }
  var links = [];
  Array.prototype.slice.call(document.querySelectorAll('a[href]')).slice(0, 300)
    .forEach(function (a) {
      if (!a.href) return;
      links.push({
        text: clean(a.innerText || a.getAttribute('aria-label') || '').slice(0, 80),
        href: String(a.href).slice(0, 300)
      });
    });
  var fields = [];
  Array.prototype.slice
    .call(document.querySelectorAll('input,textarea,select,button,[role=button]'))
    .slice(0, 120)
    .forEach(function (el) {
      if ((el.getAttribute && el.getAttribute('type')) === 'hidden') return;
      fields.push(fieldOf(el));
    });
  var frames = [];
  Array.prototype.slice.call(document.querySelectorAll('iframe')).slice(0, 20)
    .forEach(function (fr) {
      var item = { src: String(fr.src || '').slice(0, 200) };
      try {
        var d = fr.contentDocument;
        if (d) {
          item.text = clean(d.body ? d.body.innerText : '').slice(0, 3000);
          item.fields = Array.prototype.slice
            .call(d.querySelectorAll('input,textarea,select,button'))
            .slice(0, 40).map(fieldOf);
        }
      } catch (e) { item.crossOrigin = true; }
      frames.push(item);
    });
  var body = document.body ? document.body.cloneNode(true) : null;
  var text = '';
  if (body) {
    ['script', 'style', 'noscript', 'svg', 'template'].forEach(function (tag) {
      Array.prototype.slice.call(body.querySelectorAll(tag))
        .forEach(function (n) { n.remove(); });
    });
    text = clean(body.innerText || body.textContent || '');
  }
  var doc = document.documentElement;
  return JSON.stringify({
    title: document.title || '',
    url: location.href,
    text: text.slice(0, 60000),
    links: links,
    fields: fields,
    frames: frames,
    scrollY: window.scrollY,
    height: Math.max(doc.scrollHeight, document.body ? document.body.scrollHeight : 0)
  });
})()
''';

  static bool _hasItems(String raw) {
    try {
      final Map<String, dynamic> m = _asMap(raw);
      final List<dynamic> items = (m['items'] as List<dynamic>?) ?? <dynamic>[];
      return items.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Map<String, dynamic> _asMap(String raw) {
    final String s = WebViewLoader.unwrapJsString(raw);
    final dynamic j = jsonDecode(s);
    if (j is Map) return Map<String, dynamic>.from(j);
    if (j is List) return <String, dynamic>{'items': j};
    return <String, dynamic>{};
  }

  _Extract _parse(String raw) {
    Map<String, dynamic> m;
    try {
      m = _asMap(raw);
    } catch (_) {
      return _Extract(
        items: <Map<String, dynamic>>[],
        title: '',
        url: '',
        textLen: 0,
        counts: <String, int>{},
        hints: <String>['parse-error'],
        sample: raw.length > 300 ? raw.substring(0, 300) : raw,
      );
    }

    final List<Map<String, dynamic>> items =
        ((m['items'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();

    return _Extract(
      items: items,
      title: m['title']?.toString() ?? '',
      url: m['url']?.toString() ?? '',
      textLen: (m['textLen'] as num?)?.toInt() ?? 0,
      counts: ((m['counts'] as Map?) ?? <String, dynamic>{}).map(
        (dynamic k, dynamic v) =>
            MapEntry<String, int>(k.toString(), (v as num?)?.toInt() ?? 0),
      ),
      hints: ((m['hints'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic e) => e.toString())
          .toList(),
      sample: m['sample']?.toString() ?? '',
    );
  }

  String _formatSearch(_Extract ex, SearchEngine engine, int limit) {
    final StringBuffer sb = StringBuffer();
    sb.writeln('（来源：${engine.label} · 内置浏览器抓取）\n');
    final int n = ex.items.length < limit ? ex.items.length : limit;
    for (int i = 0; i < n; i++) {
      final Map<String, dynamic> m = ex.items[i];
      final String title = (m['t'] ?? '').toString().trim();
      final String url = (m['u'] ?? '').toString().trim();
      String snippet = (m['s'] ?? '').toString().trim();
      if (snippet.length > 300) snippet = '${snippet.substring(0, 300)}…';

      sb.writeln('[${i + 1}] $title');
      sb.writeln('    $url');
      if (snippet.isNotEmpty) sb.writeln('    $snippet');
      sb.writeln();
    }
    return clampOutput(sb.toString());
  }

  // ------------------------------------------------------------ 注入的脚本

  /// 依次尝试各引擎的结果选择器，最后用通用兜底，
  /// 并额外返回诊断信息（标题、地址、可见文本长度、各选择器命中数、页面开头）。
  static const String _kSearchJs = r'''
(function () {
  function clean(s) { return (s || '').replace(/\s+/g, ' ').trim(); }
  var out = [];
  function push(title, url, snippet) {
    title = clean(title); url = (url || '').trim(); snippet = clean(snippet);
    if (!title || !url || url.indexOf('http') !== 0) return;
    for (var i = 0; i < out.length; i++) { if (out[i].u === url) return; }
    out.push({ t: title, u: url, s: snippet });
  }

  var counts = {};

  counts['bing'] = document.querySelectorAll('#b_results > li.b_algo').length;
  document.querySelectorAll('#b_results > li.b_algo').forEach(function (li) {
    var a = li.querySelector('h2 a');
    var p = li.querySelector('.b_caption p') || li.querySelector('p');
    if (a) push(a.innerText, a.href, p ? p.innerText : '');
  });

  counts['baidu'] = document.querySelectorAll('div.result, div.c-container').length;
  if (!out.length) {
    document.querySelectorAll('div.result, div.c-container').forEach(function (d) {
      var a = d.querySelector('h3 a') || d.querySelector('a');
      if (a) push(a.innerText, a.href, d.innerText);
    });
  }

  counts['ddg'] = document.querySelectorAll('article[data-testid="result"], div.result').length;
  if (!out.length) {
    document.querySelectorAll('article[data-testid="result"], div.result').forEach(function (d) {
      var a = d.querySelector('a[data-testid="result-title-a"], h2 a, a.result__a');
      var p = d.querySelector('[data-result="snippet"], .result__snippet');
      if (a) push(a.innerText, a.href, p ? p.innerText : '');
    });
  }

  counts['google'] = document.querySelectorAll('div.g, div[data-hveid]').length;
  if (!out.length) {
    document.querySelectorAll('div.g, div[data-hveid]').forEach(function (d) {
      var h = d.querySelector('h3');
      var a = d.querySelector('a');
      if (h && a) push(h.innerText, a.href, d.innerText);
    });
  }

  counts['generic'] = document.querySelectorAll('h2 a, h3 a').length;
  if (!out.length) {
    document.querySelectorAll('h2 a, h3 a').forEach(function (a) {
      var box = a.closest('div, li, section');
      push(a.innerText, a.href, box ? box.innerText : '');
    });
  }

  var bodyText = clean(document.body ? document.body.innerText : '');
  var low = bodyText.toLowerCase();
  var hints = [];
  if (/captcha|unusual traffic|are you a robot|人机验证|请输入验证码|安全验证/.test(low)) hints.push('captcha');
  if (bodyText.length < 200) hints.push('empty');
  if (!out.length && /cookie|consent|同意|接受全部/.test(low)) hints.push('consent');

  return JSON.stringify({
    items: out.slice(0, 20),
    title: document.title || '',
    url: location.href,
    textLen: bodyText.length,
    counts: counts,
    hints: hints,
    sample: bodyText.slice(0, 300)
  });
})()
''';
}
