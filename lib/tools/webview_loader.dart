import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List, ValueNotifier;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 无头 WebView 加载器。
///
/// `browser` 工具和「网页链接」附件抓取都用它，避免两处各写一份
/// 生命周期管理（那很容易一边修好另一边还留着 bug）。
///
/// 核心是**轮询**而不是「等固定时长再抽一次」：结果页多是 JS 异步渲染的，
/// 固定等待要么不够（抽到空）要么白等。这里每隔一段时间重试，
/// 直到 [isDone] 为真、或尝试次数用尽（此时把最后一次结果交出去，供上层诊断）。
class WebViewLoader {
  const WebViewLoader._();

  /// **浏览器当前在干什么**（给聊天页那行状态用）。
  ///
  /// 为什么要有它：内置浏览器是**一整页**，被 agent 调起来的时候用户
  /// 可能正在聊天页上 —— 不说一声，他会觉得"应用自己跳走了"。
  /// 空串 = 没在干什么（那一行就不显示）。
  ///
  /// 用 `ValueNotifier` 而不是让调用方每处 setState：写它的人（工具）
  /// 手上没有 BuildContext，而读它的人（聊天页）需要一个"变了就重建"的信号。
  static final ValueNotifier<String> activity = ValueNotifier<String>('');

  static void beginActivity(String text) => activity.value = text;
  static void endActivity() => activity.value = '';

  // ---------------------------------------------------------------- 停止

  /// **用户按了停止。**
  ///
  /// 为什么需要它：agent 操作浏览器常常连着几步（滚动 → 点击 → 读结果），
  /// 而用户随时可能发现"它点错了地方" —— 那时他需要一个**立刻能按**的按钮，
  /// 按下去 agent 就知道停下来，而不是把后面几步做完。
  /// 人机协作里"我喊停它听不见"是最让人不敢放手的一件事。
  static bool _stop = false;
  static bool get stopRequested => _stop;

  static void requestStop() {
    _stop = true;
    activity.value = '';
  }

  /// 取走停止标记（读一次就清）—— 不清的话，下一次任务会一上来就被判成
  /// "用户已停止"。
  static bool consumeStop() {
    final bool s = _stop;
    _stop = false;
    return s;
  }

  // ---------------------------------------------------------------- 执行 JS

  /// 执行一段 JS，**两种写法都支持**：
  ///
  ///   · 函数体：`return document.title`（可以用 `await`，Promise 会被等到）
  ///   · 表达式：`document.title`
  ///
  /// 先把源码当**函数体**跑（这样 `return` 合法、Promise 会 resolve）；
  /// 没有返回值说明它其实是个表达式，再当表达式求值一次。
  ///
  /// 为什么值得这么绕：文档写着"用 `return` 交出结果"而实现只认表达式，
  /// 对 agent 是灾难级的不一致 —— 它完全靠文档决定怎么调，白扔好几轮之后
  /// 还会以为"这个站不让注入脚本"，把排查方向整个带歪。
  /// 两种都认之后，写哪种都对。
  static Future<String?> evalOn(InAppWebViewController c, String src) async {
    final String code = src.trim();
    if (code.isEmpty) return null;

    try {
      final CallAsyncJavaScriptResult? r = await c.callAsyncJavaScript(
        functionBody: code,
      );
      if (r?.error != null) {
        // **事实式报错**：把原文交出去。"可能没注入脚本"这类猜测，
        // 会让 agent 顺着一个错方向查好几轮。
        return 'JS_ERROR: ${r!.error}';
      }
      if (r?.value != null) return stringifyJsValue(r!.value);
    } catch (e) {
      return 'JS_ERROR: $e';
    }

    // 走到这里说明它没有 return（就是个表达式）
    try {
      final dynamic v = await c.evaluateJavascript(source: code);
      return v?.toString();
    } catch (e) {
      return 'JS_ERROR: $e';
    }
  }

  /// JS 返回值 → 给模型看的字符串。对象/数组转 JSON（不然 Dart 那边
  /// 会打印成一坨 `Instance of ...`）。
  static String stringifyJsValue(dynamic v) {
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    try {
      return jsonEncode(v);
    } catch (_) {
      return v.toString();
    }
  }

  /// ---- 把 cookie 写成 curl 能直接吃的 `cookies.txt`（Netscape 格式）----
  ///
  /// ## 为什么值得做这一步
  ///
  /// "AI 在浏览器里登录过、然后让 termux 里的 curl 带着这份登录态去拉接口"
  /// 是这套东西最实用的组合之一。而 `curl -b` 要的是 Netscape 那种
  /// 制表符分隔的老格式 —— 让模型手写这段格式，它每次都会写错（列数、
  /// 域名前面的点、过期时间的单位）。
  ///
  /// 格式：`域名 \t TRUE/FALSE（子域） \t 路径 \t HTTPS \t 过期时间 \t 名 \t 值`
  /// 其中过期时间是 **Unix 秒**；会话 cookie 写 0。
  /// 解析"要写进去的 cookie"，三种常见写法都认：
  ///
  ///  1. `document.cookie` 那种一行：`a=1; b=2; c=3`
  ///  2. 一行一个：`a=1\nb=2`
  ///  3. 我们导出的 **Netscape 格式**（7 列、制表符分隔）——
  ///     这样"从 A 站导出、往 B 站写回"可以直接用同一份文件
  ///
  /// [defaultDomain] 是没写明域名时用的（通常取当前页的 host）；
  /// 带点开头的域名按"含子域"处理（Netscape 那个 TRUE/FALSE 列）。
  ///
  /// 返回解析出来的列表；解析不出任何一条就返回空 —— 调用方据此报错，
  /// **不要**把一串乱七八糟的东西当成 cookie 塞进去（那会污染整个站点的
  /// 登录态，而报错只说"写失败"，很难查）。
  static List<Cookie> parseCookieInput(
    String raw, {
    String defaultDomain = '',
    String defaultPath = '/',
  }) {
    final List<Cookie> out = <Cookie>[];

    for (final String line in raw.split(RegExp(r'[\r\n]+'))) {
      final String s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;

      // ---- Netscape 格式：7 列、制表符 ----
      final List<String> cols = s.split('\t');
      if (cols.length >= 7) {
        final String domain = cols[0].trim();
        final int expires = int.tryParse(cols[4].trim()) ?? 0;
        out.add(
          Cookie(
            name: cols[5].trim(),
            value: cols[6].trim(),
            domain: domain,
            path: cols[2].trim().isEmpty ? defaultPath : cols[2].trim(),
            expiresDate: expires <= 0 ? null : expires,
          ),
        );
        continue;
      }

      // ---- `a=1; b=2` 或 `a=1` ----
      for (final String pair in s.split(';')) {
        final String p = pair.trim();
        final int eq = p.indexOf('=');
        if (eq <= 0) continue;
        final String name = p.substring(0, eq).trim();
        final String value = p.substring(eq + 1).trim();
        if (name.isEmpty) continue;
        out.add(
          Cookie(
            name: name,
            value: value,
            domain: defaultDomain.isEmpty ? null : defaultDomain,
            path: defaultPath,
          ),
        );
      }
    }
    return out;
  }

  /// **自省**：一次把"这一页能不能操作"说清楚。
  ///
  /// 没有它的时候，agent 只能自己试（比如跑一句 `document.title`）来判断
  /// "是我注入不进去，还是页面本来就没内容" —— 那是拿轮次换信息。
  static const String probeJs = r'''
return {
  url: location.href,
  title: document.title || '',
  readyState: document.readyState,
  viewport: { w: innerWidth, h: innerHeight },
  scroll: {
    y: Math.round(scrollY),
    max: Math.round(Math.max(
      document.documentElement.scrollHeight,
      document.body ? document.body.scrollHeight : 0) - innerHeight)
  },
  counts: {
    a: document.querySelectorAll('a[href]').length,
    button: document.querySelectorAll('button,[role=button],input[type=submit]').length,
    input: document.querySelectorAll('input,textarea,select').length,
    iframe: document.querySelectorAll('iframe').length
  },
  scrollManaged: (function () {
    var s = getComputedStyle(document.body).overflow;
    return s === 'hidden' || s === 'clip';
  })()
};''';

  /// **页面画完了没有**（截图前该等的时机）。
  ///
  /// 返回 true = 可以截了：文档 complete，而且 DOM 在过去 600ms 里没再变
  /// （SPA 常常在 load 之后才把内容填进去；不等就会截到"加载中"或者一片空白 ——
  /// 而 DOM 里内容其实是齐的）。
  static const String settleJs = r'''
(function () {
  if (document.readyState !== 'complete') return false;
  var sig = document.body ? document.body.innerText.length : 0;
  var now = Date.now();
  if (window.__ptSig !== sig) { window.__ptSig = sig; window.__ptAt = now; return false; }
  return (now - (window.__ptAt || 0)) > 600;
})()''';

  /// 按**文字**点击的脚本模板（`__NEEDLE__` 会被换成 JSON 转义后的目标文字）。
  ///
  /// 三种定位（选择器 → 文字 → 坐标）里，文字是视觉之外最稳的一级：用户的意图
  /// 常常就是"点那个写着'登录'的按钮"，而选择器一改版就失效。
  ///
  /// 找不到时**返回候选清单**（标签 + 文字 + 坐标），而不是一句 NO_ELEMENT ——
  /// "看得到点不到"的下一步应该是"那我按第几个点"，而不是重新猜一轮。
  /// 命中时把被点元素的信息也带回来，模型才知道自己点到了什么。
  static const String _clickTemplate = r'''
(function () {
  var want = __NEEDLE__;
  var sel = 'a,button,[role=button],input[type=submit],input[type=button],summary,label';
  var all = Array.prototype.slice.call(document.querySelectorAll(sel));
  function visible(el) {
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  function label(el) {
    return ((el.innerText || el.value || el.getAttribute('aria-label') || '')
      .replace(/\s+/g, ' ').trim()).slice(0, 60);
  }
  function info(el) {
    var r = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(), text: label(el), href: el.href || '',
      x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2)
    };
  }
  var exact = [], loose = [];
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    if (!visible(el)) continue;
    var t = label(el);
    if (!t) continue;
    if (t === want) exact.push(el);
    else if (t.indexOf(want) >= 0 || want.indexOf(t) >= 0) loose.push(el);
  }
  var hit = (exact.length ? exact : loose)[0];
  if (!hit) {
    return { ok: false, reason: 'no-match',
      candidates: all.filter(visible).map(info).filter(function (o) { return o.text; }).slice(0, 12) };
  }
  hit.scrollIntoView({ block: 'center', inline: 'center' });
  var out = info(hit);
  out.ok = true;
  out.matchedBy = exact.length ? 'exact' : 'partial';
  try { hit.click(); } catch (e) { out.clickError = String(e); }
  return out;
})()''';

  static String clickByTextJs(String text) =>
      _clickTemplate.replaceFirst('__NEEDLE__', jsonEncode(text));

  /// 滑动 / 滚动（"支持滑动"的落点）：给 `to` 就滑到那段文字处，
  /// 否则按像素 `dy` 滚。
  static const String _scrollTemplate = r'''
(function () {
  var want = __TO__, dy = __DY__;
  if (want) {
    var els = Array.prototype.slice.call(document.querySelectorAll('body *'));
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      var t = (el.innerText || '').replace(/\s+/g, ' ').trim();
      if (t && t.indexOf(want) >= 0) {
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        return { ok: true, mode: 'to-text', found: want, y: Math.round(scrollY) };
      }
    }
    return { ok: false, reason: 'text-not-found', found: want, y: Math.round(scrollY) };
  }
  var before = scrollY;
  window.scrollBy(0, dy);
  return { ok: true, mode: 'by', dy: dy, before: Math.round(before),
           after: Math.round(scrollY), moved: Math.round(scrollY - before) };
})()''';

  static String scrollJs({String to = '', int dy = 0}) => _scrollTemplate
      .replaceFirst('__TO__', to.isEmpty ? 'null' : jsonEncode(to))
      .replaceFirst('__DY__', dy.toString());

  static String netscapeCookies(List<Cookie> cookies) {
    final StringBuffer sb = StringBuffer();
    sb.writeln('# Netscape HTTP Cookie File');
    sb.writeln('# 由 Zeus 从内置浏览器导出，可直接给 curl -b 用');
    for (final Cookie c in cookies) {
      String domain = c.domain ?? '';
      // 域名以点开头表示"包含子域"，Netscape 格式把它放在第 2 列
      final bool sub = domain.startsWith('.');
      if (sub) domain = domain.substring(1);
      if (domain.isEmpty) continue;
      final int expires = (c.expiresDate == null || c.expiresDate! <= 0)
          ? 0
          : c.expiresDate!;
      final String path = (c.path ?? '/').isEmpty ? '/' : c.path!;
      sb.writeln(
        <String>[
          domain,
          sub ? 'TRUE' : 'FALSE',
          path,
          'TRUE',
          '$expires',
          c.name,
          c.value,
        ].join('\t'),
      );
    }
    return sb.toString();
  }

  /// **当前打开着的那一页**的控制器（由内置浏览器页注册）。
  ///
  /// 有了它，agent 才能读"用户正在看的那一页" —— 而不是只能自己去
  /// 无头地重新打开一遍（那会丢掉登录态、也看不到用户在页面上做的操作）。
  static InAppWebViewController? liveController;

  /// 当前打开着的那一页的地址；没有打开的页时为 null。
  static String? get liveUrl => _liveUrl;
  static String? _liveUrl;

  /// 内置浏览器页在 `onWebViewCreated` / `onLoadStop` / `dispose` 时调它。
  static void setLive(InAppWebViewController? c, {String? url}) {
    liveController = c;
    if (url != null) _liveUrl = url;
    if (c == null) _liveUrl = null;
  }

  /// 在**当前打开着的那一页**里执行 JS，返回结果字符串（失败返回 null）。
  static Future<String?> evalLive(String js) async {
    final InAppWebViewController? c = liveController;
    if (c == null) return null;
    // 走 evalOn（支持 return / Promise）—— 和 agent 直接调 `js` 是同一条路，
    // 免得"页面里跑"和"工具里跑"行为不一样。
    return evalOn(c, js);
  }

  /// 在**当前页**里跑一段脚本并等它"画完"（给截图用）。
  static Future<bool> waitSettled(
    InAppWebViewController c, {
    int attempts = 10,
    Duration interval = const Duration(milliseconds: 400),
  }) async {
    for (int i = 0; i < attempts; i++) {
      final String? r = await evalOn(c, settleJs);
      if (r == 'true') return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// 给**当前打开着的那一页**截图（返回 PNG 字节）。
  static Future<Uint8List?> captureLive() async {
    final InAppWebViewController? c = liveController;
    if (c == null) return null;
    try {
      return await c.takeScreenshot();
    } catch (_) {
      return null;
    }
  }

  /// 打开 [url] 并**截图**（返回 PNG 字节；失败或超时返回 null）。
  ///
  /// ## 为什么用 `takeScreenshot()` 而不是 RepaintBoundary
  ///
  /// WebView 在 Android 上是**平台视图**（native view），Flutter 的合成层里
  /// 只有一块占位 —— 用 `RepaintBoundary.toImage()` 截出来是**一片空白**。
  /// `takeScreenshot()` 走的是原生 WebView 自己的绘制，拿到的才是真内容。
  /// （这个坑不写下来，下次一定还会有人试 RepaintBoundary。）
  static Future<Uint8List?> capture(
    String url, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    HeadlessInAppWebView? headless;
    final Completer<Uint8List?> done = Completer<Uint8List?>();

    void finish(Uint8List? v) {
      if (!done.isCompleted) done.complete(v);
    }

    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          // WebView 自己的**表单自动填充**：让浏览器记住填过的字段
          // （地址、邮箱、搜索词这类）。真正的**密码**不在这一层 ——
          // 密码要么靠系统自动填充服务，要么由我们自己加密保管，
          // 见 README 里"密码"那一段的说明。
          saveFormData: true,
          userAgent: userAgent,
        ),
        onLoadStop: (InAppWebViewController controller, WebUri? uri) async {
          try {
            // 给首屏之外的图/字体一点时间：刚 loadStop 时常常还没画完，
            // 截出来会缺一块。
            await Future<void>.delayed(const Duration(milliseconds: 800));
            finish(await controller.takeScreenshot());
          } catch (_) {
            finish(null);
          }
        },
      );
      await headless.run();
      return await done.future.timeout(timeout, onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      try {
        await headless?.dispose();
      } catch (_) {
        // 关不掉就算了，不能因为清理失败把结果吞了
      }
    }
  }

  /// 移动端 UA。
  ///
  /// 两个作用：
  ///  1. 桌面 UA 有些站点会返回更重的页面；
  ///  2. **盖掉系统 WebView 的真实版本号** —— 这点更重要。
  ///     很多国产手机的 Android System WebView 长期不更新（没有 Play 商店），
  ///     UA 里报的是很老的 Chrome 版本，正常网站会直接回一句
  ///     「请更换浏览器」然后拒绝服务。我们只是要抓文本，
  ///     报一个正常的现代版本即可，不必暴露系统组件的实际版本。
  static const String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Mobile Safari/537.36';

  /// **桌面** UA。
  ///
  /// 什么时候需要它：一部分站点给手机端发的是"精简页"（内容被砍、要点开
  /// "展开全文"才出），给桌面端发的才是完整正文。抓资料时经常是桌面版更好用。
  /// 没有移动端标记（`Mobile`）和 `Android` 字样，站点就按桌面站返回。
  ///
  /// 为什么不做自动探测：同一个站在不同页面上表现都不一样，而"我要桌面版"
  /// 是**用户的意图**，不是可以替他猜的事 —— 所以做成设置里的一个开关。
  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 当前用哪套 UA。由设置页/启动时写入（见 `Settings.desktopUa`）。
  static bool useDesktopUa = false;

  /// 当前生效的 UA。
  static String get userAgent =>
      useDesktopUa ? desktopUserAgent : mobileUserAgent;

  /// 打开 [url]，反复执行 [js] 直到 [isDone] 为真或尝试次数用尽。
  /// 返回 null 表示主文档加载失败或整体超时。
  static Future<String?> load({
    required String url,
    required String js,
    bool Function(String value)? isDone,
    int attempts = 6,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    HeadlessInAppWebView? headless;
    final Completer<String?> completer = Completer<String?>();

    void finish(String? value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          transparentBackground: true,
          mediaPlaybackRequiresUserGesture: true,
          // **必须显式设置**。不设的话 WebView 用系统默认 UA，
          // 而系统 WebView 老旧时会把真实版本号报出去，站点据此判定
          // 「浏览器太旧」并拒绝返回内容。
          userAgent: userAgent,
          // 不加载图片：抓文本不需要，能明显加快加载
          blockNetworkImage: true,
          useShouldInterceptRequest: false,
          // 开启缓存。搜索引擎的 CSS/JS/字体第一次下完就留在本地，
          // 之后再抓同一个引擎几乎不用重新下载 —— 这是最省事的一处提速。
          cacheEnabled: true,
          clearCache: false,
        ),
        onLoadStop: (InAppWebViewController controller, WebUri? uri) async {
          if (completer.isCompleted) return;

          String? last;
          for (int i = 0; i < attempts; i++) {
            try {
              // 第一次立刻抽，不要先等。
              // 原来固定先等 900ms，等于每次加载白扔将近一秒 ——
              // 而多数静态页面在 onLoadStop 时内容已经就绪了。
              if (i > 0) {
                await Future<void>.delayed(_pollDelay(i));
              }
              if (completer.isCompleted) return;

              // 走 evalOn：支持 `return` 与 Promise（见它的说明）。
              final dynamic r = await evalOn(controller, js);
              final String? s = r?.toString();
              if (s == null) continue;

              last = s;
              if (isDone == null || isDone(s)) {
                finish(s);
                return;
              }
            } catch (_) {
              // 单次抽取失败就继续重试
            }
          }
          finish(last);
        },
        onReceivedError:
            (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceError error,
            ) {
              // 只有主文档失败才算失败；子资源（图片/广告）失败不影响
              if (request.isForMainFrame == true) finish(null);
            },
      );

      // **必须给 run() 也加超时**。
      //
      // run() 是在等平台侧创建 WebView 实例。如果系统 WebView 组件有问题
      // （版本太旧、被禁用、或损坏），这一步会**永远不返回** ——
      // 而原来的超时只包住了下面的 completer.future，
      // 结果就是整个工具卡死、界面一直转圈，超时形同虚设。
      await headless.run().timeout(_createTimeout);

      return await completer.future.timeout(timeout);
    } catch (_) {
      return null;
    } finally {
      try {
        // dispose 同样可能卡住（webview 没建起来时），一并加超时
        await headless?.dispose().timeout(const Duration(seconds: 5));
      } catch (_) {
        // 忽略清理失败
      }
    }
  }

  /// WebView 实例创建的超时。超过就认定这台机器的 WebView 组件不可用，
  /// 直接放弃 —— 宁可快速失败，也不要无限转圈。
  static const Duration _createTimeout = Duration(seconds: 12);

  /// 自适应的轮询间隔。
  ///
  /// 前面密、后面疏：内容大多在头几百毫秒内就绪，先密集探测能立刻拿到；
  /// 真遇到慢页面时再拉长间隔，避免空转浪费。
  /// 累计等待约 0.2 + 0.35 + 0.55 + 0.85 + 1.2 ≈ 3.2 秒，
  /// 比原来固定 6 × 900ms = 5.4 秒短得多，而且能更早命中。
  static Duration _pollDelay(int attempt) {
    const List<int> ms = <int>[200, 350, 550, 850, 1200];
    final int idx = attempt - 1;
    return Duration(milliseconds: idx < ms.length ? ms[idx] : ms.last);
  }

  /// evaluateJavascript 在部分平台会把字符串结果再包一层引号并转义，
  /// 这里尝试还原成可直接 jsonDecode 的文本。
  static String unwrapJsString(String raw) {
    String s = raw.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        final dynamic decoded = jsonDecode(s);
        if (decoded is String) s = decoded;
      } catch (_) {
        // 保持原样
      }
    }
    return s;
  }

  /// 提取正文：去掉脚本/样式/内嵌框架后取可见文本
  static const String extractTextJs = r'''
(function () {
  if (!document.body) return '';
  var c = document.body.cloneNode(true);
  ['script', 'style', 'noscript', 'svg', 'iframe', 'template'].forEach(function (tag) {
    c.querySelectorAll(tag).forEach(function (n) { n.remove(); });
  });
  var t = c.innerText || c.textContent || '';
  t = t.replace(/[ \t\u00A0]+/g, ' ');
  t = t.replace(/\n\s*\n\s*\n+/g, '\n\n');
  return t.trim().slice(0, 30000);
})()
''';

  /// 提取标题 + 正文，用于网页附件
  static const String extractPageJs = r'''
(function () {
  var t = '';
  if (document.body) {
    var c = document.body.cloneNode(true);
    ['script', 'style', 'noscript', 'svg', 'iframe', 'template'].forEach(function (tag) {
      c.querySelectorAll(tag).forEach(function (n) { n.remove(); });
    });
    t = c.innerText || c.textContent || '';
    t = t.replace(/[ \t\u00A0]+/g, ' ');
    t = t.replace(/\n\s*\n\s*\n+/g, '\n\n');
    t = t.trim().slice(0, 30000);
  }
  return JSON.stringify({
    title: document.title || '',
    url: location.href,
    text: t
  });
})()
''';
}
