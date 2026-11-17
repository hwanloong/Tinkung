import 'dart:convert';
import 'dart:io';

import '../core/models.dart';
import 'tool.dart';

/// 文件读写。
///
/// 全部走 Dart 的 `dart:io`，不再依赖任何系统 shell 权限：
/// 应用自己的私有目录、工作空间、`/sdcard`（已授予「所有文件访问」时）
/// 都能直接读写。模型拿到的路径就是它该用的路径。
class FileTool extends AgentTool {
  const FileTool();

  @override
  String get name => 'file_op';

  @override
  String get title => '文件';

  @override
  String get description =>
      '读写设备文件。action 取值：'
      'list（列目录）、read（读文件，text 或 base64）、write（写文件）、'
      'append（追加）、delete（删除，危险）、move、copy、mkdir、'
      'search（按文件名查找）、stat（查看属性）。'
      'read 大文件用 offset / limit **分段读**（1 起算的行号）：'
      '一次只返回一段，读完一段再读下一段，不要反复整文件读。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'action': <String, dynamic>{
        'type': 'string',
        'enum': <String>[
          'list',
          'read',
          'write',
          'append',
          'delete',
          'move',
          'copy',
          'mkdir',
          'search',
          'stat',
        ],
      },
      'path': <String, dynamic>{
        'type': 'string',
        'description': '目标路径，如 /sdcard/Download/a.txt',
      },
      'dest': <String, dynamic>{
        'type': 'string',
        'description': 'move / copy 的目标路径',
      },
      'content': <String, dynamic>{
        'type': 'string',
        'description': 'write / append 的文本内容',
      },
      'encoding': <String, dynamic>{
        'type': 'string',
        'enum': <String>['text', 'base64'],
        'description': 'read 时返回格式，默认 text',
      },
      'pattern': <String, dynamic>{
        'type': 'string',
        'description': 'search 的文件名匹配，如 *.log',
      },
      'offset': <String, dynamic>{
        'type': 'integer',
        'description': 'read 起始行号（1 起算）。默认 1。',
      },
      'limit': <String, dynamic>{
        'type': 'integer',
        'description': 'read 最多读多少行。默认 0 = 不限（仍受单次输出上限约束）。',
      },
    },
    'required': <String>['action', 'path'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) {
    final String action = args.str('action');
    final String path = args.str('path');

    switch (action) {
      case 'delete':
        return RiskAssessment(RiskLevel.dangerous, <String>[
          '删除 $path，删除后无法从回收站恢复',
        ]);
      case 'write':
      case 'append':
        return RiskAssessment(RiskLevel.caution, <String>['写入或覆盖 $path']);
      case 'move':
      case 'copy':
        return RiskAssessment(RiskLevel.caution, <String>[
          '$action 文件：$path → ${args.str('dest')}',
        ]);
      case 'mkdir':
        return RiskAssessment(RiskLevel.caution, <String>['创建目录 $path']);
      default:
        return RiskAssessment.safe;
    }
  }

  @override
  String summarize(Map<String, dynamic> args) {
    final String a = args.str('action');
    return '$a ${args.str('path')}';
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String action = args.str('action');
    final String path = args.str('path').trim();
    if (path.isEmpty) return '错误：path 不能为空';

    try {
      switch (action) {
        case 'list':
          return _list(path);

        case 'read':
          return _read(args, path);

        case 'write':
        case 'append':
          final String content = args.str('content');
          final File f = File(path);
          await f.parent.create(recursive: true);
          if (action == 'write') {
            await f.writeAsString(content);
          } else {
            await f.writeAsString(content, mode: FileMode.append);
          }
          return '${action == 'write' ? '已写入' : '已追加'} ${content.length} 字符：$path';

        case 'delete':
          return _delete(path);

        case 'move':
          final String dest = args.str('dest').trim();
          if (dest.isEmpty) return '错误：缺少 dest';
          return _move(path, dest);

        case 'copy':
          final String dest = args.str('dest').trim();
          if (dest.isEmpty) return '错误：缺少 dest';
          return _copy(path, dest);

        case 'mkdir':
          await Directory(path).create(recursive: true);
          return '已创建目录：$path';

        case 'search':
          final String pattern = args.str('pattern', fallback: '*');
          return _search(path, pattern);

        case 'stat':
          return _stat(path);

        default:
          return '错误：未知 action「$action」';
      }
    } catch (e) {
      return '操作失败：$e';
    }
  }

  String _list(String path) {
    final Directory dir = Directory(path);
    if (!dir.existsSync()) {
      final File f = File(path);
      if (!f.existsSync()) return '路径不存在：$path';
      return _stat(path);
    }
    final List<FileSystemEntity> items = dir.listSync(followLinks: false)
      ..sort((FileSystemEntity a, FileSystemEntity b) =>
          a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    if (items.isEmpty) return '目录为空：$path';
    final StringBuffer sb = StringBuffer('$path/\n');
    for (final FileSystemEntity e in items) {
      final String name = e.path.split(Platform.pathSeparator).last;
      final FileStat st = e.statSync();
      final String kind = e is Directory ? 'd' : (e is Link ? 'l' : '-');
      final String size = e is Directory ? '-' : '${st.size}';
      sb.writeln('$kind  ${size.padLeft(9)}  ${_fmtTime(st.modified)}  $name');
    }
    return clampOutput(sb.toString());
  }

  String _read(Map<String, dynamic> args, String path) {
    final File f = File(path);
    if (!f.existsSync()) return '文件不存在：$path';
    if (args.str('encoding', fallback: 'text') == 'base64') {
      return base64Encode(f.readAsBytesSync());
    }

    final int offset = args.intVal('offset', fallback: 0);
    final int limit = args.intVal('limit', fallback: 0);

    // 不分段时保持老行为：整份读 + 截断。
    if (offset <= 1 && limit <= 0) {
      return clampOutput(_decodeText(f.readAsBytesSync()));
    }

    final int start = offset <= 0 ? 1 : offset;
    final List<String> lines = const LineSplitter().convert(
      _decodeText(f.readAsBytesSync()),
    );
    if (start > lines.length) {
      return '第 $start 行没有内容（文件共 ${lines.length} 行）。';
    }
    final int end = limit <= 0
        ? lines.length
        : (start + limit - 1).clamp(start, lines.length);
    final String body = lines.sublist(start - 1, end).join('\n');
    if (body.trim().isEmpty) {
      return '第 $start–$end 行没有内容（文件可能到此为止）。';
    }
    return '【第 $start–$end 行】\n${clampOutput(body)}\n'
        '（要接着读就 offset=${end + 1}）';
  }

  String _delete(String path) {
    final File f = File(path);
    if (f.existsSync()) {
      f.deleteSync();
      return '已删除文件：$path';
    }
    final Directory d = Directory(path);
    if (d.existsSync()) {
      d.deleteSync(recursive: true);
      return '已删除目录：$path';
    }
    return '路径不存在：$path';
  }

  String _move(String path, String dest) {
    final File src = File(path);
    final Directory srcDir = Directory(path);
    if (!src.existsSync() && !srcDir.existsSync()) {
      return '路径不存在：$path';
    }
    final Directory destDir = Directory(dest);
    final bool intoDir = destDir.existsSync();
    if (src.existsSync()) {
      final String target =
          intoDir ? '$dest${Platform.pathSeparator}${_basename(path)}' : dest;
      src.renameSync(target);
      return '已移动：$path → $target';
    }
    final String target =
        intoDir ? '$dest${Platform.pathSeparator}${_basename(path)}' : dest;
    srcDir.renameSync(target);
    return '已移动：$path → $target';
  }

  String _copy(String path, String dest) {
    final File src = File(path);
    if (src.existsSync()) {
      final String target = Directory(dest).existsSync()
          ? '$dest${Platform.pathSeparator}${_basename(path)}'
          : dest;
      final File out = src.copySync(target);
      return '已复制：$path → ${out.path}';
    }
    final Directory srcDir = Directory(path);
    if (!srcDir.existsSync()) return '路径不存在：$path';
    final String target = Directory(dest).existsSync()
        ? '$dest${Platform.pathSeparator}${_basename(path)}'
        : dest;
    _copyDir(srcDir, Directory(target));
    return '已复制目录：$path → $target';
  }

  static void _copyDir(Directory src, Directory dest) {
    dest.createSync(recursive: true);
    for (final FileSystemEntity e in src.listSync(followLinks: false)) {
      final String name = _basename(e.path);
      if (e is Directory) {
        _copyDir(e, Directory('${dest.path}${Platform.pathSeparator}$name'));
      } else if (e is File) {
        e.copySync('${dest.path}${Platform.pathSeparator}$name');
      }
    }
  }

  String _search(String path, String pattern) {
    final Directory root = Directory(path);
    if (!root.existsSync()) return '目录不存在：$path';
    final RegExp re = _globToRegExp(pattern);
    final List<String> hits = <String>[];
    try {
      for (final FileSystemEntity e
          in root.listSync(recursive: true, followLinks: false)) {
        final String name = _basename(e.path);
        if (re.hasMatch(name)) hits.add(e.path);
        if (hits.length >= 500) break;
      }
    } catch (e) {
      return '搜索失败：$e';
    }
    if (hits.isEmpty) return '没有匹配「$pattern」的文件：$path';
    return clampOutput('找到 ${hits.length} 个：\n${hits.join('\n')}');
  }

  String _stat(String path) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return '路径不存在：$path';
    final FileStat st = FileStat.statSync(path);
    final String kind = switch (type) {
      FileSystemEntityType.directory => '目录',
      FileSystemEntityType.link => '链接',
      _ => '文件',
    };
    return '路径：$path\n'
        '类型：$kind\n'
        '大小：${st.size} 字节\n'
        '修改时间：${_fmtTime(st.modified)}';
  }

  static String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  static String _basename(String p) =>
      p.split(Platform.pathSeparator).where((String s) => s.isNotEmpty).last;

  static String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static RegExp _globToRegExp(String glob) {
    final StringBuffer sb = StringBuffer('^');
    for (int i = 0; i < glob.length; i++) {
      final String c = glob[i];
      if (c == '*') {
        sb.write('.*');
      } else if (c == '?') {
        sb.write('.');
      } else {
        sb.write(RegExp.escape(c));
      }
    }
    sb.write(r'$');
    return RegExp(sb.toString(), caseSensitive: false);
  }
}
