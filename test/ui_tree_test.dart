import 'package:dsh_agent/core/ui_tree.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _node({
  String cls = 'android.widget.TextView',
  String text = '',
  String desc = '',
  String rid = '',
  bool clickable = false,
  bool editable = false,
  bool scrollable = false,
  List<int> bounds = const <int>[0, 0, 100, 50],
}) {
  return <String, dynamic>{
    'cls': cls,
    'text': text,
    'desc': desc,
    'rid': rid,
    'clickable': clickable,
    'editable': editable,
    'scrollable': scrollable,
    'selected': false,
    'focused': false,
    'bounds': bounds,
  };
}

UiSnapshot _snap(List<Map<String, dynamic>> nodes) =>
    UiSnapshot.fromMap(<String, dynamic>{
      'package': 'com.demo',
      'activity': 'com.demo.Main',
      'width': 1080.0,
      'height': 2400.0,
      'nodes': nodes,
      'total': nodes.length,
      'truncated': false,
    });

void main() {
  test('控件行格式紧凑且省略空字段', () {
    final UiSnapshot s = _snap(<Map<String, dynamic>>[
      _node(
        cls: 'android.widget.EditText',
        text: '搜索商品',
        rid: 'id/search_et',
        editable: true,
      ),
      _node(text: '￥299'),
    ]);
    final String text = s.format();
    expect(text, contains('[1] EditText "搜索商品" rid=id/search_et editable'));
    expect(text, contains('[2] TextView "￥299"'));
    expect(text, isNot(contains('desc=""')));
    expect(text, isNot(contains('rid= ')));
  });

  test('超过上限时优先保留可点击/可输入节点，并标注截断', () {
    final List<Map<String, dynamic>> nodes = <Map<String, dynamic>>[
      for (int i = 0; i < 8; i++) _node(text: '普通文字 $i'),
      _node(text: '确定', clickable: true),
      _node(text: '输入框', editable: true),
    ];
    final String text = _snap(nodes).format(limit: 2);
    expect(text, contains('输入框'));
    expect(text, contains('确定'));
    expect(text, isNot(contains('普通文字 0')));
    expect(text, contains('已截断 8 个节点'));
  });

  test('目标解析优先级：rid → 精确文本 → 包含 → 描述 → index', () {
    final UiSnapshot s = _snap(<Map<String, dynamic>>[
      _node(text: '搜索商品', rid: 'id/search_et', editable: true),
      _node(text: '搜索'),
      _node(text: '购物车', desc: '返回首页', clickable: true),
    ]);
    expect(s.findTarget(<String, dynamic>{'rid': 'id/search_et'})?.index, 1);
    expect(s.findTarget(<String, dynamic>{'rid': 'search_et'})?.index, 1);
    expect(s.findTarget(<String, dynamic>{'text': '搜索'})?.index, 2);
    expect(s.findTarget(<String, dynamic>{'text': '商品'})?.index, 1);
    expect(s.findTarget(<String, dynamic>{'desc': '首页'})?.index, 3);
    expect(s.findTarget(<String, dynamic>{'index': 2})?.index, 3);
  });

  test('指纹相同代表界面没变，文本或位置变化都会变', () {
    final UiSnapshot a = _snap(<Map<String, dynamic>>[_node(text: 'A')]);
    final UiSnapshot b = _snap(<Map<String, dynamic>>[_node(text: 'A')]);
    final UiSnapshot c = _snap(<Map<String, dynamic>>[_node(text: 'B')]);
    final UiSnapshot d = _snap(<Map<String, dynamic>>[
      _node(text: 'A', bounds: const <int>[0, 10, 100, 60]),
    ]);
    expect(a.fingerprint(), b.fingerprint());
    expect(a.fingerprint(), isNot(c.fingerprint()));
    expect(a.fingerprint(), isNot(d.fingerprint()));
  });

  test('路径 JSON 三种形态都能解析', () {
    final List<List<List<double>>> nested = parseStrokes(<dynamic>[
      <dynamic>[
        <dynamic>[0, 0],
        <dynamic>[0.5, 0.5],
      ],
      <dynamic>[
        <dynamic>[0.2, 0.2],
        <dynamic>[0.8, 0.8],
      ],
    ]);
    expect(nested.length, 2);
    expect(nested.first.length, 2);

    final List<List<List<double>>> flat = parseStrokes(<dynamic>[
      <dynamic>[0, 0],
      <dynamic>[1, 1],
    ]);
    expect(flat.length, 1);
    expect(flat.single.length, 2);

    final List<List<List<double>>> wrapped = parseStrokes(<String, dynamic>{
      'points': <dynamic>[
        <dynamic>[0.1, 0.2],
        <dynamic>[0.3, 0.4],
      ],
    });
    expect(wrapped.single.first, <double>[0.1, 0.2]);
  });

  test('归一化路径映射到画布并夹住越界点', () {
    const CanvasRect rect = CanvasRect(100, 200, 400, 800);
    final List<List<List<double>>> out = rect.mapNormalized(
      <List<List<double>>>[
        <List<double>>[
          <double>[0, 0],
          <double>[0.5, 0.5],
          <double>[1.5, -1],
        ],
      ],
    );
    expect(out.single[0], <double>[100, 200]);
    expect(out.single[1], <double>[300, 600]);
    expect(out.single[2], <double>[500, 200]);
  });

  test('路径校验拒绝单点笔和超长路径', () {
    expect(
      validateStrokes(<List<List<double>>>[
        <List<double>>[
          <double>[0, 0],
        ],
      ]),
      contains('至少需要两个点'),
    );
    expect(
      validateStrokes(<List<List<double>>>[
        <List<double>>[
          <double>[0, 0],
          <double>[1, 1],
        ],
      ]),
      isNull,
    );
    expect(
      validateStrokes(<List<List<double>>>[
        List<List<double>>.generate(
          10,
          (int i) => <double>[i.toDouble(), i.toDouble()],
        ),
      ], maxPoints: 5),
      contains('超过上限'),
    );
  });
}
