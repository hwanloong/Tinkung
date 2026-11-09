import 'dart:io';

/// 把模型给的路径整理成可以直接读写的形式。
///
/// ## 为什么还需要这一层
///
/// 以前这里叫 `WorkGroupStore.resolveModelPath`，负责把**相对路径**解释成
/// 工作空间目录里的文件（模型不该自己拼绝对路径）。工作空间删掉之后，
/// 那条规则仍然需要，只是**基准目录变了**：现在相对路径相对 [baseDir]
/// （通常是应用的工作目录）。
///
/// ## 规则
///
/// · 空串 → 空串（调用方自己判错）；
/// · 绝对路径（`/x`、`C:\x`）→ 原样返回，模型明确给了绝对位置；
/// · 以 `..` 开头的相对路径 → 原样返回，不替它"修正" —— 让它自己撞到
///   "文件不存在"比悄悄把路径改到别处诚实；
/// · 其余 → 拼到 [baseDir] 后面。
String resolveModelPath(String raw, {String? baseDir}) {
  final String p = raw.trim();
  if (p.isEmpty) return p;
  if (p.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p)) {
    return p;
  }
  final String base = (baseDir ?? '').trim();
  if (base.isEmpty) return p;
  final String rel = p
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'^(\./)+'), '');
  if (rel.split('/').contains('..')) return p;
  return '$base/$rel';
}

/// 归一化成绝对路径，用于"这次任务里读过/写过哪个文件"的比较。
String normalizedAbsolute(String raw, {String? baseDir}) {
  try {
    return File(resolveModelPath(raw, baseDir: baseDir)).absolute.path;
  } catch (_) {
    return raw.trim();
  }
}
