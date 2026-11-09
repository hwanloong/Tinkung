/// 富卡片用的前端库 CDN 地址。
///
/// ## 为什么需要一份"多镜像"清单
///
/// 富卡片（mermaid 图表、Chart.js 图表）是在**内置 WebView 里**跑的
/// HTML，库本身要联网从 CDN 取。而 `cdn.jsdelivr.net` 在国内网络下
/// **时通时不通**（DNS 污染 + SNI 阻断，且不同运营商表现不一致）——
/// 一旦不通，用户看到的是"图表没了"，而模型那边一切都正常。
///
/// 所以每条库给一串镜像，**按国内可达性排序**，页面里逐个 try：
///
/// 1. **npmmirror**（阿里）：国内 CDN，几乎必通。代价是它镜像的是 npm
///    的**包文件**，路径形状和 jsdelivr 不同（见下面各条的注释）。
/// 2. **jsdelivr 的 fastly 节点**（`fastly.jsdelivr.net`）：和主域名
///    解析到不同 IP，主域被墙时它有时还是通的。
/// 3. **unpkg**：最后一个，国内通常也不通，但留着不亏 ——
///    有代理的用户能命中它。
///
/// ## 顺序为什么要写死在代码里
///
/// 不做"探测最快节点"那套：探测本身要发请求，而这段代码跑在 WebView
/// 的 `<script>` 里，多一次往返意味着用户多等一秒才看到图。
/// 按经验排序 + 逐个 fallback 已经够用，而且失败时页面会明确说明原因。
class CardCdn {
  const CardCdn._();

  /// mermaid（ESM）。注意 `?module` 后缀 ——
  /// npmmirror 上直接给 `.mjs` 会返回 `text/plain`，浏览器拒绝当模块执行；
  /// 加 `?module` 才会带正确的 `Content-Type: application/javascript`。
  static const List<String> mermaid = <String>[
    'https://registry.npmmirror.com/mermaid/11/files/dist/mermaid.esm.min.mjs',
    'https://fastly.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs',
    'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs',
    'https://unpkg.com/mermaid@11/dist/mermaid.esm.min.mjs',
  ];

  /// Chart.js（UMD，挂 `window.Chart`）。
  ///
  /// 用 UMD 而不是 ESM：Chart.js 的 ESM 构建在 `<script type="module">` 里
  /// 还需要额外处理具名导出，而 UMD 直接给全局变量，一行就够 ——
  /// 这段代码在模板字符串里，越短越不容易写错。
  static const List<String> chartJs = <String>[
    'https://registry.npmmirror.com/chart.js/4.4.1/files/dist/chart.umd.js',
    'https://fastly.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.js',
    'https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.js',
    'https://unpkg.com/chart.js@4.4.1/dist/chart.umd.js',
  ];

  /// 把一串地址渲染成 JS 数组字面量（模板里用）。
  static String jsArray(List<String> urls) =>
      '[${urls.map((String u) => "'$u'").join(',')}]';
}
