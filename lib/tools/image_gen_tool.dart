import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../core/model_profile.dart' show kImageGenTool;
import '../core/models.dart';
import '../core/net_error.dart';
import '../core/store.dart';
import 'tool.dart';
import 'vision_image.dart';

/// 用模型**生成**图片。
///
/// ## 和 [ImageTool]（识图）的区别
///
/// · `read_image` = 把图**给模型看**（多模态输入）
/// · `generate_image` = 让模型**画一张图**（多模态输出）
///
/// 两个方向相反，能力也互不蕴含 —— 有的模型只看得懂图，有的只会画图。
/// 所以模型档案上有两个独立开关（`vision` / `image`），
/// 这个工具只在 `image` 打开时注册。
///
/// ## 为什么走 `/images/generations`
///
/// 这是 OpenAI 规范的文生图端点，也是**事实标准**：
/// DALL·E、FLUX、Kolors、CogView、Seedream、通义万相的中转实现
/// 基本都照这个形状提供。相比之下"让聊天模型在回复里返回图片"
/// （`modalities: ["image","text"]`）各家差异大得多，兼容性差。
///
/// ## 返回什么给模型
///
/// **返回文件路径，不返回 base64**。一张 1024×1024 的 PNG 转 base64 是
/// 上百万字符，直接塞进上下文会把这一轮彻底撑爆。给路径之后，
/// 模型可以再用 `read_image` 去看它（需要时），或者把它交给用户打开。
///
/// ## 多图（2026-10-16 补的）
///
/// "把图二的衣服 P 到图一上"这类需求要的是**两张图一起**送进编辑端点：
/// 生图模型只看得到图、看不到对话里的"图一/图二"这种指代，只发一张
/// 它就只能凭空编另一半（以前的实现只收一个 `edit_from`，
/// 用户看到的就是"生图错误"或者一张毫无关系的图）。
///
/// 所以 `edit_from` 现在是**数组**，并且按"可能性从高到低"依次尝试
/// 各家收多图的方式（`image[]` 多个文件字段 / `image` 重复 / JSON 数组）。
class ImageGenTool extends AgentTool {
  const ImageGenTool();

  @override
  String get name => kImageGenTool;

  @override
  String get title => '生图';

  @override
  String get description =>
      '根据文字描述生成一张图片，保存到工作目录并返回文件路径。'
      '适用于"画一张…""生成一张…的图""给我做个配图"。'
      '提示词用**描述性**的自然语言（画面内容、风格、构图、光线），'
      '不要用"生成/画"这类指令词开头。\n'
      '**改图**（"把这张图的背景换掉""给这张照片加个帽子"）用 `edit_from` '
      '指向源图片 —— 那条路会**保留原图**，只按提示词改动，'
      '而不是从头画一张很像的。用户说"改一下/换成/加上/去掉"时一定要用它，'
      '否则等于把他给的图丢了。\n'
      '**两张以上一起用**（"把图二的衣服 P 到图一上""把第二张的衣服穿到'
      '第一张的人身上""用这两张图合成一张"）也是同一条路：把**所有**要用的'
      '路径按顺序放进 `edit_from`（顺序 = 图 1、图 2…）。'
      'prompt 里必须按顺序说清哪张是哪张（"第一张图里的人穿第二张图的衣服"），'
      '不要写"图二"这种只有对话里才成立的指代。\n'
      '这不是识图工具 —— 要看图请用 read_image。';

  @override
  Map<String, dynamic> get parameters => <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'prompt': <String, dynamic>{
        'type': 'string',
        'description':
            '画面描述。建议写清主体、风格、构图、光线。'
            '改图时写**要改成什么**（"把背景换成海边"），'
            '不要写"修改这张图"。',
      },
      'size': <String, dynamic>{
        'type': 'string',
        'description': '图片尺寸，如 1024x1024 / 1024x1792 / 1792x1024',
      },
      'edit_from': <String, dynamic>{
        // 数组而不是字符串：多图合成（换装 / 换背景 / 拼一张）是
        // 同一件事，只是源图不止一张。**一张也写成数组** `["路径"]`，
        // 这样"一张"和"多张"在协议上永远只有一种形状，模型不用猜。
        'type': 'array',
        'items': <String, dynamic>{'type': 'string'},
        'description':
            '**改图 / 多图合成**：源图片路径（或 http 地址），'
            '按顺序给 —— 顺序就是"图 1、图 2…"，交给生图模型时也是这个顺序。'
            '一张写 `["路径"]`，两张写 `["图1路径","图2路径"]`。'
            '给了它就变成"图片编辑"而不是"从头生成" —— '
            '想保留原图的构图/主体、只改一部分、或者把两张图合起来时用它。'
            '省略则是纯文生图。',
      },
    },
    'required': <String>['prompt'],
  };

  @override
  RiskAssessment riskFor(Map<String, dynamic> args) => RiskAssessment.safe;

  @override
  String summarize(Map<String, dynamic> args) {
    final String p = clampOutput(args.str('prompt'), max: 40);
    final int n = sourcesOf(args).length;
    if (n == 0) return '生图 $p';
    return n == 1 ? '改图 $p' : '合成 $n 张图 $p';
  }

  /// 把 `edit_from` 读成一组源图片。
  ///
  /// 只认数组是**不够**的：模型（尤其小模型）经常照旧给一个字符串，
  /// 而"参数类型不对"在服务端只会变成一句看不懂的 400。所以两种都收：
  /// 字符串 = 一张，数组 = 按顺序的多张。
  ///
  /// 顺带把空串和空数组滤掉 —— `["", "x.png"]` 这种写法模型真给得出来，
  /// 放过去就是"找不到源图片"，白费一轮。
  @visibleForTesting
  static List<String> sourcesOf(Map<String, dynamic> args) {
    final dynamic v = args['edit_from'] ?? args['editFrom'] ?? args['image'];
    final List<String> out = <String>[];
    void add(dynamic e) {
      final String s = e?.toString().trim() ?? '';
      if (s.isEmpty) return;
      if (!out.contains(s)) out.add(s);
    }

    if (v is List) {
      for (final dynamic e in v) {
        add(e);
      }
    } else {
      add(v);
    }
    return out;
  }

  @override
  Future<String> run(ToolContext ctx, Map<String, dynamic> args) async {
    final String prompt = args.str('prompt').trim();
    if (prompt.isEmpty) return '生成失败：prompt 不能为空';

    // 用**生图专用**的配置，而不是"当前对话模型"。
    // 两者几乎不会是同一个：生图模型（gpt-image-2 这类）不能对话，
    // 对话模型（deepseek 这类）不能生图。见 Settings.imageGenConfig。
    final ImageGenConfig? cfg = ctx.imageGen;
    if (cfg == null || !cfg.usable) {
      return '生成失败：还没有配置生图模型。\n'
          '到「设置 → 生图」选一个用途为生图的模型，并填上模型名'
          '（例如 `gpt-image-2` / `dall-e-3` / `flux-schnell`）。';
    }

    // ---- 改图还是文生图 ----
    //
    // 用户给了一张图 + "把背景换掉" 时，必须走**编辑端点**。
    // 走文生图等于把他给的图丢掉，从头画一张"像的" ——
    // 主体、构图、风格全变了，用户会认为"它根本没看我给的图"。
    // `edit_from` 可能写成字符串（一张）或数组（多张），统一读成列表。
    final List<String> editFrom = sourcesOf(args);

    final Uri uri;
    try {
      uri = Uri.parse(cfg.endpoint);
    } catch (_) {
      return '生成失败：接口地址不合法（${cfg.endpoint}）';
    }

    // 尺寸：只在**模型明确要**的时候发。
    //
    // 不提供"默认尺寸"设置：各家支持的值不同（`gpt-image-*` 只认
    // 1024x1024 / 1024x1536 / 1536x1024，dall-e 又是另一套），
    // 填错是 400。**不发这个参数**由服务端按模型自己挑，是唯一不会错的选项。
    final String size = args.str('size').trim();

    return editFrom.isEmpty
        ? await _generate(ctx, uri, cfg, prompt, size)
        : await _edit(ctx, uri, cfg, prompt, size, editFrom);
  }

  /// 纯文生图（`/images/generations`）。
  Future<String> _generate(
    ToolContext ctx,
    Uri uri,
    ImageGenConfig cfg,
    String prompt,
    String size,
  ) async {
    try {
      // ---- `response_format` 发不发，**先问一次再决定** ----
      //
      // 各家在这里的做法互相矛盾，没法一开始就猜对：
      //
      //  · 一部分实现（含 OpenAI 的 `gpt-image-*`）**不接受这个参数**，
      //    传了就 400（unknown parameter）—— 但它们的返回本来就是 b64，
      //    不需要这个参数；
      //  · 另一部分（`dall-e-2/3` 默认、以及不少中转站）**默认返回 url**，
      //    而 url 一小时就失效；这时要么发 `b64_json`，要么就得立刻下载。
      //
      // 所以顺序是：**先要 b64**（最省事、结果最确定），
      // 被拒（400 且报错里提到这个参数）就**去掉它重发一次**。
      // 代价是最坏情况多一个请求；收益是不用让用户去猜自己那家属于哪种。
      http.Response resp = await _post(uri, cfg, <String, dynamic>{
        'model': cfg.model,
        'prompt': prompt,
        'n': 1,
        if (size.isNotEmpty) 'size': size,
        'response_format': 'b64_json',
      });

      if (resp.statusCode == 400 &&
          _mentionsUnknownParam(resp.bodyBytes, 'response_format')) {
        resp = await _post(uri, cfg, <String, dynamic>{
          'model': cfg.model,
          'prompt': prompt,
          'n': 1,
          if (size.isNotEmpty) 'size': size,
        });
      }

      if (resp.statusCode != 200) {
        return '生成失败：HTTP ${resp.statusCode}\n'
            '${_humanize(resp.bodyBytes)}\n\n'
            '（接口：$uri）';
      }

      final String body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final GenImage? img = parseImageResponse(body);
      if (img == null) {
        return '生成失败：返回里没有图片数据。\n'
            '（接口：$uri）\n'
            '${clampOutput(body, max: 600)}';
      }

      // base64 直接落盘；url 立刻下载（它的有效期常常只有一小时）
      final List<int>? bytes =
          img.bytes ?? await _download(img.url!, apiKey: cfg.apiKey);
      if (bytes == null || bytes.isEmpty) {
        return '生成失败：拿到了图片地址但下载不下来。\n'
            '${img.url}\n\n'
            '（有些中转站的图片地址需要额外的鉴权头，或者很快就失效 —— '
            '这是对方服务的行为，不是本地保存失败。）';
      }

      final String path = await _save(ctx.workDir, bytes, img.mime);
      return '已生成图片并保存到：$path\n'
          '（${(bytes.length / 1024).round()} KB）\n'
          '提示词：${clampOutput(prompt, max: 200)}\n\n'
          '需要看图内容就用 read_image 读这个路径；'
          '也可以直接把路径告诉用户。';
    } catch (e) {
      return '生成失败：${NetError.describe(e)}';
    }
  }

  /// **改图**（`/images/edits`）。
  ///
  /// ## 协议选择：几种发法，按可能性依次尝试
  ///
  /// 图片编辑这块**没有事实标准**，各家实现分三类：
  ///
  ///  1. **multipart/form-data**（OpenAI 官方的 `/images/edits`）——
  ///     `image` 文件字段 + `prompt` 文本字段；多张图时官方用 `image[]`；
  ///  2. **JSON + base64**（不少中转站，以及 `gpt-image-*` 的某些实现）——
  ///     `{"image": "<base64>"}`，有时要写成 data URL；多张时给数组；
  ///  3. **JSON + 图片 URL** —— 源图本身是 http 地址时最省事。
  ///
  /// 猜错的表现是 400 或 415，而报错通常只说"参数不对"，
  /// 不会告诉你"我们这里要 multipart"。所以**依次试**，
  /// 每个都失败就把各路的报错一起给用户 —— 比猜一个然后失败有用得多。
  ///
  /// ## 多图：字段名也要跟着变（2026-10-16）
  ///
  /// 张数不同，**字段名**也不同：一张是 `image`（各家都认），
  /// 官方多图编辑是 `image[]`（出现多次），另一些中转站仍旧用 `image`
  /// 重复出现。所以多图时这两种都试 —— 只试一种的话，
  /// 猜错的那一半用户会直接得到"生图错误"。
  ///
  /// ## 为什么源图是本地的要先读成字节
  ///
  /// 用户给的图通常是应用生成的（私有目录里的绝对路径），
  /// 那种路径**外部服务当然访问不到**，所以只能把字节发过去。
  Future<String> _edit(
    ToolContext ctx,
    Uri uri,
    ImageGenConfig cfg,
    String prompt,
    String size,
    List<String> editFrom,
  ) async {
    // 编辑端点：把 `/generations` 换成 `/edits`。
    // 用户的 baseUrl 可能已经带 `/v1`，所以只替换最后一段。
    final Uri editUri = _editEndpoint(uri);

    // ---- 先把**每一张**源图都解析成"能发出去的东西" ----
    //
    // 模型给的常常**不是完整路径**：它在上文里看到的是文件名
    // （"photo.jpg"），或者给一个相对工作目录的路径。而附件真正落在
    // `<workDir>/attachments/<时间戳>.<ext>` —— 文件名和磁盘路径对不上。
    // 所以每张都依次试几个可能的位置（见 [_resolveSource]），
    // 而不是见到不存在就直接判失败（那样等于白费一轮，用户只会看到
    // "改图失败"）。
    //
    // 本地图读成字节，网络图留 URL：应用私有目录里的路径，
    // 外部服务当然访问不到。
    final List<_EditSource> pics = <_EditSource>[];
    for (final String raw in editFrom) {
      if (raw.startsWith('http://') || raw.startsWith('https://')) {
        pics.add(_EditSource(url: raw));
        continue;
      }
      final File? f = await _resolveSource(ctx, raw);
      if (f == null) {
        return '改图失败：找不到源图片 —— $raw\n'
            '（原地、相对工作目录、以及 `<工作目录>/attachments/` 下都找过了。）\n'
            '用户刚上传的图片，完整路径就写在消息里的【附图片 …】那一段，'
            '**照抄那个路径**。'
            '${editFrom.length > 1 ? '\n这次要一起用的图有 ${editFrom.length} 张，'
                      '**每一张**都要能找到。' : ''}';
      }
      try {
        pics.add(
          _EditSource(
            path: f.path,
            bytes: await f.readAsBytes(),
            fileName: f.path.split(Platform.pathSeparator).last,
          ),
        );
      } catch (e) {
        return '改图失败：读不了源图片（${f.path}）：$e';
      }
    }
    if (pics.isEmpty) return '改图失败：没有可用的源图片。';

    // 大小上限：base64 会把体积撑大约 1/3，而很多服务对请求体有
    // 硬上限（常见 10~20MB）。超过就直接说清楚，不要发出去等超时。
    // 多图时看的是**加起来**的体积 —— 两张 8MB 的图一样会把请求撑爆。
    final int totalBytes = pics.fold<int>(
      0,
      (int s, _EditSource p) => s + (p.bytes?.length ?? 0),
    );
    if (totalBytes > 12 * 1024 * 1024) {
      return '改图失败：源图片太大'
          '（${editFrom.length} 张共 ${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB）。\n'
          '很多生图服务对请求体有 10~20MB 的上限。'
          '可以先用 `python` 把它们缩小再改。';
    }

    final List<String> errors = <String>[];

    // ---- 尝试 1：multipart（官方形式）----
    //
    // 字段名按张数分：一张 `image`；多张先 `image[]`，再退回重复的 `image`。
    final List<String> fieldNames = pics.length > 1
        ? <String>['image[]', 'image']
        : <String>['image'];

    for (final String field in fieldNames) {
      try {
        final http.MultipartRequest req = http.MultipartRequest('POST', editUri)
          ..headers['Authorization'] = 'Bearer ${cfg.apiKey}'
          ..fields['model'] = cfg.model
          ..fields['prompt'] = prompt
          ..fields['n'] = '1';
        if (size.isNotEmpty) req.fields['size'] = size;

        bool attachedAll = true;
        for (final _EditSource p in pics) {
          if (p.url != null) {
            // multipart 里没法直接放 URL，先把图下下来
            final List<int>? dl = await _download(p.url!, apiKey: cfg.apiKey);
            if (dl == null) {
              errors.add('multipart（$field）：源图片地址下载失败（${p.url}）');
              attachedAll = false;
              break;
            }
            req.files.add(
              http.MultipartFile.fromBytes(field, dl, filename: 'image.png'),
            );
          } else {
            // 走 asUpload：和 JSON 那条路一样先压成 JPEG ——
            // 上传原图给图编辑接口，同样会撞请求体上限。
            final ({List<int> bytes, String name}) up = p.asUpload();
            req.files.add(
              http.MultipartFile.fromBytes(field, up.bytes, filename: up.name),
            );
          }
        }
        if (!attachedAll) continue;

        final http.StreamedResponse sr = await req.send().timeout(
          const Duration(seconds: 180),
        );
        final http.Response resp = await http.Response.fromStream(sr);
        final GenImage? img = _imageFrom(resp);
        if (img != null) {
          return await _editSuccess(ctx, cfg, prompt, img, pics.length);
        }
        errors.add(
          'multipart（$field）：HTTP ${resp.statusCode} '
          '${_humanize(resp.bodyBytes)}',
        );
      } catch (e) {
        errors.add('multipart（$field）：${NetError.describe(e)}');
      }
    }

    // ---- 尝试 2：JSON + data URL ----
    //
    // 源图是网络地址时用原始 URL，是本地的就用 data URL。
    // data URL 比裸 base64 兼容性好：有些实现靠前缀判断类型。
    //
    // 多图有两套写法，都试：同一个 `image` 字段给数组（主流），
    // 以及换个字段名 `images`（一部分中转站这么收）。
    final List<dynamic> imageFields = pics
        .map((_EditSource p) => p.asImageField())
        .toList();
    final List<Map<String, dynamic>> jsonPlans = <Map<String, dynamic>>[
      <String, dynamic>{
        'model': cfg.model,
        'prompt': prompt,
        'image': pics.length == 1 ? imageFields.first : imageFields,
        'n': 1,
        if (size.isNotEmpty) 'size': size,
      },
      if (pics.length > 1)
        <String, dynamic>{
          'model': cfg.model,
          'prompt': prompt,
          'images': imageFields,
          'n': 1,
          if (size.isNotEmpty) 'size': size,
        },
    ];

    for (int i = 0; i < jsonPlans.length; i++) {
      final String tag = pics.length == 1 ? 'JSON' : 'JSON（第 ${i + 1} 种字段名）';
      try {
        final http.Response resp = await _post(editUri, cfg, jsonPlans[i]);
        final GenImage? img = _imageFrom(resp);
        if (img != null) {
          return await _editSuccess(ctx, cfg, prompt, img, pics.length);
        }
        errors.add('$tag：HTTP ${resp.statusCode} ${_humanize(resp.bodyBytes)}');
      } catch (e) {
        errors.add('$tag：${NetError.describe(e)}');
      }
    }

    return '改图失败：试过的发法都不被接受'
        '${pics.length > 1 ? '（这次是 ${pics.length} 张图一起发，'
                  '如果对方只支持单张编辑，这一步就不会成功）' : ''}。\n\n'
        '接口：$editUri\n'
        '模型：${cfg.model}\n\n'
        '${errors.map((String e) => '· $e').join('\n')}\n\n'
        '（图片编辑没有统一标准：OpenAI 官方用 multipart，'
        '很多中转站用 JSON+base64，多图又各有各的字段名。'
        '上面是每一路的**真实报错**，据此能判断你这家的接口形状；'
        '把这段发给开发者就能定位。）';
  }

  /// 把模型给的 `edit_from` 解析成一个**真实存在**的文件。
  ///
  /// 依次试（顺序就是"从最可能到最兜底"）：
  ///  1. 原样 —— 完整绝对路径，正常情况就是它；
  ///  2. 相对**工作目录**的路径；
  ///  3. `<工作目录>/attachments/<名字>` —— 用户在聊天里上传的图片
  ///     全都落在这个目录下，而模型看到的是**原始文件名**
  ///     （`IMG_2034.jpg`），真正的文件名是 `<时间戳>.jpg`。
  ///
  /// 为什么要容忍这一步：模型把路径写错是**很常见**的事（它只见过
  /// 文件名），而严格校验的代价是整轮白跑、用户只看到"改图失败"。
  /// 这里多试两次的成本是几次 stat。
  ///
  /// 顺带把包在路径外面的引号去掉 —— 模型经常写成 `"…/a.png"`。
  static Future<File?> _resolveSource(ToolContext ctx, String raw) async {
    final String p = raw.trim().replaceAll('"', '').replaceAll("'", '');
    if (p.isEmpty) return null;

    final List<String> candidates = <String>[
      p,
      if (!p.startsWith('/')) '${ctx.workDir}/$p',
      if (!p.startsWith('/')) '${ctx.workDir}/attachments/$p',
    ];
    for (final String c in candidates) {
      final File f = File(c);
      try {
        if (await f.exists()) return f;
      } catch (_) {
        // 单个候选读不了就继续试下一个
      }
    }
    return null;
  }

  /// 从一次响应里取出图片（非 200 或没有图都返回 null）。
  static GenImage? _imageFrom(http.Response resp) {
    if (resp.statusCode != 200) return null;
    return parseImageResponse(
      utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
  }

  /// 改图成功后落盘并拼出给模型的说明。
  ///
  /// `count` = 这次送进去几张源图，只用来决定那句话怎么说 ——
  /// 一张是"改好"，多张是"合成"。**必须说对**：用户看到"改好了"
  /// 但其实是两张拼的，会以为图里多出来的东西是模型自己加的。
  Future<String> _editSuccess(
    ToolContext ctx,
    ImageGenConfig cfg,
    String prompt,
    GenImage img,
    int count,
  ) async {
    final List<int>? bytes =
        img.bytes ?? await _download(img.url!, apiKey: cfg.apiKey);
    if (bytes == null || bytes.isEmpty) {
      return '改图失败：拿到了图片地址但下载不下来（${img.url}）';
    }
    final String path = await _save(ctx.workDir, bytes, img.mime);
    final String what = count > 1
        ? '已按你的要求把 $count 张图合成并保存到'
        : '已按你的要求改好图片并保存到';
    return '$what：$path\n'
        '（${(bytes.length / 1024).round()} KB）\n'
        '改动说明：${clampOutput(prompt, max: 200)}\n\n'
        '**把上面这个路径写进回复**，用户就能在正文里直接看到图。';
  }

  /// `/images/generations` → `/images/edits`。
  ///
  /// 只替换**最后一段**而不是拼字符串：用户的 baseUrl 可能带 `/v1`、
  /// 可能带别的前缀，也可能已经是完整端点。用 URI 解析比字符串
  /// 替换可靠（`replaceAll('generations','edits')` 会连路径中间
  /// 恰好叫这个名字的段一起改掉）。
  static Uri _editEndpoint(Uri u) => editEndpointForTest(u);

  /// [_editEndpoint] 的公开别名，便于单独测。
  ///
  /// 为什么值得测：用户的 baseUrl 形态很多（`https://x/v1`、
  /// `https://x/v1/images/generations`、`https://x/api/v3`…），
  /// 替换错了就是 404，而 404 的报错只会说"接口不存在"，
  /// 完全看不出是本地把路径拼坏了。
  @visibleForTesting
  static Uri editEndpointForTest(Uri u) {
    final List<String> segs = List<String>.from(u.pathSegments);
    if (segs.isEmpty) return u.replace(path: '/v1/images/edits');

    // 三种形态分开处理，**按顺序判断**（顺序不能换）：
    //
    //  1. 路径里已经有 `images` —— 说明用户给的是完整端点或
    //     `<base>/images`，那么只替换/补上**最后一段**；
    //  2. 否则（只给了域名或 `/v1`）—— 补全整条 `images/edits`。
    //
    // 先判 `images` 是关键：只给 `/v1` 时如果直接 append，
    // 会得到 `/v1/edits`（少一层 `images`），那是 404。
    final int imagesAt = segs.lastIndexOf('images');
    if (imagesAt >= 0) {
      final List<String> head = segs.sublist(0, imagesAt + 1);
      // 已经以 `/images/edits` 结尾 → 原样返回（幂等，
      // 免得重复调用时变成 `/images/edits/edits`）
      if (segs.length == imagesAt + 2 && segs[imagesAt + 1] == 'edits') {
        return u;
      }
      return u.replace(pathSegments: <String>[...head, 'edits']);
    }
    return u.replace(pathSegments: <String>[...segs, 'images', 'edits']);
  }

  static String _mimeOfName(String name) {
    final String n = name.toLowerCase();
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  /// 发一次生图请求（带重试）。
  static Future<http.Response> _post(
    Uri uri,
    ImageGenConfig cfg,
    Map<String, dynamic> payload,
  ) {
    return NetError.retry(
      () => http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${cfg.apiKey}',
            },
            body: jsonEncode(payload),
          )
          // 生图很慢：`gpt-image-*` 经常 30~60 秒，
          // 高质量档还会更久。给足 3 分钟，别在差一点的时候超时。
          .timeout(const Duration(seconds: 180)),
      attempts: 2,
    );
  }

  /// 报错里是不是在说"不认识 [param] 这个参数"。
  ///
  /// 判据要**同时**出现参数名和一个"非法/多余/不认识"的意思：
  /// 光看参数名会把"缺少 response_format"这种**要求**它的报错也误判成
  /// 拒绝它，那样就会朝反方向重试。
  static bool _mentionsUnknownParam(List<int> bodyBytes, String param) =>
      mentionsUnknownParamForTest(
        utf8.decode(bodyBytes, allowMalformed: true),
        param,
      );

  /// [_mentionsUnknownParam] 的纯字符串版本，便于单独测。
  @visibleForTesting
  static bool mentionsUnknownParamForTest(String body, String param) {
    final String b = body.toLowerCase();
    if (!b.contains(param.toLowerCase())) return false;
    return b.contains('unknown') ||
        b.contains('unrecognized') ||
        b.contains('unexpected') ||
        b.contains('not supported') ||
        b.contains('invalid') ||
        b.contains('extra');
  }

  /// 从返回体里取出图片。
  ///
  /// 三种形状都认（实测中转站都出现过）：
  ///  1. `{"data":[{"b64_json":"…"}]}` —— 标准
  ///  2. `{"data":[{"url":"https://…"}]}` —— 标准，`response_format` 被忽略时
  ///  3. `{"images":[{"url":"…"}]}` / `{"output":{"url":…}}` —— 各家自创
  ///
  /// 抽成静态方法是为了能单独测：解析错了会返回"生成失败"，
  /// 而用户看到的是一句毫无信息量的报错。
  static GenImage? parseImageResponse(String body) {
    dynamic j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;

    // 收集所有可能的候选对象：data / images / output 里的元素
    final List<dynamic> candidates = <dynamic>[];
    for (final String key in <String>['data', 'images', 'output', 'result']) {
      final dynamic v = j[key];
      if (v is List) {
        candidates.addAll(v);
      } else if (v is Map) {
        candidates.add(v);
      }
    }
    // 有些实现把字段放在顶层
    candidates.add(j);

    for (final dynamic c in candidates) {
      if (c is! Map) continue;

      final dynamic b64 = c['b64_json'] ?? c['b64'] ?? c['image_base64'];
      if (b64 is String && b64.trim().isNotEmpty) {
        final List<int>? bytes = _tryBase64(b64.trim());
        if (bytes != null) return GenImage(bytes: bytes);
      }

      final dynamic url = c['url'] ?? c['image'] ?? c['image_url'];
      if (url is String && url.trim().startsWith('http')) {
        return GenImage(url: url.trim());
      }
    }
    return null;
  }

  /// base64 解码，容忍 data URL 前缀和换行。
  static List<int>? _tryBase64(String raw) {
    String s = raw;
    // `data:image/png;base64,xxxx` 这种前缀要先切掉
    final int comma = s.indexOf('base64,');
    if (comma >= 0) s = s.substring(comma + 7);
    s = s.replaceAll(RegExp(r'\s'), '');
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  /// 下载返回的图片地址。
  ///
  /// **带上 Authorization 再去取一次。** 同一个 URL，不带 Key 时很多中转站
  /// 会返回 401/403（它们把图片也放在鉴权后面），而带上 Key 就能拿到 ——
  /// 先不带、失败再带，等于白等一轮超时。
  ///
  /// （对 OpenAI 官方那种"签名 URL 不需要鉴权"的情况，多带一个
  /// Authorization 头是无害的：它不参与签名校验。）
  static Future<List<int>?> _download(String url, {String? apiKey}) async {
    Future<http.Response> get(Map<String, String> headers) => http
        .get(Uri.parse(url), headers: headers)
        .timeout(const Duration(seconds: 60));

    try {
      http.Response r = await get(const <String, String>{});
      if (r.statusCode != 200 && apiKey != null && apiKey.trim().isNotEmpty) {
        r = await get(<String, String>{'Authorization': 'Bearer $apiKey'});
      }
      if (r.statusCode != 200) return null;
      return r.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// 落盘。按魔数判断扩展名 —— 中转站给的 mime 经常是错的或者干脆没有，
  /// 而扩展名写错会让后面的 `read_image` / 图片组件认不出来。
  static Future<String> _save(
    String workDir,
    List<int> bytes,
    String? mime,
  ) async {
    final String ext = _extOf(bytes, mime);
    final Directory dir = Directory('$workDir/images');
    await dir.create(recursive: true);
    final String path =
        '${dir.path}/gen_${DateTime.now().microsecondsSinceEpoch}.$ext';
    await File(path).writeAsBytes(bytes);
    return path;
  }

  static String _extOf(List<int> b, String? mime) {
    if (b.length >= 8 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      return 'png';
    }
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
      return 'jpg';
    }
    if (b.length >= 12 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42) {
      return 'webp';
    }
    final String m = (mime ?? '').toLowerCase();
    if (m.contains('jpeg') || m.contains('jpg')) return 'jpg';
    if (m.contains('webp')) return 'webp';
    return 'png';
  }

  static String _humanize(List<int> bodyBytes) {
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
      // 不是 JSON，原样截断
    }
    return clampOutput(body, max: 400);
  }
}

/// 一张（已经解析好的）源图：本地图带字节，网络图带地址。
///
/// 抽成一个类型是为了让"这次有几张、每张是什么"只有**一处**判断：
/// multipart 和 JSON 两条路各自去读"是不是远程、字节在不在"，
/// 很容易漏掉一张 —— 而漏掉的那张在用户眼里就是
/// "它根本没看我的第二张图"（2026-10-16 用户报的正是这个）。
class _EditSource {
  _EditSource({
    this.path = '',
    this.bytes,
    this.fileName = 'image.png',
    this.url,
  });

  /// 本地绝对路径（网络图为空串）。
  final String path;
  final List<int>? bytes;
  final String fileName;

  /// 网络地址（本地图为 null）。
  final String? url;

  bool get isRemote => url != null;

  /// JSON 那条路要的字段值：网络图用原始 URL，本地图用 data URL
  /// （比裸 base64 兼容性好 —— 有些实现靠前缀判断类型）。
  String asImageField() {
    if (isRemote) return url!;
    // 和 `read_image` 用同一套压缩：图编辑接口同样按请求体大小卡，
    // 一张原样 PNG 常常直接 413（"图太大"在这里的表现是
    // "编辑没反应"或一句看不懂的服务端错误）。
    final ({List<int> bytes, String mime, String note}) pic =
        VisionImage.prepare(bytes!, mime: ImageGenTool._mimeOfName(fileName));
    return 'data:${pic.mime};base64,${base64Encode(pic.bytes)}';
  }

  /// multipart 那条路要的字节（同样先压一遍）。
  ({List<int> bytes, String name}) asUpload() {
    final ({List<int> bytes, String mime, String note}) pic =
        VisionImage.prepare(bytes!, mime: ImageGenTool._mimeOfName(fileName));
    final bool jpeg = pic.mime == 'image/jpeg';
    return (
      bytes: pic.bytes,
      name: jpeg ? '${fileName.split('.').first}.jpg' : fileName,
    );
  }
}

/// 解析出来的图片：要么是字节，要么是一个待下载的地址。
class GenImage {
  const GenImage({this.bytes, this.url, this.mime});

  final List<int>? bytes;
  final String? url;
  final String? mime;
}
