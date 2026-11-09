// 性能面板里两个"命中率"的口径：
//
//  · 搜索缓存：我们自己本地跳过一次联网请求。以前 `recordSearchCache`
//    **从来没有被调用**，所以卡片永远显示"还没有搜索过"（用户反馈
//    "命中率查不出来"）。
//  · 模型缓存：服务端复用相同的提示词前缀。DeepSeek 会返回
//    `prompt_cache_hit_tokens`，很多中转站不返回 —— 这种时候必须显示
//    "未知"，而不是编一个 0%。
import 'package:dsh_agent/core/metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final AppMetrics m = AppMetrics.instance;

  setUp(m.reset);
  tearDown(m.reset);

  test('搜索缓存：没查询过是"未知"，不是 0%', () {
    expect(m.cacheHitRate, isNull);

    m.recordSearchCache(hit: true);
    m.recordSearchCache(hit: false);
    m.recordSearchCache(hit: false);

    expect(m.searchCacheTotal, 3);
    expect(m.searchCacheHits, 1);
    expect(m.searchCacheMisses, 2);
    expect(m.cacheHitRate, closeTo(1 / 3, 0.0001));
  });

  test('模型缓存：服务端没给明细时保持未知', () {
    expect(m.promptCacheMeasured, isFalse);
    expect(m.promptCacheHitRate, isNull, reason: '"查不出来"和"0% 命中"是两件事');
  });

  test('模型缓存：有明细时按 token 数计算', () {
    m.recordPromptCache(hit: 800, miss: 200);
    expect(m.promptCacheMeasured, isTrue);
    expect(m.promptCacheHitRate, 0.8);

    // 多次请求累加
    m.recordPromptCache(hit: 0, miss: 100);
    expect(m.promptCacheTotal, 1100);
    expect(m.promptCacheHitRate, closeTo(800 / 1100, 0.0001));
  });

  test('模型缓存：明确的 0% 不能显示成"未知"', () {
    m.recordPromptCache(hit: 0, miss: 500);
    expect(m.promptCacheMeasured, isTrue);
    expect(m.promptCacheHitRate, 0.0);
  });
}
