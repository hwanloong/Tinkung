// 「真 RAG」这条链路的四段：解析 → 切分 → 向量/关键词检索 → 出处。
//
// 这里不依赖网络：Embedding 用确定性假实现，验证的是**流程与排序**；
// 真实模型的效果另说，但"切不好、检索不回来、把整库塞上下文"这些
// 工程问题必须在这里钉住。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_agent/knowledge/document_parser.dart';
import 'package:dsh_agent/knowledge/knowledge_chunker.dart';
import 'package:dsh_agent/knowledge/knowledge_embedder.dart';
import 'package:dsh_agent/knowledge/knowledge_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEmbedder implements KnowledgeEmbedder {
  const _FakeEmbedder({this.available = true});

  @override
  final bool available;
  static const int dim = 64;

  @override
  String get label => 'fake';

  @override
  Future<List<List<double>>> embed(List<String> texts) async {
    return texts.map((String t) {
      final List<double> v = List<double>.filled(dim, 0);
      for (final String tok in knowledgeTokens(t)) {
        int h = 0;
        for (final int c in tok.codeUnits) {
          h = (h * 31 + c) % dim;
        }
        v[h] += 1;
      }
      return normalizeVector(v);
    }).toList();
  }
}

void main() {
  group('切分', () {
    test('标题是边界，块不超过上限，带标题路径', () {
      final String text =
          '# 第一章\n\n'
          '${'这是一段用来测试切分的正文。' * 20}\n\n'
          '## 1.1 小节\n\n'
          '${'另一段更长的内容，用来触发第二块。' * 20}';
      final List<KnowledgeChunkDraft> chunks = chunkKnowledgeText(
        text,
        maxChars: 160,
        overlap: 40,
      );

      expect(chunks.length, greaterThan(1));
      for (final KnowledgeChunkDraft c in chunks) {
        expect(c.text.length, lessThanOrEqualTo(160));
      }
      expect(chunks.first.heading, contains('第一章'));
      expect(
        chunks.any((KnowledgeChunkDraft c) => c.heading.contains('1.1 小节')),
        isTrue,
        reason: '小节标题要能进片段的出处',
      );
    });

    test('相邻片段有重叠，避免一句话被切断后两边都读不懂', () {
      final String text = '甲乙丙丁戊己庚辛壬癸。' * 80;
      final List<KnowledgeChunkDraft> chunks = chunkKnowledgeText(
        text,
        maxChars: 120,
        overlap: 30,
      );
      expect(chunks.length, greaterThan(2));
      // 后一片的开头应当能在前一片的结尾找到（重叠 30 字）
      final String prevTail = chunks[0].text.substring(
        chunks[0].text.length - 20,
      );
      expect(
        chunks[1].text,
        contains(prevTail.substring(prevTail.length - 10)),
      );
    });

    test('空文档安全', () {
      expect(chunkKnowledgeText('   \n\n '), isEmpty);
    });
  });

  group('分词', () {
    test('中文出 bigram，英文出整词', () {
      final List<String> t = knowledgeTokens('退货 policy 2026');
      expect(t, contains('退货'));
      expect(t, contains('policy'));
      expect(t, contains('2026'));
    });
  });

  group('解析', () {
    test('HTML 去掉脚本与标签，保留段落', () {
      final String text = htmlToPlainText(
        '<h1>标题</h1><script>alert(1)</script>'
        '<p>正文 <b>重点</b></p><style>.x{}</style>',
      );
      expect(text, contains('标题'));
      expect(text, contains('重点'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('<b>')));
    });

    test('CSV 转成"表头=值"的自然语言行', () async {
      final ParsedDocument d = await parseKnowledgeBytes(
        Uint8List.fromList(utf8.encode('name,age\nAlice,30\nBob,25')),
        'people.csv',
      );
      expect(d.kind, 'CSV');
      expect(d.text, contains('name=Alice'));
      expect(d.text, contains('age=30'));
      expect(d.text, contains('表头'));
    });

    test('Markdown 原样进文本', () async {
      final ParsedDocument d = await parseKnowledgeBytes(
        Uint8List.fromList(utf8.encode('# 标题\n\n正文')),
        'a.md',
      );
      expect(d.kind, 'Markdown');
      expect(d.text, contains('# 标题'));
    });

    test('DOCX 抽取段落（zip + xml）', () async {
      final Archive archive = Archive();
      archive.add(
        ArchiveFile.string(
          'word/document.xml',
          '<?xml version="1.0"?>'
              '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
              '<w:body><w:p><w:r><w:t>Hello RAG</w:t></w:r></w:p>'
              '<w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body></w:document>',
        ),
      );
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final ParsedDocument d = await parseKnowledgeBytes(bytes, 'a.docx');
      expect(d.kind, 'Word');
      expect(d.text, contains('Hello RAG'));
      expect(d.text, contains('第二段'));
    });

    test('XLSX 把行转成表头=值', () async {
      final Archive archive = Archive();
      archive.add(
        ArchiveFile.string(
          'xl/sharedStrings.xml',
          '<?xml version="1.0"?><sst>'
              '<si><t>姓名</t></si><si><t>年龄</t></si>'
              '<si><t>张三</t></si><si><t>30</t></si></sst>',
        ),
      );
      archive.add(
        ArchiveFile.string(
          'xl/worksheets/sheet1.xml',
          '<?xml version="1.0"?><worksheet><sheetData>'
              '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
              '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>30</v></c></row>'
              '</sheetData></worksheet>',
        ),
      );
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      final ParsedDocument d = await parseKnowledgeBytes(bytes, 'a.xlsx');
      expect(d.kind, 'Excel');
      expect(d.text, contains('姓名=张三'));
      expect(d.text, contains('年龄=30'));
    });

    test('PPTX 按幻灯片抽文字', () async {
      final Archive archive = Archive();
      archive.add(
        ArchiveFile.string(
          'ppt/slides/slide1.xml',
          '<?xml version="1.0"?>'
              '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>季度汇报</a:t></a:r></a:p>'
              '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );
      final ParsedDocument d = await parseKnowledgeBytes(
        Uint8List.fromList(ZipEncoder().encode(archive)),
        'a.pptx',
      );
      expect(d.kind, 'PPT');
      expect(d.text, contains('幻灯片 1'));
      expect(d.text, contains('季度汇报'));
    });

    test('PDF 文本层能抽出来', () async {
      const String body =
          'BT /F1 12 Tf 72 720 Td '
          '(Hello RAG knowledge base test with more than forty chars) Tj ET';
      final String pdf =
          '%PDF-1.4\n1 0 obj\n<< /Length ${body.length} >>\n'
          'stream\n$body\nendstream\nendobj\n%%EOF';
      final ParsedDocument d = await parseKnowledgeBytes(
        Uint8List.fromList(utf8.encode(pdf)),
        'a.pdf',
      );
      expect(d.kind, 'PDF');
      expect(d.text, contains('Hello RAG'));
    });
  });

  group('入库与检索', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dsh_kb');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('切片入库 → 检索命中正确文档 → 向量维度写入', () async {
      final KnowledgeStore store = await KnowledgeStore.configure(
        tmp,
        embedder: const _FakeEmbedder(),
      );
      expect(await store.createBase('售后'), isNull);
      final KnowledgeBase b = store.byName('售后')!;

      expect(
        await store.importText(
          b.id,
          title: '退换货政策',
          text: '七天无理由退货。商品需保持完好，运费由买家承担。',
        ),
        isNull,
      );
      expect(
        await store.importText(
          b.id,
          title: '会员权益',
          text: '会员每月获得积分，积分可以兑换优惠券。',
        ),
        isNull,
      );

      expect(b.docs, hasLength(2));
      expect(b.chunks, isNotEmpty);
      expect(b.dim, 64);
      expect(store.vectorReady, isTrue);

      final List<KnowledgeHit> hits = await store.search(
        query: '怎么退货',
        baseId: b.id,
        topK: 2,
      );
      expect(hits, isNotEmpty);
      expect(hits.first.doc.title, '退换货政策');
      expect(hits.first.chunk.text, contains('退货'));
    });

    test('向量索引落盘：重启后仍能检索', () async {
      final KnowledgeStore first = await KnowledgeStore.configure(
        tmp,
        embedder: const _FakeEmbedder(),
      );
      await first.createBase('资料');
      final KnowledgeBase b = first.byName('资料')!;
      await first.importText(
        b.id,
        title: '部署说明',
        text: '生产环境的部署需要先备份数据库，再滚动重启。',
      );

      final KnowledgeStore second = await KnowledgeStore.configure(
        tmp,
        embedder: const _FakeEmbedder(),
      );
      expect(second.bases, hasLength(1));
      expect(second.bases.first.chunks, isNotEmpty);
      expect(second.bases.first.dim, 64);
      final List<KnowledgeHit> hits = await second.search(
        query: '部署前要注意什么',
        topK: 1,
      );
      expect(hits, isNotEmpty);
      expect(hits.first.doc.title, '部署说明');
    });

    test('没有 Embedding 模型时，关键词检索仍然可用', () async {
      final KnowledgeStore store = await KnowledgeStore.configure(
        tmp,
        embedder: const _FakeEmbedder(available: false),
      );
      await store.createBase('手册');
      final KnowledgeBase b = store.byName('手册')!;
      await store.importText(
        b.id,
        title: '报销流程',
        text: '差旅报销需要附上发票和行程单，提交给财务审批。',
      );

      expect(store.vectorReady, isFalse);
      final List<KnowledgeHit> hits = await store.search(
        query: '发票 报销',
        baseId: b.id,
      );
      expect(hits, isNotEmpty);
      expect(hits.first.doc.title, '报销流程');
      expect(hits.first.vectorScore, 0);
      expect(hits.first.lexicalScore, greaterThan(0));
    });

    test('删除文档会同时删掉它的片段', () async {
      final KnowledgeStore store = await KnowledgeStore.configure(
        tmp,
        embedder: const _FakeEmbedder(),
      );
      await store.createBase('库');
      final KnowledgeBase b = store.byName('库')!;
      await store.importText(b.id, title: 'A', text: '甲' * 100);
      final KnowledgeDoc doc = b.docs.single;
      expect(b.chunks, isNotEmpty);
      await store.removeDoc(b.id, doc.id);
      expect(b.docs, isEmpty);
      expect(b.chunks, isEmpty);
      expect(b.dim, 0);
    });
  });
}
