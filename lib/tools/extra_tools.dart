import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;

import '../core/metrics.dart';
import '../core/models.dart';
import '../core/net_error.dart';
import '../core/scrub.dart';
import 'browser_tool.dart';
import 'tool.dart';
import 'vision_image.dart';

/// 联网：搜索 + 抓取网页。
///
/// 有搜索 API key 时走 Tavily（结果质量好）；
/// 没配置时退化为 DuckDuckGo 的轻量 HTML 页面解析——不需要 key，
/// 但属于 best-effort，页面结构一变就可能失效，所以失败时会明确说明原因，
/// 而不是静默返回空。
class WebTool extends AgentTool {
  const WebTool();

  @override
  String get name => 'web';

  @override
  String get title => '联网';

  @override
  String get description =>
      '联网获取信息。action：'
      'search（按关键词搜索，返回标题/链接/摘要）、'
      'fetch（抓取指定网址的正文文本）。'
      '注意：未配置搜索 API Key 时只能拿到「即时答案」（百科、词条类），'
      '普通关键词的覆盖有限；fetch 则不受此限制，可以直接读任意网页。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>['search', 'fetch'],
      },
      'query': <String, dynamic>{
        'type': 'string',
        'description': 'search 的关键词',
      },
      'url': <String, dynamic>{'type': 'string', 'description': 'fetch 的完整网址'},
      'limit': <String, dynamic>{
        'type': 'integer',
        'description': 'search 返回条数，默认 5',
      },
    },
    'required': <String>['action'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) {
    return args.str('action') == 'search'
        ? '搜索 ${args.str('query')}'
        : '抓取 ${args.str('url')}';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String action = args.str('action');

    if (action == 'fetch') {
      final String url = args.str('url').trim();
      if (url.isEmpty) return '错误：缺少 url';
      return _fetch(ctx, url);
    }

    if (action == 'search') {
      final String query = args.str('query').trim();
      if (query.isEmpty) return '错误：缺少 query';
      final int limit = args.intVal('limit', fallback: 5).clamp(1, 10);
      return _search(ctx, query, limit);
    }

    return '错误：未知 action「$action」';
  }

  /// 按「联网方式」设置选择通道，并在失败时依次降级。
  ///
  /// 顺序有讲究：服务端搜索最快且不受反爬影响，但**能否生效存疑**
  /// （官方 Tools 表把 web_search 标为「忽略」），所以放在最前面试一次，
  /// 用「响应里有没有 web_search_call」来判断真假，不成就往下走。
  /// 带缓存的外层入口。
  ///
  /// agent 很常把相近的问题问两遍（先搜一次、再确认一次），
  /// 而这些通道最慢的能跑到几十秒。缓存能把整条链路直接跳过。
  Future<String> _search(ToolContext ctx, String query, int limit) async {
    final String key =
        '$query|$limit|${ctx.webSearchMode}|${ctx.selfHostedSearchUrl}|${ctx.searchEngine}';

    final String? cached = _SearchCache.get(key);
    if (cached != null) {
      // 命中率埋点：以前这个计数**从来没有被调用过**，性能面板里
      // 永远显示"还没有搜索过"（用户反馈"命中率查不出来"）。
      AppMetrics.instance.recordSearchCache(hit: true);
      return '（缓存结果，未重新联网）\n\n$cached';
    }
    AppMetrics.instance.recordSearchCache(hit: false);

    final String result = await _searchUncached(ctx, query, limit);

    // 只缓存成功的结果。失败往往是瞬时的（网络抖动、对方限流），
    // 缓存下来会导致用户重试也没用，反而更难恢复。
    final bool failed =
        result.startsWith('以下通道都没成功') ||
        result.startsWith('错误：') ||
        result.startsWith('搜索失败') ||
        result.startsWith('搜索出错');
    if (!failed) _SearchCache.put(key, result);

    return result;
  }

  Future<String> _searchUncached(
    ToolContext ctx,
    String query,
    int limit,
  ) async {
    final List<String> tried = <String>[];

    // ---------- 1) Tavily（有 Key 用 Key，没 Key 走免 key 模式）----------
    //
    // **无条件调用**：以前这里判断"填了 Key 才走"，导致没配 Key 的用户
    // 直接跳到注定失败的 DuckDuckGo。而 Tavily 的免 key 模式不需要任何配置，
    // 实测国内直连可达 —— 它应该是默认的第一选择，不是可选项。
    {
      final String r = await _tavily(ctx, query, limit);
      if (!r.startsWith('搜索失败') && !r.startsWith('搜索出错')) return r;
      tried.add('Tavily：${r.split('\n').first}');
    }

    // ---------- 2) 内置浏览器（百度优先）----------
    //
    // 这条**必须放在 DuckDuckGo 之前**。
    //
    // 原来这里直接调 DDG 的 HTTP 兜底，但 DDG 在国内连 DNS 都解析不了，
    // 每次都是白等一趟超时；而内置浏览器走百度是能**立刻出结果**的那条。
    // 更糟的是 `web` 和 `browser` 各有一条独立的兜底链，
    // 模型先调 `web` 就会撞上 DDG 这条死路，再调 `browser` 才拿到结果 ——
    // 用户看到的就是"能出结果，但先白跑了一趟"。
    //
    // 复用同一个 BrowserTool 就消除了这个分裂：两条路最终落到同一套引擎。
    final String viaBrowser = await const BrowserTool().run(
      ctx,
      <String, dynamic>{'action': 'search', 'query': query, 'limit': limit},
    );

    if (!viaBrowser.startsWith('搜索失败') && !viaBrowser.startsWith('搜索出错')) {
      return viaBrowser;
    }
    tried.add('内置浏览器：${viaBrowser.split('\n').first}');

    // ---------- 3) DuckDuckGo 兜底（国内基本不可用，留着以防换网络）----------
    final String browser = await _ddg(query, limit);
    final ScrubResult cleaned = PromptScrubber.scrub(browser);
    final String safeBrowser = cleaned.clean
        ? browser
        : '$browser\n\n⚠ ${cleaned.summary}';

    if (tried.isEmpty) return safeBrowser;

    // 前面几层都失败时，把「尝试过什么」一并带上，否则用户只看到最后一层的报错，
    // 会以为根本没试过其它通道。
    return '以下通道都没成功：\n${tried.join('\n')}\n\n'
        '最后一次尝试（DuckDuckGo 兜底）：\n$safeBrowser';
  }

  // ------------------------------------------------------------ Tavily

  Future<String> _tavily(ToolContext ctx, String query, int limit) async {
    // 有 Key 用 Key，没 Key 用 **keyless 模式**。
    //
    // Tavily 提供免 key 访问：加一个 `X-Tavily-Access-Mode: keyless` 头即可，
    // 不需要账号、不需要配置，返回结构和带 Key 完全一致。
    // 实测国内**直连可达**（HTTP 200），不需要代理 —— 这一点很关键：
    // 它是唯一一条不依赖手机网络能翻墙的搜索通道。
    //
    // 额度用完后接口会返回一段自然语言说明，这里原样带出去，用户能看懂。
    final bool keyless = ctx.searchApiKey.trim().isEmpty;

    try {
      final http.Response resp = await http
          .post(
            Uri.parse('https://api.tavily.com/search'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              if (keyless) 'X-Tavily-Access-Mode': 'keyless',
            },
            body: jsonEncode(<String, dynamic>{
              if (!keyless) 'api_key': ctx.searchApiKey,
              'query': query,
              'max_results': limit,
              'include_answer': true,
            }),
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode != 200) {
        final String detail = clampOutput(resp.body, max: 400);
        if (resp.statusCode == 429 || detail.toLowerCase().contains('rate')) {
          return '搜索失败：免费额度已用完。\n$detail\n\n'
              '（免 Key 模式是限流的。去 app.tavily.com 注册可拿 1000 次/月，'
              '把 Key 填进「设置 → 联网」即可，代码不用改。）';
        }
        return '搜索失败：HTTP ${resp.statusCode}\n$detail';
      }

      final Map<String, dynamic> j =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      final StringBuffer sb = StringBuffer();
      final dynamic answer = j['answer'];
      if (answer is String && answer.trim().isNotEmpty) {
        sb.writeln('摘要：${answer.trim()}\n');
      }

      final List<dynamic> results =
          (j['results'] as List<dynamic>?) ?? <dynamic>[];
      for (int i = 0; i < results.length; i++) {
        final Map<String, dynamic> r = Map<String, dynamic>.from(
          results[i] as Map,
        );
        sb.writeln('[${i + 1}] ${r['title']}');
        sb.writeln('    ${r['url']}');
        final dynamic c = r['content'];
        if (c is String && c.trim().isNotEmpty) {
          sb.writeln('    ${c.trim()}');
        }
        sb.writeln();
      }

      return sb.isEmpty ? '没有找到结果' : clampOutput(sb.toString());
    } catch (e) {
      return '搜索出错：$e';
    }
  }

  // ------------------------------------------------------- 无 key 时的兜底搜索

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0 Mobile Safari/537.36';

  /// 没配置搜索 API key 时的兜底。
  ///
  /// 依次尝试 DuckDuckGo 的两个端点，因为：
  ///  · `lite` 是给低带宽/无 JS 环境用的，结构极简，最不容易被改版打断；
  ///  · `html` 端点在改版或限流时经常返回拦截页。
  /// 两个都拿不到结果时，会把**具体原因**回报给模型，而不是笼统说「失败」，
  /// 这样它能直接告诉用户该怎么办。
  Future<String> _ddg(String query, int limit) async {
    final List<String> notes = <String>[];

    // 1) 官方 Instant Answer API —— 实测唯一可用的免 key 通道。
    final String? instant = await _tryInstantAnswer(query, limit, notes);
    if (instant != null) return instant;

    // 2) 网页抓取。实测已被 DuckDuckGo 封死（202 + anomaly 页、零结果），
    //    保留代码只是为了万一哪天恢复，不作为可依赖的路径。
    final String? lite = await _tryLite(query, limit, notes);
    if (lite != null) return lite;

    final String? html = await _tryHtml(query, limit, notes);
    if (html != null) return html;

    return '搜索失败。${notes.isEmpty ? '' : '\n原因：${notes.join('；')}'}\n'
        '免 key 通道只能拿到「即时答案」（百科、词条、定义类），对普通关键词覆盖有限；'
        'DuckDuckGo 的网页抓取已不可用。'
        '想要稳定的通用搜索，请在「设置 → 联网」里填一个 Tavily API Key。';
  }

  /// DuckDuckGo 官方 Instant Answer API（无需 key）。
  ///
  /// 局限要说清楚：它是「即时答案」而不是通用网页搜索，
  /// 偏实体/词条/定义类查询；问「XX 怎么配置」这种长尾问题往往没有结果。
  /// 但它是免 key 场景下唯一实测可用的通道，所以作为主力兜底。
  Future<String?> _tryInstantAnswer(
    String query,
    int limit,
    List<String> notes,
  ) async {
    try {
      final Uri uri = Uri.parse(
        'https://api.duckduckgo.com/?q=${Uri.encodeComponent(query)}'
        '&format=json&no_html=1&skip_disambig=1&t=dsh-agent',
      );

      final http.Response resp = await http
          .get(uri, headers: <String, String>{'User-Agent': _ua})
          .timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) {
        notes.add('即时答案 API HTTP ${resp.statusCode}');
        return null;
      }

      final Map<String, dynamic> j =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      final StringBuffer sb = StringBuffer();
      int n = 0;

      final String heading = j['Heading']?.toString() ?? '';
      final String abstractText = j['AbstractText']?.toString() ?? '';
      final String abstractUrl = j['AbstractURL']?.toString() ?? '';
      final String source = j['AbstractSource']?.toString() ?? '';

      if (abstractText.trim().isNotEmpty) {
        n++;
        sb.writeln(
          '[1] ${heading.isEmpty ? query : heading}'
          '${source.isEmpty ? '' : '（$source）'}',
        );
        if (abstractUrl.isNotEmpty) sb.writeln('    $abstractUrl');
        sb.writeln('    $abstractText');
        sb.writeln();
      }

      for (final dynamic item
          in (j['Results'] as List<dynamic>?) ?? <dynamic>[]) {
        if (n >= limit) break;
        final Map<String, dynamic> m = Map<String, dynamic>.from(item as Map);
        final String text = m['Text']?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        n++;
        sb.writeln('[$n] $text');
        final String url = m['FirstURL']?.toString() ?? '';
        if (url.isNotEmpty) sb.writeln('    $url');
        sb.writeln();
      }

      // RelatedTopics 里有些条目是分组（带嵌套 Topics），要摊平
      for (final dynamic item
          in (j['RelatedTopics'] as List<dynamic>?) ?? <dynamic>[]) {
        if (n >= limit) break;
        final Map<String, dynamic> m = Map<String, dynamic>.from(item as Map);

        final dynamic nested = m['Topics'];
        if (nested is List) {
          for (final dynamic sub in nested) {
            if (n >= limit) break;
            final Map<String, dynamic> sm = Map<String, dynamic>.from(
              sub as Map,
            );
            final String text = sm['Text']?.toString() ?? '';
            if (text.trim().isEmpty) continue;
            n++;
            sb.writeln('[$n] $text');
            final String url = sm['FirstURL']?.toString() ?? '';
            if (url.isNotEmpty) sb.writeln('    $url');
            sb.writeln();
          }
          continue;
        }

        final String text = m['Text']?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        n++;
        sb.writeln('[$n] $text');
        final String url = m['FirstURL']?.toString() ?? '';
        if (url.isNotEmpty) sb.writeln('    $url');
        sb.writeln();
      }

      if (n == 0) {
        notes.add('即时答案 API 无结果');
        return null;
      }

      return clampOutput('（来源：DuckDuckGo 即时答案）\n\n${sb.toString()}');
    } catch (e) {
      notes.add('即时答案 API 异常：$e');
      return null;
    }
  }

  Future<String?> _tryLite(String query, int limit, List<String> notes) async {
    try {
      final http.Response resp = await http
          .get(
            Uri.parse(
              'https://lite.duckduckgo.com/lite/?q=${Uri.encodeComponent(query)}',
            ),
            headers: <String, String>{'User-Agent': _ua},
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode != 200) {
        notes.add('lite 端点 HTTP ${resp.statusCode}');
        return null;
      }

      final String body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (_looksBlocked(body)) {
        notes.add('lite 端点被拦截');
        return null;
      }

      // lite 的结构：标题在 <a class="result-link">，摘要在紧随的
      // <td class="result-snippet"> 里，两者按顺序一一对应。
      final RegExp linkRe = RegExp(
        r'''<a[^>]*class=['"]result-link['"][^>]*href=['"]([^'"]+)['"][^>]*>(.*?)</a>''',
        dotAll: true,
        caseSensitive: false,
      );
      final RegExp snipRe = RegExp(
        r'''<td[^>]*class=['"]result-snippet['"][^>]*>(.*?)</td>''',
        dotAll: true,
        caseSensitive: false,
      );

      final List<RegExpMatch> links = linkRe.allMatches(body).toList();
      final List<RegExpMatch> snips = snipRe.allMatches(body).toList();

      if (links.isEmpty) {
        notes.add('lite 端点未解析到结果');
        return null;
      }

      final StringBuffer sb = StringBuffer();
      sb.writeln('（来源：DuckDuckGo Lite）\n');
      final int n = links.length < limit ? links.length : limit;
      for (int i = 0; i < n; i++) {
        sb.writeln('[${i + 1}] ${_clean(links[i].group(2) ?? '')}');
        sb.writeln('    ${_clean(links[i].group(1) ?? '')}');
        if (i < snips.length) {
          sb.writeln('    ${_clean(snips[i].group(1) ?? '')}');
        }
        sb.writeln();
      }
      return clampOutput(sb.toString());
    } catch (e) {
      notes.add('lite 端点异常：$e');
      return null;
    }
  }

  Future<String?> _tryHtml(String query, int limit, List<String> notes) async {
    try {
      final http.Response resp = await http
          .get(
            Uri.parse(
              'https://html.duckduckgo.com/html/?q=${Uri.encodeComponent(query)}',
            ),
            headers: <String, String>{'User-Agent': _ua},
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode != 200) {
        notes.add('html 端点 HTTP ${resp.statusCode}');
        return null;
      }

      final String body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (_looksBlocked(body)) {
        notes.add('html 端点被拦截');
        return null;
      }

      final RegExp re = RegExp(
        r'''result__a[^>]*href=['"]([^'"]+)['"][^>]*>(.*?)</a>'''
        r'''[\s\S]*?result__snippet[^>]*>(.*?)</a>''',
        dotAll: true,
        caseSensitive: false,
      );

      final StringBuffer sb = StringBuffer();
      int n = 0;
      for (final RegExpMatch m in re.allMatches(body)) {
        if (n >= limit) break;
        n++;
        String url = m.group(1) ?? '';
        final Uri? u = Uri.tryParse(url);
        if (u != null && u.queryParameters.containsKey('uddg')) {
          url = u.queryParameters['uddg'] ?? url;
        }
        sb.writeln('[$n] ${_clean(m.group(2) ?? '')}');
        sb.writeln('    ${_clean(url)}');
        sb.writeln('    ${_clean(m.group(3) ?? '')}');
        sb.writeln();
      }

      if (n == 0) {
        notes.add('html 端点未解析到结果');
        return null;
      }
      return clampOutput('（来源：DuckDuckGo）\n\n${sb.toString()}');
    } catch (e) {
      notes.add('html 端点异常：$e');
      return null;
    }
  }

  /// DDG 在判定为机器人流量时会返回一个不含结果的提示页
  static bool _looksBlocked(String body) {
    final String b = body.toLowerCase();
    return b.contains('anomaly') ||
        b.contains('unusual traffic') ||
        (b.contains('captcha') && !b.contains('result-link'));
  }

  static String _clean(String s) {
    String out = s;
    out = out.replaceAll(RegExp(r'<[^>]+>'), '');
    out = out
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&hellip;', '…');
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ------------------------------------------------------------ fetch

  Future<String> _fetch(ToolContext ctx, String url) async {
    try {
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        return '错误：url 不合法';
      }
      final http.Response resp = await http
          .get(
            uri,
            headers: <String, String>{
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 30));

      final String body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final String text = _stripHtml(body);

      return 'HTTP ${resp.statusCode}\nURL: $url\n\n${clampOutput(text, max: 8000)}';
    } catch (e) {
      return '抓取出错：$e';
    }
  }

  static String _stripHtml(String html) {
    String s = html;
    s = s.replaceAll(
      RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
      ' ',
    );
    s = s.replaceAll(
      RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
      ' ',
    );
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'");
    s = s.replaceAll(RegExp(r'[ \t\u00A0]+'), ' ');
    s = s.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');
    return s.trim();
  }
}

/// 一个可用的视觉模型配置
class VisionTarget {
  const VisionTarget(this.baseUrl, this.apiKey, this.model, this.label);

  final String baseUrl;
  final String apiKey;
  final String model;

  /// 给人看的来源说明，会写进工具返回值
  final String label;
}

/// 按设置解析"这次该拿哪些视觉模型去试"。
///
/// ## 为什么要单独抽出来
///
/// 这里出过一次**"图像老是不走多模态、直接 OCR"**的 bug：
/// 设置页上写的是「地址/密钥留空则复用上面那条」，但代码要求
/// **地址和密钥同时非空**才认这个视觉模型 —— 用户按提示只填了模型名
/// （或只填了地址），配置就被整个跳过；主模型要是再不支持图像
/// （`deepseek-v4-pro`），候选列表直接为空，只能 OCR。
///
/// 现在的规则（缺的项一律回退主档案，和设置页的说明一致）：
///  1. 用户填过地址或密钥 → 视为自定义视觉模型，缺的项用主档案补；
///  2. 主模型声明能看图 → 也放进候选（自定义失败后还能兜底）；
///  3. 主模型不能看图 → 用主档案的地址/密钥试一次默认视觉模型
///     （`deepseek-flash`）。官方档案下这一条就是"识图专用模型"，
///     用户不用再单独配任何东西。
///
/// 同一个地址 + 模型只请求一次。
@visibleForTesting
List<VisionTarget> resolveVisionTargets({
  required String mainBaseUrl,
  required String mainApiKey,
  required String mainModel,
  required bool mainSeesImages,
  required String visionBaseUrl,
  required String visionApiKey,
  required String visionModel,
}) {
  final List<VisionTarget> out = <VisionTarget>[];
  final String mainBase = mainBaseUrl.trim();
  final String mainKey = mainApiKey.trim();
  final String vUrl = visionBaseUrl.trim();
  final String vKey = visionApiKey.trim();
  // 视觉模型名的默认值就是 deepseek-flash：留空 = "用上面那个 Flash"。
  final String vModel = visionModel.trim().isEmpty
      ? 'deepseek-flash'
      : visionModel.trim();

  void add(String base, String key, String model, String label) {
    final String b = base.trim().replaceAll(RegExp(r'/+$'), '');
    final String k = key.trim();
    final String m = model.trim();
    if (b.isEmpty || k.isEmpty || m.isEmpty) return;
    final bool dup = out.any(
      (VisionTarget t) =>
          t.baseUrl.trim().replaceAll(RegExp(r'/+$'), '') == b && t.model == m,
    );
    if (!dup) out.add(VisionTarget(b, k, m, label));
  }

  // 1) 自定义视觉模型：只填了其中一两项也算 —— 缺的按设置页的
  //    "留空则复用"回退到主档案。
  if (vUrl.isNotEmpty || vKey.isNotEmpty) {
    add(
      vUrl.isEmpty ? mainBase : vUrl,
      vKey.isEmpty ? mainKey : vKey,
      vModel,
      '自定义视觉模型',
    );
  }

  // 2) 主模型自己（声明能看图时）。
  if (mainSeesImages) add(mainBase, mainKey, mainModel, '主模型');

  // 3) 兜底：主模型不能看图时，用同一套地址/密钥再试一次默认视觉模型。
  //    官方 `deepseek-v4-pro` 用户就是靠这条真正"走多模态"的。
  //
  //    但**同一个模型**不再试：那正是用户明确说"它看不了图"的那一个，
  //    再发一次只会多等一轮、拿回同样的 400。
  if (!mainSeesImages && vModel != mainModel.trim()) {
    add(mainBase, mainKey, vModel, '默认视觉模型');
  }

  return out;
}

/// 视觉接口的完整地址。
///
/// 用户经常把**完整 endpoint** 直接粘进"视觉接口地址"
/// （`…/chat/completions`）。以前无条件再拼一次，结果请求打到
/// `…/chat/completions/chat/completions` → 404 → 降级 OCR。
@visibleForTesting
String visionChatEndpoint(String baseUrl) {
  final String b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (b.isEmpty) return '';
  if (b.endsWith('/chat/completions')) return b;
  return '$b/chat/completions';
}

/// 识图。
///
/// 优先级：
///  1. 用户在设置里单独配置的视觉模型（地址/密钥/模型都可只填一部分）；
///  2. 主模型自己 —— `deepseek-flash` 原生支持图像理解，直接复用主对话的 key；
///  3. 主模型不支持图像时，用同一套地址密钥试一次默认视觉模型；
///  4. 本地 Google ML Kit OCR 兜底 —— 只在上面全部失败时使用。
///     离线、免费，只能读文字、不能理解画面。
///
/// 注意：图片只能放在 `user` 消息里，放进 system/assistant 会被 API 判 400。
class ImageTool extends AgentTool {
  const ImageTool();

  @override
  String get name => 'read_image';

  @override
  String get title => '识图';

  @override
  String get description =>
      '识别图片内容。默认交给具备图像理解能力的模型（deepseek-flash）来分析，'
      '可以描述画面、读取截图中的文字、分析图表。'
      '如果模型识图失败或不支持图像，会降级为设备本地 OCR（只能提取文字），'
      '并且会把失败原因一并返回。'
      'path 传本地文件绝对路径，通常是 screen_capture 截图后返回的路径。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'path': <String, dynamic>{'type': 'string', 'description': '本地图片绝对路径'},
      'question': <String, dynamic>{
        'type': 'string',
        'description': '针对图片的问题；使用视觉模型时生效',
      },
      'mode': <String, dynamic>{
        'type': 'string',
        'enum': <String>['auto', 'model', 'local'],
        'description':
            'auto 默认（模型优先，失败降级 OCR）；'
            'model 只用模型，失败不降级；local 只用本地 OCR',
      },
    },
    'required': <String>['path'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) => '识别 ${args.str('path')}';

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String path = args.str('path').trim();
    if (path.isEmpty) return '错误：缺少 path';

    final File f = File(path);
    if (!await f.exists()) {
      return '错误：文件不存在 —— $path';
    }

    final String question = args.str('question');
    // 模型偶尔会把枚举值写成 `AUTO` / `Model` —— 统一小写，别因为大小写
    // 掉进"未知模式"（默认分支等于 auto，但 `MODEL` 会失效、白降级 OCR）。
    final String mode = args.str('mode', fallback: 'auto').trim().toLowerCase();

    if (mode == 'local') return _ocr(path);

    // 组装候选：单独配置的视觉模型优先，其次是主模型本身 /
    // 同一套地址密钥下的默认视觉模型。规则见 [resolveVisionTargets]。
    final List<VisionTarget> targets = resolveVisionTargets(
      mainBaseUrl: ctx.mainBaseUrl,
      mainApiKey: ctx.mainApiKey,
      mainModel: ctx.mainModel,
      mainSeesImages: ctx.modelSeesImages,
      visionBaseUrl: ctx.visionBaseUrl,
      visionApiKey: ctx.visionApiKey,
      visionModel: ctx.visionModel,
    );

    final List<String> errors = <String>[];
    for (final VisionTarget t in targets) {
      final _VisionResult r = await _callVision(
        baseUrl: t.baseUrl,
        apiKey: t.apiKey,
        model: t.model,
        file: f,
        question: question,
      );
      if (r.content != null && r.content!.trim().isNotEmpty) {
        return '（来源：${t.label} · ${t.model}）\n\n'
            '${clampOutput(r.content!, max: 9000)}';
      }
      errors.add('${t.label}（${t.model}）：${r.error ?? '未知错误'}');
    }

    // 指定只用模型：失败就如实报错，不悄悄换成 OCR
    if (mode == 'model') {
      if (errors.isEmpty) {
        return '没有可用的视觉模型配置。\n'
            '当前主模型是「${ctx.mainModel}」，'
            '${ctx.modelSeesImages ? '它支持图像输入，请检查设置里的 API Key 是否已填。' : '它不支持图像输入，请在设置 → 联网与识图里配置视觉模型（留空的地址/密钥会复用主模型）。'}';
      }
      return '模型识图失败（已指定 mode=model，不降级到 OCR）：\n${errors.join('\n')}';
    }

    // 降级到本地 OCR，但**先说清局限**、再附原因。
    //
    // 顺序很重要：以前把 OCR 文本放最前面，模型经常直接拿它当"看懂了画面"，
    // 用户得到的是一段没有画面理解的回答。现在第一句就是警告。
    final String ocr = await _ocr(path);
    if (errors.isEmpty) {
      return '⚠ 没有可用的视觉模型，以下只是**本地 OCR** 提取的文字（没有画面理解）。\n\n'
          '$ocr\n\n'
          '—— 当前主模型是「${ctx.mainModel}」，'
          '${ctx.modelSeesImages ? '它支持图像输入，请检查设置里的 API Key 是否已填。' : '它不支持图像输入；在 设置 → 联网与识图 里配置视觉模型即可（地址/密钥留空会复用主模型）。'}';
    }
    return '⚠ 多模态识图没有成功，已降级为本地 OCR（只能读文字，理解不了画面）。\n'
        '失败原因：\n${errors.join('\n')}\n\n'
        '—— 本地 OCR 结果 ——\n$ocr';
  }

  Future<String> _ocr(String path) async {
    TextRecognizer? recognizer;
    try {
      recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
      final RecognizedText result = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );

      if (result.text.trim().isEmpty) {
        return '（本地 OCR 未识别到文字，图片可能是纯图形内容。'
            '如需理解图片内容本身，请在设置中配置视觉模型。）';
      }

      final StringBuffer sb = StringBuffer();
      sb.writeln('（来源：本地 OCR）\n');
      for (final TextBlock block in result.blocks) {
        for (final TextLine line in block.lines) {
          sb.writeln(line.text);
        }
      }
      return clampOutput(sb.toString());
    } catch (e) {
      return '本地 OCR 失败：$e';
    } finally {
      try {
        await recognizer?.close();
      } catch (_) {}
    }
  }

  /// 调用 OpenAI 兼容的视觉接口。
  ///
  /// 失败时返回**带原因**的结果而不是静默返回 null —— 否则调用方降级到 OCR 后，
  /// 用户完全不知道模型那边到底报了什么错（这正是之前「怎么只调 OCR」的根因）。
  Future<_VisionResult> _callVision({
    required String baseUrl,
    required String apiKey,
    required String model,
    required File file,
    required String question,
  }) async {
    // 先按"最干净"的请求发一次（不带 `thinking`）。
    _VisionResult r = await _visionOnce(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      file: file,
      question: question,
      thinking: false,
    );

    // 服务端不认 `thinking` 这个字段时，会回一句"未知参数"——
    // 那是**请求本身**的问题，重试同一个形状没有意义，
    // 但换成带 `thinking` 的写法（老版本一直用的那个）反而可能通，
    // 因为有些服务端/中转站只认它。两边都试一次，比猜哪边对强。
    if (r.content == null && _mentionsThinking(r.error)) {
      final _VisionResult alt = await _visionOnce(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        file: file,
        question: question,
        thinking: true,
      );
      if (alt.content != null) return alt;
      r = alt;
    }

    // 瞬时网络故障（长任务里最常见的失败）：隔一下再试**同一个**请求。
    if (r.content == null && r.transient) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final _VisionResult again = await _visionOnce(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        file: file,
        question: question,
        thinking: false,
      );
      if (again.content != null) return again;
      r = again;
    }
    return r;
  }

  /// 请求里那句错误是不是在说"我不认识 thinking 这个字段"。
  static bool _mentionsThinking(String? err) {
    final String s = (err ?? '').toLowerCase();
    return s.contains('thinking') ||
        s.contains('unknown field') ||
        s.contains('unrecognized') ||
        s.contains('extra fields') ||
        s.contains('invalid_request_error');
  }

  /// 真正发一次请求。[thinking] 只影响要不要带那个字段。
  Future<_VisionResult> _visionOnce({
    required String baseUrl,
    required String apiKey,
    required String model,
    required File file,
    required String question,
    required bool thinking,
  }) async {
    // 在 try 外面声明：catch 里也要用它（超时/网络错时同样想知道"发了多大的图"）。
    String sizeNote = '';
    try {
      final List<int> raw = await file.readAsBytes();
      // 单图 base64 上限 32 MiB（官方限制），这里留点余量
      if (raw.length > 20 * 1024 * 1024) {
        return _VisionResult(
          null,
          '图片过大（${(raw.length / 1024 / 1024).toStringAsFixed(1)} MB，'
          '内联上限 20 MB）',
        );
      }

      final String ext = file.path.split('.').last.toLowerCase();
      // 官方支持 JPEG / PNG / GIF / WebP。**先按文件头判断**、再退回扩展名：
      // 下载来的图常被改名，mime 发错时有的服务端直接 400，
      // 在这边的表现又是一次"降级 OCR"。
      String mime =
          VisionImage.sniffMime(raw) ??
          switch (ext) {
            'png' => 'image/png',
            'webp' => 'image/webp',
            'gif' => 'image/gif',
            _ => 'image/jpeg',
          };

      // 图太大了就先**压成 JPEG**（见 [VisionImage.prepare] 的说明）。
      //
      // 以前只是缩到长边 1600 再编码成 **PNG**：尺寸小了、体积没小多少
      // （截图压完还常有 1.5-3 MB），base64 之后超过不少中转站的请求体上限
      // → 413/400 → `read_image` 降级成本地 OCR。JPEG 能把同样内容的
      // 体积压到 1/5 以下。
      // 放到**后台 isolate** 里压：一张 1080×2400 的截图解码 + 缩放 + 编码
      // 在手机上要一两百毫秒，留在主 isolate 会让聊天界面卡一下。
      final ({List<int> bytes, String mime, String note}) pic = await compute(
        _prepareVisionImage,
        (raw: Uint8List.fromList(raw), mime: mime),
      );
      final List<int> bytes = pic.bytes;
      mime = pic.mime;
      sizeNote = pic.note;
      final String b64 = base64Encode(bytes);

      final String endpoint = visionChatEndpoint(baseUrl);
      final Uri? uri = Uri.tryParse(endpoint);
      if (uri == null || uri.host.isEmpty) {
        return _VisionResult(null, '接口地址不合法：$baseUrl');
      }

      final http.Response resp = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(<String, dynamic>{
              'model': model,
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'role': 'user',
                  // 图片只能出现在 user 消息里；
                  // 放进 system/assistant 会被 API 拒绝（400）。
                  'content': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'type': 'text',
                      'text': question.trim().isEmpty
                          ? '请详细描述这张图片的内容，并提取其中所有文字。'
                          : question.trim(),
                    },
                    <String, dynamic>{
                      'type': 'image_url',
                      'image_url': <String, dynamic>{
                        'url': 'data:$mime;base64,$b64',
                      },
                    },
                  ],
                },
              ],
              // 识图不需要长思维链，关掉可以明显更快更省
              //
              // 但 `thinking` **不在 OpenAI 规范里**，各家自己加：
              // 不认它的服务端会直接 400（"unknown field"），
              // 而那种 400 在我们这边表现成"视觉模型用不了，降级 OCR"。
              // 所以默认**不带**它，只有确认对方要（见 _mentionsThinking）
              // 才补上。
              if (thinking) 'thinking': <String, dynamic>{'type': 'disabled'},
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (resp.statusCode != 200) {
        return _VisionResult(
          null,
          // 把"发出去的图多大"一起报出来：413/400 的时候，这句话直接
          // 说明是不是体积的问题（以前只能看到一句 HTTP 400）。
          'HTTP ${resp.statusCode}：${_humanizeError(resp.bodyBytes)}'
          '${sizeNote.isEmpty ? '' : '\n（这次发出去的图：$sizeNote）'}',
          note: sizeNote,
        );
      }

      final Map<String, dynamic> j =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      // 有些错误是 200 + error 字段
      if (j['error'] != null) {
        return _VisionResult(null, '接口返回错误：${j['error']}');
      }

      final List<dynamic> choices =
          (j['choices'] as List<dynamic>?) ?? <dynamic>[];
      if (choices.isEmpty) {
        return const _VisionResult(null, '返回里没有 choices');
      }

      final dynamic firstMsg = (choices.first as Map)['message'];
      if (firstMsg is! Map) {
        return const _VisionResult(null, '返回里没有 message');
      }
      final Map<String, dynamic> msg = Map<String, dynamic>.from(firstMsg);

      final String content = msg['content']?.toString() ?? '';
      if (content.trim().isEmpty) {
        final String reasoning = msg['reasoning_content']?.toString() ?? '';
        return _VisionResult(
          null,
          reasoning.trim().isEmpty ? '返回内容为空' : '只返回了思维链没有正文（可尝试换模型）',
        );
      }

      return _VisionResult(content, null, note: sizeNote);
    } on TimeoutException {
      return _VisionResult(null, '请求超时（90 秒）', transient: true, note: sizeNote);
    } catch (e) {
      return _VisionResult(
        null,
        NetError.describe(e),
        transient: NetError.isTransient(e),
      );
    }
  }

  /// 把 API 的错误 JSON 提炼成人话
  static String _humanizeError(List<int> bodyBytes) {
    final String body = utf8.decode(bodyBytes, allowMalformed: true);
    try {
      final dynamic j = jsonDecode(body);
      if (j is Map) {
        final dynamic err = j['error'];
        if (err is Map && err['message'] != null) {
          return err['message'].toString();
        }
        if (j['message'] != null) return j['message'].toString();
      }
    } catch (_) {
      // 不是 JSON，原样截断返回
    }
    return body.length > 300 ? '${body.substring(0, 300)}…' : body.trim();
  }
}

/// 视觉调用结果：成功带 [content]，失败带 [error]
class _VisionResult {
  const _VisionResult(
    this.content,
    this.error, {
    this.transient = false,
    this.note = '',
  });

  final String? content;
  final String? error;

  /// 这次失败是不是"重试一次就可能成功"（网络抖动、超时）。
  ///
  /// 单独立一个字段：长任务里（termux 在跑编译、生成 PPT）手机本来就吃紧，
  /// 偶发的连接中断很常见 —— 那时候直接降级成 OCR，等于把"一次抖动"
  /// 变成了"这一轮只能看文字"。
  final bool transient;

  /// 这次实际发出去的图**被压成了什么样**（原图多大、压到多大）。
  ///
  /// 单独带出来是为了让"识图失败"那句报错**能自证**：
  /// 是图太大被拒、还是模型/地址的问题，一眼能分。
  final String note;
}

/// 搜索结果的内存缓存（带有效期 + 条数上限）。
///
/// 只是个会话内的短缓存，不落盘：联网结果时效性强，存久了反而会给出过期信息。
/// 条数上限是为了不让它无限膨胀 —— 每次搜索结果可能上万字符。
class _SearchCache {
  const _SearchCache._();

  static const Duration _ttl = Duration(minutes: 10);
  static const int _maxEntries = 24;

  /// key -> (结果, 写入时间)
  static final Map<String, (String, DateTime)> _entries =
      <String, (String, DateTime)>{};

  static String? get(String key) {
    final (String, DateTime)? hit = _entries[key];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.$2) > _ttl) {
      _entries.remove(key);
      return null;
    }
    return hit.$1;
  }

  static void put(String key, String value) {
    if (_entries.length >= _maxEntries) {
      // 简单淘汰：删掉最早写入的一条。
      // 这里不值得上 LRU —— 命中率本来就不高，够用即可。
      String? oldestKey;
      DateTime? oldestAt;
      for (final MapEntry<String, (String, DateTime)> e in _entries.entries) {
        if (oldestAt == null || e.value.$2.isBefore(oldestAt)) {
          oldestAt = e.value.$2;
          oldestKey = e.key;
        }
      }
      if (oldestKey != null) _entries.remove(oldestKey);
    }
    _entries[key] = (value, DateTime.now());
  }
}

/// `compute` 的入口必须是**顶层函数**（要能在另一个 isolate 里被找到）。
///
/// 参数和返回值都可跨 isolate 传递：Uint8List + String + record。
({List<int> bytes, String mime, String note}) _prepareVisionImage(
  ({Uint8List raw, String mime}) input,
) => VisionImage.prepare(input.raw, mime: input.mime);
