import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import 'visual_memo.dart';
import 'webview_loader.dart';

/// 浏览器工具的错误**短代码**。
///
/// ## 为什么要有它
///
/// 以前失败长这样：「读取失败：页面没打开，或者执行超时。」—— 三种完全
/// 不同的情况挤在一句话里，模型只能猜，猜错就把同一步重试一遍（每次都
/// 白等十几秒）。短代码把"接下来该换哪条路"直接写清楚：
///
///  · [pageClosed] → 先 `open` 一页，别对着空气点；
///  · [noElement] → 选择器不对，先 `dom` 看页面上到底有什么；
///  · [blockedTrusted] → JS 点击被站点拒绝，改用 `mode: trusted`，
///    或者 `ask` 把这一页交给用户；
///  · [timeout] → 等的东西一直没出现，别原地重试，先看 `dom`；
///  · [httpError] → 是服务端的响应码，不是本地脚本写错了。
class BrowserCode {
  const BrowserCode._();

  /// 这一页已经关了（或者从来没打开过）。
  static const String pageClosed = 'PAGE_CLOSED';

  /// 选择器（或文字）在页面上找不到。
  static const String noElement = 'NO_ELEMENT';

  /// 需要**真实触摸**，但当前没有可注入的窗口（headless 页收不到触摸）。
  static const String blockedTrusted = 'BLOCKED_TRUSTED';

  /// 等的东西一直没出现。
  static const String timeout = 'TIMEOUT';

  /// 服务端返回了错误码（网络这一层是通的）。
  static const String httpError = 'HTTP_ERROR';

  /// 参数不对（少字段、类型错、必填为空）。
  static const String badArg = 'BAD_ARG';

  /// 这套环境做不了（例如没有可用的 WebView 组件）。
  static const String unsupported = 'UNSUPPORTED';

  /// **动作报成功、页面其实没反应**。
  ///
  /// 这个代码是为一次实战加的：`click` / `scroll` / `press` 全都返回
  /// "已点击 / 已滚动 0 → 1913"，而页面上的计数器和 scrollY 纹丝不动 ——
  /// 注入的输入事件在一些页面上会被**静默丢弃**。最坏的地方不是"点不动"，
  /// 而是**它说点动了**：agent 会带着这个假前提一路往下走，
  /// 最后交出一份错的结论。
  ///
  /// 所以现在所有"应该让页面动一下"的动作，**成功与否由回读决定**：
  /// 页面收到的 click/keydown 计数、scrollY、输入框的值，动没动？
  /// 没动就回这个代码，让模型换路（`js` 直接调、或者 `ask` 交给用户）。
  static const String noEffect = 'NO_EFFECT';
}

/// 一步操作的结果：成功带正文，失败带**短代码**。
///
/// [render] 是交给模型看的那一行 —— 失败时永远是
/// `CODE — 人话说明`，模型据此换路，而不是把同一步重试一遍。
class StepResult {
  const StepResult.ok(this.text) : code = '';
  const StepResult.fail(this.code, this.text);

  final String code;
  final String text;

  bool get ok => code.isEmpty;
  String get render => ok ? text : '$code — $text';

  static const StepResult closed = StepResult.fail(
    BrowserCode.pageClosed,
    '这一页没有打开着。先 `open` 一个网址，或者 `ask` 把它交给用户打开。',
  );
}

/// 会话里抓到的一个下载请求（`onDownloadStartRequest`）。
class PendingDownload {
  const PendingDownload({
    required this.url,
    this.mimeType = '',
    this.suggestedFilename = '',
    this.contentLength = 0,
    this.userAgent = '',
  });

  final String url;
  final String mimeType;
  final String suggestedFilename;
  final int contentLength;
  final String userAgent;
}

/// **agent 自己的那个浏览器页面**：保活、能操作、能看见网络。
///
/// ## 为什么必须是"保活的一页"，而不是每次新建
///
/// 以前每个动作都是"新建一个无头 WebView → 打开 → 读一次 → 销毁"。
/// 三个后果，全是硬的：
///
///  1. **点不动**：点完按钮页面变了、跳走了，下一次动作又是新的一页，
///     上一动作的现场全没了。登录更是没戏 —— 表单填一半就没了；
///  2. **网络抓不到**：要记录 fetch/XHR 的响应体，必须在**文档开始时**
///     注入包装脚本，然后让页面一直活着；每次重建等于每次重装；
///  3. **慢**：每建一个 Chromium 实例要几秒，一次任务十几个动作就是
///     一分钟起步。
///
/// 所以这一页**跨工具调用活着**：模型说"打开 A、填表单、点提交、
/// 等接口回来、把 JSON 存下来"时，这五步都在**同一页**上发生。
///
/// ## 和内置浏览器页的关系
///
///  · 用户的页面（[WebViewLoader.liveController]）：给**人**看的，
///    要登录、要授权时用 `ask` 推到他面前；
///  · 这一页：给 **agent** 用的，不占界面、不打扰用户，但和用户那页
///    **共用同一份 cookie**（都在平台的 cookie 库里）——
///    所以"用户登录一次，agent 之后所有动作都带着登录态"。
///
/// ## 空闲回收
///
/// 一个 WebView 会占几十 MB，没人用的时候不该一直躺着。[idleReclaim]
/// 之后自动销毁；下次动作会重新建（cookie 不丢）。
class WebSession {
  WebSession._();

  static final WebSession instance = WebSession._();

  /// 原生那一路：真实触摸 / 按键 / cookie 落盘（见 `WebBridge.kt`）。
  static const MethodChannel _native = MethodChannel('dsh/web');

  /// 空闲多久回收。**长任务不受影响**：每次动作都会把计时器往后推。
  static const Duration idleReclaim = Duration(minutes: 12);

  static const Duration _createTimeout = Duration(seconds: 15);
  static const Duration _navTimeout = Duration(seconds: 35);

  HeadlessInAppWebView? _page;
  InAppWebViewController? _ctl;
  Completer<InAppWebViewController?>? _creating;

  bool _loading = false;
  String _url = '';
  String _title = '';
  String _lastError = '';
  int _navSeq = 0;
  Timer? _idle;

  /// 页面上弹过的原生对话框（alert / confirm / prompt）。
  ///
  /// 只留最近的几条：这是给模型看的**证据**（"它问我删不删，我替它答了
  /// 取消"），不是日志文件。
  final List<String> dialogs = <String>[];

  /// 下一个弹窗的答案（由 `dialog` 动作预设）。用掉就清空。
  bool? _nextAnswer;
  String _nextPromptText = '';

  /// 上一次 `onDownloadStartRequest` 抓到的下载请求。
  PendingDownload? lastDownload;

  /// 看图点坐标的**记忆**（点过之后记住"怎么用非视觉的方式找到它"）。
  ///
  /// 懒加载：只有真的用到坐标点击时才去建/读盘，
  /// 纯 API 抓数据那种任务不该为它多读一个文件。
  VisualMemo? _memo;
  String _memoDir = '';

  bool get alive => _ctl != null;

  /// 告诉会话"工作目录在哪"—— 点按记忆存这下面。
  ///
  /// 传空串是有意义的：等于说"这次没有可写的地方"，记忆就只在内存里
  /// （本次会话内照样管用，重启就没了）。**不能因为目录没了就不记忆** ——
  /// 一个任务里连点三次同一个按钮，省下的那两次才是记忆的价值。
  void bindWorkDir(String dir) {
    final String d = dir.trim();
    if (d == _memoDir) return;
    _memoDir = d;
    _memo = null;
  }

  VisualMemo? _memoOrNull() {
    if (_memo != null) return _memo;
    if (_memoDir.isEmpty) return null;
    _memo = VisualMemo(file: File('$_memoDir/browser_visual_memo.json'));
    return _memo;
  }

  /// 已记住的"坐标 → 非视觉定位"条数（`status` 用）。
  int get visualMemoSize => _memo?.length ?? 0;
  bool get loading => _loading;
  String get url => _url;
  String get title => _title;
  String get lastError => _lastError;

  /// 给 `status` 动作用的一句话状态。
  String get stateWord {
    if (_ctl == null) return 'closed';
    if (_loading) return 'loading';
    return 'ready';
  }

  // -------------------------------------------------------------- 生命周期

  /// 确保有一页活着，返回它的控制器。
  ///
  /// 并发调用会**共用同一次创建**（`_creating`）：模型偶尔会在一个回合里
  /// 同时调两个浏览器动作，各建一个实例的话，后一个会把前一个的现场顶掉。
  Future<InAppWebViewController?> ensure() async {
    _touchIdle();
    if (_ctl != null) return _ctl;

    final Completer<InAppWebViewController?>? pending = _creating;
    if (pending != null) return pending.future;

    final Completer<InAppWebViewController?> c =
        Completer<InAppWebViewController?>();
    _creating = c;
    try {
      final HeadlessInAppWebView page = HeadlessInAppWebView(
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          domStorageEnabled: true,
          databaseEnabled: true,
          // 第三方 cookie 必须开：SSO 登录常常是"从 A 站跳 B 站授权再跳
          // 回来"，关掉之后授权那一步的 cookie 写不进去，登录态断在半路。
          thirdPartyCookiesEnabled: true,
          useShouldInterceptRequest: false,
          userAgent: WebViewLoader.userAgent,
          // 这一页是 agent 干活的，不是给人看的：不加载图片能快很多。
          // 真要"看"页面用 `screenshot` 动作（那条路走用户的页面）。
          blockNetworkImage: true,
          mediaPlaybackRequiresUserGesture: true,
          cacheEnabled: true,
        ),
        // **必须在文档开始时注入**：网络包装要赶在页面自己的脚本之前把
        // fetch/XHR 换掉，晚一步这一页的请求就全抓不到了。
        initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
          bootstrapScript,
        ]),
        onWebViewCreated: (InAppWebViewController controller) {
          _ctl = controller;
          if (!c.isCompleted) c.complete(controller);
        },
        onLoadStart: (InAppWebViewController controller, WebUri? uri) {
          _loading = true;
          _lastError = '';
          if (uri != null) _url = uri.toString();
        },
        onLoadStop: (InAppWebViewController controller, WebUri? uri) async {
          _loading = false;
          if (uri != null) _url = uri.toString();
          try {
            final String? t = await controller.getTitle();
            if (t != null && t.isNotEmpty) _title = t;
          } catch (_) {
            // 标题读不到不影响任何事
          }
        },
        onReceivedError:
            (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceError error,
            ) {
              // 只有主文档失败才算失败；子资源（图片/广告）失败不影响
              if (request.isForMainFrame == true) {
                _lastError = error.description;
              }
            },
        onReceivedHttpError:
            (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceResponse response,
            ) {
              if (request.isForMainFrame == true) {
                _lastError = 'HTTP ${response.statusCode}';
              }
            },
        // 下载：先**接住**（记下地址），真正落盘由 `download` 动作做 ——
        // WebView 自己的下载器不认我们在 cookie 库里的登录态，
        // 直接让它下往往是 401 的一页 HTML。
        onDownloadStartRequest:
            (InAppWebViewController controller, DownloadStartRequest req) {
              lastDownload = PendingDownload(
                url: req.url.toString(),
                mimeType: req.mimeType ?? '',
                suggestedFilename: req.suggestedFilename ?? '',
                contentLength: req.contentLength,
                userAgent: req.userAgent ?? '',
              );
            },
        // 原生弹窗：**必须替用户答一句**，否则页面的 JS 永远停在
        // `confirm()` 那一行上 —— 无头页上没人能点，后台就这么卡住。
        onJsAlert:
            (InAppWebViewController controller, JsAlertRequest req) async {
              _recordDialog('alert', req.message ?? '');
              return JsAlertResponse(
                action: JsAlertResponseAction.CONFIRM,
                message: req.message ?? '',
              );
            },
        onJsConfirm:
            (InAppWebViewController controller, JsConfirmRequest req) async {
              final bool ok = _takeAnswer();
              _recordDialog(
                'confirm',
                req.message ?? '',
                answered: ok ? '确定' : '取消',
              );
              return JsConfirmResponse(
                action: ok
                    ? JsConfirmResponseAction.CONFIRM
                    : JsConfirmResponseAction.CANCEL,
                message: req.message ?? '',
              );
            },
        onJsPrompt:
            (InAppWebViewController controller, JsPromptRequest req) async {
              final bool ok = _takeAnswer();
              _recordDialog(
                'prompt',
                req.message ?? '',
                answered: ok ? '填了「$_nextPromptText」' : '取消',
              );
              return JsPromptResponse(
                action: ok
                    ? JsPromptResponseAction.CONFIRM
                    : JsPromptResponseAction.CANCEL,
                message: req.message ?? '',
                value: _nextPromptText,
              );
            },
      );

      _page = page;
      // `run()` 在等平台侧建实例。系统 WebView 组件有问题时它会**永远
      // 不返回** —— 不加超时就是整个工具卡死。
      await page.run().timeout(_createTimeout);

      final InAppWebViewController? controller = await c.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => _ctl,
      );
      if (controller == null) {
        await close();
        return null;
      }
      // cookie 落盘：写完立刻 flush，进程被杀也不会丢刚登录的那一份。
      unawaited(flushCookies());
      return controller;
    } catch (_) {
      await close();
      return null;
    } finally {
      _creating = null;
    }
  }

  /// 关掉这一页（空闲回收 / 出错清理 / 用户主动关）。
  Future<void> close() async {
    _idle?.cancel();
    _idle = null;
    final HeadlessInAppWebView? p = _page;
    _page = null;
    _ctl = null;
    _loading = false;
    _url = '';
    _title = '';
    if (p != null) {
      try {
        await p.dispose().timeout(const Duration(seconds: 5));
      } catch (_) {
        // 关不掉就算了，不能因为清理失败把结果吞掉
      }
    }
  }

  void _touchIdle() {
    _idle?.cancel();
    _idle = Timer(idleReclaim, () {
      // 正在加载就不收：收了等于把这一轮的动作全作废。
      if (_loading) {
        _touchIdle();
        return;
      }
      unawaited(close());
    });
  }

  // ------------------------------------------------------------------ 导航

  /// 打开一个网址（在**同一页**上导航，不新建实例）。
  Future<StepResult> navigate(
    String rawUrl, {
    Duration timeout = _navTimeout,
  }) async {
    final String target = rawUrl.trim();
    if (target.isEmpty) {
      return const StepResult.fail(BrowserCode.badArg, '缺少 url。');
    }
    final Uri? uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme) {
      return StepResult.fail(BrowserCode.badArg, 'url 不合法 —— $target');
    }

    final InAppWebViewController? c = await ensure();
    if (c == null) {
      return const StepResult.fail(
        BrowserCode.unsupported,
        'WebView 起不来（系统 WebView 组件可能被禁用或损坏）。',
      );
    }

    final int seq = ++_navSeq;
    _lastError = '';
    _loading = true;

    try {
      // 导航期间**自动替用户答"确定"**：离开当前页正是这一步的意图，
      // 而 beforeunload 那种"要离开吗"的确认框如果答"取消"，
      // 这次导航就永远发不出去。
      _nextAnswer = true;
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
    } catch (e) {
      return StepResult.fail(BrowserCode.unsupported, '打不开这一页：$e');
    }

    await _waitForLoad(seq, timeout);
    _nextAnswer = null;

    if (seq != _navSeq) {
      return const StepResult.fail(
        BrowserCode.timeout,
        '这一页被另一次导航顶掉了（同一页上又打开了别的地址）。',
      );
    }
    if (_lastError.isNotEmpty) {
      return StepResult.fail(
        BrowserCode.httpError,
        '打开失败：$_lastError\n地址：${_url.isEmpty ? target : _url}',
      );
    }

    final String finalUrl = (await _currentUrl(c)) ?? _url;
    _url = finalUrl;
    final String t = await _currentTitle(c);
    if (t.isNotEmpty) _title = t;

    final String finalHost = Uri.tryParse(finalUrl)?.host ?? '';
    final bool redirected =
        uri.host.isNotEmpty && finalHost.isNotEmpty && finalHost != uri.host;

    return StepResult.ok(
      '已打开：${t.isEmpty ? finalUrl : t}\n'
      '地址：$finalUrl\n'
      '${redirected ? '（注意：**跳转过** —— 请求的是 ${uri.host}，'
                '最终落在 $finalHost）\n' : ''}',
    );
  }

  Future<void> _waitForLoad(int seq, Duration timeout) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (seq != _navSeq) return;
      if (!_loading) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<String?> _currentUrl(InAppWebViewController c) async {
    try {
      final WebUri? u = await c.getUrl();
      return u?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<String> _currentTitle(InAppWebViewController c) async {
    try {
      return (await c.getTitle()) ?? '';
    } catch (_) {
      return '';
    }
  }

  // ------------------------------------------------------------------ 执行

  /// 在页面里执行一段 JS。**`return x` 和 `x` 两种写法都支持，Promise 会被等到。**
  ///
  /// ## 为什么这件事必须两边都认（一次实战换来的）
  ///
  /// 原来只用 `evaluateJavascript`，也就是**只认表达式**：文档里写着
  /// "用 `return` 交出结果"，而 `return document.title` 得到的是
  /// **"执行完成，没有返回内容"**（那个语法错被吞掉了）。
  ///
  /// 对 agent 来说这是灾难级的不一致 —— 它完全靠文档决定怎么调用：
  /// 白扔四五轮之后，它会开始怀疑"这个站不让注入脚本"，
  /// 然后沿着一个完全错误的方向排查（那次真是这么走歪的）。
  Future<StepResult> eval(String js) async {
    final String source = js.trim();
    if (source.isEmpty) {
      return const StepResult.fail(BrowserCode.badArg, '缺少 js。');
    }
    final InAppWebViewController? c = await ensure();
    if (c == null) return StepResult.closed;

    final String? raw = await WebViewLoader.evalOn(c, source);
    if (raw == null) {
      return const StepResult.ok('执行完成，没有返回内容。');
    }
    // **事实式报错**：把 JS 引擎的原话交出去。"可能没注入脚本"这种猜测
    // 会把 agent 带到错误的方向上查好几轮。
    if (raw.startsWith('JS_ERROR: ')) {
      return StepResult.fail(BrowserCode.unsupported, raw);
    }
    final String text = WebViewLoader.unwrapJsString(raw);
    if (text.trim().isEmpty || text.trim() == 'null') {
      return const StepResult.ok('执行完成，没有返回内容。');
    }
    return StepResult.ok(text);
  }

  /// 确认这一页有注入脚本（`window.__dsh`），没有就**补注一次**。
  ///
  /// ## 为什么需要它（一次实战里最伤信任的那个现象）
  ///
  /// 引导脚本是"文档开始时"注入的，正常情况下每个文档都有。但现实里它确实
  /// 会缺：新文档还没注入、这一页是 PDF / `blob:` / 特殊 scheme、
  /// 或者 touch 到的根本不是我们建的那一页。
  ///
  /// 缺了会怎样？——`dom` 照样读得到内容（它不依赖注入脚本），
  /// 而 `click` 回一句 `NO_BOOTSTRAP`。在模型眼里这就是
  /// **"看得见，点不着"**：它能看到那个按钮的字，就是点不动，
  /// 于是反复重试、换各种选择器，把整个排查方向带歪。
  ///
  /// 引导脚本自己开头就有 `if (window.__dsh && v >= 1) return;`，
  /// 是幂等的，所以补一次是安全的。
  Future<bool> ensureBootstrap() async {
    const String probeJs =
        'return (window.__dsh && window.__dsh.v >= 1) ? "yes" : "no"';
    final StepResult first = await eval(probeJs);
    if (first.ok && first.text.trim() == 'yes') return true;

    await eval(kSessionBootstrapJs);

    final StepResult again = await eval(probeJs);
    return again.ok && again.text.trim() == 'yes';
  }

  /// 跑一段**依赖注入脚本**的 JS：缺脚本就先补上，再重试一次。
  ///
  /// 只有明确回了 `NO_BOOTSTRAP` 才重试 —— 其它失败（找不到元素、被拒绝）
  /// 补脚本也没用，重试只是白等一轮。
  Future<StepResult> evalBoot(String js) async {
    final StepResult first = await eval(js);
    if (!first.ok || !first.text.contains('NO_BOOTSTRAP')) return first;
    if (!await ensureBootstrap()) return first;
    return eval(js);
  }

  /// 在页面里执行一段**会 await** 的 JS（能用 Promise / fetch）。
  ///
  /// 和 [eval] 分开是因为两者能力不同：`evaluateJavascript` 拿不到
  /// Promise 的结果（它只回一个句柄），所以"页内发一个带 cookie 的请求"
  /// 这类事必须走这里。失败时返回 `{'__error': ...}`。
  Future<dynamic> evalAsync(
    String functionBody, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    final InAppWebViewController? c = await ensure();
    if (c == null) return null;
    try {
      final CallAsyncJavaScriptResult? r = await c
          .callAsyncJavaScript(functionBody: functionBody, arguments: args)
          .timeout(const Duration(seconds: 90));
      if (r == null) return null;
      if (r.error != null) return <String, dynamic>{'__error': r.error};
      return r.value;
    } catch (e) {
      return <String, dynamic>{'__error': '$e'};
    }
  }

  // ------------------------------------------------------------ 原生那一路

  /// 问原生：现在有没有一个**能收触摸**的 WebView（= 用户的浏览器页开着）。
  Future<bool> nativeTouchReady() async {
    try {
      final bool? ok = await _native.invokeMethod<bool>('canTap');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 注入一次真实触摸（`ACTION_DOWN` + `ACTION_UP`）。
  ///
  /// [x]/[y] 是**CSS 像素**（页面坐标系），[innerWidth] 是页面自己报的
  /// 视口宽度 —— 原生那侧靠它把 CSS 坐标换算成视图坐标。
  ///
  /// headless 页没有窗口、尺寸是 0，收不到触摸，所以这条路只在用户的
  /// 浏览器页开着时可用（见 [nativeTouchReady]）。返回 null = 成功，
  /// 否则是原生给的错误串。
  Future<String?> tapAt(double x, double y) async {
    try {
      return await _native.invokeMethod<String>('tap', <String, dynamic>{
        'x': x,
        'y': y,
        'innerWidth': await _innerWidth(),
      });
    } catch (e) {
      return '$e';
    }
  }

  Future<double> _innerWidth() async {
    final StepResult r = await eval('return window.innerWidth || 0');
    final double? v = double.tryParse(r.text.trim());
    return (v == null || v <= 0) ? 0 : v;
  }

  /// 注入一次真实按键（Enter / Back / 方向键…）。同样需要用户那页开着。
  Future<String?> pressKeyNative(String key) async {
    try {
      return await _native.invokeMethod<String>('key', <String, dynamic>{
        'key': key,
      });
    } catch (e) {
      return '$e';
    }
  }

  /// 把 cookie 写盘。
  ///
  /// 平台的 cookie 库平时**攒着不写**，进程一被杀就丢 —— 表现就是
  /// "刚才明明登录好了，重开应用又要登"。原生 `CookieManager.flush()`
  /// 就是干这个的，插件没暴露，所以走我们自己的通道。
  Future<void> flushCookies() async {
    try {
      await _native.invokeMethod<bool>('flushCookies');
    } catch (_) {
      // 落盘失败不影响这一轮动作
    }
  }

  /// 一次真实滑动（手势：拖动、拖拽、懒加载）。
  ///
  /// 起点和终点**各自带 x 和 y**：横向列表、滑块、地图拖动都靠它，
  /// 只能竖着滑的话这三种一个都做不了。
  Future<String?> swipeNative({
    required double fromX,
    required double fromY,
    required double toX,
    required double toY,
    required int ms,
  }) async {
    try {
      return await _native.invokeMethod<String>('swipe', <String, dynamic>{
        'fromX': fromX,
        'fromY': fromY,
        'toX': toX,
        'toY': toY,
        'ms': ms,
        'innerWidth': await _innerWidth(),
      });
    } catch (e) {
      return '$e';
    }
  }

  // -------------------------------------------------------------- 页面操作

  /// 点一下。
  ///
  /// ## 两级点击
  ///
  ///  1. **默认走 JS** `el.click()`：快、不挑窗口、绝大多数站点都认；
  ///  2. 只有 [trusted] 为真时才注入**真实触摸** —— 有些站点在事件里查
  ///     `event.isTrusted`，脚本点上去它一律当没点。真实触摸需要有一个
  ///     **真实窗口**（用户的浏览器页开着）：headless 页没有尺寸、
  ///     收不到触摸，这时直接回 [BrowserCode.blockedTrusted] 并说明该
  ///     怎么做，而不是假装点过了。
  ///
  /// ## 点完要**核实**
  ///
  /// JS 的 `click()` 不报错**不代表点到了**（可能被遮罩挡住、可能是
  /// 个装饰性元素）。所以结果里带上：点了哪个元素、有没有引发跳转。
  /// 什么都没发生时提示模型"先 `dom` 看清楚，或者换 `trusted`"。
  /// 点一下 —— **成功与否由回读决定**（见 [_verifyEffect]）。
  ///
  /// 这一层只做两件事：记下"动作之前页面收到了几次 click"，动作，然后核对。
  Future<StepResult> click({
    String selector = '',
    String text = '',
    int index = 0,
    bool trusted = false,
    double? atX,
    double? atY,
  }) async {
    final ({bool has, int clicks, int keys}) seen0 = await _pageEvents();
    final String url0 = _url;
    final StepResult r = await _clickInner(
      selector: selector,
      text: text,
      index: index,
      trusted: trusted,
      atX: atX,
      atY: atY,
    );
    return _verifyEffect(r, click: true, what: '点击', seen0: seen0, url0: url0);
  }

  Future<StepResult> _clickInner({
    String selector = '',
    String text = '',
    int index = 0,
    bool trusted = false,
    double? atX,
    double? atY,
  }) async {
    // ---- 坐标点击：**视觉方案的落脚点** ----
    //
    // 选择器会随改版失效、文字匹配会遇到"同一个词出现在三个地方"，
    // 而"我看着截图，就点这个位置"是最后一条永远可用的路。
    // 没有它的话，两级定位都失败时 agent 直接没招（那次实战就卡在这儿）。
    //
    // [atX]/[atY] 是**截图上的像素坐标**（模型看的就是那张图），
    // 而页面里要的是 CSS 像素 —— 差一个 `devicePixelRatio`。
    // 这个除法放在页面里做（JS 自己知道自己的 DPR），比在 Dart 侧猜更稳。
    // 坐标**必须成对**。只给一个的后果以前是静默走别的分支
    // （模型写了 x 忘了 y，以为点了坐标、实际按选择器/文字找去了），
    // 现在直接说缺哪个字段。
    if ((atX == null) != (atY == null)) {
      return StepResult.fail(
        BrowserCode.badArg,
        'x / y 要**成对**给：现在只给了 ${atX != null ? 'x' : 'y'}，'
        '缺 ${atX != null ? 'y' : 'x'}。',
      );
    }
    if (atX != null && atY != null) {
      return _clickAt(atX, atY, trusted: trusted);
    }

    if (selector.trim().isEmpty && text.trim().isEmpty) {
      return const StepResult.fail(
        BrowserCode.badArg,
        'click 至少要给一样：selector（选择器）、text（可见文字），'
        '或者 x **和** y（截图上的坐标）。',
      );
    }

    if (trusted) {
      final bool ready =
          WebViewLoader.liveController != null && await nativeTouchReady();
      if (!ready) {
        return StepResult.fail(
          BrowserCode.blockedTrusted,
          '真实点击需要一个**开着的浏览器页**（headless 页没有窗口，'
          '收不到触摸）。两条路：\n'
          '· 用默认的 JS 点击（`trusted` 留空）—— 大多数站点够用；\n'
          '· 或者先 `ask` 把这一页交给用户打开，再用 `trusted: true`。',
        );
      }
      return _trustedTap(selector: selector, text: text, index: index);
    }

    final int dialogsBefore = dialogs.length;
    // evalBoot：缺注入脚本时先补上再重试（"看得见点不着"就是这么修的）
    final StepResult r = await evalBoot(
      'return JSON.stringify(window.__dsh ? window.__dsh.click('
      '${jsonEncode(selector)}, ${jsonEncode(text)}, $index) '
      ': {ok:false, code:"NO_BOOTSTRAP"})',
    );
    if (!r.ok) return r;

    final Map<String, dynamic> m = asMap(r.text);
    if (m['code'] == 'NO_BOOTSTRAP') {
      return const StepResult.fail(
        BrowserCode.unsupported,
        // 补注入已经试过了（见 evalBoot），所以走到这里是**真的注不进去**：
        // PDF 阅览器、`blob:` 之类的特殊页面。
        '这一页注入不进操作脚本（已经重试补充注入）：可能是 PDF 阅览器、'
        '`blob:` 之类的特殊页面。\n'
        '换路：用 `js` 自己写一段点击，或者 `ask` 把这一页交给用户。',
      );
    }
    if (m['ok'] != true) {
      final String code = (m['code'] ?? 'NO_ELEMENT').toString();
      if (code == 'NO_ELEMENT') {
        return StepResult.fail(
          BrowserCode.noElement,
          '没找到可点的元素'
          '${selector.isEmpty ? '（按文字 "$text" 找）' : '（选择器 $selector）'}。\n'
          '先 `dom` 看这一页上到底有什么（它会给出链接和按钮的清单）。',
        );
      }
      if (code == 'DISABLED') {
        return StepResult.fail(
          BrowserCode.noElement,
          '那个元素是**禁用**状态：${_describe(m['info'])}\n'
          '通常要先满足页面上的条件（登录、勾选同意、填完必填项）。',
        );
      }
      return StepResult.fail(
        BrowserCode.blockedTrusted,
        '脚本点击被页面拒绝了（${m['error'] ?? code}）：${_describe(m['info'])}\n'
        '这类站点会查 `event.isTrusted`，需要真实触摸：'
        '先 `ask` 把这一页交给用户打开，再 `click(trusted: true)`。',
      );
    }

    final bool jumped = (m['urlBefore'] ?? '') != (m['urlAfter'] ?? '');
    return StepResult.ok(
      '已点击：${_describe(m['info'])}\n'
      '${jumped ? '页面已跳转到：${m['urlAfter']}' : '页面地址没变（有些操作本来就不跳转：展开、勾选、弹出面板）'}\n'
      '${_dialogNote(dialogsBefore)}',
    );
  }

  /// 按**坐标**点击（截图上的像素坐标）。
  ///
  /// ## 两条路
  ///
  ///  · [trusted] = true → 让原生注入**真实触摸**：这条最像人手指，
  ///    也要用户那一页开着（headless 没窗口收不到触摸）；
  ///  · 否则 → 页内 JS：`elementFromPoint` 找到那一点上的元素，
  ///    往上爬到最近的可点祖先，再 `.click()`。
  ///
  /// 无论哪条路，**都把"点到了什么"带回来**（标签 / 文字 / 坐标）：
  /// 模型看着截图点的坐标，它需要知道那一下落在哪个东西上，
  /// 否则点错了也不知道错在哪、"下一次换哪儿"就更无从谈起。
  ///
  /// ⚠️ 坐标是**截图上的像素**（模型手里的那张 PNG 是设备像素），
  /// 而页面里要 CSS 像素 —— 差一个 `devicePixelRatio`。除法放在页面里做：
  /// 页面自己知道自己的 DPR，比在 Dart 侧猜更稳。
  Future<StepResult> _clickAt(
    double sx,
    double sy, {
    required bool trusted,
  }) async {
    final InAppWebViewController? c = await ensure();
    if (c == null) return StepResult.closed;

    // 页面几何：DPR 用来把截图像素换算成页面像素；滚动量用来把"视口坐标"
    // 换成**文档坐标** —— 记忆按文档坐标存，页面滚一下才不会全部错位。
    final ({double dpr, double scrollX, double scrollY}) geo =
        await _geometry();
    final double docX = sx / geo.dpr + geo.scrollX;
    final double docY = sy / geo.dpr + geo.scrollY;

    // ---- 第一级：这一片以前点过、并且记下了"怎么用非视觉的方式找到它" ----
    //
    // 用户要的"点按之后记住这条路，下次先走非视觉方案"就是这一步。
    // 省下的不只是一次截图：看图的模型**不用再看那张 PNG**，
    // 也就不会因为看图而看错一半的细节。
    final VisualMemo? memo = _memoOrNull();
    if (memo != null) {
      await _ensureMemo();
      final Map<String, dynamic>? past = memo.recall(_url, docX, docY);
      if (past != null) {
        final StepResult hit = await _clickRemembered(past, docX, docY);
        if (hit.ok) return hit;
        // 过期的记忆留着只会让人下次再白试一遍，删掉。
        memo.forget((past['k'] ?? '').toString());
        await memo.save();
      }
    }

    // ---- 第二级：真的按坐标点 ----
    if (trusted) {
      final bool ready =
          WebViewLoader.liveController != null && await nativeTouchReady();
      if (!ready) {
        return StepResult.fail(
          BrowserCode.blockedTrusted,
          '真实触摸需要一个**开着的浏览器页**（headless 页没有窗口，收不到触摸）。\n'
          '两条路：用默认的 JS 点击（`trusted` 留空），'
          '或者先 `ask` 把这一页交给用户打开。',
        );
      }
      // 真实触摸前先**读**一眼那一点上是什么：原生注入不带信息回执，
      // 不读的话，模型永远不知道那一下落在了哪个东西上（点错了也不知道）。
      final Map<String, dynamic> read = asMap(
        (await eval(kPointAtJs(sx, sy, click: false))).text,
      );
      final String? err = await tapAt(sx / geo.dpr, sy / geo.dpr);
      if (err != null) {
        return StepResult.fail(
          BrowserCode.blockedTrusted,
          '真实触摸失败：$err（坐标 ${sx.round()},${sy.round()} → '
          'CSS ${(sx / geo.dpr).round()},${(sy / geo.dpr).round()}）',
        );
      }
      final String remember = await _rememberPoint(memo, read, docX, docY);
      return StepResult.ok(
        '已按坐标注入真实触摸：截图坐标 ${sx.round()},${sy.round()}'
        '（页面坐标 ${(sx / geo.dpr).round()},${(sy / geo.dpr).round()}，'
        'DPR ${geo.dpr}）。\n'
        '${_hitReport(read)}$remember',
      );
    }

    final String js = kPointAtJs(sx, sy, click: true);

    final int dialogsBefore = dialogs.length;
    final StepResult r = await eval(js);
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);

    if (m['code'] == 'NO_POINT') {
      return StepResult.fail(
        BrowserCode.noElement,
        '**那个坐标上没有元素**：截图坐标 (${sx.round()},${sy.round()}) → '
        '页面坐标 (${(sx / geo.dpr).round()},${(sy / geo.dpr).round()})，'
        'DPR ${geo.dpr}；视口 ${mapOf(m['at'])['viewport']}。\n'
        '**事实是"没打中"**：截图是设备像素、页面是 CSS 像素，'
        '两者差一个 devicePixelRatio。先 `screenshot` 重新取一张图，'
        '用 `hit_test(x:, y:)` 试几次（它不点、只回报命中什么），'
        '别连续重试同一个坐标。',
      );
    }
    if (m['ok'] != true) {
      return StepResult.fail(
        BrowserCode.noElement,
        '坐标点击没成功：${m['clickError'] ?? m['error'] ?? m['code']}',
      );
    }

    final String remember = await _rememberPoint(memo, m, docX, docY);
    final bool jumped = (m['urlBefore'] ?? '') != (m['urlAfter'] ?? '');
    return StepResult.ok(
      '已按坐标点击（截图 (${sx.round()},${sy.round()}) → '
      '页面 (${(sx / geo.dpr).round()},${(sy / geo.dpr).round()})）：\n'
      '${_hitReport(m)}\n'
      '${jumped ? '页面已跳转到：${m['urlAfter']}' : '页面地址没变'}\n'
      '${m['domChanged'] == true ? '（页面内容有变化）' : '（页面内容也没变 —— 如果这一步本该有反应，'
                '说明点到的不是那个控件：用 `hit_test` 确认它到底是什么）'}\n'
      '${_dialogNote(dialogsBefore)}$remember',
    );
  }

  /// 页面**实际收到**了多少次 click / keydown。
  ///
  /// 计数由注入脚本在 document 上装的 capture 监听器维护 —— 它量的是
  /// "事件有没有真的到这一页上来"，而不是"我们那段 JS 有没有返回成功"。
  /// 这两件事在 headless 页上**不总是一回事**：注入的输入事件会被某些页面
  /// 静默丢弃，而 `el.click()` 依旧返回 undefined（我们这边就当成功了）。
  ///
  /// `has=false` 表示这一页没有计数器（没注入进去、或者是 PDF 之类的
  /// 特殊页面）—— 那种情况**不擅自下判断**，动作照常算成功，
  /// 只在结果里补一句"没能回读验证"。
  Future<({bool has, int clicks, int keys})> _pageEvents() async {
    final StepResult r = await eval(
      'return JSON.stringify({'
      'has: !!window.__dshSeen, '
      'c: (window.__dshSeen && window.__dshSeen.clicks) || 0, '
      'k: (window.__dshSeen && window.__dshSeen.keys) || 0})',
    );
    final Map<String, dynamic> m = asMap(r.text);
    return (
      has: m['has'] == true,
      clicks: (m['c'] as num?)?.toInt() ?? 0,
      keys: (m['k'] as num?)?.toInt() ?? 0,
    );
  }

  /// 动作之后**回读**：页面到底有没有反应？
  ///
  /// 判定顺序（每一步都是事实，不猜）：
  ///  1. 动作本身失败 → 原样返回（它已经带了短代码）；
  ///  2. **地址变了** → 算成功（跳转本身就是效果；新文档的计数器会归零，
  ///     拿它比没意义）；
  ///  3. 有计数器、而且计数涨了 → 成功；
  ///  4. 有计数器、计数**没涨** → [BrowserCode.noEffect]，把"页面没收到"
  ///     这件事说清楚，并给出换路的办法；
  ///  5. 没有计数器 → 不判断（原样成功 + 一句说明）。
  ///
  /// 为什么值得多花一次 eval：以前"点完没反应"和"点到了"在结果里长得
  /// 一模一样，agent 会带着假前提继续往下走 —— 那比直接报错糟得多。
  Future<StepResult> _verifyEffect(
    StepResult r, {
    required bool click,
    required String what,
    required ({bool has, int clicks, int keys}) seen0,
    required String url0,
  }) async {
    if (!r.ok) return r;
    // 给页面一点时间把事件处理完（跳转、展开动画、计数器自增）
    await Future<void>.delayed(const Duration(milliseconds: 140));
    final String url1 = _url;
    if (url1 != url0) return r;

    final ({bool has, int clicks, int keys}) seen1 = await _pageEvents();
    if (!seen0.has || !seen1.has) {
      return StepResult.ok(
        '${r.text}\n（这一页没有注入计数器，**这次没能回读验证** —— '
        '如果看起来没反应，用 `js` 直接调或者 `ask` 交给用户。）',
      );
    }
    final int before = click ? seen0.clicks : seen0.keys;
    final int after = click ? seen1.clicks : seen1.keys;
    if (after > before) return r;

    return StepResult.fail(
      BrowserCode.noEffect,
      '页面**没有收到这次$what**（动作执行了，但页面上的事件计数没动：'
      '$before → $after；地址也没变）。\n'
      '这说明注入的输入事件被这一页丢掉了 —— 常见于 headless 页'
      '（没有窗口，收不到合成触摸/鼠标）。\n'
      '换路：\n'
      '· `js` 里直接调元素的 `click()`（这条在多数站点有效）；\n'
      '· 要真的触摸：先 `ask` 把这一页交给用户打开，再 `trusted: true`。',
    );
  }

  /// 页面的几何：设备像素比 + 滚动位置。
  ///
  /// 点按记忆存的是**文档坐标**（视口坐标 + 滚动量）。用视口坐标存的话，
  /// 页面往下滚一屏，所有记下来的位置就全部错位 —— 而"滚下去再点"
  /// 恰恰是最常见的用法。
  Future<({double dpr, double scrollX, double scrollY})> _geometry() async {
    final StepResult r = await eval(
      'return JSON.stringify({dpr: window.devicePixelRatio || 1, '
      'sx: window.scrollX || 0, sy: window.scrollY || 0})',
    );
    final Map<String, dynamic> m = asMap(r.text);
    double pick(String k, double fallback) {
      final num? v = m[k] as num?;
      return (v == null || v <= 0) ? fallback : v.toDouble();
    }

    return (
      dpr: pick('dpr', 1),
      scrollX: (m['sx'] as num? ?? 0).toDouble(),
      scrollY: (m['sy'] as num? ?? 0).toDouble(),
    );
  }

  bool _memoLoaded = false;

  Future<void> _ensureMemo() async {
    if (_memoLoaded) return;
    _memoLoaded = true;
    await _memoOrNull()?.load();
  }

  /// 把"这一下点中了什么、怎么用非视觉的方式找到它"记下来，并回一句给模型。
  ///
  /// 返回的是**要拼进结果里的那句话**（可能为空 = 没记下）。
  /// 一定要说出来：模型据此知道"下一次这一片不用再看截图了"，
  /// 而且是它唯一能看见"这套东西在学"的地方。
  Future<String> _rememberPoint(
    VisualMemo? memo,
    Map<String, dynamic> payload,
    double docX,
    double docY,
  ) async {
    if (memo == null) return '';
    final Map<String, dynamic> mm = mapOf(payload['memo']);
    final String sel = (mm['sel'] ?? '').toString().trim();
    final String txt = (mm['txt'] ?? '').toString().trim();
    if (sel.isEmpty && txt.isEmpty) return '';
    final Map<String, dynamic> at = mapOf(mm['at']);
    memo.note(
      _url,
      docX,
      docY,
      selector: sel,
      text: txt,
      label: (mm['label'] ?? '').toString(),
      atX: numOf(at['x']) ?? 0,
      atY: numOf(at['y']) ?? 0,
    );
    await memo.save();
    return '\n· 记下了这条路：这一片下次先用'
        '${sel.isNotEmpty ? '选择器 `$sel`' : '文字「$txt」'}点，不用再看截图。';
  }

  /// 用**记忆**点（非视觉方案）。找不到 / 对不上就返回失败，交给坐标那条路。
  ///
  /// 两道关都要过：**还找得到**（选择器唯一命中，或者那段文字唯一命中）
  /// 而且**还在原来那一带**（元素中心相对记下时的位置没跑远）。
  /// 第二道关是关键 —— 页面重排之后同一个坐标可能已经变成别的东西，
  /// 照着旧记忆点下去就是**点错**，而点错比点不到更糟：
  /// 点不到模型会换路，点错了它以为已经成了。
  Future<StepResult> _clickRemembered(
    Map<String, dynamic> hit,
    double docX,
    double docY,
  ) async {
    final VisualMemo? memo = _memoOrNull();
    final Map<String, dynamic> at = mapOf(hit['at']);
    final double ax = numOf(at['x']) ?? 0;
    final double ay = numOf(at['y']) ?? 0;
    final bool hasAt = ax != 0 || ay != 0;
    final String js = kRecallClickJs(
      selector: (hit['sel'] ?? '').toString(),
      text: (hit['txt'] ?? '').toString(),
      atX: ax,
      atY: ay,
      hasAt: hasAt,
      tolerance: (memo?.drift ?? 80).round(),
    );

    final int dialogsBefore = dialogs.length;
    final StepResult r = await eval(js);
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['ok'] != true) {
      final String why = (m['why'] ?? '').toString();
      final String code = (m['code'] ?? '').toString();
      final String reason = code == 'MEMO_MOVED'
          ? '记下的位置和它现在的位置差了 ${m['dist']} 像素（页面重排过了）'
          : (why.isEmpty ? '已经找不到它了' : why);
      return StepResult.fail(
        BrowserCode.noElement,
        'MEMO：这一片上次点的地方变了（$reason），继续按坐标点。',
      );
    }

    // 点成了：把这条记忆的命中次数刷一下（用**同一次点击的坐标**，
    // 这样刷的是同一条记录；用元素中心去刷会算出另一个格子，
    // 结果是"每次命中都新开一条记录"，命中次数永远停在 1、旧的还赖着不走）。
    if (memo != null) {
      memo.note(
        _url,
        docX,
        docY,
        selector: (hit['sel'] ?? '').toString(),
        text: (hit['txt'] ?? '').toString(),
        label: (hit['label'] ?? '').toString(),
        atX: ax,
        atY: ay,
      );
    }
    final bool jumped = (m['urlBefore'] ?? '') != (m['urlAfter'] ?? '');
    final int hits = (hit['hits'] as int? ?? 1);
    return StepResult.ok(
      '已点击（**没用坐标**：这一片上次点过 ${hits > 1 ? '$hits 次' : '一次'}，'
      '记下的路是${m['via']}）\n'
      '· 点了：${_describe(m['info'])}\n'
      '${jumped ? '页面已跳转到：${m['urlAfter']}' : '页面地址没变'}\n'
      '${_dialogNote(dialogsBefore)}',
    );
  }

  /// 页面的几何元数据（截图与坐标换算共用）。
  ///
  /// ## 为什么必须报出来
  ///
  /// 视觉方案有一个**隐式契约**：`screenshot` 给的图上坐标，和
  /// `click(x:, y:)` 收的坐标，是**同一个坐标空间**。以前这个契约
  /// 全靠猜 —— 图里没有 DPR、没有视口尺寸，模型没法自证"我读的这个
  /// 像素位置"和"工具会把它换算到哪"是一回事。一旦读图那边对图
  /// 做过分块或缩放，偏差是**系统性**的，而且现场完全看不出来。
  ///
  /// 交出去之后就能自检：图的像素宽 ≈ CSS 视口宽 × dpr，
  /// 而且同一页连续两次截图这几个数应该稳定不变。
  Future<
    ({
      double dpr,
      double vw,
      double vh,
      double pw,
      double ph,
      double sx,
      double sy,
    })
  >
  pageGeometry({bool live = false}) async {
    const String js =
        'return JSON.stringify({'
        'dpr: window.devicePixelRatio || 1, '
        'vw: innerWidth, vh: innerHeight, '
        'pw: document.documentElement.scrollWidth, '
        'ph: document.documentElement.scrollHeight, '
        'sx: window.scrollX || 0, sy: window.scrollY || 0})';
    String raw = '';
    if (live) {
      raw = await WebViewLoader.evalLive(js) ?? '';
    } else {
      final StepResult r = await eval(js);
      raw = r.ok ? r.text : '';
    }
    final Map<String, dynamic> m = asMap(raw);
    double pick(String k, double fallback) => numOf(m[k]) ?? fallback;
    final double dpr = pick('dpr', 1) <= 0 ? 1 : pick('dpr', 1);
    return (
      dpr: dpr,
      vw: pick('vw', 0),
      vh: pick('vh', 0),
      pw: pick('pw', 0),
      ph: pick('ph', 0),
      sx: pick('sx', 0),
      sy: pick('sy', 0),
    );
  }

  /// 截 **agent 自己那一页**（跨动作保活的那张）。
  ///
  /// 为什么需要它：截图以前只有两条路 —— 用户的浏览器页，或者"新开一个
  /// headless 页去那个地址"。后者对"登录过、填过表单"的页面等于**换了个人**，
  /// 截出来的东西根本不是 agent 一路操作过来的现场。
  Future<Uint8List?> captureSelf() async {
    final InAppWebViewController? c = await ensure();
    if (c == null) return null;
    try {
      await WebViewLoader.waitSettled(c);
      return await c.takeScreenshot();
    } catch (_) {
      return null;
    }
  }

  /// 铺 / 撤一层**坐标网格**（截图自校准用）。
  ///
  /// 网格上写的数字是**截图上的像素**（= CSS 像素 × dpr），和
  /// `click(x:, y:)` 收的坐标是同一套单位。有了它，看图就能直接读坐标，
  /// 不用"目测一个位置然后指望它准"。
  ///
  /// 只在截图那一刻铺上、截完立刻撤掉：留一层盖在页面上，后面每次
  /// 截图都会带着它（`pointer-events:none` 挡得住点击，挡不住误判 ——
  /// 模型会以为页面上真有那些线，拿它去算坐标就全歪了）。
  Future<bool> setGrid(bool on, {bool live = false, double step = 100}) async {
    final String js = on
        ? 'return (function () {\n'
              '  var old = document.getElementById("__dsh_grid__");\n'
              '  if (old) old.remove();\n'
              '  var dpr = window.devicePixelRatio || 1;\n'
              '  var css = $step / dpr;\n'
              '  var d = document.createElement("div");\n'
              '  d.id = "__dsh_grid__";\n'
              '  d.style.cssText = "position:fixed;left:0;top:0;right:0;bottom:0;"'
              ' + "z-index:2147483647;pointer-events:none;";\n'
              '  d.style.backgroundImage = '
              '"repeating-linear-gradient(to right,rgba(255,0,0,.45) 0 1px,'
              'transparent 1px " + css + "px),'
              'repeating-linear-gradient(to bottom,rgba(255,0,0,.45) 0 1px,'
              'transparent 1px " + css + "px)";\n'
              '  function tag(t, x, y) {\n'
              '    var s = document.createElement("span");\n'
              '    s.textContent = t;\n'
              '    s.style.cssText = "position:fixed;left:" + x + "px;top:" + y'
              ' + "px;font:10px monospace;color:#c00;'
              'background:rgba(255,255,255,.75);padding:0 1px;";\n'
              '    d.appendChild(s);\n'
              '  }\n'
              '  for (var x = css; x < window.innerWidth; x += css) {\n'
              '    tag(String(Math.round(x * dpr)), x + 1, 0);\n'
              '  }\n'
              '  for (var y = css; y < window.innerHeight; y += css) {\n'
              '    tag(String(Math.round(y * dpr)), 1, y + 1);\n'
              '  }\n'
              '  document.documentElement.appendChild(d);\n'
              '  return "on";\n'
              '})()'
        : 'return (function () {\n'
              '  var d = document.getElementById("__dsh_grid__");\n'
              '  if (d) d.remove();\n'
              '  return "off";\n'
              '})()';
    if (live) {
      final String? r = await WebViewLoader.evalLive(js);
      return (r ?? '').contains('on');
    }
    final InAppWebViewController? c = await ensure();
    if (c == null) return false;
    final StepResult r = await eval(js);
    return r.ok && r.text.contains('on');
  }

  /// 只回报"这个坐标上是什么"，**不点**。
  ///
  /// ## 为什么值得单独给一个动作
  ///
  /// "看图 → 定位 → 点"这个闭环里，最贵的是**出错的那一步**：
  /// 坐标算偏了、模型把二维码图标看成"百度一下"、页面上真东西被一层
  /// 装饰盖着 —— 这些在点击那一刻才发现，而点击**是有副作用的**
  /// （跳走、提交、删东西）。
  ///
  /// 有了这个，模型可以先花**一次没有副作用**的调用问清楚
  /// "我算的这个坐标到底落在什么上面"，再决定点不点。
  /// 成本从"点错 + 收拾"降到"读一次"。
  ///
  /// 回报里一定带上**能不能点**：命中一个装饰性 `div` 时，
  /// 直接说出来比让模型自己猜强 —— 它猜的成本是再来一轮截图。
  Future<StepResult> hitTest({double x = -1, double y = -1}) async {
    if (x < 0 || y < 0) {
      return const StepResult.fail(
        BrowserCode.badArg,
        'hit_test 要给 x 和 y（**成对**给，单位是截图上的像素，和 click 一样）。',
      );
    }
    final InAppWebViewController? c = await ensure();
    if (c == null) return StepResult.closed;

    final ({double dpr, double scrollX, double scrollY}) geo =
        await _geometry();
    final StepResult r = await eval(kPointAtJs(x, y, click: false));
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    final Map<String, dynamic> at = mapOf(m['at']);
    final String where =
        '截图 (${x.round()},${y.round()}) → '
        '页面 (${(x / geo.dpr).round()},${(y / geo.dpr).round()})，'
        'DPR ${geo.dpr}';

    if (m['code'] == 'NO_POINT') {
      return StepResult.fail(
        BrowserCode.noElement,
        '**那个坐标上没有元素**（$where）。\n'
        '视口 ${mapOf(at['viewport'])['w']}×${mapOf(at['viewport'])['h']}，'
        '页面 ${mapOf(at['page'])['w']}×${mapOf(at['page'])['h']}。\n'
        '要么坐标落到了空白处，要么页面滚过了 —— 重新 `screenshot` 再算。',
      );
    }
    if (m['ok'] != true) {
      return StepResult.fail(
        BrowserCode.unsupported,
        '这次命中测试没做成：${m['error'] ?? m['code']}',
      );
    }

    final Map<String, dynamic> h = mapOf(m['hit']);
    final Map<String, dynamic> top = mapOf(h['top']);
    final bool same = h['sameTarget'] == true;
    final StringBuffer sb = StringBuffer();
    sb.writeln('命中（$where）：');
    sb.writeln(
      '· 最上面：${_describe(top['info'])}'
      '${rectText(top['rect']).isEmpty ? '' : ' rect ${rectText(top['rect'])}'}'
      '${top['clickable'] == true ? '' : ' ← **不可点**'}',
    );
    if (!same) {
      sb.writeln(
        '· 穿透之后能点的是：${_describe(h)}'
        '${rectText(h['rect']).isEmpty ? '' : ' rect ${rectText(h['rect'])}'}'
        '（选择器 `${h['sel']}`）',
      );
    } else if (top['clickable'] != true) {
      sb.writeln(
        '· 那一点上**没有可点的东西** —— 这个坐标不该点，'
        '要么换个位置，要么用 `dom` 找选择器。',
      );
    }
    sb.writeln('（这只是**读**，没有点下去。要真点：`click(x:…, y:…)`。）');
    return StepResult.ok(sb.toString());
  }

  /// 按**坐标**滑一下 —— 视觉方案里的"滑动"。
  ///
  /// `click` 管的是"看到就能点"，但很多界面**只能靠滑**：地图、轮播、
  /// 滑块、抽屉、横向列表。它们在 DOM 里常常就是一个 `div`，
  /// 选择器无从下手，唯一的路是"从 A 划到 B"，让页面自己解释这串触摸。
  ///
  /// 坐标同样是**截图上的像素**（和 `click` 的 x/y 一致），页面侧按 DPR 换算。
  ///
  /// ## 两条路
  ///
  ///  · 用户的浏览器页开着 → 原生注入**真实触摸**：按下、逐帧移动、抬起。
  ///    页面自己的手势逻辑认得它，拖滑块、拖地图这种才会真的动。
  ///  · 没开着 → 页内 JS 兜底：把起点下面最近的那个**可滚动祖先**滚一段。
  ///    **结果里会明说这一下不是真实触摸** —— 含糊其辞会让模型以为
  ///    拖动类操作在后台也做得了，然后对着一句"其实只是滚了一下"的结果
  ///    继续往下推。
  Future<StepResult> swipe({
    double fromX = -1,
    double fromY = -1,
    double toX = -1,
    double toY = -1,
    int ms = 350,
    bool trusted = false,
  }) async {
    if (fromX < 0 || fromY < 0 || toX < 0 || toY < 0) {
      return const StepResult.fail(
        BrowserCode.badArg,
        'swipe 要给四个坐标：from_x / from_y（起点）、to_x / to_y（终点），'
        '单位是**截图上的像素**（和 click 的 x/y 一样）。',
      );
    }
    final InAppWebViewController? c = await ensure();
    if (c == null) return StepResult.closed;
    final ({double dpr, double scrollX, double scrollY}) geo =
        await _geometry();
    final double fx = fromX / geo.dpr;
    final double fy = fromY / geo.dpr;
    final double tx = toX / geo.dpr;
    final double ty = toY / geo.dpr;
    final int dur = ms.clamp(80, 3000);
    // 至少 5 个中间点（用户明确要求的）：只有起点和终点的"拖动"，
    // 绝大多数手势库会当成"瞬移"直接忽略。
    final int steps = dur < 150 ? 5 : (dur / 60).round().clamp(5, 40);

    if (trusted) {
      if (WebViewLoader.liveController == null || !await nativeTouchReady()) {
        return StepResult.fail(
          BrowserCode.blockedTrusted,
          'BLOCKED_TRUSTED / NO_FOREGROUND_BROWSER_WINDOW —— '
          '真实触摸需要**用户的浏览器页开着**，现在没有前台窗口。\n'
          '· 只是想把页面往下翻：用 `scroll`（不依赖触摸注入）；\n'
          '· 确实要真手指（站点查 `event.isTrusted`）：先 `ask` 把这一页'
          '交给用户打开，再 `swipe(trusted: true)`。',
        );
      }
      // 用户那一页必须**就是这一页**：坐标是给 agent 这页算的，
      // 手指却落在另一页上，等于点了个随机的坐标。
      final String live = WebViewLoader.liveUrl ?? '';
      if (live.isNotEmpty && _url.isNotEmpty && !samePageUrl(live, _url)) {
        return StepResult.fail(
          BrowserCode.blockedTrusted,
          '用户那一页现在停在 $live，而这次拖动是给 $_url 的 —— '
          '手指会落在另一页上。先让浏览器页打开同一页（`ask`），再试。',
        );
      }
      final ({bool ok, String raw}) s0 = await _liveSnapshot();
      final String? err = await swipeNative(
        fromX: fx,
        fromY: fy,
        toX: tx,
        toY: ty,
        ms: dur,
      );
      if (err != null && err.isNotEmpty) {
        return StepResult.fail(
          BrowserCode.blockedTrusted,
          '真实滑动失败：$err（截图 (${fromX.round()},${fromY.round()}) → '
          '(${toX.round()},${toY.round()})）',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final ({bool ok, String raw}) s1 = await _liveSnapshot();
      final bool changed = s0.ok && s1.ok && s0.raw != s1.raw;
      if (!changed) {
        return StepResult.fail(
          BrowserCode.noEffect,
          'NO_EFFECT / PAGE_DID_NOT_RECEIVE_INPUT —— 真实触摸注入了，'
          '但用户那一页的状态没有变化（滚动位置、元素矩​形、transform '
          '全都没动）。\n'
          '· 想把页面翻一页：用 `scroll`；\n'
          '· 想拖控件：确认坐标落在那个控件上（`hit_test`），'
          '再试一次。',
        );
      }
      return StepResult.ok(
        '已注入真实触摸拖动（**用户的浏览器页**）：'
        '截图 (${fromX.round()},${fromY.round()}) → '
        '(${toX.round()},${toY.round()})，${dur}ms / $steps 步。\n'
        '· 页面坐标 (${fx.round()},${fy.round()}) → '
        '(${tx.round()},${ty.round()})，DPR ${geo.dpr}\n'
        '· 回读：页面状态**有变化**（changed: true）',
      );
    }

    // ---- 默认：页内合成 pointer + touch 拖动 ----
    final StepResult r = await eval(kSwipeDragJs(fx, fy, tx, ty, dur, steps));
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['code'] == 'NO_POINT') {
      return StepResult.fail(
        BrowserCode.noElement,
        '起点 (${fx.round()},${fy.round()}) 上没有元素'
        '（截图上是 (${fromX.round()},${fromY.round()})）。'
        '先 `screenshot` 确认要滑的那块在哪。',
      );
    }
    if (m['ok'] != true) {
      return StepResult.fail(
        BrowserCode.unsupported,
        '拖动没执行完：${m['error'] ?? m['code']}',
      );
    }

    final bool changed = m['changed'] == true;
    final String changedBy = (m['changedBy'] ?? '').toString();
    final Map<String, dynamic> before = mapOf(m['before']);
    final Map<String, dynamic> after = mapOf(m['after']);
    final int muts = (m['mutations'] as num?)?.toInt() ?? 0;
    final String where =
        '截图 (${fromX.round()},${fromY.round()}) → '
        '(${toX.round()},${toY.round()}) · 页面 (${fx.round()},${fy.round()}) → '
        '(${tx.round()},${ty.round()}) · DPR ${geo.dpr} · '
        '${m['steps'] ?? steps} 步 / ${dur}ms';

    if (changed) {
      return StepResult.ok(
        '已拖动（页内 pointer/touch 序列）：$where\n'
        '· 变了的是：$changedBy\n'
        '· 回读：滚动 ${before['sx']},${before['sy']} → '
        '${after['sx']},${after['sy']}；DOM 变化 $muts 处\n'
        '（这次**不是**真实触摸：合成事件在当前页里派发。'
        '只有站点查 `event.isTrusted` 时才需要 `ask` + `trusted: true`。）',
      );
    }
    return StepResult.fail(
      BrowserCode.noEffect,
      'NO_EFFECT / TARGET_DID_NOT_RESPOND —— 拖动序列发出去了'
      '（pointerdown → ${m['steps'] ?? steps} 次 pointermove → pointerup，'
      'touch 那套同步一份），但页面上**没有任何可验证的变化**：\n'
      '· 滚动 ${before['sx']},${before['sy']} → ${after['sx']},${after['sy']}\n'
      '· 目标元素的矩形 / value / transform / scrollLeft 都没动，'
      'DOM 变化 $muts 处\n'
      '$where\n'
      '两种可能：\n'
      '· 这个坐标上**没有可拖的东西**（想翻页请用 `scroll` / `js`）；\n'
      '· 那个控件只认**真实触摸**（查 `event.isTrusted`）—— '
      '先 `ask` 把这一页交给用户，再 `swipe(trusted: true)`。',
    );
  }

  /// 用户那一页的"状态指纹"（`swipe(trusted: true)` 回读用）。
  ///
  /// 只看**四样便宜又敏感**的东西：滚动位置、body 的 innerHTML 长度、
  /// 前 40 个带 inline transform 的元素的 transform 串、以及
  /// `activeElement` 的标签 —— 地图/滑块/轮播动起来时，至少会撞上一样。
  Future<({bool ok, String raw})> _liveSnapshot() async {
    final String? raw = await WebViewLoader.evalLive(
      'return JSON.stringify({'
      'sx: Math.round(window.scrollX), sy: Math.round(window.scrollY), '
      'h: document.body ? document.body.innerHTML.length : 0, '
      't: (function () {'
      '  var a = document.querySelectorAll("[style*=transform]");'
      '  var s = ""; for (var i = 0; i < a.length && i < 40; i++) {'
      '    s += a[i].style.transform; } return s; })(), '
      'a: document.activeElement ? document.activeElement.tagName : ""})',
    );
    return (ok: raw != null && raw.isNotEmpty, raw: raw ?? '');
  }

  /// 真实触摸那一路：先在**用户的页面**上量出元素中心，再让原生注入。
  Future<StepResult> _trustedTap({
    required String selector,
    required String text,
    required int index,
  }) async {
    final String list = selector.isEmpty
        ? 'Array.prototype.slice.call(document.querySelectorAll('
              '"a,button,input,[role=button]"))'
        : 'Array.prototype.slice.call(document.querySelectorAll('
              '${jsonEncode(selector)}))';
    final String filter = text.isEmpty
        ? ''
        : 'var t = ${jsonEncode(text)}.toLowerCase();'
              'list = list.filter(function (el) {'
              ' var s = String(el.innerText || el.value || "");'
              ' return s.toLowerCase().indexOf(t) >= 0; });';

    final String? raw = await WebViewLoader.evalLive(
      'return JSON.stringify((function () {'
      ' var list = $list;'
      ' $filter'
      ' list = list.filter(function (el) {'
      ' var r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; });'
      ' if (!list.length) return {found: false};'
      ' var el = list[${index < 0 ? 0 : index}];'
      ' el.scrollIntoView({block: "center"});'
      ' var r = el.getBoundingClientRect();'
      ' return {found: true, x: r.left + r.width / 2, y: r.top + r.height / 2,'
      ' tag: el.tagName ? el.tagName.toLowerCase() : "",'
      ' text: String(el.innerText || el.value || "").slice(0, 60)};'
      '})())',
    );
    final Map<String, dynamic> m = asMap(raw ?? '');
    if (m['found'] != true) {
      return StepResult.fail(
        BrowserCode.noElement,
        '用户的浏览器页上没找到那个元素'
        '${selector.isEmpty ? '' : '（选择器 $selector）'}。\n'
        '注意：真实触摸只作用于**用户正开着的那一页**，'
        '和 agent 自己那一页可能不是同一个地址。',
      );
    }
    final String? err = await tapAt(
      (m['x'] as num?)?.toDouble() ?? 0,
      (m['y'] as num?)?.toDouble() ?? 0,
    );
    if (err != null && err.isNotEmpty) {
      return StepResult.fail(
        BrowserCode.blockedTrusted,
        '注入触摸失败：$err（那一页可能已经关了）',
      );
    }
    return StepResult.ok(
      '已注入真实触摸：${m['tag']}「${m['text']}」'
      '（坐标 ${(m['x'] as num?)?.round()}, ${(m['y'] as num?)?.round()}）\n'
      '真实触摸**没有返回值**：页面变没变得看下一步 —— '
      '用 `dom` 或 `wait_for` 确认。',
    );
  }

  /// 往输入框里写字。
  ///
  /// 关键是**发事件**：只把 `value` 改掉的话，页面的校验、按钮的启用状态、
  /// 框架的受控组件全都不会更新 —— 表现就是"填了但提交按钮还是灰的"。
  /// 注入脚本同时发 `input` 和 `change`，并且对 React 那类框架走原型上的
  /// 原生 setter（直接赋值会被它内部状态盖回去）。
  Future<StepResult> typeText({
    required String selector,
    required String text,
    bool submit = false,
  }) async {
    if (selector.trim().isEmpty) {
      return const StepResult.fail(BrowserCode.badArg, 'type 要给 selector。');
    }
    final int dialogsBefore = dialogs.length;
    final StepResult r = await evalBoot(
      'return JSON.stringify(window.__dsh ? window.__dsh.type('
      '${jsonEncode(selector)}, ${jsonEncode(text)}, $submit) '
      ': {ok:false, code:"NO_BOOTSTRAP"})',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['ok'] != true) {
      return StepResult.fail(
        BrowserCode.noElement,
        '没找到输入框'
        '${selector.isEmpty ? '' : '（选择器 $selector）'}'
        '，或者写不进去。先 `dom` 看这一页的输入框清单'
        '（它会给每个输入框的 name / id / 占位文字）。\n'
        '${_dialogNote(dialogsBefore)}',
      );
    }
    return StepResult.ok(
      '已填写：${_describe(m['info'])}\n'
      '当前值：${m['value']}'
      '${submit ? '\n（已提交：走表单 submit / 回车）' : ''}\n'
      '${_dialogNote(dialogsBefore)}',
    );
  }

  /// 选下拉框的一项（按 value 或显示文字）。
  Future<StepResult> selectOption({
    required String selector,
    String value = '',
    String label = '',
    int? index,
  }) async {
    final StepResult r = await evalBoot(
      'return JSON.stringify(window.__dsh ? window.__dsh.select('
      '${jsonEncode(selector)}, ${jsonEncode(value)}, ${jsonEncode(label)}, '
      '${index?.toString() ?? 'null'}) : {ok:false, code:"NO_BOOTSTRAP"})',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['ok'] != true) {
      final List<dynamic> opts =
          (m['options'] as List<dynamic>?) ?? <dynamic>[];
      return StepResult.fail(
        BrowserCode.noElement,
        '选不中：${m['code']}\n'
        '${opts.isEmpty ? '先 `dom` 看这一页有没有 select。' : '可选值：${opts.map((dynamic o) => '${(o as Map)['value']}（${o['text']}）').join('、')}'}',
      );
    }
    return StepResult.ok('已选择：${m['text']}（value=${m['value']}）');
  }

  /// 按一个键。默认派发 JS 键盘事件；[trusted] 时走原生注入。
  Future<StepResult> pressKey({
    required String key,
    bool trusted = false,
  }) async {
    // 和 click 一样：**成功与否由回读决定**。
    // `press Enter` 以前会回"已注入真实按键"，而页面上的 activeElement、
    // 地址、表单全都没动 —— 那是同一个"静默假成功"。
    final ({bool has, int clicks, int keys}) seen0 = await _pageEvents();
    final String url0 = _url;
    final StepResult r = await _pressKeyInner(key: key, trusted: trusted);
    return _verifyEffect(r, click: false, what: '按键', seen0: seen0, url0: url0);
  }

  Future<StepResult> _pressKeyInner({
    required String key,
    bool trusted = false,
  }) async {
    final String k = key.trim();
    if (k.isEmpty) {
      return const StepResult.fail(BrowserCode.badArg, 'press 要给 key。');
    }
    if (trusted) {
      if (!await nativeTouchReady()) {
        return const StepResult.fail(
          BrowserCode.blockedTrusted,
          '真实按键需要用户的浏览器页开着。默认方式（不带 trusted）'
          '一般就够。',
        );
      }
      final String? err = await pressKeyNative(k);
      if (err != null && err.isNotEmpty) {
        return StepResult.fail(BrowserCode.blockedTrusted, '注入按键失败：$err');
      }
      return StepResult.ok('已注入真实按键：$k');
    }
    final StepResult r = await evalBoot(
      'return JSON.stringify(window.__dsh ? window.__dsh.press('
      '${jsonEncode(k)}) : {ok:false, code:"NO_BOOTSTRAP"})',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['ok'] != true) {
      return const StepResult.fail(
        BrowserCode.unsupported,
        '按键事件没发出去（页面可能没有注入脚本）。可以先 `click` 一下'
        '要输入的框，再用 `type(submit: true)` 提交。',
      );
    }
    return StepResult.ok('已按键：$k（焦点在 ${_describe(m['active'])}）');
  }

  /// 滚动。懒加载列表要"滚到底再读"，不然只看到头几条。
  Future<StepResult> scroll({
    String to = 'down',
    int times = 1,
    bool trusted = false,
  }) async {
    final String dir = to.trim().toLowerCase();
    final int n = times < 1 ? 1 : times;

    if (trusted) {
      if (!await nativeTouchReady()) {
        return const StepResult.fail(
          BrowserCode.blockedTrusted,
          '真实滑动需要用户的浏览器页开着；先试默认的 `scroll`。',
        );
      }
      final double h =
          double.tryParse(
            (await eval('return window.innerHeight || 0')).text.trim(),
          ) ??
          0;
      if (h <= 0) {
        return const StepResult.fail(
          BrowserCode.unsupported,
          '读不到视口高度，没法算滑动坐标。',
        );
      }
      for (int i = 0; i < n; i++) {
        final double cx = await _innerWidth() / 2;
        final String? err = await swipeNative(
          fromX: cx,
          fromY: h * 0.75,
          toX: cx,
          toY: h * 0.2,
          ms: 350,
        );
        if (err != null && err.isNotEmpty) {
          return StepResult.fail(BrowserCode.blockedTrusted, '真实滑动失败：$err');
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      return StepResult.ok('已注入 $n 次真实滑动。');
    }

    final int dialogsBefore = dialogs.length;
    final StepResult r = await evalBoot(
      'return JSON.stringify(window.__dsh ? window.__dsh.scroll('
      '${jsonEncode(dir)}, $n) : {ok:false, code:"NO_BOOTSTRAP"})',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['ok'] != true) {
      return const StepResult.fail(
        BrowserCode.unsupported,
        '这一页滚不动（可能没有注入脚本，或者页面自己管滚动）。',
      );
    }
    final num after = (m['after'] as num?) ?? 0;
    final num height = (m['height'] as num?) ?? 0;
    final num before = (m['before'] as num?) ?? 0;
    // **位置没变就不叫成功**。
    //
    // 这条是实战换来的：以前这里照样回"已滚动 0 → 1913"，而页面上的
    // scrollY 采样一直是 0 —— 工具报的数和页面的事实对不上，模型却
    // 当成"滚到底了"，接着去读一个根本没滚动过的页面。
    // 现在把"没动"当成失败（带 NO_EFFECT），并说清两种可能。
    if (after == before) {
      return StepResult.fail(
        BrowserCode.noEffect,
        '位置**没变**：$before → $after（页面总高 $height）。\n'
        '两种可能，都指向"这一下没生效"：\n'
        '· 这一页本来就${dir == 'up' || dir == 'top' ? '到顶了' : '到底了'}'
        '（那是页面的事实，不是工具的问题）；\n'
        '· 滚动条在某个**容器**里，`window.scrollBy` 推不动它 —— '
        '用 `swipe`（在容器上滑）或者 `js` 直接滚那个元素。',
      );
    }
    return StepResult.ok(
      '已滚动：$before → $after（页面总高 $height）\n'
      '${_dialogNote(dialogsBefore)}',
    );
  }

  /// 等到某一件事发生。
  ///
  /// 五种等待，可以叠加（都满足才算等到）：
  ///  · [selector] 出现；[text] 出现在正文里；[js] 表达式为真；
  ///  · [urlContains] 地址包含某段；[networkContains] 匹配到某个请求
  ///    **跑完** —— 最后这条最关键：`onPageFinished` 只代表骨架加载完，
  ///    数据往往之后才到，只等 load 拿到的还是空壳。
  Future<StepResult> waitFor({
    String selector = '',
    String text = '',
    String js = '',
    String urlContains = '',
    String networkContains = '',
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (selector.isEmpty &&
        text.isEmpty &&
        js.isEmpty &&
        urlContains.isEmpty &&
        networkContains.isEmpty) {
      return const StepResult.fail(
        BrowserCode.badArg,
        'wait_for 至少要给一个条件（selector / text / js / url_contains / '
        'network_contains）。',
      );
    }
    final InAppWebViewController? c = await ensure();
    if (c == null) return StepResult.closed;

    final DateTime deadline = DateTime.now().add(timeout);
    String lastProbe = '';
    while (DateTime.now().isBefore(deadline)) {
      final StepResult probe = await eval(
        'return JSON.stringify(window.__dsh ? window.__dsh.probe('
        '${jsonEncode(<String, dynamic>{'selector': selector, 'text': text, 'js': js})}'
        ') : {ready: document.readyState, url: location.href})',
      );
      lastProbe = probe.text;
      final Map<String, dynamic> m = asMap(probe.text);

      bool ok = true;
      if (selector.isNotEmpty) ok = ((m['selectorCount'] as num?) ?? 0) > 0;
      if (ok && text.isNotEmpty) ok = m['textFound'] == true;
      if (ok && js.isNotEmpty) ok = m['jsTrue'] == true;
      if (ok && urlContains.isNotEmpty) {
        ok = ((m['url'] ?? _url).toString()).contains(urlContains);
      }
      if (ok && networkContains.isNotEmpty) {
        final StepResult net = await eval(
          'return window.__dsh ? window.__dsh.netList('
          '${jsonEncode(networkContains)}) : "{}"',
        );
        final Map<String, dynamic> nm = asMap(net.text);
        final List<dynamic> items =
            (nm['items'] as List<dynamic>?) ?? <dynamic>[];
        ok = items.any(
          (dynamic e) =>
              (e as Map)['done'] == true && ((e['status'] as num?) ?? 0) > 0,
        );
      }

      if (ok) {
        return StepResult.ok(
          '条件已满足。\n'
          '地址：${m['url'] ?? _url}\n'
          '标题：${m['title'] ?? _title}\n'
          '${selector.isNotEmpty ? '选择器 $selector 命中 ${m['selectorCount']} 个\n' : ''}'
          '${networkContains.isNotEmpty ? '匹配到「$networkContains」的请求已完成\n' : ''}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    return StepResult.fail(
      BrowserCode.timeout,
      '等了 ${timeout.inSeconds} 秒，条件还是没满足。\n'
      '最后一次探测：$lastProbe\n'
      '别原地重试 —— 先 `dom` 看清楚这一页现在是什么'
      '${networkContains.isEmpty ? '' : '，再用 `network` 看请求发出没有、状态码是什么'}。',
    );
  }

  // ------------------------------------------------------------------ 弹窗

  // -------------------------------------------------------------- 网络与数据

  /// 列出页面发出的请求（含状态、类型、大小、耗时）。
  ///
  /// ## 为什么这个比"猜接口地址"重要
  ///
  /// 这套东西真正吃数据的地方是接口，而接口地址（`connectapi.garmin.cn`
  /// 那种）不该由模型去猜：让它自己**从页面的请求里认出来**，
  /// 然后按同一个地址在页内取一次就完事了。
  Future<StepResult> networkList(String contains) async {
    final StepResult r = await eval(
      'return window.__dsh ? window.__dsh.netList(${jsonEncode(contains)}) : "{}"',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    final List<dynamic> items = (m['items'] as List<dynamic>?) ?? <dynamic>[];
    if (items.isEmpty) {
      return StepResult.ok(
        '这一页还没有记录到请求'
        '${contains.isEmpty ? '' : '（没有匹配「$contains」的）'}。\n'
        '只能记录**这一页打开之后**发出的请求：要抓某个接口，'
        '先 `network` 里 op=reset 清空、再触发一次（点一下按钮），然后回来看。',
      );
    }
    final StringBuffer sb = StringBuffer();
    sb.writeln('共记录到 ${m['count']} 个请求（下面是最新的 ${items.length} 个）：\n');
    for (final dynamic e in items) {
      final Map<String, dynamic> r = Map<String, dynamic>.from(e as Map);
      final int status = (r['status'] as num?)?.toInt() ?? 0;
      final int size = (r['size'] as num?)?.toInt() ?? 0;
      final int ms = (r['ms'] as num?)?.toInt() ?? 0;
      final String type = (r['type'] ?? '').toString();
      sb.writeln(
        '[${r['id']}] ${r['method']} '
        '${status == 0 ? (r['done'] == true ? '失败' : '进行中') : status}'
        '${type.isEmpty ? '' : ' · $type'}'
        '${size > 0 ? ' · $size 字节' : ''}'
        '${ms > 0 ? ' · ${ms}ms' : ''}',
      );
      sb.writeln('    ${r['url']}');
      final String err = (r['error'] ?? '').toString();
      if (err.isNotEmpty) sb.writeln('    ⚠ $err');
    }
    sb.write('\n要看某个请求的**响应体**：`network` 里 op=detail + id=<编号>。');
    return StepResult.ok(sb.toString());
  }

  /// 看某个请求的响应体（按 id 或 url 片段找）。
  Future<StepResult> networkDetail({int id = 0, String contains = ''}) async {
    final StepResult r = await eval(
      'return window.__dsh ? window.__dsh.netDetail($id, '
      '${jsonEncode(contains)}) : "{}"',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['found'] != true) {
      return StepResult.fail(
        BrowserCode.noElement,
        '没找到那个请求（id=$id contains="$contains"）。'
        '先 `network` 里 op=list 看有哪些。',
      );
    }
    if (m['binary'] == true) {
      return StepResult.ok(
        '请求 [${m['id']}] ${m['method']} ${m['status']} · ${m['type']}\n'
        '地址：${m['url']}\n'
        '这是**二进制响应**（${m['size']} 字节），内容没进上下文。\n'
        '要拿它：用 `fetch` 动作按同一个地址取一次并 save=true。',
      );
    }
    final String body = (m['body'] ?? '').toString();
    final String head =
        '请求 [${m['id']}] ${m['method']} ${m['status']} · '
        '${m['type']} · ${m['size']} 字节\n地址：${m['url']}\n\n';
    if (m['trimmed'] == true) {
      return StepResult.ok(
        '$head（这个响应体因为总预算已经**丢掉**了 —— 页面上的副本只保留'
        '最近 2MB。要它的内容：用 `fetch` 动作按同一个地址取一次并 save=true。）',
      );
    }
    if (body.isEmpty) {
      return StepResult.ok('$head（响应体是空的，或者还在传）');
    }
    return StepResult.ok(
      body.length > kResultBudget
          ? '$head${body.substring(0, 1200)}\n…（共 ${body.length} 字符，'
                '要全文就 `fetch` 这个地址并 save=true）'
          : '$head$body',
    );
  }

  /// 清空网络记录（"先清空、再触发、再看"是抓接口的标准姿势）。
  Future<StepResult> networkReset() async {
    final StepResult r = await eval(
      'return window.__dsh ? window.__dsh.netReset() : "{}"',
    );
    if (!r.ok) return r;
    return const StepResult.ok('已清空这一页的网络记录。现在去触发那个操作吧。');
  }

  /// **在页面里**发一个请求（带 cookie / csrf），把结果存下来。
  ///
  /// 和 `curl` 的区别正是那份建议指出的那点：cookie、`csrf` token、
  /// 同源策略都由**页面自己的上下文**带着，所以那些"curl 拿到 302/403、
  /// 页面上却是 200"的接口，只有这条路能通。
  Future<StepResult> pageFetch({
    required String url,
    String method = 'GET',
    String body = '',
    Map<String, dynamic> headers = const <String, dynamic>{},
    required String workDir,
    bool save = false,
  }) async {
    if (url.trim().isEmpty) {
      return const StepResult.fail(BrowserCode.badArg, 'fetch 要给 url。');
    }
    // 先确认有一页：页内请求就是"在那一页里发"，没有页面就没有"页面上下文"。
    if (await ensure() == null) return StepResult.closed;
    final dynamic value = await evalAsync(
      'return await window.__dsh.pxFetch(url, opt);',
      args: <String, dynamic>{
        'url': url,
        'opt': <String, dynamic>{
          'method': method,
          'body': body,
          'headers': headers,
        },
      },
    );
    final String err = resultError(value);
    if (err.isNotEmpty) {
      return StepResult.fail(BrowserCode.unsupported, '页内请求失败：$err');
    }
    if (value is! Map) {
      return const StepResult.fail(
        BrowserCode.unsupported,
        '页内请求没有返回可读结果（这一页可能没有注入脚本）。',
      );
    }
    final Map<String, dynamic> m = Map<String, dynamic>.from(value);
    final int status = (m['status'] as num?)?.toInt() ?? 0;
    final String type = (m['type'] ?? '').toString();
    final int size = (m['size'] as num?)?.toInt() ?? 0;

    if (status == 0) {
      return StepResult.fail(
        BrowserCode.httpError,
        '请求没发出去：${m['error'] ?? '未知原因'}\n'
        '（可能是跨域被拦。可以改用 `network` 看页面自己发的那个请求。）',
      );
    }

    // 二进制：落盘，绝不进上下文
    if (m['b64'] != null) {
      final List<int> bytes = base64Decode(m['b64'].toString());
      final ({String path, String? shared, int bytes}) saved =
          await Artifacts.saveBytes(
            workDir,
            stampName('fetch', _extOf(type)),
            bytes,
          );
      return StepResult.ok(
        'HTTP $status · $type · $size 字节（二进制）\n'
        '已保存到：${saved.path}\n'
        '${saved.shared == null ? '' : '在 termux / 内置 Linux 里：${saved.shared}\n'}',
      );
    }

    final String text = (m['text'] ?? '').toString();
    if (save || text.length > kResultBudget) {
      final String t = text.trimLeft();
      final String name = stampName(
        'fetch',
        (t.startsWith('{') || t.startsWith('[')) ? 'json' : _extOf(type),
      );
      final ({String path, String? shared, int bytes}) saved =
          await Artifacts.saveText(workDir, name, text);
      return StepResult.ok(
        'HTTP $status · $type · $size 字符\n'
        '已保存到：${saved.path}\n'
        '${saved.shared == null ? '' : '在 termux / 内置 Linux 里：${saved.shared}\n'}'
        '\n开头一段：\n${text.substring(0, text.length > 900 ? 900 : text.length)}',
      );
    }
    return StepResult.ok('HTTP $status · $type · $size 字符\n\n$text');
  }

  /// 接住下载：**带着 cookie 和 UA 重下**。
  ///
  /// 为什么不交给 WebView 自己的下载器：它走另一条网络栈，不认我们在
  /// CookieManager 里的登录态，也不带我们设的 UA —— 下载站返回的往往是
  /// "请先登录"的一页 HTML，而且用户看不到任何提示。
  Future<StepResult> download({
    String url = '',
    required String workDir,
    String name = '',
    Map<String, dynamic> headers = const <String, dynamic>{},
  }) async {
    String target = url.trim();
    String filename = name.trim();
    String mime = '';
    if (target.isEmpty) {
      final PendingDownload? d = lastDownload;
      if (d == null) {
        return const StepResult.fail(
          BrowserCode.noElement,
          '这一页还没有触发过下载。先点那个下载按钮（`click`），'
          '或者直接给 `url`。',
        );
      }
      target = d.url;
      mime = d.mimeType;
      if (filename.isEmpty) filename = d.suggestedFilename;
    }

    // `blob:` 只有页面自己取得出来 —— 交给页内请求那条路
    if (target.startsWith('blob:')) {
      return pageFetch(url: target, workDir: workDir, save: true);
    }

    final Uri? uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme) {
      return StepResult.fail(BrowserCode.badArg, '下载地址不合法：$target');
    }

    String cookieHeader = '';
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(target),
      );
      cookieHeader = cookies
          .map((Cookie c) => '${c.name}=${c.value}')
          .join('; ');
    } catch (_) {
      // 没 cookie 也照样能下（公开文件）
    }

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 10);
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, WebViewLoader.userAgent);
      if (cookieHeader.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, cookieHeader);
      }
      // **自定义请求头。**
      //
      // 为什么这个参数值得单独加：有些站点的下载接口要带自家头
      // （Garmin 的 `NK` + `Connect-Csrf-Token` 就是），不带就是 403。
      // 没有这个参数时的绕法是：hook 抓头 → 页内 fetch 取 arrayBuffer
      // → 分块 btoa → 拼成大字符串落盘 → base64 解码 —— 一整套绕行，
      // 而它本来只是一个参数的事。（那次实战最可惜的一处。）
      headers.forEach((String k, dynamic v) {
        if (k.trim().isEmpty || v == null) return;
        try {
          req.headers.set(k.trim(), v.toString());
        } catch (_) {
          // 名字不合法就跳过这一个，不要因此让整个下载失败
        }
      });
      final HttpClientResponse resp = await req.close();
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in resp) {
        bytes.addAll(chunk);
      }
      final String ct = resp.headers.contentType?.mimeType ?? mime;

      if (resp.statusCode != 200) {
        return StepResult.fail(
          BrowserCode.httpError,
          '下载失败：HTTP ${resp.statusCode}\n地址：$target\n'
          '${resp.statusCode == 401 || resp.statusCode == 403 ? '（要登录：先在浏览器里登录，或者用 `ask` 让用户登一次 —— cookie 是共用的。）' : ''}',
        );
      }
      // 下回来是 HTML，多半是被登录墙挡了 —— 说清楚，别让模型把它当文件
      if (ct.contains('text/html') && !target.toLowerCase().endsWith('.html')) {
        return StepResult.fail(
          BrowserCode.httpError,
          '下回来的是一页 **HTML**（${bytes.length} 字节），不是文件本身 —— '
          '多半是登录墙或跳转页。\n'
          '先确认这一页的登录态（`cookies`），或者用 `ask` 让用户在这页上'
          '点一次下载。',
        );
      }

      final String fname = filename.isEmpty
          ? stampName('download', _extOf(ct))
          : _safeName(filename);
      final ({String path, String? shared, int bytes}) saved =
          await Artifacts.saveBytes(workDir, fname, bytes);
      return StepResult.ok(
        '已下载：$fname\n'
        '大小：${(bytes.length / 1024).round()} KB · 类型：${ct.isEmpty ? '未知' : ct}\n'
        '保存到：${saved.path}\n'
        '${saved.shared == null ? '' : '在 termux / 内置 Linux 里：${saved.shared}\n'}',
      );
    } catch (e) {
      return StepResult.fail(BrowserCode.unsupported, '下载出错：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 往页面的文件框里塞文件（`<input type=file>`）。
  ///
  /// ## 为什么要绕这么一圈
  ///
  /// JS **读不了本地文件**（同源策略），而手机上的文件选择器只有用户能点。
  /// 唯一的办法是：我们把文件字节读出来、base64 送进页面、在页里造一个
  /// `File` 对象，再用 `DataTransfer` 写进 `input.files` —— 这条路能成，
  /// 是因为 `DataTransfer` 是浏览器给"拖拽上传"留的正当入口。
  ///
  /// 上限：单个 6MB、合计 12MB（base64 会撑大 1/3，再大就要走
  /// evaluateJavascript 的字符串通道，得不偿失）。
  Future<StepResult> upload({
    required String selector,
    required List<String> paths,
  }) async {
    if (paths.isEmpty) {
      return const StepResult.fail(BrowserCode.badArg, 'upload 要给 paths。');
    }
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
    int total = 0;
    for (final String p in paths) {
      final File f = File(p);
      if (!await f.exists()) {
        return StepResult.fail(BrowserCode.noElement, '文件不存在：$p');
      }
      final List<int> bytes = await f.readAsBytes();
      total += bytes.length;
      if (bytes.length > 6 * 1024 * 1024 || total > 12 * 1024 * 1024) {
        return const StepResult.fail(
          BrowserCode.badArg,
          '文件太大（单个 6MB / 合计 12MB 是上限）。'
          '先用 `python` 或终端压一下，或者让用户手动在页面上选文件。',
        );
      }
      files.add(<String, dynamic>{
        'name': p.split('/').last.split('\\').last,
        'type': _mimeOf(p),
        'b64': bytesToBase64Chunked(bytes),
      });
    }

    final StepResult r = await evalBoot(
      'return JSON.stringify(window.__dsh ? window.__dsh.setFiles('
      '${jsonEncode(selector)}, ${jsonEncode(files)}, 0) '
      ': {ok:false, code:"NO_BOOTSTRAP"})',
    );
    if (!r.ok) return r;
    final Map<String, dynamic> m = asMap(r.text);
    if (m['ok'] != true) {
      return StepResult.fail(
        BrowserCode.noElement,
        '没找到文件框'
        '${selector.isEmpty ? '（默认找 input[type=file]）' : '（选择器 $selector）'}。\n'
        '有些页面的文件框是**点一下才创建**的：先 `click` 那个'
        '"上传 / 选择文件"按钮，再回来 `upload`。',
      );
    }
    return StepResult.ok(
      '已把 ${m['count']} 个文件放进 ${_describe(m['info'])}\n'
      '（${paths.map((String p) => p.split('/').last).join('、')}）\n'
      '多数页面在这个事件里就会开始上传；用 `network` 能看到它发给了谁。',
    );
  }

  /// 弹窗记录（页面问过什么、我们替它答了什么）。
  String dialogReport() {
    if (dialogs.isEmpty) {
      return '这一页到目前为止没有弹过 alert / confirm / prompt。';
    }
    return '这一页弹过的框（最多留最近 6 条）：\n'
        '${dialogs.map((String d) => '· $d').join('\n')}\n\n'
        '默认策略：alert 直接确定；confirm / prompt **一律取消** ——'
        '替用户点"确定"（尤其是"确定删除吗"这种）是不可接受的。\n'
        '要让下一个框答"确定"：先 `dialog` 里 op=answer + answer=ok，'
        '再去做那个会弹框的动作（这个设定只用一次）。';
  }

  String _dialogNote(int from) {
    if (dialogs.length <= from) return '';
    final List<String> fresh = dialogs.sublist(from);
    return '⚠ 这一步里页面弹了框：\n${fresh.map((String d) => '· $d').join('\n')}\n';
  }

  /// 描述一个元素（给模型看的短摘要）。
  static String _describe(dynamic info) {
    if (info is! Map) return '（未知元素）';
    final Map<dynamic, dynamic> m = info;
    final String tag = (m['tag'] ?? '?').toString();
    final String id = (m['id'] ?? '').toString();
    final String name = (m['name'] ?? '').toString();
    final String cls = (m['cls'] ?? '').toString();
    final String txt = (m['text'] ?? '').toString();
    // 认得出是哪个元素，比好看重要：id 最稳，其次 name，再次第一个 class。
    final String pick = id.isNotEmpty
        ? '#$id'
        : (name.isNotEmpty
              ? '[name=$name]'
              : (cls.isEmpty ? '' : '.${cls.split(' ').first}'));
    return '<$tag$pick>${txt.isEmpty ? '' : '「$txt」'}';
  }

  /// 命中结果排成人话（坐标点击 / 真实触摸 / `hit_test` 共用）。
  ///
  /// 为什么非要说这么细：模型看着截图点的坐标，它需要知道那一下落在
  /// **哪个东西**上。只回一句"点完了"，它在"没反应"时只能猜 ——
  /// 而猜的方式通常是**把同一个坐标再点一次**。
  /// 把"那一点最上面是谁、它不可点、所以穿透到了谁"写出来，
  /// 它才有依据换下一步（换坐标 / 换选择器 / 交给用户）。
  static String _hitReport(Map<String, dynamic> payload) {
    final Map<String, dynamic> h = mapOf(payload['hit']);
    if (h.isEmpty) return '· 这一趟没读到命中信息。\n';
    final String via = (h['via'] ?? '').toString();
    final String rect = rectText(h['rect']);
    final bool through = via == 'through' || via == 'through-label';

    final StringBuffer sb = StringBuffer();
    sb.writeln('· 命中：${_describe(h)}${rect.isEmpty ? '' : ' rect $rect'}');
    if (through) {
      final Map<String, dynamic> top = mapOf(h['top']);
      sb.writeln(
        '· 那一点最上面是：${_describe(top['info'])}'
        '${rectText(top['rect']).isEmpty ? '' : ' rect ${rectText(top['rect'])}'}'
        ' —— 它不可点，所以**穿透**到了下面那个',
      );
    }
    if (via == 'top-label' || via == 'through-label') {
      sb.writeln('· 命中的是 `label`：点它会转给对应的输入控件（勾选框、输入框）。');
    }
    if (via == 'fallback') {
      sb.writeln(
        '· 注意：那一点上没有明确的控件，取的是最近的可点祖先 —— '
        '如果这一步本该有反应，先用 `hit_test` 看清楚这底下是什么。',
      );
    }
    return sb.toString();
  }

  /// 按 content-type 猜扩展名（落盘时用）。
  static String _extOf(String contentType) {
    final String t = contentType.toLowerCase();
    if (t.contains('json')) return 'json';
    if (t.contains('csv')) return 'csv';
    if (t.contains('html')) return 'html';
    if (t.contains('pdf')) return 'pdf';
    if (t.contains('zip')) return 'zip';
    if (t.contains('png')) return 'png';
    if (t.contains('jpeg') || t.contains('jpg')) return 'jpg';
    if (t.contains('gif')) return 'gif';
    if (t.contains('fit')) return 'fit';
    if (t.contains('xml')) return 'xml';
    if (t.contains('plain') || t.contains('text')) return 'txt';
    return 'bin';
  }

  static String _mimeOf(String path) {
    final String p = path.toLowerCase();
    if (p.endsWith('.json')) return 'application/json';
    if (p.endsWith('.csv')) return 'text/csv';
    if (p.endsWith('.txt')) return 'text/plain';
    if (p.endsWith('.pdf')) return 'application/pdf';
    if (p.endsWith('.zip')) return 'application/zip';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.gif')) return 'image/gif';
    return 'application/octet-stream';
  }

  /// 文件名清洗：去掉路径分隔符和上跳，避免写到工作目录外面去。
  static String _safeName(String raw) {
    String n = raw.split('/').last.split('\\').last;
    n = n.replaceAll('..', '_').trim();
    if (n.isEmpty) n = stampName('download');
    return n.length > 120 ? n.substring(n.length - 120) : n;
  }

  bool _takeAnswer() {
    final bool? a = _nextAnswer;
    _nextAnswer = null;
    // 默认**答"取消"**：页面上那种"确定要删除吗"的框，替用户点"确定"
    // 是不可接受的。导航那一步会自己预设"确定"（见 [navigate]）。
    return a ?? false;
  }

  void _recordDialog(String kind, String message, {String answered = '确定'}) {
    dialogs.add('[$kind] ${message.trim()} → 代答：$answered');
    while (dialogs.length > 6) {
      dialogs.removeAt(0);
    }
  }

  /// 预设下一个弹窗的答案（`dialog` 动作）。
  void presetAnswer(String answer, {String promptText = ''}) {
    final String a = answer.toLowerCase();
    _nextAnswer = a == 'ok' || a == 'confirm' || a == 'yes' || a == '确定';
    _nextPromptText = promptText;
  }

  /// 记下一次下载请求。
  ///
  /// 公开出来是因为**用户那一页**（[WebViewLoader.liveController]）也要走它：
  /// 用户在页面上点"导出"时，那条下载请求得和 agent 自己那一页共用同一份
  /// 记录，之后 `download` 动作才接得住（否则只能重新去猜那个地址）。
  void rememberDownload(DownloadStartRequest req) {
    lastDownload = PendingDownload(
      url: req.url.toString(),
      mimeType: req.mimeType ?? '',
      suggestedFilename: req.suggestedFilename ?? '',
      contentLength: req.contentLength,
      userAgent: req.userAgent ?? '',
    );
  }

  /// 记一条弹窗（用户那一页的原生弹窗也走这里）。
  void noteDialog(String kind, String message, {String answered = '确定'}) =>
      _recordDialog(kind, message, answered: answered);

  /// 取下一个弹窗的答案（用户那一页的原生弹窗也用它）。
  bool takePresetAnswer() => _takeAnswer();

  void clearDialogs() => dialogs.clear();
}

/// "往上爬到最近的可点祖先"照这份清单找（带引号，直接拼进 JS）。
///
/// 含 `input, select, textarea`：点输入框本身是**要**的行为（拿到焦点才能输入），
/// 不该被当成"爬到外面的 label 上"。
const String _kClickableSel =
    '"a,button,[role=button],input,select,textarea,summary,label,[onclick]"';

/// 定位与几何的 JS 骨架（坐标点击、记忆记录、记忆召回、滑动共用）。
///
/// 三件事：
///  · [durable] 挑一个**稳定**的定位方式：`#id` → `data-*` / `name` /
///    `aria-label` / `title` / `href` → CSS 路径。顺序就是"抗改版能力"的顺序。
///  · [vis] 只认**看得见**的元素：隐藏在 DOM 里的同一个按钮到处都是，
///    命中一个看不见的等于没命中。
///  · [docRect] 给的是**文档坐标**（加上滚动量）。用视口坐标记位置的话，
///    页面滚一屏，所有记忆一起错位。
///
/// 为什么要挑得这么讲究：这套东西的产出会被**存下来当下一轮的定位依据**。
/// 存一个 `div:nth-child(3)` 这种早晚会失效的东西，等于给下一轮埋雷 ——
/// 而它的失效方式还是最坏的那种：**看起来点成功了，点的是别的按钮**。
const String kLocatorJs = r'''
  function clean(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/\s+/g, ' ').trim();
  }
  function vis(e) {
    var r = e.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var st = getComputedStyle(e);
    return st.visibility !== 'hidden' && st.display !== 'none' && st.opacity !== '0';
  }
  function label(e) {
    var t = clean(e.innerText || e.value ||
      (e.getAttribute ? e.getAttribute('aria-label') : '')).slice(0, 40);
    return (e.tagName || '').toLowerCase() + '「' + t + '」';
  }
  function info(e) {
    return {
      tag: (e.tagName || '').toLowerCase(),
      text: clean(e.innerText || e.value ||
        (e.getAttribute ? e.getAttribute('aria-label') : '')).slice(0, 60),
      href: e.href || ''
    };
  }
  function docRect(e) {
    var r = e.getBoundingClientRect();
    return {
      x: r.left + r.width / 2 + (window.scrollX || 0),
      y: r.top + r.height / 2 + (window.scrollY || 0),
      w: r.width, h: r.height
    };
  }
  function cssRect(e) {
    var r = e.getBoundingClientRect();
    return {
      x: Math.round(r.left), y: Math.round(r.top),
      w: Math.round(r.width), h: Math.round(r.height)
    };
  }
  // 那一点上**叠着**哪些元素（从最上面一层到最底下）。
  // 用 elementsFromPoint 而不是 elementFromPoint：只要最上面那个，
  // 就永远看不见"它下面其实压着真正的输入框"。
  function stackAt(x, y) {
    var out = [];
    try { out = document.elementsFromPoint(x, y) || []; } catch (e) { out = []; }
    if (!out.length) {
      var one = document.elementFromPoint(x, y);
      if (one) out = [one];
    }
    return out;
  }
  // 往上找最近的、能点的祖先（返回 null = 这个元素和它的祖先都不可点）。
  function up(node, sel) {
    if (!node) return null;
    try { return node.closest ? node.closest(sel) : null; } catch (e) { return null; }
  }
  // 能点的两层清单（JS 里各写一份：这段是**原始字符串**，塞不进 Dart 插值）。
  // TIER1 = 真能点的控件；TIER2 = label 这类"点了会转给别的控件"的。
  var TIER1 = 'input,textarea,select,button,a,summary,[role=button],'
    + '[role=link],[role=tab],[role=menuitem],[role=checkbox],'
    + '[role=radio],[onclick]';
  var TIER2 = 'label,[for]';
  // 命中：顶层是谁、真正该点的是谁、是"直接命中"还是"穿透遮挡"。
  function pick(x, y) {
    var st = stackAt(x, y);
    var top = st.length ? st[0] : null;
    var target = null, via = '', depth = st.length;
    for (var t = 0; t < 2 && !target; t++) {
      var sel = t === 0 ? TIER1 : TIER2;
      for (var i = 0; i < st.length; i++) {
        var c = (st[i].matches && st[i].matches(sel)) ? st[i] : up(st[i], sel);
        if (c && vis(c)) {
          target = c;
          via = (t === 0 ? (i === 0 ? 'top' : 'through') : (i === 0 ? 'top-label' : 'through-label'));
          break;
        }
      }
    }
    if (!target && top) {
      target = up(top, 'a,button,[role=button],input,select,textarea,summary,label,[onclick]') || top;
      via = 'fallback';
    }
    return {top: top, target: target, via: via, depth: depth, stack: st};
  }
  function path(e) {
    var parts = [], cur = e, guard = 0;
    while (cur && cur.nodeType === 1 && guard++ < 14) {
      var n = 1, s = cur;
      while ((s = s.previousElementSibling)) {
        if (s.tagName === cur.tagName) n++;
      }
      parts.unshift(cur.tagName.toLowerCase() + ':nth-of-type(' + n + ')');
      var cand = parts.join(' > ');
      try {
        if (document.querySelectorAll(cand).length === 1) return cand;
      } catch (err) { return ''; }
      cur = cur.parentElement;
    }
    return parts.join(' > ');
  }
  function durable(e) {
    try {
      if (e.id) {
        var s0 = '#' + CSS.escape(e.id);
        if (document.querySelectorAll(s0).length === 1) return s0;
      }
    } catch (err) {}
    var attrs = ['data-testid', 'data-test', 'data-qa', 'name',
      'aria-label', 'title', 'alt', 'href'];
    for (var i = 0; i < attrs.length; i++) {
      var v = e.getAttribute ? e.getAttribute(attrs[i]) : null;
      if (!v) continue;
      var s1 = e.tagName.toLowerCase() + '[' + attrs[i] + '="' +
        clean(v).replace(/"/g, '\\"') + '"]';
      try {
        if (document.querySelectorAll(s1).length === 1) return s1;
      } catch (err) {}
    }
    return path(e);
  }
''';

/// 「截图上的这个坐标上是什么」。[click] 为真时顺手点下去。
///
/// 两个用途：坐标点击（要回执"点到了什么"）和真实触摸前的**读**
/// （原生注入不带回执，不读的话，模型永远不知道那一下落在了哪个东西上
/// —— 点错了也不知道错在哪）。两处都要同一份"怎么可靠地再找到它"的结论，
/// 所以共用这一份。
///
/// 记进记忆的目标是 `hit` 的**最外层 `<a>`**（有的话）：人手指点在一个
/// 链接里的图标上，浏览器把这次点击交给那个 `<a>` —— 记忆里存 `<a>`
/// 下次才点得动。
String kPointAtJs(double sx, double sy, {required bool click}) {
  final String body = click
      ? '  var out = {ok:true, at:at, hit:hitInfo, urlBefore: location.href};\n'
            '  try { hit.target.click(); }\n'
            '  catch (e) { out.clickError = String(e); }\n'
            '  out.urlAfter = location.href;\n'
            '  out.domChanged = (document.body ? document.body.innerHTML.length : 0) !== lenBefore;\n'
            '  return JSON.stringify(out);\n'
      : '  return JSON.stringify({ok:true, at:at, hit:hitInfo});\n';

  return 'return (function (sx, sy) {\n'
      '  var dpr = window.devicePixelRatio || 1;\n'
      '  var x = sx / dpr, y = sy / dpr;\n'
      '$kLocatorJs\n'
      '  var at = {x:Math.round(x), y:Math.round(y), sx:Math.round(sx), '
      'sy:Math.round(sy), dpr:dpr,\n'
      '    viewport:{w:innerWidth, h:innerHeight}, '
      'page:{w:document.documentElement.scrollWidth, '
      'h:document.documentElement.scrollHeight}};\n'
      '  var picked = pick(x, y);\n'
      '  if (!picked.top) return JSON.stringify({ok:false, code:"NO_POINT", '
      'at:at});\n'
      '  var hit = picked.target || picked.top;\n'
      '  var owner = (hit.closest && hit.closest("a")) || hit;\n'
      '  var hitInfo = {\n'
      '    ok: true, via: picked.via, depth: picked.depth,\n'
      '    top: {info: info(picked.top), rect: cssRect(picked.top),\n'
      '      clickable: !!up(picked.top, $_kClickableSel)},\n'
      '    info: info(hit), rect: cssRect(hit), sameTarget: picked.top === hit,\n'
      '    sel: durable(hit), owner: durable(owner),\n'
      '    memo: {sel: durable(owner), txt: info(owner).text,\n'
      '      label: label(owner), at: docRect(owner)}\n'
      '  };\n'
      '  var lenBefore = document.body ? document.body.innerHTML.length : 0;\n'
      '$body'
      '})(${sx.round()}, ${sy.round()})';
}

/// 用**记忆**点的那段 JS：先按选择器找，再按文字找，找不到就如实说为什么。
///
/// 两道关：
///  1. **还找得到**：选择器要**唯一命中**（命中两个等于没定位），
///     文字也要唯一（页面上三个"下一页"的话，凭什么敢点？）；
///  2. **还在原来那一带**：元素中心相对记下时的位置没跑远。
///     页面重排之后同一个坐标可能已经是别的东西 —— 那时候宁可退回坐标，
///     也不能照着一份过期的记忆点下去。
///
/// 失败时把原因（`why` / `MEMO_MOVED`）带回去：主流程据此决定"删掉这条记忆"，
/// 顺便让模型知道刚发生了什么，而不是又一次"点了没反应"。
String kRecallClickJs({
  required String selector,
  required String text,
  required double atX,
  required double atY,
  required bool hasAt,
  required int tolerance,
}) {
  return 'return (function (sel, txt, ax, ay, hasAt, tol) {\n'
      '$kLocatorJs\n'
      '  var el = null, via = "", why = "";\n'
      '  if (sel) {\n'
      '    var list = null;\n'
      '    try { list = document.querySelectorAll(sel); }\n'
      '    catch (e) { why = "选择器写法不认了"; }\n'
      '    if (list && list.length === 1 && vis(list[0])) {\n'
      '      el = list[0]; via = "选择器";\n'
      '    } else if (list && list.length > 1) {\n'
      '      why = "选择器现在命中 " + list.length + " 个地方";\n'
      '    }\n'
      '  }\n'
      '  if (!el && txt) {\n'
      '    var all = document.querySelectorAll($_kClickableSel);\n'
      '    var found = [];\n'
      '    for (var i = 0; i < all.length && found.length < 3; i++) {\n'
      '      var e = all[i];\n'
      '      if (!vis(e)) continue;\n'
      '      var own = clean(e.innerText || e.value || '
      '(e.getAttribute ? e.getAttribute("aria-label") : ""));\n'
      '      if (own === txt) found.push(e);\n'
      '    }\n'
      '    if (found.length === 1) { el = found[0]; via = "文字"; }\n'
      '    else if (!why) {\n'
      '      why = found.length ? "那段文字现在有 " + found.length + " 个"\n'
      '        : "那段文字不见了";\n'
      '    }\n'
      '  }\n'
      '  if (!el) return JSON.stringify({ok:false, code:"MEMO_MISS", why:why});\n'
      '  if (hasAt) {\n'
      '    var c = docRect(el);\n'
      '    var dx = c.x - ax, dy = c.y - ay;\n'
      '    var dist = Math.sqrt(dx * dx + dy * dy);\n'
      '    if (dist > tol) return JSON.stringify('
      '{ok:false, code:"MEMO_MOVED", dist:Math.round(dist)});\n'
      '  }\n'
      '  var out = {ok:true, via:via, info:info(el), '
      'sel:durable(el), urlBefore:location.href};\n'
      '  try { el.click(); } catch (e) { out.clickError = String(e); }\n'
      '  out.urlAfter = location.href;\n'
      '  return JSON.stringify(out);\n'
      '})(${jsonEncode(selector)}, ${jsonEncode(text)}, '
      '${atX.round()}, ${atY.round()}, $hasAt, $tolerance)';
}

/// 按坐标滑动那段 JS 的**兜底**分支（浏览器页没开着时走它）。
///
/// 它做的事和真实触摸**不等价**，只是"能滚就先滚一段"：
/// 找到起点下面最近的可滚动祖先，滚一段。所以结果里必须写清楚
/// 这一下不是真实触摸 —— 否则模型会以为拖动类操作（滑块、地图）
/// 在后台也做得了，然后对着一句"其实只是滚了一下"的结果继续往下推。
String kSwipeDragJs(
  double fx,
  double fy,
  double tx,
  double ty,
  int ms,
  int steps,
) {
  final int x0 = fx.round();
  final int y0 = fy.round();
  final int x1 = tx.round();
  final int y1 = ty.round();
  return 'return await (async function () {\n'
      '  var start = document.elementFromPoint($x0, $y0);\n'
      '  if (!start) return JSON.stringify({ok:false, code:"NO_POINT"});\n'
      '  function rectOf(e) {\n'
      '    var r = e.getBoundingClientRect();\n'
      '    return [Math.round(r.left), Math.round(r.top), '
      'Math.round(r.width), Math.round(r.height)];\n'
      '  }\n'
      '  function snap() {\n'
      '    var cs = window.getComputedStyle(start);\n'
      '    return {\n'
      '      sx: Math.round(window.scrollX), sy: Math.round(window.scrollY),\n'
      '      r: rectOf(start),\n'
      '      v: start.value === undefined ? null : String(start.value),\n'
      '      t: cs.transform,\n'
      '      sl: Math.round(start.scrollLeft), st: Math.round(start.scrollTop)\n'
      '    };\n'
      '  }\n'
      '  var before = snap();\n'
      // DOM 变化计数：地图拖动改的是**子元素的 transform**，
      // 滑块改的是 value —— 两样都不一定会让 `start` 自己的矩形变化，
      // 所以再挂一个观察器兜住"任何可见的动静"。
      '  var muts = 0, mo = null;\n'
      '  try {\n'
      '    mo = new MutationObserver(function (list) { muts += list.length; });\n'
      '    mo.observe(document.documentElement, {subtree: true, childList: true, '
      'attributes: true, characterData: true});\n'
      '  } catch (e) { mo = null; }\n'
      '\n'
      '  var id = 1, px = $x0, py = $y0;\n'
      '  function pev(kind) {\n'
      '    var ev = null;\n'
      '    try {\n'
      '      ev = new PointerEvent(kind, {bubbles: true, cancelable: true, '
      'composed: true, pointerId: id, pointerType: "touch", isPrimary: true, '
      'clientX: px, clientY: py, '
      'buttons: kind === "pointerup" ? 0 : 1, '
      'button: kind === "pointerdown" ? 0 : -1, '
      'pressure: kind === "pointerup" ? 0 : 0.5});\n'
      '    } catch (e) {\n'
      '      var alt = kind === "pointerdown" ? "mousedown" : '
      '(kind === "pointerup" ? "mouseup" : "mousemove");\n'
      '      ev = new MouseEvent(alt, {bubbles: true, cancelable: true, '
      'clientX: px, clientY: py, buttons: kind === "pointerup" ? 0 : 1});\n'
      '    }\n'
      '    start.dispatchEvent(ev);\n'
      '  }\n'
      '  function tev(kind) {\n'
      '    try {\n'
      '      var t = new Touch({identifier: id, target: start, '
      'clientX: px, clientY: py, '
      'pageX: px + window.scrollX, pageY: py + window.scrollY});\n'
      '      var list = kind === "touchend" ? [] : [t];\n'
      '      start.dispatchEvent(new TouchEvent(kind, {bubbles: true, '
      'cancelable: true, composed: true, touches: list, targetTouches: list, '
      'changedTouches: [t]}));\n'
      '    } catch (e) {}\n'
      '  }\n'
      '  function wait(ms2) { return new Promise(function (r) { setTimeout(r, ms2); }); }\n'
      '\n'
      '  pev("pointerdown"); tev("touchstart");\n'
      '  var n = $steps;\n'
      '  var gap = Math.max(6, Math.round($ms / n));\n'
      '  for (var i = 1; i <= n; i++) {\n'
      '    await wait(gap);\n'
      '    px = Math.round($x0 + ($x1 - $x0) * i / n);\n'
      '    py = Math.round($y0 + ($y1 - $y0) * i / n);\n'
      '    pev("pointermove"); tev("touchmove");\n'
      '  }\n'
      '  await wait(40);\n'
      '  pev("pointerup"); tev("touchend");\n'
      '  await wait(160);\n'
      '  var after = snap();\n'
      '  if (mo) { try { mo.disconnect(); } catch (e) {} }\n'
      '\n'
      '  var why = [];\n'
      '  if (before.sy !== after.sy || before.sx !== after.sx) why.push("页面滚动位置变了");\n'
      '  if (before.v !== after.v) why.push("控件的 value 变了");\n'
      '  if (String(before.r) !== String(after.r)) why.push("元素矩形变了");\n'
      '  if (before.t !== after.t) why.push("元素的 transform 变了");\n'
      '  if (before.sl !== after.sl || before.st !== after.st) why.push("容器的滚动位置变了");\n'
      '  if (muts > 0) why.push("页面 DOM 有 " + muts + " 处变化");\n'
      '  return JSON.stringify({\n'
      '    ok: true, changed: why.length > 0, changedBy: why.join("、"),\n'
      '    before: before, after: after, mutations: muts, steps: n\n'
      '  });\n'
      '})()';
}

/// 每个页面**文档开始时**注入的引导脚本。
///
/// 三件事放在同一个文件里，因为它们共用一层作用域：网络包装、元素定位、
/// 页内请求。分开注入会有先后问题 —— 网络包装必须最早。
///
/// ## 为什么网络抓取只能靠包装 fetch/XHR
///
/// `shouldInterceptRequest` 只能看到**请求**，拿不到响应体 —— 而"接口
/// 返回了什么"才是数据本身。所以唯一的办法是：在这页的 JS 里把 `fetch`
/// 和 `XMLHttpRequest` 换掉，让它们自己把结果抄一份留下来。
UserScript get bootstrapScript => UserScript(
  source: kSessionBootstrapJs,
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  // 只注主框架会漏掉 iframe 里的请求（登录框常常在 iframe 里），
  // 所以子框架也注。
  forMainFrameOnly: false,
);

/// 注入脚本的正文（抽成常量以便单独测）。
const String kSessionBootstrapJs = r'''
(function () {
  if (window.__dsh && window.__dsh.v >= 1) return;
  var NET = [];
  var NET_MAX = 60;
  var BODY_MAX = 200000;
  var BODY_TOTAL = 0;
  var BODY_BUDGET = 2000000;

  // ---- 事件计数器：用来**回读**"动作到底有没有落到这一页上" ----
  //
  // 为什么要在 document 上装 capture 监听器：`el.click()` 会返回成功，
  // 但那不代表**页面收到了事件**（被遮罩挡住、元素已经不在树上、
  // 或者浏览器把注入的事件丢了）。这两个计数是唯一能证明
  // "这一下真的到了页面"的证据 —— 工具据此决定报成功还是 NO_EFFECT。
  //
  // 只计数、不做任何拦截（capture 但**不** preventDefault/stopPropagation），
  // 所以对页面行为零影响。
  var SEEN = { clicks: 0, keys: 0 };
  try {
    document.addEventListener('click', function () { SEEN.clicks++; }, true);
    document.addEventListener('keydown', function () { SEEN.keys++; }, true);
  } catch (e) {}
  window.__dshSeen = SEEN;
  var seq = 0;

  function str(v, n) {
    v = (v === null || v === undefined) ? '' : String(v);
    return v.length > n ? v.slice(0, n) : v;
  }
  function text(el) {
    return str(String(
      el.innerText || el.value || el.getAttribute('aria-label') ||
      el.getAttribute('title') || ''
    ).replace(/\s+/g, ' ').trim(), 120);
  }
  function push(rec) {
    NET.push(rec);
    while (NET.length > NET_MAX) {
      var old = NET.shift();
      if (old && old.body) BODY_TOTAL -= old.body.length;
    }
    return rec;
  }
  // 响应体**总共**最多留 2MB：一个长会话里几十个接口、每个几百 KB 的话，
  // 页面的内存会被这些"抄下来的副本"撑爆（用户在页面上还会继续操作，
  // 崩的是他正在用的这一页）。超了就从**最旧的**开始把 body 丢掉，
  // 元信息（状态码/地址/大小）全部保留 —— 那些才是指认接口用的。
  function keepBody(rec, t) {
    rec.size = t.length;
    rec.body = str(t, BODY_MAX);
    BODY_TOTAL += rec.body.length;
    var i = 0;
    while (BODY_TOTAL > BODY_BUDGET && i < NET.length) {
      var r = NET[i];
      if (r.body) {
        BODY_TOTAL -= r.body.length;
        r.body = '';
        r.trimmed = true;
      }
      i++;
    }
  }
  function byId(id) {
    for (var i = 0; i < NET.length; i++) { if (NET[i].id === id) return NET[i]; }
    return null;
  }
  function absorb(rec, xhr) {
    try {
      rec.status = xhr.status;
      rec.ok = xhr.status >= 200 && xhr.status < 400;
      rec.type = (xhr.getResponseHeader && xhr.getResponseHeader('content-type')) || '';
      var t = (xhr.responseType === '' || xhr.responseType === 'text') ? xhr.responseText : '';
      if (t) { keepBody(rec, t); }
      rec.ended = Date.now();
    } catch (e) {}
  }

  // ---------------- 网络：fetch ----------------
  try {
    var rawFetch = window.fetch;
    if (rawFetch) {
      window.fetch = function (input, init) {
        var url = (typeof input === 'string') ? input : ((input && input.url) || '');
        var method = ((init && init.method) || (input && input.method) || 'GET');
        var rec = push({
          id: ++seq, kind: 'fetch',
          method: String(method).toUpperCase(), url: String(url),
          started: Date.now(), status: 0, ok: false, type: '', size: 0,
          body: '', req: str(init && init.body, 2000), error: ''
        });
        var p = rawFetch.apply(window, arguments);
        return p.then(function (res) {
          rec.status = res.status;
          rec.ok = res.ok;
          try { rec.type = (res.headers && res.headers.get('content-type')) || ''; }
          catch (e) {}
          try {
            var ct = (rec.type || '').toLowerCase();
            if (/json|text|xml|javascript|x-www-form-urlencoded|html/.test(ct)) {
              res.clone().text().then(function (t) {
                keepBody(rec, t);
                rec.ended = Date.now();
              }, function () {});
            } else {
              res.clone().arrayBuffer().then(function (b) {
                rec.size = b.byteLength;
                rec.binary = true;
                rec.ended = Date.now();
              }, function () {});
            }
          } catch (e) {}
          return res;
        }, function (e) {
          rec.error = String(e);
          rec.ended = Date.now();
          throw e;
        });
      };
    }
  } catch (e) {}

  // ---------------- 网络：XHR ----------------
  try {
    var xo = XMLHttpRequest.prototype.open;
    var xs = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (m, u) {
      this.__dsh = push({
        id: ++seq, kind: 'xhr',
        method: String(m || 'GET').toUpperCase(), url: String(u || ''),
        started: Date.now(), status: 0, ok: false, type: '', size: 0,
        body: '', req: '', error: ''
      });
      return xo.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function (body) {
      var rec = this.__dsh;
      if (rec) {
        rec.req = str(body, 2000);
        var self = this;
        this.addEventListener('load', function () { absorb(rec, self); });
        this.addEventListener('error', function () {
          rec.error = 'network';
          rec.ended = Date.now();
        });
        this.addEventListener('abort', function () {
          rec.error = 'abort';
          rec.ended = Date.now();
        });
      }
      return xs.apply(this, arguments);
    };
  } catch (e) {}

  // ---------------- 元素定位 ----------------
  function all(sel) {
    try { return Array.prototype.slice.call(document.querySelectorAll(sel)); }
    catch (e) { return []; }
  }
  function shown(el) {
    try {
      var r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) return false;
      var st = window.getComputedStyle ? window.getComputedStyle(el) : null;
      if (st && (st.visibility === 'hidden' || st.display === 'none' ||
          parseFloat(st.opacity || '1') === 0)) return false;
      return true;
    } catch (e) { return false; }
  }
  function describe(el) {
    return {
      tag: el.tagName ? el.tagName.toLowerCase() : '',
      id: el.id || '',
      name: (el.getAttribute && el.getAttribute('name')) || '',
      cls: str((el.className && el.className.toString) ? el.className.toString() : '', 60),
      type: (el.getAttribute && el.getAttribute('type')) || '',
      text: text(el),
      href: el.href ? str(String(el.href), 200) : ''
    };
  }
  // 只认**看得见**的元素：页面上常常有一堆隐藏的同名节点
  // （给手机/桌面各准备一份），点到隐藏的那个会"什么都没有发生"。
  function resolve(sel, wantText, index) {
    var list = sel
      ? all(sel)
      : all('a,button,input[type=submit],input[type=button],[role=button],[onclick]');
    if (wantText) {
      var t = String(wantText).toLowerCase();
      list = list.filter(function (el) {
        var s = String(el.innerText || el.value ||
          el.getAttribute('aria-label') || '');
        return s.toLowerCase().indexOf(t) >= 0;
      });
    }
    var visible = list.filter(shown);
    if (!visible.length) return { count: visible.length, el: null };
    var i = Math.max(0, Math.min(index | 0, visible.length - 1));
    return { count: visible.length, el: visible[i] };
  }
  function rectOf(el) {
    try {
      el.scrollIntoView({ block: 'center', inline: 'nearest' });
      var r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
    } catch (e) { return null; }
  }
  // React 那类框架会**绕过 value 的 setter**：直接 `el.value = x` 它们收不到
  // （内部记着旧值，下次渲染又盖回来）。所以要拿原型上的原生 setter 来写。
  function setValue(el, v) {
    try {
      var proto = el.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype
        : (el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype);
      var d = Object.getOwnPropertyDescriptor(proto, 'value');
      if (d && d.set) { d.set.call(el, v); return true; }
    } catch (e) {}
    try { el.value = v; return true; } catch (e) { return false; }
  }
  function fire(el, kind) {
    try { el.dispatchEvent(new Event(kind, { bubbles: true })); } catch (e) {}
  }

  window.__dsh = {
    v: 1,

    // ---- 网络 ----
    netList: function (contains) {
      var items = NET.filter(function (r) {
        return !contains || r.url.indexOf(contains) >= 0;
      }).map(function (r) {
        return {
          id: r.id, kind: r.kind, method: r.method, url: r.url,
          status: r.status, ok: r.ok, type: r.type, size: r.size,
          ms: r.ended ? (r.ended - r.started) : 0, done: !!r.ended,
          error: r.error || ''
        };
      });
      return JSON.stringify({ count: items.length, items: items.slice(-40) });
    },
    netDetail: function (id, contains) {
      var r = null;
      if (id) r = byId(id);
      if (!r && contains) {
        for (var i = NET.length - 1; i >= 0; i--) {
          if (NET[i].url.indexOf(contains) >= 0 && NET[i].done) { r = NET[i]; break; }
        }
      }
      if (!r) return JSON.stringify({ found: false });
      return JSON.stringify({
        found: true, id: r.id, method: r.method, url: r.url, status: r.status,
        type: r.type, size: r.size, binary: !!r.binary, body: r.body || '',
        trimmed: !!r.trimmed, error: r.error || ''
      });
    },
    netReset: function () { NET = []; return JSON.stringify({ ok: true }); },

    // ---- 页内请求（带 cookie / csrf，绕开 curl 的 302/403）----
    pxFetch: function (url, opt) {
      opt = opt || {};
      var headers = opt.headers || {};
      var init = {
        credentials: 'include',
        method: opt.method || 'GET',
        headers: headers,
        redirect: 'follow'
      };
      if (opt.body !== undefined && opt.body !== null && opt.body !== '') {
        init.body = (typeof opt.body === 'string') ? opt.body : JSON.stringify(opt.body);
        var hasCt = false;
        for (var k in headers) { if (k.toLowerCase() === 'content-type') hasCt = true; }
        if (!hasCt) headers['Content-Type'] = 'application/json';
      }
      return fetch(url, init).then(function (res) {
        var type = '';
        try { type = res.headers.get('content-type') || ''; } catch (e) {}
        var isText = /json|text|xml|javascript|x-www-form-urlencoded|csv|html/
          .test(type.toLowerCase());
        if (isText) {
          return res.text().then(function (t) {
            return {
              ok: res.ok, status: res.status, type: type,
              size: t.length, text: str(t, 2000000)
            };
          });
        }
        return res.arrayBuffer().then(function (b) {
          var bytes = new Uint8Array(b);
          var bin = '';
          for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
          return {
            ok: res.ok, status: res.status, type: type,
            size: bytes.length, b64: btoa(bin)
          };
        });
      }, function (e) {
        return { ok: false, status: 0, type: '', size: 0, text: '', error: String(e) };
      });
    },

    // ---- 元素 ----
    find: function (sel, wantText, index) {
      var r = resolve(sel, wantText, index);
      if (!r.el) return JSON.stringify({ found: false, count: r.count });
      return JSON.stringify({
        found: true, count: r.count, info: describe(r.el), rect: rectOf(r.el)
      });
    },
    click: function (sel, wantText, index) {
      var r = resolve(sel, wantText, index);
      if (!r.el) return JSON.stringify({ ok: false, code: 'NO_ELEMENT', count: r.count });
      var el = r.el;
      if (el.disabled) {
        return JSON.stringify({ ok: false, code: 'DISABLED', info: describe(el) });
      }
      var before = location.href;
      try { if (el.focus) el.focus(); } catch (e) {}
      try { el.click(); }
      catch (e) {
        return JSON.stringify({
          ok: false, code: 'JS_CLICK_THREW', error: String(e),
          info: describe(el), rect: rectOf(el)
        });
      }
      return JSON.stringify({
        ok: true, info: describe(el), rect: rectOf(el),
        urlBefore: before, urlAfter: location.href
      });
    },
    type: function (sel, value, submit) {
      var r = resolve(sel, null, 0);
      if (!r.el) return JSON.stringify({ ok: false, code: 'NO_ELEMENT', count: r.count });
      var el = r.el;
      try { if (el.focus) el.focus(); } catch (e) {}
      var wrote = false;
      if (el.isContentEditable) {
        el.textContent = value;
        wrote = true;
      } else {
        wrote = setValue(el, value);
      }
      // input + change 都要发：只改 value 不发事件，页面的校验和
      // "提交"按钮的启用状态都不会更新（表现就是"填了但发不出去"）。
      fire(el, 'input');
      fire(el, 'change');
      if (submit) {
        try {
          var f = el.form;
          if (f && f.requestSubmit) f.requestSubmit();
          else if (f) f.submit();
          else if (el.dispatchEvent) {
            el.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Enter' }));
          }
        } catch (e) {}
      }
      return JSON.stringify({
        ok: wrote, info: describe(el), value: str(el.value, 120)
      });
    },
    select: function (sel, value, label, index) {
      var r = resolve(sel, null, 0);
      if (!r.el) return JSON.stringify({ ok: false, code: 'NO_ELEMENT', count: r.count });
      var el = r.el;
      if (el.tagName !== 'SELECT') {
        return JSON.stringify({ ok: false, code: 'NOT_A_SELECT', info: describe(el) });
      }
      var idx = -1;
      for (var i = 0; i < el.options.length; i++) {
        var o = el.options[i];
        if ((value && o.value === value) || (label && text(o) === label)) { idx = i; break; }
      }
      if (idx < 0 && index !== null && index !== undefined && index !== '') idx = index | 0;
      if (idx < 0 || idx >= el.options.length) {
        return JSON.stringify({
          ok: false, code: 'NO_OPTION',
          options: Array.prototype.slice.call(el.options).slice(0, 20).map(function (o) {
            return { value: o.value, text: text(o) };
          })
        });
      }
      el.selectedIndex = idx;
      fire(el, 'input');
      fire(el, 'change');
      return JSON.stringify({ ok: true, value: el.value, text: text(el.options[idx]) });
    },
    press: function (key) {
      var el = document.activeElement || document.body;
      var codes = {
        Enter: 13, Escape: 27, Tab: 9, Backspace: 8,
        ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39
      };
      var ok = true;
      try {
        ['keydown', 'keypress', 'keyup'].forEach(function (kind) {
          el.dispatchEvent(new KeyboardEvent(kind, {
            bubbles: true, cancelable: true, key: key,
            code: key, keyCode: codes[key] || 0
          }));
        });
      } catch (e) { ok = false; }
      return JSON.stringify({ ok: ok, active: describe(el) });
    },
    scroll: function (to, times, step) {
      var before = window.scrollY;
      var n = times || 1;
      for (var i = 0; i < n; i++) {
        if (to === 'bottom') window.scrollTo(0, document.body.scrollHeight);
        else if (to === 'top') window.scrollTo(0, 0);
        else window.scrollBy(0, (to === 'down' ? 1 : -1) * (step || window.innerHeight * 0.9));
      }
      var doc = document.documentElement;
      return JSON.stringify({
        ok: true, before: before, after: window.scrollY,
        height: Math.max(doc.scrollHeight, document.body ? document.body.scrollHeight : 0),
        viewport: window.innerHeight
      });
    },
    // 一键把文件框填上。`DataTransfer` 是唯一能写 `input.files` 的路 ——
    // 直接赋值会被忽略（files 是只读的 FileList）。
    setFiles: function (sel, files, index) {
      var r = resolve(sel || 'input[type=file]', null, index || 0);
      if (!r.el) return JSON.stringify({ ok: false, code: 'NO_ELEMENT', count: r.count });
      var dt = new DataTransfer();
      for (var i = 0; i < files.length; i++) {
        var bin = atob(files[i].b64);
        var bytes = new Uint8Array(bin.length);
        for (var j = 0; j < bin.length; j++) bytes[j] = bin.charCodeAt(j);
        dt.items.add(new File([bytes], files[i].name,
          { type: files[i].type || 'application/octet-stream' }));
      }
      r.el.files = dt.files;
      fire(r.el, 'input');
      fire(r.el, 'change');
      return JSON.stringify({ ok: true, count: dt.files.length, info: describe(r.el) });
    },
    // 单次条件求值：`wait_for` 靠它轮询（比"等固定秒数"准得多）
    probe: function (cond) {
      cond = cond || {};
      var out = {
        url: location.href,
        title: document.title || '',
        ready: document.readyState
      };
      if (cond.selector) {
        out.selectorCount = all(cond.selector).filter(shown).length;
      }
      if (cond.text) {
        var body = document.body ? (document.body.innerText || '') : '';
        out.textFound = body.indexOf(cond.text) >= 0;
      }
      if (cond.js) {
        try { out.jsTrue = !!eval(cond.js); } catch (e) { out.jsError = String(e); }
      }
      return JSON.stringify(out);
    }
  };
})()
''';

/// 把结果落盘（工作目录 + `/shared` 副本）。
///
/// 为什么每个动作都要能落盘：模型拿到的任何东西都是**上下文预算**，
/// 一份九万字符的 HTML 塞进去，后面几轮都没法聊了。落盘之后它只需要
/// 拿路径去交给 python / termux，正文留在磁盘上。
class Artifacts {
  const Artifacts._();

  /// 写文本。返回工作目录路径、`/shared` 路径（没有就 null）、字节数。
  static Future<({String path, String? shared, int bytes})> saveText(
    String workDir,
    String name,
    String text,
  ) async {
    final Directory dir = Directory('$workDir/browser');
    await dir.create(recursive: true);
    final File f = File('${dir.path}/$name');
    await f.writeAsString(text);
    return (
      path: f.path,
      shared: await copyToShared(f, name),
      bytes: text.length,
    );
  }

  /// 写字节（下载、二进制接口返回）。
  static Future<({String path, String? shared, int bytes})> saveBytes(
    String workDir,
    String name,
    List<int> bytes,
  ) async {
    final Directory dir = Directory('$workDir/browser');
    await dir.create(recursive: true);
    final File f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes);
    return (
      path: f.path,
      shared: await copyToShared(f, name),
      bytes: bytes.length,
    );
  }

  /// 往**内置 Linux 的交换目录** `/shared` 写一份副本，返回那个短路径。
  ///
  /// `workDir` 在 `/sdcard/Android/data/<包名>/files/dsh` 下 —— Linux 里
  /// 也能读到，但那条路径又长又容易拼错，模型十次有八次写不对。
  /// `/shared` 是我们自己绑的短名字（见 `LinuxRuntime.binds`）。
  ///
  /// ⚠️ `/shared` 对应的是**应用内部的 filesDir/shared**
  /// （`getApplicationSupportDirectory()` 在 Android 上就是 `filesDir`），
  /// 不是手机存储里那个 `dsh/../shared` —— 后者没被绑进 Linux，
  /// 写进去等于没写。写不成就返回 null，让调用方退回 workDir 的路径：
  /// 不因为这一步失败丢内容。
  static Future<String?> copyToShared(File src, String name) async {
    try {
      final Directory base = await getApplicationSupportDirectory();
      final Directory linuxShared = Directory('${base.path}/shared');
      await linuxShared.create(recursive: true);
      final File dst = File('${linuxShared.path}/$name');
      await src.copy(dst.path);
      return '/shared/$name';
    } catch (_) {
      return null;
    }
  }

  /// `/shared/<name>` 那一份的**绝对路径**（不存在就 null）。
  ///
  /// 给"要往聊天正文里贴图"的场景用：正文能渲染的是**绝对路径**，
  /// 而 `/shared/...` 只是内置 Linux 里的短别名 ——
  /// 它们指向同一个文件，但只有绝对路径贴进回复才会显示出图。
  /// 以前只给了 `workDir` 下面那个（外部私有目录），
  /// 模型照着写进正文，用户什么也看不到。
  static Future<String?> sharedAbsolute(String name) async {
    try {
      final Directory base = await getApplicationSupportDirectory();
      final File f = File('${base.path}/shared/$name');
      return await f.exists() ? f.path : null;
    } catch (_) {
      return null;
    }
  }
}

/// 一段结果超过这个长度就落盘、只回摘要。
///
/// 取 3500：一轮里正文和一两条接口返回都能直接看；超过这个数（HTML、
/// 长列表、大 JSON）就不是"看一眼"的量了，落盘 + 摘要更划算。
const int kResultBudget = 3500;

/// 生成一个给文件用的短时间戳名。
String stampName(String prefix, [String ext = 'txt']) {
  final String s = DateTime.now().microsecondsSinceEpoch.toString();
  return '${prefix}_${s.substring(s.length - 8)}.$ext';
}

/// 把 `evalAsync` 结果里可能出现的 `__error` 变成一句人话。
String resultError(dynamic value) {
  if (value is Map && value['__error'] != null) return '${value['__error']}';
  return '';
}

/// 两个地址是不是"同一页"（主机 + 路径；查询串和 hash 不参与）。
///
/// `swipe(trusted: true)` 靠它判断"用户那一页是不是就是这一页" ——
/// 坐标是给 agent 这页算的，手指落在另一页上等于点了个随机坐标。
bool samePageUrl(String a, String b) {
  final String x = a.trim();
  final String y = b.trim();
  if (x.isEmpty || y.isEmpty) return false;
  try {
    final Uri ua = Uri.parse(x);
    final Uri ub = Uri.parse(y);
    if (ua.host != ub.host) return false;
    final String pa = ua.path.isEmpty ? '/' : ua.path;
    final String pb = ub.path.isEmpty ? '/' : ub.path;
    return pa == pb;
  } catch (_) {
    return x == y;
  }
}

/// 把 JS 返回的 JSON 字符串解析成 Map（拿不到就返回空 Map）。
Map<String, dynamic> asMap(String raw) {
  final String s = WebViewLoader.unwrapJsString(raw).trim();
  if (s.isEmpty) return <String, dynamic>{};
  try {
    final dynamic j = jsonDecode(s);
    if (j is Map) return Map<String, dynamic>.from(j);
  } catch (_) {
    // 不是 JSON（页面把结果包成了普通字符串）—— 交给调用方的兜底分支
  }
  return <String, dynamic>{};
}

/// 从**已经是 Map** 的值里取一个子对象（拿不到就返回空 Map）。
///
/// 和 [asMap] 是两件事，别混：`asMap` 吃的是 **JSON 字符串**（页面 eval 回来
/// 的那种），这里是**已经解析好的 Map 字段**。
///
/// 混用会炸得很难看：把 Map 传给 `asMap(String)` 是隐式向下转型，
/// 运行时报 `type '_Map<String, dynamic>' is not a subtype of type 'String'`
/// —— 这句 Dart 原生错误直接冒到 agent 面前，它既看不懂也修不了，
/// 只能反复重试同一个调用。（这一版之前，**每一次坐标点击**都会这样炸。）
Map<String, dynamic> mapOf(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// 包围盒 → `(x,y w×h)`（拿不到就空串）。
///
/// 只读那四个数，别的一概不管：页面里各处传回来的矩形字段名不完全一样，
/// 而且模型更需要的是"能不能看见这个数"，不是"它长什么样"。
String rectText(dynamic v) {
  final Map<String, dynamic> r = mapOf(v);
  if (r.isEmpty) return '';
  final Object? x = r['x'];
  final Object? y = r['y'];
  final Object? w = r['w'];
  final Object? h = r['h'];
  if (x == null && y == null && w == null && h == null) return '';
  return '(${x ?? '?'},${y ?? '?'} ${w ?? '?'}×${h ?? '?'})';
}

/// 读一个数（模型给字符串、给 null 都不该炸）。
///
/// **不要**在参数上写 `as num`：模型把坐标写成 `"527"` 或者
/// 给个对象都是常事，`as` 会直接抛原生异常，而那种异常对 agent 毫无信息量。
double? numOf(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString().trim() ?? '');
}

/// 二进制转 base64（分块拼接）。
///
/// 一次 `base64Encode` 一个大文件，会在内存里同时留着原数据和两倍大的
/// base64 字符串；分块之后峰值低得多，几 MB 的文件也不会把内存顶爆。
String bytesToBase64Chunked(List<int> bytes) {
  final Uint8List data = Uint8List.fromList(bytes);
  final StringBuffer sb = StringBuffer();
  // 必须是 3 的倍数：base64 按 3 字节一组编码，断了会对不上。
  const int chunk = 3 * 4096;
  for (int i = 0; i < data.length; i += chunk) {
    final int end = (i + chunk < data.length) ? i + chunk : data.length;
    sb.write(base64Encode(Uint8List.sublistView(data, i, end)));
  }
  return sb.toString();
}
