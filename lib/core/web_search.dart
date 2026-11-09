import 'dart:convert';

import 'package:http/http.dart' as http;

import 'net_error.dart';

/// 一次搜索的一条结果。
class WebHit {
  const WebHit({required this.title, required this.url, this.snippet = ''});

  final String title;
  final String url;
  final String snippet;

  bool get usable => title.trim().isNotEmpty || url.trim().isNotEmpty;
}

/// 一次搜索的结果：命中的条目 + 人话说明（失败原因 / 走了哪条通道）。
class WebSearchResult {
  const WebSearchResult({required this.source, required this.hits, this.error});

  /// 实际出结果的通道（`bing-rss` / `duckduckgo` …）。
  /// 失败时是**最后尝试的那个**，用来写错误信息。
  final String source;

  final List<WebHit> hits;

  /// 非空表示没搜到 / 出错。有 [hits] 时也可能带一段提示（比如"已降级"）。
  final String? error;

  bool get ok => hits.isNotEmpty;

  /// 渲染成可以直接塞给模型（或当附件正文）的 markdown。
  ///
  /// 带上来源标注：模型引用这些内容时要能说出来是哪一条，
  /// 用户核对时也需要。
  String toMarkdown(String query) {
    if (hits.isEmpty) {
      return '## 联网搜索：$query\n\n（没有取到结果${error == null ? '' : '：$error'}）\n';
    }
    final StringBuffer sb = StringBuffer()
      ..writeln('## 联网搜索：$query')
      ..writeln()
      ..writeln('来源通道：$_sourceLabel')
      ..writeln();
    for (int i = 0; i < hits.length; i++) {
      final WebHit h = hits[i];
      sb.writeln('### [${i + 1}] ${h.title}');
      sb.writeln('<${h.url}>');
      if (h.snippet.trim().isNotEmpty) {
        sb.writeln();
        sb.writeln(h.snippet.trim());
      }
      sb.writeln();
    }
    return sb.toString();
  }

  String get _sourceLabel => WebSearchSource.byId(source)?.label ?? source;
}

/// 一个可选的联网搜索通道。
///
/// ## 为什么要有"多个通道"这件事
///
/// 这个应用的目标用户在国内网络上。搜索结果这件事**没有一条通道是永远可用的**：
///
/// · Tavily 免 key 模式实测国内直连可达，但会限流；
/// · 百度能出结果，但它是**中文站内**为主，查技术文档/英文资料很差；
/// · DuckDuckGo 的结果质量（尤其技术内容）明显更好，但国内经常连不上；
/// · Bing 的 **RSS 输出**（`&format=rss`）比抓 HTML 稳得多 ——
///   它给的是结构化 XML，不需要跟页面改版和反爬斗智。
///
/// 所以这里把它们做成"通道"，由用户选、失败自动落到下一条，
/// 而不是写死一条链让用户等着超时。
class WebSearchSource {
  const WebSearchSource({
    required this.id,
    required this.label,
    required this.desc,
    required this.search,
  });

  final String id;
  final String label;
  final String desc;

  /// 真正执行搜索。**不应抛异常** —— 失败要包成带 `error` 的结果，
  /// 否则调用方（可能是 agent 循环）会被一个网络错误打断。
  final Future<WebSearchResult> Function(String query, int limit) search;

  static const List<WebSearchSource> all = <WebSearchSource>[
    WebSearchSource(
      id: 'bing-rss',
      label: 'Bing（RSS）',
      desc: '走 Bing 的 RSS 输出，国内可达、结构稳定',
      search: _bingRss,
    ),
    WebSearchSource(
      id: 'duckduckgo',
      label: 'DuckDuckGo',
      desc: '结果质量好、无广告，但国内网络常常连不上',
      search: _duckDuckGo,
    ),
  ];

  static WebSearchSource? byId(String id) {
    for (final WebSearchSource s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 依次尝试，第一个出结果的获胜。
  ///
  /// [preferred] 是用户选的通道，**排第一位**但不会独占：
  /// 国内网络下"DuckDuckGo 连不上"是常态，直接报错让用户手动换一个
  /// 是糟糕的体验 —— 他自己并不知道哪条通。
  static Future<WebSearchResult> searchWithFallback(
    String query,
    int limit, {
    String preferred = 'bing-rss',
  }) async {
    final WebSearchSource first = byId(preferred) ?? all.first;
    final List<WebSearchSource> order = <WebSearchSource>[
      first,
      ...all.where((WebSearchSource s) => s.id != first.id),
    ];

    final List<String> failures = <String>[];
    for (final WebSearchSource s in order) {
      final WebSearchResult r = await s.search(query, limit);
      if (r.ok) {
        // 不是首选通道时明确说出来：用户选了 DDG 却拿到 Bing 的结果，
        // 不说明的话他会以为 DDG 通了，下次还会踩同一个坑。
        if (s.id != first.id) {
          return WebSearchResult(
            source: s.id,
            hits: r.hits,
            error: '${first.label} 没取到结果，已自动改用 ${s.label}',
          );
        }
        return r;
      }
      failures.add('${s.label}：${r.error ?? '没有结果'}');
    }

    return WebSearchResult(
      source: first.id,
      hits: const <WebHit>[],
      error: failures.join('；'),
    );
  }

  // ------------------------------------------------------------ Bing RSS
  //
  // `https://www.bing.com/search?q=…&format=rss` 返回的是标准 RSS 2.0。
  //
  // **为什么用 RSS 而不是抓 HTML**：Bing 的 HTML 结果页结构经常变、
  // 且对非浏览器 UA 有反爬（会返回一个空壳页 + JS 跳转）；RSS 是老接口，
  // 结构十几年没动过，也不需要执行 JS。代价是没有摘要里的高亮、
  // 条目数上限约 10 条 —— 对"把资料喂给模型"这个用途完全够。
  static Future<WebSearchResult> _bingRss(String query, int limit) async {
    final Uri uri = Uri.https('www.bing.com', '/search', <String, String>{
      'q': query,
      'format': 'rss',
      // 条数由 Bing 自己决定（通常 10），这里只是尽量表达意图
      'count': '$limit',
    });

    try {
      final http.Response resp = await NetError.retry(
        () => http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20)),
        attempts: 2,
      );

      if (resp.statusCode != 200) {
        return WebSearchResult(
          source: 'bing-rss',
          hits: const <WebHit>[],
          error: 'HTTP ${resp.statusCode}',
        );
      }

      final List<WebHit> hits = parseBingRss(
        utf8.decode(resp.bodyBytes),
        limit,
      );
      if (hits.isEmpty) {
        return const WebSearchResult(
          source: 'bing-rss',
          hits: <WebHit>[],
          error: 'RSS 里没有 item（可能是查询词无结果，或被降级成了 HTML）',
        );
      }
      return WebSearchResult(source: 'bing-rss', hits: hits);
    } catch (e) {
      return WebSearchResult(
        source: 'bing-rss',
        hits: const <WebHit>[],
        error: NetError.describe(e),
      );
    }
  }

  /// 解析 Bing 的 RSS。
  ///
  /// 抽成静态方法是为了能单独测 —— 解析错了会把"别的查询的结果"
  /// 当成这次的结果，比搜不到更糟。
  ///
  /// 不用 XML 库：RSS 的结构固定到可以用正则安全地切 `<item>`，
  /// 而为此引一个依赖（`xml` 包）不值得。这里只做**取字段 + 去标记 +
  /// 解实体**三件事，任何一步失败就跳过那一条，不会整份崩掉。
  static List<WebHit> parseBingRss(String xml, int limit) {
    final List<WebHit> hits = <WebHit>[];
    final RegExp itemRe = RegExp(r'<item>(.*?)</item>', dotAll: true);

    for (final RegExpMatch m in itemRe.allMatches(xml)) {
      if (hits.length >= limit) break;
      final String item = m.group(1) ?? '';
      final String title = _tag(item, 'title');
      final String link = _tag(item, 'link');
      final String desc = _tag(item, 'description');
      if (link.trim().isEmpty && title.trim().isEmpty) continue;
      hits.add(
        WebHit(
          title: title.trim().isEmpty ? link.trim() : title.trim(),
          url: link.trim(),
          snippet: _stripTags(desc),
        ),
      );
    }
    return hits;
  }

  /// 取一个标签的文本内容。RSS 里字段都是纯文本，不需要处理属性。
  static String _tag(String item, String name) {
    final RegExp re = RegExp('<$name>(.*?)</$name>', dotAll: true);
    final RegExpMatch? m = re.firstMatch(item);
    return m == null ? '' : _unescape(m.group(1) ?? '');
  }

  static String _stripTags(String s) {
    final String noTags = s
        .replaceAll(RegExp('<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return noTags;
  }

  /// XML 实体解码。
  ///
  /// 顺序要紧：`&amp;` 必须**最后**解 —— 先解它的话，`&amp;lt;`
  /// 会被二次解码成 `<`，凭空造出标记。
  static String _unescape(String s) {
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll(RegExp(r'&amp;'), '&');
  }

  // ------------------------------------------------------------ DuckDuckGo
  //
  // 用 `lite.duckduckgo.com/lite/` 而不是 `html.duckduckgo.com/html/`：
  // lite 版是**无 JS 的纯表格页面**，比 html 版少一层包装，解析更稳，
  // 返回体积也小得多（移动网络下这个差别不小）。
  static Future<WebSearchResult> _duckDuckGo(String query, int limit) async {
    final Uri uri = Uri.https('lite.duckduckgo.com', '/lite/', <String, String>{
      'q': query,
    });

    try {
      final http.Response resp = await NetError.retry(
        () => http
            .get(uri, headers: _headers)
            .timeout(const Duration(seconds: 20)),
        attempts: 2,
      );

      if (resp.statusCode != 200) {
        return WebSearchResult(
          source: 'duckduckgo',
          hits: const <WebHit>[],
          error: 'HTTP ${resp.statusCode}',
        );
      }

      final List<WebHit> hits = parseDuckLite(
        utf8.decode(resp.bodyBytes),
        limit,
      );
      if (hits.isEmpty) {
        return const WebSearchResult(
          source: 'duckduckgo',
          hits: <WebHit>[],
          error: '页面里没有结果链接（可能被反爬拦下，或查询无结果）',
        );
      }
      return WebSearchResult(source: 'duckduckgo', hits: hits);
    } catch (e) {
      return WebSearchResult(
        source: 'duckduckgo',
        hits: const <WebHit>[],
        error: NetError.describe(e),
      );
    }
  }

  /// 解析 DDG lite 的结果页。
  ///
  /// lite 版的每一条结果长这样（简化后）：
  ///
  /// ```html
  /// <a rel="nofollow" href="https://example.com/x" class='result-link'>标题</a>
  /// ...
  /// <td class='result-snippet'>摘要…</td>
  /// ```
  ///
  /// 只认 `result-link` 这个 class 找结果行：直接抓所有 `<a href>` 会把
  /// 导航栏、广告、"相关搜索"一起抓进来。
  static List<WebHit> parseDuckLite(String html, int limit) {
    final List<WebHit> hits = <WebHit>[];

    // 标题和链接在同一个 <a> 上，class 可能是单引号也可能是双引号
    final RegExp linkRe = RegExp(
      r"""<a[^>]*class=['"]result-link['"][^>]*>(.*?)</a>""",
      dotAll: true,
    );

    for (final RegExpMatch m in linkRe.allMatches(html)) {
      if (hits.length >= limit) break;
      final String whole = m.group(0) ?? '';
      final RegExpMatch? href = RegExp(r"""href=['"]([^'"]+)['"]""")
          .firstMatch(whole);
      final String url = href == null ? '' : _ddgUrl(href.group(1) ?? '');
      final String title = _stripTags(m.group(1) ?? '');
      if (url.isEmpty && title.isEmpty) continue;
      hits.add(WebHit(title: title, url: url));
    }

    // 摘要单独扫：lite 的摘要在结果链接之后，用顺序对应。
    // 数量对不上时（页面结构变了）就不填摘要 —— 少字段比错位好。
    final List<String> snippets =
        RegExp(
              r"""<td[^>]*class=['"]result-snippet['"][^>]*>(.*?)</td>""",
              dotAll: true,
            )
            .allMatches(html)
            .map((RegExpMatch m) => _stripTags(m.group(1) ?? ''))
            .toList();

    if (snippets.length == hits.length) {
      for (int i = 0; i < hits.length; i++) {
        hits[i] = WebHit(
          title: hits[i].title,
          url: hits[i].url,
          snippet: snippets[i],
        );
      }
    }

    return hits;
  }

  /// DDG 有时会把真实地址包在 `/l/?uddg=<编码后的地址>` 里。
  /// 不还原的话模型拿到的是一个 DDG 的跳转链接，抓不到内容。
  ///
  /// 判断依据是 **`uddg` 参数本身**，而不是"主机名是不是 duckduckgo.com"：
  /// lite 页返回的是**相对路径**（`/l/?uddg=…`），根本没有主机名，
  /// 按主机名判断会全部漏掉（这是实测踩到的：结果里的链接全成了
  /// `/l/?uddg=…` 这种半截地址，模型点不开也抓不到）。
  static String _ddgUrl(String raw) {
    if (raw.startsWith('//')) return 'https:$raw';

    // 相对路径补上主机，这样 Uri 才解析得出 query
    final String abs = raw.startsWith('/') ? 'https://duckduckgo.com$raw' : raw;
    final Uri? u = Uri.tryParse(abs);
    if (u == null) return raw;

    final String? target = u.queryParameters['uddg'];
    if (target != null && target.trim().isNotEmpty) {
      // uddg 是被 URL 编码过的，queryParameters 已经解了一层
      return target.trim();
    }
    return u.hasScheme ? abs : raw;
  }

  /// 伪装成一个正常的浏览器 UA。
  ///
  /// 不带 UA 的请求会被这两家直接判成爬虫。不伪造 Referer / Cookie ——
  /// 那属于绕过对方的反爬策略，而这个功能只是"帮用户查一下公开资料"，
  /// 被拦了就换一条通道（见 [searchWithFallback]）才是对的应对。
  static const Map<String, String> _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/126.0.0.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };
}
