// Word / Excel / PPT 的"能看见版式"预览。
//
// 这些测试造的是**真的 OOXML 压缩包**（只是内容最小化），检查解析结果里
// 有没有图片、表格、粗体、底色、合并、列宽这些"看起来像原文件"的信息。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_agent/cwt/docx_preview.dart';
import 'package:dsh_agent/cwt/pptx_preview.dart';
import 'package:dsh_agent/cwt/xlsx_preview.dart';
import 'package:flutter_test/flutter_test.dart';

const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
    'q842iQAAAABJRU5ErkJggg==';

ArchiveFile _xml(String path, String body) =>
    ArchiveFile.string(path, '<?xml version="1.0" encoding="UTF-8"?>$body');

ArchiveFile _png(String path) => ArchiveFile(
  path,
  base64Decode(_pngBase64).length,
  base64Decode(_pngBase64),
);

Future<File> _write(Archive archive, String name) async {
  final Directory tmp = await Directory.systemTemp.createTemp('dsh_office');
  final File f = File('${tmp.path}/$name');
  await f.writeAsBytes(ZipEncoder().encode(archive));
  return f;
}

void main() {
  group('Word 预览', () {
    test('保留标题、样式、图片、表格', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'word/document.xml',
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
              'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
              '<w:body>'
              '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
              '<w:r><w:rPr><w:b/></w:rPr><w:t>季度报告</w:t></w:r></w:p>'
              '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
              '<w:r><w:t>正文</w:t></w:r>'
              '<w:r><w:rPr><w:i/><w:color w:val="FF0000"/><w:sz w:val="30"/></w:rPr>'
              '<w:t>重点</w:t></w:r></w:p>'
              '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="914400" cy="457200"/>'
              '<a:graphic><a:graphicData><pic:pic><pic:blipFill>'
              '<a:blip r:embed="rId9"/></pic:blipFill></pic:pic></a:graphicData>'
              '</a:graphic></wp:inline></w:drawing></w:r></w:p>'
              '<w:tbl><w:tr><w:trPr><w:tblHeader/></w:trPr>'
              '<w:tc><w:p><w:r><w:t>姓名</w:t></w:r></w:p></w:tc>'
              '<w:tc><w:p><w:r><w:t>分数</w:t></w:r></w:p></w:tc></w:tr>'
              '<w:tr><w:tc><w:p><w:r><w:t>张三</w:t></w:r></w:p></w:tc>'
              '<w:tc><w:p><w:r><w:t>95</w:t></w:r></w:p></w:tc></w:tr>'
              '</w:tbl>'
              '</w:body></w:document>',
        ),
      );
      a.add(
        _xml(
          'word/_rels/document.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId9" '
              'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
              'Target="media/pic.png"/></Relationships>',
        ),
      );
      a.add(_png('word/media/pic.png'));

      final File f = await _write(a, 'a.docx');
      final List<DocxPage> pages = parseDocxPreview(f.path);
      expect(pages, isNotEmpty);
      final List<DocxBlock> blocks = pages.first.blocks;

      final DocxParagraph title = blocks.whereType<DocxParagraph>().first;
      expect(title.heading, 1);
      expect(title.text, '季度报告');
      expect(title.runs.first.bold, isTrue);

      final DocxParagraph body = blocks.whereType<DocxParagraph>().toList()[1];
      expect(body.align, 'ctr');
      expect(body.text, contains('重点'));
      final DocxRun red = body.runs.firstWhere((DocxRun r) => r.text == '重点');
      expect(red.italic, isTrue);
      expect(red.colorArgb, 0xFFFF0000);
      expect(red.size, 15);

      final DocxImageBlock img = blocks.whereType<DocxImageBlock>().first;
      expect(img.bytes.length, greaterThan(10));
      expect(img.aspect, closeTo(2, 0.01), reason: '按 extent 还原比例');

      final DocxTableBlock table = blocks.whereType<DocxTableBlock>().first;
      expect(table.header, isTrue);
      expect(table.rows.first, <String>['姓名', '分数']);
      expect(table.rows[1][1], '95');
    });

    test('图片格式无法显示时跳过而不是报错', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'word/document.xml',
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
              'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
              '<w:body><w:p><w:r><w:drawing><wp:inline><wp:extent cx="10" cy="10"/>'
              '<a:graphic><a:graphicData><pic:pic><pic:blipFill>'
              '<a:blip r:embed="rId1"/></pic:blipFill></pic:pic></a:graphicData>'
              '</a:graphic></wp:inline></w:drawing></w:r>'
              '<w:r><w:t>图片后的文字</w:t></w:r></w:p></w:body></w:document>',
        ),
      );
      a.add(
        _xml(
          'word/_rels/document.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="image" Target="media/a.emf"/>'
              '</Relationships>',
        ),
      );
      a.add(ArchiveFile.string('word/media/a.emf', 'fake'));

      final File f = await _write(a, 'b.docx');
      final List<DocxPage> pages = parseDocxPreview(f.path);
      final List<DocxBlock> blocks = pages.first.blocks;
      expect(blocks.whereType<DocxImageBlock>(), isEmpty);
      expect(
        blocks
            .whereType<DocxParagraph>()
            .map((DocxParagraph p) => p.text)
            .join(),
        contains('图片后的文字'),
        reason: '图片挂了也不能把同一段的文字吞掉',
      );
    });
  });

  group('Excel 预览', () {
    test('工作表、底纹、粗体、合并、列宽、数字格式', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'xl/workbook.xml',
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<sheets><sheet name="成绩" sheetId="1" r:id="rId1"/></sheets></workbook>',
        ),
      );
      a.add(
        _xml(
          'xl/_rels/workbook.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="worksheet" '
              'Target="worksheets/sheet1.xml"/></Relationships>',
        ),
      );
      a.add(
        _xml(
          'xl/sharedStrings.xml',
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<si><t>姓名</t></si><si><t>张三</t></si><si><t>日期</t></si></sst>',
        ),
      );
      a.add(
        _xml(
          'xl/styles.xml',
          '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<fonts><font><sz val="11"/></font><font><b/><color rgb="FF1F4B3F"/></font></fonts>'
              '<fills><fill><patternFill patternType="none"/></fill>'
              '<fill><patternFill patternType="gray125"/></fill>'
              '<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/></patternFill></fill></fills>'
              '<cellXfs><xf fontId="0" fillId="0" numFmtId="0"/>'
              '<xf fontId="1" fillId="2" numFmtId="0" applyFont="1" applyFill="1">'
              '<alignment horizontal="center"/></xf>'
              '<xf fontId="0" fillId="0" numFmtId="14"/></cellXfs>'
              '</styleSheet>',
        ),
      );
      a.add(
        _xml(
          'xl/worksheets/sheet1.xml',
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
              '<sheetFormatPr defaultColWidth="10"/>'
              '<cols><col min="1" max="1" width="16"/></cols>'
              '<sheetData>'
              '<row r="1"><c r="A1" t="s" s="1"><v>0</v></c>'
              '<c r="B1" t="s"><v>0</v></c></row>'
              '<row r="2"><c r="A2" t="s"><v>1</v></c>'
              '<c r="B2"><v>95.5</v></c>'
              '<c r="C2" s="2"><v>45000</v></c></row>'
              '</sheetData>'
              '<mergeCells><mergeCell ref="B1:C1"/></mergeCells>'
              '</worksheet>',
        ),
      );

      final File f = await _write(a, 'c.xlsx');
      final List<XlsxSheet> sheets = parseXlsxPreview(f.path);
      expect(sheets, hasLength(1));
      final XlsxSheet s = sheets.first;
      expect(s.name, '成绩');
      expect(s.rows[0][0]!.text, '姓名');
      expect(s.rows[0][0]!.bold, isTrue);
      expect(s.rows[0][0]!.fillArgb, 0xFFFFF2CC);
      expect(s.rows[0][0]!.align, 'ctr');
      expect(s.rows[0][1]!.colSpan, 2, reason: 'B1:C1 合并');
      expect(s.rows[1][1]!.text, '95.5');
      expect(s.rows[1][2]!.text, contains('-'), reason: '日期格式');
      expect(
        s.colWidths.first,
        greaterThan(s.colWidths[1]),
        reason: 'A 列 16 字符应该更宽',
      );
    });
  });

  group('PPT 预览', () {
    test('图片、色块、表格、背景都进渲染节点', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'ppt/presentation.xml',
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      a.add(
        _xml(
          'ppt/theme/theme1.xml',
          '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<a:themeElements><a:clrScheme name="t">'
              '<a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
              '<a:accent1><a:srgbClr val="4472C4"/></a:accent1>'
              '</a:clrScheme></a:themeElements></a:theme>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/slide1.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="F4F7F5"/>'
              '</a:solidFill></p:bgPr></p:bg>'
              '<p:spTree>'
              '<p:sp><p:spPr><a:xfrm><a:off x="600000" y="500000"/>'
              '<a:ext cx="4000000" cy="900000"/></a:xfrm>'
              '<a:prstGeom prst="rect"/></p:spPr>'
              '<p:txBody><a:bodyPr anchor="ctr"/><a:p><a:pPr algn="ctr"/>'
              '<a:r><a:rPr sz="2400" b="1"/><a:t>季度汇报</a:t></a:r></a:p>'
              '</p:txBody></p:sp>'
              '<p:sp><p:spPr><a:xfrm><a:off x="600000" y="1600000"/>'
              '<a:ext cx="3000000" cy="400000"/></a:xfrm>'
              '<a:solidFill><a:schemeClr val="accent1"/></a:solidFill>'
              '<a:prstGeom prst="roundRect"/></p:spPr></p:sp>'
              '<p:pic><p:spPr><a:xfrm><a:off x="5000000" y="1200000"/>'
              '<a:ext cx="3000000" cy="2000000"/></a:xfrm></p:spPr>'
              '<p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>'
              '<p:graphicFrame><p:xfrm><a:off x="600000" y="3000000"/>'
              '<a:ext cx="6000000" cy="1800000"/></p:xfrm>'
              '<a:graphic><a:graphicData><a:tbl>'
              '<a:tblGrid><a:gridCol w="3000000"/><a:gridCol w="3000000"/></a:tblGrid>'
              '<a:tr h="600000"><a:tc><a:txBody><a:p><a:r><a:t>项目</a:t></a:r></a:p>'
              '</a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>数值</a:t></a:r></a:p>'
              '</a:txBody></a:tc></a:tr>'
              '<a:tr h="600000"><a:tc><a:txBody><a:p><a:r><a:t>收入</a:t></a:r></a:p>'
              '</a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>100</a:t></a:r></a:p>'
              '</a:txBody></a:tc></a:tr>'
              '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>'
              '</p:spTree></p:cSld></p:sld>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/_rels/slide1.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId2" Type="image" Target="../media/pic.png"/>'
              '</Relationships>',
        ),
      );
      a.add(_png('ppt/media/pic.png'));

      final File f = await _write(a, 'd.pptx');
      final List<PptxSlide> slides = parsePptxPreview(f.path);
      expect(slides, hasLength(1));
      final PptxSlide s = slides.first;
      expect(s.backgroundArgb, 0xFFF4F7F5);
      expect(s.nodes.whereType<PptxImageShape>(), hasLength(1));
      expect(s.nodes.whereType<PptxBoxShape>(), hasLength(1));
      expect(
        s.nodes.whereType<PptxBoxShape>().first.fillArgb,
        0xFF4472C4,
        reason: 'accent1 要从 theme 解出颜色',
      );
      final PptxTableShape table = s.nodes.whereType<PptxTableShape>().first;
      expect(table.rows[0], <String>['项目', '数值']);
      expect(table.rows[1][1], '100');
      final PptxShape title = s.shapes.first;
      expect(title.text, '季度汇报');
      expect(title.align, 'ctr');
      expect(title.anchor, 'ctr');
      expect(title.fontSize, 24);
    });

    test('按 presentation 的顺序排页，占位符没写 xfrm 时用版式位置', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'ppt/presentation.xml',
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:sldIdLst><p:sldId id="256" r:id="rId3"/>'
              '<p:sldId id="257" r:id="rId4"/></p:sldIdLst>'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      a.add(
        _xml(
          'ppt/_rels/presentation.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId3" Type="slide" Target="slides/slide2.xml"/>'
              '<Relationship Id="rId4" Type="slide" Target="slides/slide1.xml"/>'
              '</Relationships>',
        ),
      );
      // slide2 是**第一页**（按 sldIdLst），标题占位符没有 xfrm
      a.add(
        _xml(
          'ppt/slides/slide2.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:spTree><p:sp>'
              '<p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
              '<p:txBody><a:p><a:r><a:rPr sz="3200" b="1"/><a:t>版式标题</a:t>'
              '</a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/_rels/slide2.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="slideLayout" '
              'Target="../slideLayouts/slideLayout1.xml"/></Relationships>',
        ),
      );
      a.add(
        _xml(
          'ppt/slideLayouts/slideLayout1.xml',
          '<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="EEEEEE"/>'
              '</a:solidFill></p:bgPr></p:bg><p:spTree><p:sp>'
              '<p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
              '<p:spPr><a:xfrm><a:off x="1219200" y="685800"/>'
              '<a:ext cx="9753600" cy="1371600"/></a:xfrm></p:spPr>'
              '</p:sp></p:spTree></p:cSld></p:sldLayout>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/slide1.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:spTree><p:sp><p:spPr><a:xfrm>'
              '<a:off x="0" y="0"/><a:ext cx="2000000" cy="1000000"/></a:xfrm></p:spPr>'
              '<p:txBody><a:p><a:r><a:t>第二张</a:t></a:r></a:p></p:txBody>'
              '</p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );

      final File f = await _write(a, 'e.pptx');
      final List<PptxSlide> slides = parsePptxPreview(f.path);
      expect(slides, hasLength(2));
      expect(
        slides[0].shapes.first.text,
        '版式标题',
        reason: '第一页应该是 sldIdLst 里的 slide2',
      );
      expect(slides[0].shapes.first.rect.left, closeTo(0.1, 0.001));
      expect(slides[0].shapes.first.rect.top, closeTo(0.1, 0.001));
      expect(slides[0].shapes.first.rect.width, closeTo(0.8, 0.001));
      expect(slides[0].backgroundArgb, 0xFFEEEEEE, reason: '幻灯片没写背景时继承版式');
      expect(slides[1].shapes.first.text, '第二张');
    });

    test('版式里的背景图和装饰图会垫在幻灯片下面', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'ppt/presentation.xml',
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst>'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      a.add(
        _xml(
          'ppt/_rels/presentation.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="slide" Target="slides/slide1.xml"/>'
              '</Relationships>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/slide1.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
              '<p:cSld><p:spTree><p:sp><p:spPr><a:xfrm>'
              '<a:off x="600000" y="500000"/><a:ext cx="4000000" cy="900000"/></a:xfrm></p:spPr>'
              '<p:txBody><a:p><a:r><a:t>幻灯片标题</a:t></a:r></a:p></p:txBody>'
              '</p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/_rels/slide1.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rIdL" Type="slideLayout" '
              'Target="../slideLayouts/slideLayout1.xml"/></Relationships>',
        ),
      );
      a.add(
        _xml(
          'ppt/slideLayouts/slideLayout1.xml',
          '<p:sldLayout xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:cSld><p:bg><p:bgPr><a:blipFill><a:blip r:embed="rIdBg"/>'
              '</a:blipFill></p:bgPr></p:bg>'
              '<p:spTree>'
              '<p:pic><p:spPr><a:xfrm><a:off x="0" y="0"/>'
              '<a:ext cx="12192000" cy="6858000"/></a:xfrm></p:spPr>'
              '<p:blipFill><a:blip r:embed="rIdLogo"/></p:blipFill></p:pic>'
              '<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
              '<p:txBody><a:p><a:r><a:t>版式提示字</a:t></a:r></a:p></p:txBody></p:sp>'
              '</p:spTree></p:cSld></p:sldLayout>',
        ),
      );
      a.add(
        _xml(
          'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rIdBg" Type="image" Target="../media/bg.png"/>'
              '<Relationship Id="rIdLogo" Type="image" Target="../media/logo.png"/>'
              '<Relationship Id="rIdM" Type="slideMaster" '
              'Target="../slideMasters/slideMaster1.xml"/></Relationships>',
        ),
      );
      a.add(_png('ppt/media/bg.png'));
      a.add(_png('ppt/media/logo.png'));

      final File f = await _write(a, 'f.pptx');
      final List<PptxSlide> slides = parsePptxPreview(f.path);
      final PptxSlide s = slides.first;
      expect(s.backgroundImage, isNotNull, reason: '背景图来自版式');
      expect(
        s.nodes.whereType<PptxImageShape>(),
        hasLength(1),
        reason: '版式里的 logo 也要画出来',
      );
      expect(
        s.shapes.map((PptxShape x) => x.text).join(),
        isNot(contains('版式提示字')),
        reason: '版式占位提示不能当成正文',
      );
      expect(s.shapes.first.text, '幻灯片标题');
      expect(s.nodes.last is PptxShape, isTrue, reason: '幻灯片自己的内容要在装饰层之上');
    });

    test('图片填充的形状同时带文字时，图也要画出来', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'ppt/presentation.xml',
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/slide1.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:cSld><p:spTree><p:sp><p:spPr><a:xfrm>'
              '<a:off x="1200000" y="1200000"/><a:ext cx="9000000" cy="4200000"/>'
              '</a:xfrm><a:blipFill><a:blip r:embed="rId9"/></a:blipFill></p:spPr>'
              '<p:txBody><a:p><a:r><a:t>介词，凭借</a:t></a:r></a:p></p:txBody>'
              '</p:sp></p:spTree></p:cSld></p:sld>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/_rels/slide1.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId9" Type="image" Target="../media/pic.png"/>'
              '</Relationships>',
        ),
      );
      a.add(_png('ppt/media/pic.png'));

      final File f = await _write(a, 'g.pptx');
      final PptxSlide s = parsePptxPreview(f.path).first;
      expect(
        s.nodes.whereType<PptxImageShape>(),
        hasLength(1),
        reason: '形状里的图片填充不能因为"有文字"就被漏掉',
      );
      expect(s.shapes.first.text, '介词，凭借');
    });

    test('解不出来的 EMF 会被计数，用于界面提示', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'ppt/presentation.xml',
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/slide1.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:cSld><p:spTree><p:pic><p:spPr><a:xfrm>'
              '<a:off x="0" y="0"/><a:ext cx="4000000" cy="3000000"/></a:xfrm></p:spPr>'
              '<p:blipFill><a:blip r:embed="rId1"/></p:blipFill></p:pic>'
              '</p:spTree></p:cSld></p:sld>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/_rels/slide1.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="image" Target="../media/a.emf"/>'
              '</Relationships>',
        ),
      );
      a.add(ArchiveFile.string('ppt/media/a.emf', 'not-a-real-emf'));

      final File f = await _write(a, 'h.pptx');
      final PptxSlide s = parsePptxPreview(f.path).first;
      expect(s.unsupportedMedia, 1);
      expect(s.nodes.whereType<PptxImageShape>(), isEmpty);
    });

    test('字号从 lstStyle/defRPr 继承；装饰形状和大小写路径都能画', () async {
      final Archive a = Archive();
      a.add(
        _xml(
          'ppt/presentation.xml',
          '<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
              '<p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/slide1.xml',
          '<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
              'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
              'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<p:cSld><p:spTree>'
              // 星形装饰：以前只在 rect/roundRect/ellipse 时画
              '<p:sp><p:spPr><a:xfrm><a:off x="600000" y="600000"/>'
              '<a:ext cx="800000" cy="800000"/></a:xfrm>'
              '<a:prstGeom prst="star5"/><a:solidFill><a:srgbClr val="FF0000"/>'
              '</a:solidFill></p:spPr></p:sp>'
              // 字号写在 lstStyle 的 defRPr 里，run 自己没有 sz
              '<p:sp><p:spPr><a:xfrm><a:off x="2000000" y="2000000"/>'
              '<a:ext cx="6000000" cy="1000000"/></a:xfrm></p:spPr>'
              '<p:txBody><a:lstStyle><a:lvl1pPr><a:defRPr sz="3200"/>'
              '</a:lvl1pPr></a:lstStyle>'
              '<a:p><a:r><a:t>继承来的大字号</a:t></a:r></a:p></p:txBody></p:sp>'
              // 反斜杠 + 大写扩展名的图片路径
              '<p:pic><p:spPr><a:xfrm><a:off x="0" y="3000000"/>'
              '<a:ext cx="2000000" cy="1500000"/></a:xfrm></p:spPr>'
              '<p:blipFill><a:blip r:embed="rIdImg"/></p:blipFill></p:pic>'
              '</p:spTree></p:cSld></p:sld>',
        ),
      );
      a.add(
        _xml(
          'ppt/slides/_rels/slide1.xml.rels',
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rIdImg" Type="image" Target="..\\MEDIA\\PIC.PNG"/>'
              '</Relationships>',
        ),
      );
      a.add(_png('ppt/media/pic.png'));

      final File f = await _write(a, 'i.pptx');
      final PptxSlide s = parsePptxPreview(f.path).first;
      expect(
        s.nodes.whereType<PptxBoxShape>(),
        isNotEmpty,
        reason: 'star5 这类预设形状也要画',
      );
      expect(
        s.nodes.whereType<PptxImageShape>(),
        hasLength(1),
        reason: '反斜杠/大小写路径要能找回图片',
      );
      final PptxShape title = s.shapes.firstWhere(
        (PptxShape x) => x.text.contains('继承来的大字号'),
      );
      expect(title.fontSize, 32);
    });
  });
}
