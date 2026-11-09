// 「引用回复」要真的把引用内容送到模型那边。
//
// 为什么必须测：引用一开始只做在界面上（消息里存了字段、UI 画了卡片），
// 但**完全没有拼进请求** —— 用户看到自己引用了，模型却只收到一句
// "那这个呢？"，于是答非所问。这是一整类"UI 看起来对、功能是空的"的 bug，
// 而且只有真的发出请求才会发现。
import 'package:dsh_agent/ai/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('withQuotedContext', () {
    test('有引用时，原文排在回复前面', () {
      final String r = withQuotedContext('那这个呢？', '今天的天气不错');
      expect(r, contains('今天的天气不错'));
      expect(r, contains('那这个呢？'));
      // 顺序：引用必须在前 —— 模型要先拿到指代对象再读问题
      expect(r.indexOf('今天的天气不错'), lessThan(r.indexOf('那这个呢？')));
    });

    test('两段都有清楚的标签（否则模型分不清哪句是谁说的）', () {
      final String r = withQuotedContext('改成蓝色', '把标题字号调大');
      expect(r, contains('引用的原文'));
      expect(r, contains('我的回复'));
    });

    test('没有引用时原样返回，不加任何包装', () {
      // 给每条普通消息都套标签会白占上下文，
      // 也会让模型以为那是某种特殊结构。
      expect(withQuotedContext('普通消息', null), '普通消息');
      expect(withQuotedContext('普通消息', ''), '普通消息');
      expect(withQuotedContext('普通消息', '   '), '普通消息');
    });

    test('引用内容两端的空白会被去掉', () {
      final String r = withQuotedContext('好', '  带空格的引用  ');
      expect(r, contains('带空格的引用'));
      expect(r, isNot(contains('  带空格的引用')));
    });

    test('多行引用不会被压成一行', () {
      final String r = withQuotedContext('继续', '第一行\n第二行');
      expect(r, contains('第一行\n第二行'));
    });

    test('空回复也能带着引用发出去', () {
      // 边界：内容为空但引用非空时，不能让引用也被丢掉
      final String r = withQuotedContext('', '被引的话');
      expect(r, contains('被引的话'));
    });
  });
}
