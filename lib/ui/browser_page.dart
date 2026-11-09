import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_nav.dart';
import '../core/store.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../tools/web_session.dart';
import '../tools/webview_loader.dart';

/// 应用内浏览器。
///
/// 用途：从聊天里的网页卡片点开、预览 AI 给出的链接、
/// 或者需要登录/交互才能看到内容的页面（抓取拿不到时用它人工看一眼）。
///
/// 刻意做成「真实的浏览器」而不是只读渲染：
/// 带地址栏、前进后退、刷新、外部打开。很多页面需要滚动和点击才有内容。
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.initialUrl, this.title});

  final String initialUrl;
  final String? title;

  static Future<void> open(
    BuildContext context, {
    required String url,
    String? title,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => BrowserPage(initialUrl: url, title: title),
      ),
    );
  }

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  InAppWebViewController? _controller;
  late final TextEditingController _urlField;

  double _progress = 0;
  bool _loading = true;

  /// 当前用哪套 UA。**它同时是 WebView 的 key 的一部分** ——
  /// 见下面 `InAppWebView` 那里为什么必须重建。
  late bool _desktopUa = WebViewLoader.useDesktopUa;
  String _currentUrl = '';
  String _pageTitle = '';
  bool _canBack = false;
  bool _canForward = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _pageTitle = widget.title ?? '';
    _urlField = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _urlField.dispose();
    // 这一页要没了 → 把"当前页"的登记撤掉。
    // 不清的话 agent 会拿着一个已经销毁的控制器去执行 JS，
    // 报出来的错和"页面没打开"完全联系不上。
    WebViewLoader.setLive(null);
    // 同时把输入框上方那行「AI 打开了 xxx」也收掉 ——
    // 用户关掉浏览器就是"这件事结束了"，那行提示再留着只会一直占位置
    // （用户的原话："网页支持退出啊，不然一直显示在输入框上边"）。
    WebViewLoader.endActivity();
    super.dispose();
  }

  void _navigate(String raw) {
    String u = raw.trim();
    if (u.isEmpty) return;
    // 容忍直接输入域名
    if (!u.contains('://')) u = 'https://$u';
    final Uri? uri = Uri.tryParse(u);
    if (uri == null || !uri.hasScheme) return;
    _controller?.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
  }

  Future<void> _syncNavState(InAppWebViewController c) async {
    final bool back = await c.canGoBack();
    final bool fwd = await c.canGoForward();
    if (mounted) {
      setState(() {
        _canBack = back;
        _canForward = fwd;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);
    final double topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: s.pageBg,
      body: Column(
        children: <Widget>[
          GlassBar(
            hairlineBottom: true,
            padding: EdgeInsets.fromLTRB(10, topInset + 6, 12, 8),
            child: Row(
              children: <Widget>[
                GlassIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  size: 34,
                  iconSize: 18,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      // 地址栏是"输入框"，不是卡片：用 codeBg 让它从顶栏
                      // 的暖纸上凹下去一档，输入区的身份一眼能看出来。
                      color: s.codeBg,
                      borderRadius: BorderRadius.circular(AppRadius.field),
                      border: Border.all(color: s.border, width: 0.9),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: _urlField,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _navigate,
                      style: AppFonts.body(size: 13.5, color: s.text),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: '输入网址',
                        hintStyle: AppFonts.body(size: 13.5, color: s.muted),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: Icons.open_in_new_rounded,
                  tooltip: '用系统浏览器打开',
                  size: 34,
                  iconSize: 17,
                  onTap: () async {
                    final Uri? uri = Uri.tryParse(_currentUrl);
                    if (uri == null) return;
                    try {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    } catch (_) {
                      // 忽略
                    }
                  },
                ),
              ],
            ),
          ),
          if (_loading && _progress < 1)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: AppColors.accent,
            ),
          Expanded(
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  // ---- 为什么这里要一个 key ----
                  //
                  // **UA 是建 WebView 时定死的**，`reload()` 改不了它 ——
                  // 换句话说"切换 UA 之后 reload 一下"这种写法点了等于没点。
                  // 换 key 会让这一层**整个重建**：旧的销毁，新的按新的
                  // initialSettings 建出来，登录态在 cookie 库里不受影响。
                  // （用户报的"桌面端显示不可用"就是这个 —— 点了没反应。）
                  key: ValueKey<bool>(_desktopUa),
                  initialUrlRequest: URLRequest(
                    url: WebUri(
                      _currentUrl.isEmpty ? widget.initialUrl : _currentUrl,
                    ),
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    mediaPlaybackRequiresUserGesture: true,
                    // 第三方 cookie：SSO 登录是"从 A 站跳 B 站授权再跳回来"，
                    // 关着的话授权那一步的 cookie 写不进去，登录态断在半路。
                    thirdPartyCookiesEnabled: true,
                    useShouldInterceptRequest: false,
                    userAgent: WebViewLoader.userAgent,
                  ),
                  // **和 agent 那一页用同一套注入脚本**：这样用户在页面上
                  // 点的按钮、触发的接口，agent 之后也能看见
                  // （"用户点了导出、AI 去把那个文件取回来"）。
                  initialUserScripts: UnmodifiableListView<UserScript>(
                    <UserScript>[bootstrapScript],
                  ),
                  onWebViewCreated: (InAppWebViewController c) {
                    _controller = c;
                    // **把这一页交给 agent**：`browser` 工具的
                    // dom / cookies / js / screenshot 四个动作在 url 留空时
                    // 就作用于它 —— 读用户正在看的这一页。
                    // 不注册的话，agent 只能自己无头重开一遍：
                    // 那会丢掉登录态，也看不到用户在页面上做过的事。
                    WebViewLoader.setLive(c);
                    // cookie 落盘一次：不落盘的话，用户刚登录完、
                    // 进程就被系统杀掉时，那份会话会丢。
                    unawaited(WebSession.instance.flushCookies());
                  },
                  // 下载：别让 WebView 自己的下载器去下（它不认我们的
                  // cookie 和 UA，拿到的是"请先登录"的一页 HTML）。
                  // 记下来交给 `browser` 工具的 download 动作，带 cookie 重下。
                  onDownloadStartRequest:
                      (InAppWebViewController c, DownloadStartRequest req) {
                        WebSession.instance.rememberDownload(req);
                        if (mounted) {
                          setState(() {}); // 让"可下载"的提示浮出来
                        }
                      },
                  // 原生弹窗：确认框必须有人答，否则页面逻辑停在那儿。
                  // 默认**取消**（替用户点"确定删除"是不可接受的），
                  // 要改成"确定"由 agent 用 `dialog` 动作预设。
                  onJsAlert:
                      (InAppWebViewController c, JsAlertRequest req) async {
                        WebSession.instance.noteDialog(
                          'alert',
                          req.message ?? '',
                        );
                        return JsAlertResponse(
                          action: JsAlertResponseAction.CONFIRM,
                          message: req.message ?? '',
                        );
                      },
                  onJsConfirm:
                      (InAppWebViewController c, JsConfirmRequest req) async {
                        final bool ok = WebSession.instance.takePresetAnswer();
                        WebSession.instance.noteDialog(
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
                  onLoadStart: (InAppWebViewController c, WebUri? uri) {
                    if (!mounted) return;
                    setState(() {
                      _loading = true;
                      _error = null;
                      if (uri != null) {
                        _currentUrl = uri.toString();
                        _urlField.text = _currentUrl;
                      }
                    });
                    if (uri != null) {
                      WebViewLoader.setLive(c, url: uri.toString());
                    }
                  },
                  onLoadStop: (InAppWebViewController c, WebUri? uri) async {
                    if (!mounted) return;
                    setState(() {
                      _loading = false;
                      if (uri != null) {
                        _currentUrl = uri.toString();
                        _urlField.text = _currentUrl;
                      }
                    });
                    final String? t = await c.getTitle();
                    if (mounted && t != null && t.isNotEmpty) {
                      setState(() => _pageTitle = t);
                    }
                    await _syncNavState(c);
                  },
                  onProgressChanged: (InAppWebViewController c, int p) {
                    if (!mounted) return;
                    setState(() => _progress = p / 100);
                  },
                  onReceivedError:
                      (
                        InAppWebViewController c,
                        WebResourceRequest req,
                        WebResourceError err,
                      ) {
                        // 只有主文档失败才提示；子资源失败很常见，不用打扰用户
                        if (req.isForMainFrame == true && mounted) {
                          setState(() {
                            _loading = false;
                            _error = err.description;
                          });
                        }
                      },
                ),
                if (_error != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: SurfaceCard(
                      color: AppColors.danger.withValues(alpha: 0.10),
                      borderColor: AppColors.danger.withValues(alpha: 0.30),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.error_outline_rounded,
                            size: 16,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '加载失败：$_error',
                              style: AppFonts.body(
                                size: 12.5,
                                color: AppColors.danger,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          GlassBar(
            hairlineTop: true,
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              8 + MediaQuery.of(context).padding.bottom,
            ),
            child: Row(
              children: <Widget>[
                BackButton(
                  onPressed: _canBack
                      ? () async {
                          await _controller?.goBack();
                          if (_controller != null) {
                            await _syncNavState(_controller!);
                          }
                        }
                      : null,
                ),
                const SizedBox(width: 16),
                GlassIconButton(
                  icon: Icons.arrow_forward_rounded,
                  tooltip: '前进',
                  size: 36,
                  iconSize: 18,
                  onTap: _canForward
                      ? () async {
                          await _controller?.goForward();
                          if (_controller != null) {
                            await _syncNavState(_controller!);
                          }
                        }
                      : null,
                ),
                const SizedBox(width: 16),
                GlassIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: '刷新',
                  size: 36,
                  iconSize: 18,
                  onTap: () => _controller?.reload(),
                ),
                const SizedBox(width: 16),
                // ---- 停止：告诉 agent"别再往下做了" ----
                //
                // 为什么需要一个**单独的按钮**：agent 操作这一页可能连着几步
                // （滚动 → 点击 → 读结果），而用户常常是在看它点错地方的**那一刻**
                // 才发现不对。那时他需要立刻能按下去，让 agent 知道停下，
                // 而不是把后面几步做完再说。
                //
                // 人机协作里"我喊停它听不见"是最让人不敢放手的一件事 ——
                // 有了这个按钮，用户才敢让 agent 去点。
                // （工具侧每一步动作前都会查一次这个标记，见 browser_tool。）
                GlassIconButton(
                  icon: Icons.pan_tool_alt_rounded,
                  tooltip: '停止 AI 的浏览器操作',
                  size: 36,
                  iconSize: 18,
                  onTap: () {
                    WebViewLoader.requestStop();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已请求停止：AI 会在下一步停下来'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 16),
                // ---- 手机版 / 桌面版切换 ----
                //
                // 为什么放在这一页而不是只在设置里：**要切换的场合就在这里**
                // —— 桌面版发的是完整内容，手机版是精简页（正文被砍、
                // 要点"展开全文"）。用户是在看着这一页的时候发现"这页不对"
                // 才想切的；让他退出浏览器、进设置、再回来，那是三次导航。
                //
                // 切换会**改写全局设置**（不只是这一页）：同一个开关在
                // 设置里也能改，两处必须是同一个值 —— 否则"我在浏览器里
                // 切成桌面版了，为什么 AI 抓回来的还是手机版"。
                GlassIconButton(
                  icon: _desktopUa
                      ? Icons.desktop_windows_outlined
                      : Icons.smartphone_rounded,
                  tooltip: _desktopUa ? '当前：桌面版（点切换回手机版）' : '当前：手机版（点切换到桌面版）',
                  size: 36,
                  iconSize: 18,
                  onTap: () async {
                    final bool next = !_desktopUa;
                    WebViewLoader.useDesktopUa = next;
                    // 写回全局设置（见 `appSettings` 的说明）——
                    // 这一页是被推上来的，构造函数里拿不到 Settings。
                    final Settings? st = appSettings;
                    if (st != null) {
                      await st.update(() => st.desktopUa = next);
                    }
                    if (!mounted) return;
                    // 改 `_desktopUa` 就够了：它是上面 WebView 的 key 的一部分，
                    // 变了就会**重建** WebView（旧的销毁、新的带新 UA 建出来，
                    // 并且从当前地址重新加载）。所以这里**不要**再调 reload() ——
                    // 那是对旧 WebView 下的命令，白跑一次。
                    setState(() => _desktopUa = next);
                  },
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _pageTitle.isEmpty ? _currentUrl : _pageTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.body(size: 12, color: s.muted, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 浏览器入口的**首页**：跟随用户在设置里选的搜索引擎。
///
/// ## 为什么不能是 `about:blank`
///
/// 一开始图省事用的是 `about:blank`（网址栏就在那儿等他输）——
/// 结果是：从菜单点进浏览器，看到的是一张**白纸**，用户的判断是
/// "浏览器坏了"。空页面在浏览器里不是"准备就绪"，是"没加载出来"。
///
/// 跟随搜索引擎是因为那本来就是用户选过的偏好（抓取用的那个引擎），
/// 而且它一定在他的网络里能用（连不上他就不会选它）。
String browserHomeUrl(String searchEngine) => switch (searchEngine) {
  'baidu' => 'https://www.baidu.com',
  'google' => 'https://www.google.com',
  'duckduckgo' => 'https://duckduckgo.com',
  _ => 'https://www.bing.com',
};
