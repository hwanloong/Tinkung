import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/model_profile.dart';
import '../core/net_error.dart';
import '../core/store.dart';

/// 模型请求调用某个工具
class ToolCallRequest {
  ToolCallRequest({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;

  /// 原始 JSON 字符串（回传时必须原样带上）
  final String arguments;
}

/// 一轮 assistant 回复
class AssistantTurn {
  AssistantTurn({
    this.content = '',
    this.reasoning = '',
    this.toolCalls = const <ToolCallRequest>[],
    this.promptTokens,
    this.completionTokens,
    this.reasoningTokens,
    this.cacheHitTokens,
    this.cacheMissTokens,
    this.reasoningMs = 0,
  });

  final String content;

  /// deepseek-reasoner 的思维链，普通模型为空
  final String reasoning;
  final List<ToolCallRequest> toolCalls;

  /// API 实测返回的 token 用量。为 null 表示服务端没给，
  /// 调用方只能本地估算 —— 这两者在 UI 上必须区分显示。
  final int? promptTokens;
  final int? completionTokens;
  final int? reasoningTokens;

  /// 服务端 prompt cache 的命中 / 未命中 token 数。
  ///
  /// 两者都为 null = 服务端没有返回缓存明细（很多中转站如此）。
  /// **不能用 0 代替 null**：0% 命中率和"不知道"是两件事。
  final int? cacheHitTokens;
  final int? cacheMissTokens;

  /// **思考用了多久**（毫秒）。0 = 没有思考。
  ///
  /// 口径：从**第一个 reasoning 分片**到**第一个正文分片**（或流结束）。
  /// 不从请求发出算起 —— 那里面还含建连和排队，那不是"思考"。
  final int reasoningMs;

  bool get hasUsage => promptTokens != null || completionTokens != null;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// DeepSeek（OpenAI 兼容）客户端。
class DeepSeekClient {
  DeepSeekClient(this.settings, {ModelProfile? profile}) : _override = profile;

  final Settings settings;

  /// **指定用哪个模型档案发这次请求**；null = 跟随「当前选中的档案」。
  ///
  /// ## 为什么需要它
  ///
  /// 群聊里每位成员有自己的模型（甚至是不同的中转站和 key），
  /// 而"当前选中的档案"全局只有一个。从前这个客户端的所有参数都从
  /// `settings.xxx` 读，那个读写器转发到当前档案 —— 于是群聊要么得
  /// 在发请求前偷偷切换当前档案（用户会在设置页看到选中的模型
  /// 莫名其妙地跳来跳去，而且并发时必然串味），要么就得复制一整套 client。
  ///
  /// 传一个档案进来，那些 getter 就只对这一次请求生效。
  final ModelProfile? _override;

  /// 这次请求真正用的档案。
  ModelProfile? get _profile => _override ?? settings.activeProfile;

  /// 能不能发。指定了档案时看**那个档案**填全了没有 ——
  /// 否则"当前档案没配好"会连带把配好的群聊成员一起拦住。
  bool get _configured => _override == null
      ? settings.configured
      : (_override.apiKey.trim().isNotEmpty &&
            _override.model.trim().isNotEmpty);

  /// **全应用共用的 HTTP 连接池。**
  ///
  /// 从前每发一次请求都 `http.Client()` → 用完 `close()`，等于每条消息、
  /// 每一轮工具调用都要重新做一次 TCP + TLS 握手：
  ///
  ///   DNS → TCP → TLS 1.3 握完才能发出第一个字节。
  ///
  /// 在手机上这一步是 200~800ms（弱网更久），而 agent 一次任务常常要跑
  /// 三到五轮 —— 用户看到的就是"同一个 key，电脑上快得多"。
  ///
  /// 现在整个进程共用一个客户端：连接池（keep-alive）会复用已经建好的
  /// 连接，第二轮起几乎没有握手开销。`idleTimeout` 也调长了 ——
  /// dart:io 默认 15 秒就关空闲连接，而用户回一句话的间隔通常超过 15 秒。
  ///
  /// ⚠️ 这个客户端**不能**在 `cancel()` 里 close：它是全进程共用的，
  /// 关掉会把别人的连接一起掐了。取消只置标志位，由 `_consumeStream`
  /// 读到 `cancelled` 后自己退出循环。
  static http.Client? _shared;

  static http.Client get _httpClient {
    final http.Client? cached = _shared;
    if (cached != null) return cached;
    final io.HttpClient inner = io.HttpClient()
      ..idleTimeout = const Duration(minutes: 5)
      ..connectionTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 6;
    return _shared = IOClient(inner);
  }

  /// 内置免费通道的上游暂时不可用时，本次请求改走备用免费池。
  ///
  /// 只在**还没收到任何内容**时切换：已经流出正文再换模型会把同一段
  /// 回答输出两遍。切换也只发生一次，避免两个上游互相踢皮球。
  bool _usingFreeFallback = false;

  bool get _isFreeLane => _profile?.isFreeDeepSeek ?? false;

  /// 置为 true 可让进行中的流式请求尽快停下
  bool cancelled = false;

  void cancel() {
    // 只置标志位：`_consumeStream` 读到它就会退出循环，连接交还给
    // 共享连接池。**不能 close 客户端** —— 那是全进程共用的。
    cancelled = true;
  }

  /// 组装"思考模式"相关的请求字段。
  ///
  /// ## 为什么不能写死一种形状
  ///
  /// 这个字段**不在 OpenAI 规范里** —— 是各家自己加的，
  /// 于是同一件事有好几种写法，而且**服务端大多会严格校验 type**：
  /// 传错不是"忽略"，是直接 400。实测遇到的：
  ///
  /// · **DeepSeek**：`thinking: {type: "enabled" | "disabled"}`，
  ///   开启时配套发 `reasoning_effort`。关闭时 temperature 才生效。
  /// · **Anthropic 系**（含走 Anthropic 兼容层的中转站）：
  ///   只接受 `thinking: {type: "adaptive"}`。
  ///   发 `"enabled"` 会被顶回来 —— 而它们的报错通常只说参数不合法，
  ///   用户根本不知道该把 `enabled` 换成什么。
  /// · **多数 OpenAI 兼容服务**（OpenAI 自己、Kimi、智谱、本地 Ollama）：
  ///   压根不认识这个字段。发过去轻则被忽略，重则 400。
  ///
  /// 所以这个形状**由用户在模型档案上选**（见 [ThinkingStyle]），
  /// 而不是我们按模型名猜：中转站里一个模型名可能被套上任何后端，
  /// 猜错的代价是一次 400。
  ///
  /// 静态方法，便于单独测 —— 键名和取值写错只有真发请求才会暴露。
  @visibleForTesting
  static Map<String, dynamic> buildThinkingParams({
    required ThinkingStyle style,
    required bool enabled,
    required String effort,
    required double temperature,
  }) {
    switch (style) {
      case ThinkingStyle.none:
        // 完全不发 thinking。temperature 照发 ——
        // 对不认识这个字段的服务来说，它就是普通的采样温度。
        return <String, dynamic>{'temperature': temperature};

      case ThinkingStyle.anthropic:
        // Anthropic：**只认 `adaptive`**，没有"关闭"这个取值。
        //
        // 所以"关闭思考"在这里没法用参数表达 —— 只能整个不发这个字段
        // （下面这条分支这么做了）。这是对方的接口限制，不是我们的取舍。
        if (!enabled) return <String, dynamic>{'temperature': temperature};
        return <String, dynamic>{
          'thinking': <String, dynamic>{'type': 'adaptive'},
          // Anthropic 的强度是 `budget_tokens`。这里不做映射：
          // 各家中转对它的上下限要求不同，猜一个数字不如让服务端用它自己的
          // 默认值 —— 少一个可能被拒绝的参数。
        };

      case ThinkingStyle.openAiLike:
      case ThinkingStyle.deepseek:
        if (!enabled) {
          // 关闭思考时才发温度：DeepSeek 明确说明思考模式下
          // temperature / presence_penalty / frequency_penalty
          // 「设置不报错但也不生效」，发了只会造成误导。
          return <String, dynamic>{
            'thinking': <String, dynamic>{'type': 'disabled'},
            'temperature': temperature,
          };
        }
        return <String, dynamic>{
          'thinking': <String, dynamic>{'type': 'enabled'},
          ...effort.trim().isEmpty
              ? const <String, dynamic>{}
              : <String, dynamic>{'reasoning_effort': effort},
        };

      case ThinkingStyle.effortOnly:
        return <String, dynamic>{
          'temperature': temperature,
          if (enabled && effort.trim().isNotEmpty)
            'reasoning_effort': effort.trim(),
        };
    }
  }

  /// 这个 HTTP 状态码值不值得重试。
  ///
  /// 429（限流）和 5xx（上游故障/过载）等几秒通常会恢复；
  /// 400 / 401 / 402 / 403 是请求形状、密钥、额度问题，重试没有意义。
  static bool _retryableStatus(int? code) {
    if (code == null) return true;
    return code == 429 || code >= 500;
  }

  /// 发一轮对话请求。[onText] 会在流式过程中被反复调用。
  ///
  /// [onRetry]：准备重试时回调（第几次、总共几次、等多久、什么错误）。
  /// 界面可以用它显示"正在重试 2/5"，而不是让用户对着一屏空白等 15 秒。
  Future<AssistantTurn> chat({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const <Map<String, dynamic>>[],
    void Function(String text)? onText,
    void Function(String reasoning)? onReasoning,
    void Function(int attempt, int maxRetries, Duration wait, Object error)?
        onRetry,
  }) async {
    if (!_configured) {
      throw ApiException('还没有填 API Key，请到设置里填写 DeepSeek API Key');
    }

    cancelled = false;

    // 一旦已经流出内容，就不能重试了 —— 重试会把前面的内容再输出一遍，
    // 用户会看到重复的段落。所以只在整个响应还"干净"的时候才重试。
    bool receivedAnything = false;

    try {
      return await NetError.retry(
        () => _attempt(
          messages: messages,
          tools: tools,
          onText: (String t) {
            receivedAnything = true;
            onText?.call(t);
          },
          onReasoning: (String r) {
            receivedAnything = true;
            onReasoning?.call(r);
          },
        ),
        // 模型接口的规矩（用户要求）：**报错等 3 秒再试，最多重试 5 次**。
        //
        // 为什么要等 3 秒而不是 0.7 秒：上游 5xx / 过载通常是几秒钟的
        // 窗口，退避太密只会连续撞在同一个故障期里，把 3 次机会全烧掉。
        // 5 次重试 = 最多等 15 秒；15 秒后仍失败就**停下来**，把真实错误
        // 交给界面 —— 不无限重试，也不静默吞掉。
        attempts: 6,
        delay: const Duration(seconds: 3),
        onRetry: (int attempt, Duration wait, Object error) {
          onRetry?.call(attempt, 5, wait, error);
        },
        shouldRetry: (Object e) =>
            !receivedAnything &&
            !cancelled &&
            (e is! ApiException || _retryableStatus(e.statusCode)),
      );
    } on ApiException catch (e) {
      // 免费车道的 403 / FreeTierError / Model is unavailable 不是用户
      // 配错了什么，而是上游按地区或额度临时拒绝。换备用免费池再试一次，
      // 让"默认模型"在更多网络环境下是真的能直接说话。
      if (_isFreeLane &&
          !_usingFreeFallback &&
          !receivedAnything &&
          !cancelled &&
          _shouldTryFreeFallback(e)) {
        _usingFreeFallback = true;
        return await NetError.retry(
          () => _attempt(
            messages: messages,
            tools: tools,
            onText: (String t) {
              receivedAnything = true;
              onText?.call(t);
            },
            onReasoning: (String r) {
              receivedAnything = true;
              onReasoning?.call(r);
            },
          ),
          attempts: 2,
          shouldRetry: (Object _) => !receivedAnything && !cancelled,
        );
      }
      rethrow;
    } catch (e) {
      if (cancelled) return AssistantTurn(content: '');
      // 把 ECONNABORTED 这类底层 errno 文案翻译成人话。
      // 瞬时错误已经在这里被重试过 5 次了，告诉用户"为什么等了这么久"，
      // 否则 15 秒后只弹一句"超时"，看起来像卡死了。
      final String base = NetError.describe(e);
      if (NetError.isTransient(e) && !receivedAnything) {
        throw ApiException(
          '$base\n\n已自动重试 5 次（每次间隔 3 秒）仍失败，已暂停重试。'
          '可以稍后再发一次，或检查网络 / 模型额度。',
        );
      }
      throw ApiException(base);
    }
  }

  Future<AssistantTurn> _attempt({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required void Function(String text) onText,
    required void Function(String reasoning) onReasoning,
  }) async {
    // 复用全进程的连接池，不为每条消息重开 TCP/TLS（见 [_httpClient]）。
    final http.Client client = _httpClient;

    final bool freeLane = _isFreeLane && !_usingFreeFallback;
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': _usingFreeFallback
          ? kFreeFallbackModel
          : (_override?.model ?? settings.model),
      'messages': messages,
      'stream': true,
      // 请求在流末尾附带 usage（OpenAI 兼容字段）。
      // 服务端不支持时会被静默忽略，那就拿不到实测值，
      // 调用方会退回本地估算 —— 不会因此报错。
      'stream_options': <String, dynamic>{'include_usage': true},
    };

    // 思考参数各家的形状不一样，抽成静态方法便于单独测 ——
    // 这几个键名写错的表现是**服务端直接 400**，而报错信息通常
    // 只说"参数不合法"，看不出该改成什么。
    payload.addAll(
      buildThinkingParams(
        style: _usingFreeFallback
            ? ThinkingStyle.effortOnly
            : (_override?.thinkingStyle ?? settings.thinkingStyle),
        enabled: _override?.thinking ?? settings.thinkingEnabled,
        effort: _override?.reasoningEffort ?? settings.reasoningEffort,
        temperature: _override?.temperature ?? settings.temperature,
      ),
    );

    if (tools.isNotEmpty) {
      payload['tools'] = tools;
      payload['tool_choice'] = 'auto';
    }

    // OpenCode 的免费车道用客户端指纹辨认调用方。缺这些头时上游会
    // 回一句很容易误导人的 "free tier can only be used from within
    // OpenCode" —— 看起来像账号问题，其实是请求形状不对。
    if (freeLane) _applyOpenCodeFingerprint(payload);

    final String endpoint = _usingFreeFallback
        ? '$kFreeFallbackBaseUrl/chat/completions'
        : (_override?.chatEndpoint ?? settings.chatEndpoint);
    final http.Request req = http.Request('POST', Uri.parse(endpoint));
    req.headers.addAll(<String, String>{
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    if (!_usingFreeFallback) {
      req.headers['Authorization'] =
          'Bearer ${_override?.apiKey ?? settings.apiKey}';
    }
    if (freeLane) {
      req.headers.addAll(<String, String>{
        'User-Agent': 'opencode/latest/2.0.26/cli',
        'x-opencode-client': 'cli',
        'x-opencode-session': _freeSession,
        'x-opencode-session-id': _freeSession,
        'x-session-affinity': _freeSession,
        'x-session-id': _freeSession,
        'x-opencode-project': 'global',
      });
    }
    req.body = jsonEncode(payload);

    final http.StreamedResponse resp = await client
        .send(req)
        .timeout(const Duration(seconds: 60));

    if (resp.statusCode != 200) {
      final String body = await resp.stream.bytesToString().timeout(
        const Duration(seconds: 20),
      );
      // 带状态码的错误不重试：401/400/402 重试多少次都一样
      throw ApiException(_humanize(body), statusCode: resp.statusCode);
    }

    return await _consumeStream(resp, onText, onReasoning);
  }

  /// 解析 SSE 流。
  ///
  /// 这里有两个必须处理对的点：
  ///  1. `data:` 里可能是空行、注释行、`[DONE]`，都要跳过；
  ///  2. **tool_calls 是按 index 分片下发的**——第一片只有 id 和 name，
  ///     后续片只带 arguments 的片段。必须按 index 累加拼接，
  ///     否则会拿到被截断的 JSON 参数。
  Future<AssistantTurn> _consumeStream(
    http.StreamedResponse resp,
    void Function(String)? onText,
    void Function(String)? onReasoning,
  ) async {
    final StringBuffer content = StringBuffer();
    final StringBuffer reasoning = StringBuffer();
    final Map<int, _ToolAcc> acc = <int, _ToolAcc>{};

    int? usagePrompt;
    int? usageCompletion;
    int? usageReasoning;
    int? usageCacheHit;
    int? usageCacheMiss;

    // ---- 思考计时 ----
    //
    // 记录**两个时刻**，相减才是"思考用了多久"：
    //  · 第一个 reasoning 分片到达 = 开始想；
    //  · 第一个正文分片到达（或流结束）= 想完了。
    //
    // 不在请求发出时起算：那里面含着建连、排队、服务端调度，
    // 用户问的是"它想了多久"，不是"我等了多久"。
    // （想完到输出第一个字之间通常还有几十毫秒的间隙，忽略不计。）
    Stopwatch? thinkingClock;

    final Stream<String> lines = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final String rawLine in lines) {
      if (cancelled) break;

      final String line = rawLine.trim();
      if (line.isEmpty || !line.startsWith('data:')) continue;

      final String data = line.substring(5).trim();
      if (data == '[DONE]') break;
      if (data.isEmpty) continue;

      Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue; // 半截 JSON 或心跳，跳过
      }

      if (chunk['error'] != null) {
        throw ApiException(_humanize(jsonEncode(chunk['error'])));
      }

      // 用量在最后一个 chunk 里，而那个 chunk 的 choices 通常是空数组，
      // 会在下面被 continue 跳过 —— 所以必须在这之前取。
      final dynamic usage = chunk['usage'];
      if (usage is Map) {
        usagePrompt = (usage['prompt_tokens'] as num?)?.toInt() ?? usagePrompt;
        usageCompletion =
            (usage['completion_tokens'] as num?)?.toInt() ?? usageCompletion;
        final dynamic details = usage['completion_tokens_details'];
        if (details is Map) {
          usageReasoning =
              (details['reasoning_tokens'] as num?)?.toInt() ?? usageReasoning;
        }

        // ---- 服务端 prompt cache ----
        //
        // DeepSeek 用 `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`；
        // 部分 OpenAI 兼容服务用 `prompt_tokens_details.cached_tokens`。
        // 两种都认，拿不到就保持 null。
        usageCacheHit =
            (usage['prompt_cache_hit_tokens'] as num?)?.toInt() ??
            usageCacheHit;
        usageCacheMiss =
            (usage['prompt_cache_miss_tokens'] as num?)?.toInt() ??
            usageCacheMiss;
        final dynamic promptDetails = usage['prompt_tokens_details'];
        if (promptDetails is Map) {
          usageCacheHit =
              (promptDetails['cached_tokens'] as num?)?.toInt() ??
              usageCacheHit;
        }
      }

      final List<dynamic> choices =
          (chunk['choices'] as List<dynamic>?) ?? <dynamic>[];
      if (choices.isEmpty) continue;

      final Map<String, dynamic> choice = Map<String, dynamic>.from(
        choices.first as Map,
      );
      final Map<String, dynamic>? delta = choice['delta'] == null
          ? null
          : Map<String, dynamic>.from(choice['delta'] as Map);
      if (delta == null) continue;

      final dynamic c = delta['content'];
      if (c is String && c.isNotEmpty) {
        // 正文一开始，思考就算结束（只在第一次到达时停表）
        if (thinkingClock?.isRunning ?? false) thinkingClock!.stop();
        content.write(c);
        onText?.call(c);
      }

      // 官方 DeepSeek 用 `reasoning_content`；Kilo / OpenRouter 这类
      // 免费聚合网关常用 `reasoning`。两个都认，思考过程才不会消失。
      final dynamic rc = delta['reasoning_content'] ?? delta['reasoning'];
      if (rc is String && rc.isNotEmpty) {
        // 第一个思维链分片 = 开始思考。
        // 用 `??=` 只在第一次启动，后续分片不重置 —— 重置的话
        // 测出来会变成"最后两个分片之间的间隔"，几乎是 0。
        thinkingClock ??= Stopwatch()..start();
        reasoning.write(rc);
        onReasoning?.call(rc);
      }

      final List<dynamic>? tc = delta['tool_calls'] as List<dynamic>?;
      if (tc != null) {
        for (final dynamic item in tc) {
          final Map<String, dynamic> t = Map<String, dynamic>.from(item as Map);
          final int index = (t['index'] as num?)?.toInt() ?? 0;
          final _ToolAcc a = acc.putIfAbsent(index, () => _ToolAcc());

          final dynamic id = t['id'];
          if (id is String && id.isNotEmpty) a.id = id;

          final dynamic fn = t['function'];
          if (fn is Map) {
            final Map<String, dynamic> f = Map<String, dynamic>.from(fn);
            final dynamic name = f['name'];
            if (name is String && name.isNotEmpty) a.name = name;
            final dynamic argsFrag = f['arguments'];
            if (argsFrag is String) a.arguments.write(argsFrag);
          }
        }
      }
    }

    final List<ToolCallRequest> calls = acc.entries
        .where((MapEntry<int, _ToolAcc> e) => e.value.name.isNotEmpty)
        .map(
          (MapEntry<int, _ToolAcc> e) => ToolCallRequest(
            id: e.value.id.isEmpty
                ? 'call_${e.key}_${DateTime.now().microsecondsSinceEpoch}'
                : e.value.id,
            name: e.value.name,
            arguments: e.value.arguments.toString().trim().isEmpty
                ? '{}'
                : e.value.arguments.toString(),
          ),
        )
        .toList();

    // 流结束还没出正文（比如纯思考、或只调工具）也要停表，
    // 否则这个数会一直是 0，界面上就看不到任何时间。
    if (thinkingClock?.isRunning ?? false) thinkingClock!.stop();

    return AssistantTurn(
      content: content.toString(),
      reasoning: reasoning.toString(),
      toolCalls: calls,
      promptTokens: usagePrompt,
      completionTokens: usageCompletion,
      reasoningTokens: usageReasoning,
      cacheHitTokens: usageCacheHit,
      cacheMissTokens: usageCacheMiss,
      reasoningMs: thinkingClock?.elapsedMilliseconds ?? 0,
    );
  }

  /// 把 API 的错误 JSON 变成人话。
  ///
  /// 除了取出服务端的 `message`，还会**识别几种"用错了"的错误并补上怎么办** ——
  /// 服务端的原文只说了现象，没说动作，而用户看到的往往就是这一句话：
  ///
  /// > This model is not supported on chat completions endpoint
  ///
  /// 这话对用户没有帮助：他不知道自己做错了什么（他只是在聊天框里发了句话），
  /// 也不知道该换成什么。而真实原因是**这类模型根本不提供对话接口** ——
  /// `gpt-image-*`、`dall-e-*`、`stable-diffusion-*` 这些是纯文生图模型，
  /// 只有 `/images/generations`，没有 `/chat/completions`。
  ///
  /// 所以这里把它翻成"这个模型只能生图，不能对话；换一个对话模型，
  /// 或者用它来生图"。
  /// 静态方法，便于单独测（错误文案是用户唯一能看到的线索，
  /// 写错了会让排查方向彻底跑偏）。
  @visibleForTesting
  static String humanizeError(String body) => _humanize(body);

  static String _humanize(String body) {
    String message = '';
    try {
      final dynamic j = jsonDecode(body);
      if (j is Map) {
        final dynamic err = j['error'];
        if (err is Map && err['message'] != null) {
          message = err['message'].toString();
        } else if (j['message'] != null) {
          message = j['message'].toString();
        }
      }
    } catch (_) {
      // 不是 JSON，下面用原文
    }
    if (message.isEmpty) {
      message = body.length > 400 ? '${body.substring(0, 400)}…' : body;
    }

    final String hint = _endpointHint(message);
    return hint.isEmpty ? message : '$message\n\n$hint';
  }

  /// 认"用错端点"这类错误，返回一句该怎么做；认不出来返回空串。
  static String _endpointHint(String message) {
    final String m = message.toLowerCase();

    // 0) 内置免费车道的上游拒绝
    if (m.contains('freetier') ||
        m.contains('free tier') ||
        m.contains('free-tier')) {
      return '👉 内置免费通道当前被上游限流或地区限制。\n'
          '· 稍等一会儿再试；应用已自动尝试备用免费池。\n'
          '· 想稳定使用，到「模型」页绑定自己的 API Key 或中转站。';
    }

    // 1) 拿生图模型去对话
    final bool noChat =
        (m.contains('not supported') || m.contains('unsupported')) &&
        (m.contains('chat completion') || m.contains('chat/completions'));
    if (noChat) {
      return '👉 这个模型**不提供对话接口**，只能用来生成图片。\n'
          '· 想聊天：在输入框上方换一个对话模型（名字里通常带 chat / instruct / turbo）。\n'
          '· 想生图：直接说"画一张…"，它会走 `/images/generations`。'
          '如果没反应，到这个模型的编辑页确认「支持生成图片」已勾上。';
    }

    // 2) 反过来：拿对话模型去生图
    if (m.contains('not supported') &&
        (m.contains('image') || m.contains('generation'))) {
      return '👉 这个模型不支持生成图片。\n'
          '· 到这个模型的编辑页把「支持生成图片」**关掉**，免得它一直被调用；\n'
          '· 换一个文生图模型（DALL·E / FLUX / Kolors / CogView 这类）。';
    }

    // 3) 模型名写错了（中转站最常见的一类）
    if (m.contains('model') &&
        (m.contains('not found') ||
            m.contains('does not exist') ||
            m.contains('unknown') ||
            m.contains('invalid'))) {
      return '👉 对方不认识这个模型名。\n'
          '· 到「模型」页用一个**它自己列出来的**名字'
          '（可以用「批量导入」拉一遍列表，照抄）。\n'
          '· 中转站的模型名常带前缀，例如 `openai/gpt-4o`，少一段就会这样。';
    }

    return '';
  }

  /// 免费车道失败到什么程度才值得切备用池。
  ///
  /// 401/400 这类是**配置错了**，换一家只会把真正的原因藏起来；
  /// 403/404/429/5xx 才是"这条车道现在不给我们用"，换池有意义。
  static bool _shouldTryFreeFallback(ApiException e) {
    final int? code = e.statusCode;
    if (code == 403 || code == 404 || code == 408 || code == 429) return true;
    if (code != null && code >= 500) return true;
    final String m = e.message.toLowerCase();
    return m.contains('freetier') ||
        m.contains('free tier') ||
        m.contains('model is unavailable') ||
        m.contains('region') ||
        m.contains('upstream request failed');
  }

  /// 给 OpenCode 免费车道补上它认的客户端指纹。
  ///
  /// 上游会在**声明了 `read` / `shell`** 时才放行免费额度，而且
  /// 这两个名字的定义必须和官方客户端逐字一致。我们并不执行它们：
  /// 它们只是请求形状的一部分，系统消息里明确告诉模型别调用。
  /// 真正能执行的工具仍由 [AgentRunner] 的白名单决定。
  static void _applyOpenCodeFingerprint(Map<String, dynamic> payload) {
    final List<Map<String, dynamic>> tools =
        ((payload['tools'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
    final Set<String> names = tools
        .map((Map<String, dynamic> t) {
          final dynamic fn = t['function'];
          return fn is Map ? fn['name']?.toString() ?? '' : '';
        })
        .where((String n) => n.isNotEmpty)
        .toSet();
    for (final MapEntry<String, Map<String, dynamic>> e
        in _fingerprintTools.entries) {
      if (!names.contains(e.key)) tools.add(e.value);
    }
    payload['tools'] = tools;
    // 免费车道看到 tool_choice: none 会直接 403。
    if (payload['tool_choice'] == 'none') payload.remove('tool_choice');

    final List<Map<String, dynamic>> messages =
        ((payload['messages'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
    messages.insert(0, <String, dynamic>{
      'role': 'system',
      'content':
          'Do not call the `read` or `shell` tools; they are '
          'placeholders that do nothing. Use the other tools you have '
          'been given instead.',
    });
    payload['messages'] = messages;
  }
}

/// 一个稳定的免费车道会话 id。
///
/// 上游按 session 统计免费额度：每个请求都新铸一个会很快吃满 429。
/// 形状是 `ses_` + 12 位时间编码 hex + 14 位 base62，不能直接用随机串。
final String _freeSession = _mintFreeSession();

String _mintFreeSession() {
  final int ts = DateTime.now().millisecondsSinceEpoch;
  final BigInt raw = BigInt.from(ts) * BigInt.from(0x1000) + BigInt.one;
  final BigInt value = -raw - BigInt.one;
  final StringBuffer hex = StringBuffer();
  for (int i = 0; i < 6; i++) {
    final int b = ((value >> (40 - 8 * i)) & BigInt.from(0xff)).toInt();
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  const String alphabet =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  final Random rng = Random.secure();
  final StringBuffer tail = StringBuffer();
  for (int i = 0; i < 14; i++) {
    tail.write(alphabet[rng.nextInt(alphabet.length)]);
  }
  return 'ses_$hex$tail';
}

const Map<String, Map<String, dynamic>>
_fingerprintTools = <String, Map<String, dynamic>>{
  'read': <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'read',
      'description':
          'Read the contents of a file or directory. Supports '
          'text files, images, and PDFs. Images and PDFs are presented '
          'directly to the model. Each text line is prefixed by its 1-based '
          'line number as <line>: <content>. The prefix is for reference '
          'and is not part of the file content. Directory entries are '
          'returned one per line. Use offset and limit to read large files '
          'or directories in sections. Prefer one larger read over many '
          'small slices, and use grep to find specific content in large files.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description': 'File or directory to read',
          },
          'offset': <String, dynamic>{
            'type': 'integer',
            'minimum': 0,
            'description':
                'The line or directory entry to start reading from (1-based)',
          },
          'limit': <String, dynamic>{
            'type': 'integer',
            'minimum': 0,
            'description':
                'The maximum number of lines or directory entries to read '
                '(defaults to and capped at 2000)',
          },
        },
        'required': <String>['path'],
        'additionalProperties': false,
      },
    },
  },
  'shell': <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'shell',
      'description':
          'Execute a shell command and return its output. '
          'Commands run on Linux using bash. Quote file paths containing '
          'spaces or special characters. Prefer dedicated tools over shell '
          'commands when possible. When output is large, the full result is '
          'saved to a file and a truncated preview is returned. Rely on '
          'automatic truncation unless filtering the output is more useful. '
          'Commands accept an optional timeout, background commands have no '
          'timeout by default. Background commands return immediately, and '
          'you will be notified when they complete.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{
            'type': 'string',
            'description': 'Shell command string to execute',
          },
          'workdir': <String, dynamic>{
            'type': 'string',
            'description':
                'Working directory to execute the command in. '
                'Defaults to the current working directory. When possible, '
                'avoid changing directories in the command and set the '
                'working directory here instead.',
          },
          'timeout': <String, dynamic>{
            'type': 'integer',
            'minimum': 0,
            'description':
                'Timeout in milliseconds. Set to 0 to disable the '
                'timeout. Defaults to 120000 for foreground commands. '
                'Background commands have no timeout by default.',
          },
          'background': <String, dynamic>{
            'type': 'boolean',
            'description':
                'Run the command in the background and return '
                'immediately (useful for dev servers and long-running '
                'builds). You do not need to use \'&\' at the end of the '
                'command when using this parameter. You will be notified '
                'when it completes. DO NOT poll for completion.',
          },
        },
        'required': <String>['command'],
        'additionalProperties': false,
      },
    },
  },
};

class _ToolAcc {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
