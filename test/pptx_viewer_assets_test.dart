// 高保真 PPT 预览的前端资源必须真的打进 APK。
//
// 这组测试不跑 WebView（测试环境没有 Android WebView），只确认：
//  · viewer.html 在；
//  · 它引用的是随包携带的 pptx-preview.umd.js；
//  · 传输/翻页/取字这几个 JS 接口都在。
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('viewer.html 引用本地脚本并暴露必要接口', () async {
    final String html = await rootBundle.loadString(
      'assets/pptx_viewer/viewer.html',
    );
    expect(html, contains('pptx-preview.umd.js'));
    expect(html, contains('pptxPreview.init'));
    expect(html, contains('beginPptx'));
    expect(html, contains('addChunk'));
    expect(html, contains('finishPptx'));
    expect(html, contains('showSlide'));
    expect(html, contains('pickText'));
    expect(html, contains('pptx-preview-wrapper-next'), reason: '要能隐藏库自带的翻页按钮');
  });

  test('UMD 构建随包携带（离线可用）', () async {
    final ByteData data = await rootBundle.load(
      'assets/pptx_viewer/pptx-preview.umd.js',
    );
    expect(data.lengthInBytes, greaterThan(1000000));
  });

  test('保留上游版权/授权说明', () async {
    final String license = await rootBundle.loadString(
      'assets/pptx_viewer/LICENSE.txt',
    );
    expect(license, contains('pptx-preview'));
    expect(license, contains('ISC'));
  });
}
