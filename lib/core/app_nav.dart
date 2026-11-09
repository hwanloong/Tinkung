import 'package:flutter/material.dart';

import 'store.dart';

/// **全局导航键。**
///
/// ## 为什么需要它
///
/// 工具是在 agent 里跑的（`ToolContext` 里没有 `BuildContext`），
/// 但有些工具**必须打开一整页**给用户看 —— 最典型的是"这一页要登录，
/// 请你先登一下"：模型没有手，只有用户有。
///
/// 没有这个键的话，那种工具只能回一句"请你自己去打开浏览器" ——
/// 而用户根本不知道要打开哪个地址、也不知道我们期待他去做什么。
///
/// 有它之后，工具能直接把内置浏览器推到那个网址上，用户登完回来说一声，
/// 模型就带着**已经登录好的 cookie** 继续（cookie 在平台的 cookie 库里，
/// 三条通道共享）。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// **全局设置对象**（`main()` 里赋值一次）。
///
/// 有些界面是从代码里"推"出来的（比如内置浏览器被工具推上来给用户登录），
/// 那些地方拿不到构造参数、也没有 BuildContext —— 但它们同样需要**写回设置**
/// （浏览器页里那个"手机版/桌面版"开关就是）。与其把 Settings 一层层穿透
/// 构造函数，不如在这里放一个引用：它本来就只有一个实例。
Settings? appSettings;
