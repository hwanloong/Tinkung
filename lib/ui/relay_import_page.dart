import 'package:flutter/material.dart';

import '../core/ids.dart';
import '../core/model_profile.dart';
import '../core/store.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';

/// 「批量导入」页：填一个中转站地址 + Key，把它的模型列表拉下来勾选绑定。
///
/// ## 为什么做成独立页面而不是塞进「添加模型」里
///
/// 两者的**前提**不同：手工添加是"我知道要用哪个模型"，
/// 批量导入是"我买了个中转站，里面有什么我都不知道"。
/// 后者的第一步是**发现**（拉列表），第二步才是选择；
/// 而前者的第一步就是填表。硬塞进一页会让那张表上堆一排
/// 只有导入才用得着的控件（拉取按钮、过滤框、全选）。
class RelayImportPage extends StatefulWidget {
  const RelayImportPage({super.key, required this.settings});

  final Settings settings;

  @override
  State<RelayImportPage> createState() => _RelayImportPageState();
}

class _RelayImportPageState extends State<RelayImportPage> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _filter = TextEditingController();

  bool _loading = false;
  String? _error;

  /// 拉到的全部模型名
  List<String> _all = <String>[];

  /// 勾选中的模型名
  final Set<String> _picked = <String>{};

  /// 拉取成功的那个地址 —— 导入时必须用它，而不是用户输入的原串
  /// （比如用户填了 `https://x.com`，实际生效的是 `https://x.com/v1`）。
  String? _resolvedBase;

  @override
  void initState() {
    super.initState();
    // 已经绑过模型时，把它的地址和 Key 预填进来 ——
    // 用户多半是在同一个中转站上加模型。
    final ModelProfile? p = widget.settings.activeProfile;
    if (p != null) {
      _url.text = p.baseUrl;
      _key.text = p.apiKey;
    }
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _filter.dispose();
    super.dispose();
  }

  List<String> get _visible {
    final String f = _filter.text.trim().toLowerCase();
    if (f.isEmpty) return _all;
    return _all.where((String m) => m.toLowerCase().contains(f)).toList();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _all = <String>[];
      _picked.clear();
      _resolvedBase = null;
    });

    final ImportOutcome out = await ModelImporter.fetchModels(
      baseUrl: _url.text,
      apiKey: _key.text,
    );

    if (!mounted) return;
    setState(() {
      _loading = false;
      if (out.ok) {
        _all = out.models;
        _resolvedBase = out.endpoint;
      } else {
        _error = out.error;
      }
    });
  }

  /// 把勾选的模型一次绑成档案。
  ///
  /// 地址用 [_resolvedBase] **去掉末尾的 `/models`** ——
  /// 那才是可以拼 `/chat/completions` 的 base。
  Future<void> _import() async {
    final String? endpoint = _resolvedBase;
    if (endpoint == null || _picked.isEmpty) return;

    final String base = endpoint.replaceAll(RegExp(r'/+models$'), '');
    final String key = _key.text.trim();
    final List<String> names = _picked.toList()..sort();

    // 已有同 baseUrl + 同 model 的档案就跳过，避免重复导入时列表里
    // 出现一堆一模一样的条目（用户会以为导入坏了）。
    final Set<String> existing = widget.settings.profiles
        .where((ModelProfile p) => p.normalizedBaseUrl == base)
        .map((ModelProfile p) => p.model)
        .toSet();

    final List<String> fresh = names
        .where((String m) => !existing.contains(m))
        .toList();

    await widget.settings.update(() {
      for (final String m in fresh) {
        widget.settings.addProfile(
          ModelProfile(
            id: newId(),
            // 名称留空 → UI 会显示模型名本身。中转站的模型名通常已经
            // 足够好认（`gpt-4o`、`claude-3-5-sonnet`），
            // 再要求用户逐个起名是纯负担。
            name: '',
            baseUrl: base,
            apiKey: key,
            model: m,
            // 名字里带这些词的，基本可以确定它的能力 ——
            // 猜错的代价只是"发图被 400"或"点了生图报错"，
            // 用户随时能在编辑页改。比全部默认 false 好用得多。
            vision: _looksLikeVision(m),
            // 工具集**留 null = 跟随默认**，不给导入的模型写死一份。
            //
            // 这里原来写的是 `_looksLikeImage(m) ? ['generate_image'] : []`，
            // 也就是给**每一台不能画图的模型**（也就是用户真正拿来聊天的
            // 那些）写一个显式的空数组。当时 `generate_image` 还挂在
            // 档案工具集上判断，于是导入的模型一个都不能生图 ——
            // 用户说"画一张图"，模型回"我没有这个能力"。
            // 现在那个判断已经拆掉了（见 model_profile.dart），
            // 这里也不再写死：名字像生图模型只是**预览里的一个标签**，
            // 不该顺手改掉档案的数据。
            tools: null,
            // 纯生图模型**默认关掉对话能力**：gpt-image-2 这类只有
            // `/images/generations`，拿它发消息只会拿到服务端一句
            // "not supported on chat completions endpoint"，
            // 而用户根本不知道自己错在哪。标出来之后他一眼睛就明白。
            chat: !_looksImageOnly(m),
            // Anthropic 系的模型要把"思考"参数换成它认的形状，
            // 否则会一直报参数不合法（见 ThinkingStyle 的注释）。
            // 按名字猜一下 —— 猜错了用户能在编辑页改，
            // 而猜对的收益是"不用先撞一次 400"。
            thinkingStyle: _looksAnthropic(m)
                ? ThinkingStyle.anthropic
                : ThinkingStyle.deepseek,
          ),
          // 只在第一个上切过去，别把当前模型改成最后一个导进来的。
          activate: m == fresh.first,
        );
      }
    });

    if (!mounted) return;
    final int skipped = names.length - fresh.length;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已绑定 ${fresh.length} 个模型'
          '${skipped > 0 ? '（$skipped 个已存在，跳过）' : ''}',
        ),
      ),
    );
  }

  /// 从模型名猜"看不看得懂图"。
  static bool _looksLikeVision(String m) {
    final String s = m.toLowerCase();
    return s.contains('gpt-4') ||
        s.contains('gpt-5') ||
        s.contains('claude') ||
        s.contains('gemini') ||
        s.contains('glm-4v') ||
        s.contains('qwen-vl') ||
        s.contains('qwen2-vl') ||
        s.contains('qwen2.5-vl') ||
        s.contains('vision') ||
        s.contains('vl-') ||
        s.endsWith('-vl') ||
        s.contains('flash') ||
        s.contains('omni');
  }

  /// 从模型名猜"是不是 Anthropic 系"。
  ///
  /// 为什么这个必须猜：`thinking` 这个字段各家形状不一样，而 Anthropic
  /// **只认** `{"type":"adaptive"}` —— 发 `enabled` 会被直接拒绝，
  /// 报错只说参数不合法，用户不知道该改成什么。
  ///
  /// 判错了也不致命（编辑页能改），但判对能省掉一次必然失败的请求。
  static bool _looksAnthropic(String m) {
    final String s = m.toLowerCase();
    return s.contains('claude') ||
        s.contains('anthropic') ||
        s.contains('sonnet') ||
        s.contains('haiku') ||
        s.contains('opus');
  }

  /// 从模型名猜"画不画得出图"。
  static bool _looksLikeImage(String m) {
    final String s = m.toLowerCase();
    return s.contains('dall-e') ||
        s.contains('gpt-image') ||
        s.contains('flux') ||
        s.contains('stable-diffusion') ||
        s.contains('sdxl') ||
        s.contains('kolors') ||
        s.contains('cogview') ||
        s.contains('seedream') ||
        s.contains('imagen') ||
        s.contains('wanx') ||
        s.contains('text-to-image') ||
        s.contains('t2i');
  }

  /// 从模型名猜"**只能**生图、不能对话"。
  ///
  /// 和 [_looksLikeImage] 不是一回事：那一条只说明"能生图"，
  /// 而这一条说明"没有 chat 接口"。`flux` 系列常常两种都支持，
  /// 而 `gpt-image-*` / `dall-e-*` / `stable-diffusion-*` 是纯生图。
  ///
  /// 判错了也不致命：用户随时能在编辑页把这个开关改回来 ——
  /// 但默认猜对的收益很大，因为**撞一次这个错误很费解**
  /// （服务端只说"不支持 chat endpoint"，不说该用什么）。
  static bool _looksImageOnly(String m) {
    final String s = m.toLowerCase();
    return s.contains('gpt-image') ||
        s.contains('dall-e') ||
        s.contains('stable-diffusion') ||
        s.contains('sdxl') ||
        s.contains('cogview') ||
        s.contains('text-to-image') ||
        s.endsWith('-t2i');
  }

  @override
  Widget build(BuildContext context) {
    final AppSurface s = AppSurface.of(context);

    return Scaffold(
      backgroundColor: s.pageBg,
      appBar: AppBar(
        title: const Text('批量导入模型'),
        leading: const BackButton(),
        actions: <Widget>[
          if (_picked.isNotEmpty)
            TextButton(
              onPressed: _import,
              child: Text('导入 ${_picked.length} 个'),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: <Widget>[
          Text(
            '很多中转站（以及 OpenRouter、硅基流动这类聚合站）都提供 OpenAI 规范的'
            ' `/models` 接口。填上地址和 Key，就能把它们支持的模型一次全列出来。',
            style: AppFonts.body(size: 12.6, color: s.muted, height: 1.6),
          ),
          const SizedBox(height: 14),

          // ---- 表单收进一张卡 ----
          //
          // 地址和 Key 是**同一件事的两个填空**（一起决定"连哪家"），
          // 平铺在页面上会和下面的结果列表混成一片。用一张卡把它们框住，
          // 页面就自然分成三块：说明 → 连接信息 → 拉到的结果。
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _label(s, '中转站地址'),
                _input(
                  s,
                  controller: _url,
                  hint: 'https://xx.com/v1',
                  mono: true,
                ),
                const SizedBox(height: 8),
                // 常见地址一键填 —— 漏写 `/v1` 是这一步最常见的错。
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final RelayPreset r in RelayPreset.all)
                      ActionChip(
                        label: Text(r.label),
                        onPressed: () => setState(() => _url.text = r.baseUrl),
                      ),
                  ],
                ),

                const SizedBox(height: 14),
                _label(s, 'API Key'),
                _input(
                  s,
                  controller: _key,
                  hint: 'sk-',
                  obscure: true,
                  // 卡片底部内边距由外层给（6），这里补上对齐用的那一点
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),

          const SizedBox(height: 14),
          // **整页唯一的填充按钮**：拉列表是这一步的主操作，
          // 后面的勾选和导入都建立在它成功之上。
          FilledButton.icon(
            onPressed: _loading ? null : _fetch,
            icon: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_outlined, size: 20),
            label: Text(_loading ? '正在拉取' : '拉取模型列表'),
          ),

          if (_error != null) ...<Widget>[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                // 错误卡用淡红底而不是纯白 + 红框：
                // 它要**被看见**，红框在暖白底上还不够显眼，
                // 而铺满的深红又太像崩溃页面。
                color: AppColors.danger.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.35),
                ),
              ),
              child: Text(
                _error!,
                style: AppFonts.body(size: 12.6, color: s.text, height: 1.6),
              ),
            ),
          ],

          if (_all.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            // ---- 结果区也是一张卡 ----
            //
            // 标题、过滤框、勾选行属于同一件事（"从这批里挑"），
            // 框在一起之后，它们和上面的连接表单在视觉上是两层，
            // 用户不会把过滤框误当成又一个地址栏。
            Container(
              decoration: BoxDecoration(
                color: s.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: s.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '拉到 ${_all.length} 个模型',
                                style: AppFonts.body(
                                  size: 14,
                                  weight: FontWeight.w600,
                                  color: s.text,
                                  height: 1.3,
                                ),
                              ),
                              // 地址用等宽小字：它是**核对**用的（确认拉的是
                              // 哪个站），不是标题的一部分。
                              if (_resolvedBase != null) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  _resolvedBase!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppFonts.code(
                                    size: 11,
                                    color: s.muted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            final List<String> v = _visible;
                            // 已经是"全选"状态就反过来做全不选 —— 否则用户
                            // 想清空选择时得一个一个点。
                            if (v.every(_picked.contains)) {
                              _picked.removeAll(v);
                            } else {
                              _picked.addAll(v);
                            }
                          }),
                          child: Text(
                            _visible.every(_picked.contains) ? '全不选' : '全选',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                    child: _input(
                      s,
                      controller: _filter,
                      hint: '过滤，例如 gpt / claude / qwen',
                    ),
                  ),
                  Divider(color: s.border, height: 1),
                  if (_visible.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                      child: Text(
                        '没有匹配「${_filter.text.trim()}」的模型。'
                        '清空过滤框可以看到全部 ${_all.length} 个。',
                        style: AppFonts.body(
                          size: 12.2,
                          color: s.muted,
                          height: 1.6,
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
                      child: Column(
                        children: <Widget>[
                          for (final String m in _visible)
                            CheckboxListTile(
                              value: _picked.contains(m),
                              onChanged: (bool? v) => setState(() {
                                if (v == true) {
                                  _picked.add(m);
                                } else {
                                  _picked.remove(m);
                                }
                              }),
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              visualDensity: VisualDensity.compact,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(
                                m,
                                style: AppFonts.code(size: 12.8, color: s.text),
                              ),
                              subtitle: _badges(s, m),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 勾选项下面的能力标注。
  ///
  /// 显示出来是因为**导入时会按名字猜这两项**，用户得能看到猜成了什么，
  /// 否则"能生图"这个开关被自动打开或关掉他是不知道的。
  Widget? _badges(AppSurface s, String m) {
    final bool imageOnly = _looksImageOnly(m);
    final List<String> tags = <String>[
      // 「仅生图」放在最前面、用警示色：它决定了这个模型**能不能用来聊天**，
      // 是这一行里最要紧的信息。
      if (imageOnly) '仅生图',
      if (_looksLikeVision(m)) '可看图',
      if (_looksLikeImage(m)) '可生图',
    ];
    if (tags.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        tags.join(' · '),
        style: AppFonts.body(
          size: 11,
          color: imageOnly ? AppColors.warning : AppColors.accent,
        ),
      ),
    );
  }

  Widget _label(AppSurface s, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      text,
      style: AppFonts.body(size: 12.8, weight: FontWeight.w600, color: s.muted),
    ),
  );

  Widget _input(
    AppSurface s, {
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    bool mono = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: mono
          ? AppFonts.code(size: 13, color: s.text)
          : AppFonts.body(size: 14.5, color: s.text),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: mono
            ? AppFonts.code(size: 12.5, color: s.muted)
            : AppFonts.body(size: 13.5, color: s.muted),
      ),
    );
  }
}
