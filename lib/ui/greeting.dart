import '../core/memory.dart';

/// 问候语：全应用**唯一**一处"现在该说早上好还是晚上好"的判断。
///
/// ## 为什么抽成一个类
///
/// 这句话现在有两个地方要说：侧边菜单的抬头，和首页那条**空白对话**上
/// 的问候。两处各写一遍的话，迟早会出现"菜单里是晚上好、空白页是下午好"
/// 这种同一秒里说不通的情况 —— 而这正是"两处实现"的必然结果。
///
/// 顺带把"从记忆里抠称呼"也搬过来：那也是"怎么跟用户打招呼"的一部分。
class Greeting {
  Greeting._();

  /// 全应用取"现在"的地方（问候语和侧边菜单里的时间都用它）。
  ///
  /// 默认就是系统时间。**测试会把它换成固定时刻** —— 没有这一层，
  /// 渲染图里的问候语就跟着时钟走：同一份代码下午出图、晚上再跑就红，
  /// 而 golden 的报错只说"像素不一致"，看起来像界面坏了，
  /// 实际上两张图只差"下午"和"晚上"两个字。
  static DateTime Function() clock = DateTime.now;

  /// 按当前时间挑一个问候词。
  ///
  /// 分界点取 5 / 11 / 13 / 18 点，而不是看"太阳"：凌晨 2 点说"晚上好"、
  /// 早上 5 点说"早上好"都别扭，但被吐槽最多的其实是**深夜**那段 ——
  /// 用 5 点收尾至少让熬夜到 4 点的人不会看到一句"早上好"。
  ///
  /// 「中午」只占 11–13 这两小时：它是三段里最短的一段，因为"中午好"
  /// 的适用范围本来就窄 —— 下午三点还说中午好，比说"下午好"更别扭。
  static String word([DateTime? now]) {
    final int h = (now ?? clock()).hour;
    if (h >= 5 && h < 11) return '早上';
    if (h >= 11 && h < 13) return '中午';
    if (h >= 13 && h < 18) return '下午';
    return '晚上';
  }

  /// 一句完整的问候：「早上好」；从记忆里抠到称呼时是「早上好，小明」。
  ///
  /// 抠不到称呼就不带逗号：留一个空的"好，"看起来像加载失败。
  static String line([DateTime? now]) {
    final String? name = userName();
    return name == null ? '${word(now)}好' : '${word(now)}好，$name';
  }

  /// 从长期记忆里抠一个称呼。抠不到就返回 null。
  ///
  /// 记忆是给**模型**看的自然语言事实（"用户的名字是 XX"），没有
  /// `key`/`value` 这种字段可以精确取，所以只能按关键词找再正则截。
  /// 规矩是：**宁可回退到"你好"，也不显示半截怪句子** ——
  /// 截出来超过 12 个字、或者根本不是人名（带标点、带"的"）的一律丢掉。
  static String? userName() {
    try {
      final Set<MemoryItem> hits = <MemoryItem>{
        ...MemoryStore.instance.search('名字'),
        ...MemoryStore.instance.search('称呼'),
      };
      final RegExp pat = RegExp(
        r'(?:我叫|名字是|名字叫|称呼是|称呼[:：]|叫我|自称)\s*'
        r'([^\s，。,.、；;：:！!？?的]{1,12})',
      );
      for (final MemoryItem m in hits) {
        final RegExpMatch? r = pat.firstMatch(m.text.trim());
        if (r != null) return r.group(1);
      }
    } catch (_) {
      // 记忆单例没初始化（测试环境）时当作"没有名字"，不影响界面渲染。
    }
    return null;
  }
}
