// 附件进上下文时**必须带绝对路径**。
//
// 用户的原话："每次上传文件，AI 都不知道文件在哪里，都要靠 termux 扫盘
// 扫出来才知道，速度慢又伤机。" 这组测试盯的就是这句话。
import 'package:dsh_agent/ai/agent.dart';
import 'package:dsh_agent/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('二进制附件给出绝对路径与类型，并明确禁止扫盘', () {
    final Attachment ppt = Attachment(
      kind: AttachmentKind.file,
      path: '/data/user/0/com.dsh.dsh_agent/files/attachments/123.pptx',
      name: '季度方案.pptx',
      size: 48213,
    );
    final String note = attachmentNote(ppt, null);
    expect(
      note,
      contains('/data/user/0/com.dsh.dsh_agent/files/attachments/123.pptx'),
    );
    expect(note, contains('季度方案.pptx'));
    expect(note, contains('PPTX'));
    expect(note, contains('48213'));
    expect(note, contains('termux'));
    expect(note, contains('不要用'), reason: '要明确禁止扫盘');
  });

  test('文本附件带路径 + 正文', () {
    final Attachment txt = Attachment(
      kind: AttachmentKind.file,
      path: '/tmp/notes/a.md',
      name: 'a.md',
      size: 5,
    );
    final String note = attachmentNote(txt, '# 标题');
    expect(note, contains('/tmp/notes/a.md'));
    expect(note, contains('# 标题'));
  });

  test('没有名字时用路径最后一段兜底', () {
    final Attachment f = Attachment(
      kind: AttachmentKind.file,
      path: '/tmp/x/报告.pdf',
      name: '',
    );
    expect(attachmentNote(f, null), contains('报告.pdf'));
  });
}
