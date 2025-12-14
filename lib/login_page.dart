import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
// 这里的 cookie_jar 引用保留，虽然在这个页面主要靠 WebView 自身存 Cookie
import 'package:dio/dio.dart';

// 伪装成较新的 Android Chrome，通用性最强
const String kUserAgent =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Mobile Safari/537.36";

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final WebViewController controller;
  bool isDetecting = false; // 防止重复回调

  @override
  void initState() {
    super.initState();

    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent) // 关键：伪装 UserAgent
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            // 页面加载完，检查一下是不是登上了
            _checkLoginStatus();
          },
          onUrlChange: (UrlChange change) {
            // URL 变化时（比如跳转了）也检查一下
            _checkLoginStatus();
          },
        ),
      );

    // 【修改】直接加载最原始、最稳定的手机版登录页
    // mobile=2 是 Discuz 标准触屏版，界面简单，不容易被墙拦截
    controller.loadRequest(
      Uri.parse(
        'https://www.giantessnight.com/gnforum2012/member.php?mod=logging&action=login&mobile=2',
      ),
    );
  }

  Future<void> _checkLoginStatus() async {
    if (isDetecting) return;

    try {
      // 获取当前 Cookie
      final String cookies =
          await controller.runJavaScriptReturningResult('document.cookie')
              as String;

      // 清洗 Cookie 字符串
      String rawCookie = cookies;
      if (rawCookie.startsWith('"') && rawCookie.endsWith('"')) {
        rawCookie = rawCookie.substring(1, rawCookie.length - 1);
      }

      // Discuz 登录成功的标志：含有 auth 或 saltkey
      if (rawCookie.contains('auth') ||
          (rawCookie.contains('saltkey') && rawCookie.contains('uchome'))) {
        isDetecting = true;
        print("✅ 检测到登录 Cookie: $rawCookie");

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('登录成功，正在同步...'),
              duration: Duration(seconds: 1),
            ),
          );

          // 给一点时间让 Cookie 写入系统存储
          await Future.delayed(const Duration(milliseconds: 500));

          if (mounted) {
            Navigator.pop(context, true); // 返回 true 通知主页刷新
          }
        }
      }
    } catch (e) {
      print("Cookie 检查失败: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("登录账号"),
        actions: [
          // 保留一个刷新按钮，万一卡白屏可以点
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => controller.reload(),
          ),
        ],
      ),
      body: WebViewWidget(controller: controller),
    );
  }
}
