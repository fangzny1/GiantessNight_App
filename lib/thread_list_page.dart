import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:html/parser.dart' as html_parser;
import 'dart:convert';
import 'dart:io';
import 'forum_model.dart';
import 'login_page.dart';
import 'thread_detail_page.dart';

import 'main.dart'; // 引入 main.dart 以访问 customWallpaperPath

class ThreadListPage extends StatefulWidget {
  final String fid;
  final String forumName;

  const ThreadListPage({super.key, required this.fid, required this.forumName});

  @override
  State<ThreadListPage> createState() => _ThreadListPageState();
}

class _ThreadListPageState extends State<ThreadListPage> {
  late final WebViewController _hiddenController;
  final ScrollController _scrollController = ScrollController();

  List<Thread> _threads = [];
  bool _isFirstLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String _errorMsg = "";
  int _currentPage = 1;
  int _targetPage = 1;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  void _initWebView() {
    _hiddenController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            // 【核心修复】检测重定向：如果板块列表变成了帖子详情
            if (url.contains("viewthread")) {
              print("🔀 检测到板块重定向到帖子，正在跳转...");
              _handleRedirectToThread(url);
              return;
            }
            _tryParseData();
          },
          onWebResourceError: (e) {
            // 忽略非致命错误
            if (_isFirstLoading)
              setState(() {
                _errorMsg = "网络连接不稳定，请重试";
                _isFirstLoading = false;
              });
          },
        ),
      );
    _loadPage(1);
  }

  // 处理板块直接跳帖子的情况（如新人引导）
  void _handleRedirectToThread(String url) {
    // 从 URL 提取 TID
    RegExp reg = RegExp(r'tid=(\d+)');
    var match = reg.firstMatch(url);
    if (match != null) {
      String tid = match.group(1)!;
      // 跳转详情页，并关闭当前列表页（因为这个列表页其实不存在）
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) =>
              ThreadDetailPage(tid: tid, subject: widget.forumName),
        ),
      );
    }
  }

  void _loadPage(int page) {
    if (!_hasMore && page > 1) return;
    _targetPage = page;
    String url;
    if (page == 1) {
      url =
          'https://www.giantessnight.com/gnforum2012/api/mobile/index.php?version=4&module=forumdisplay&fid=${widget.fid}&page=1';
    } else {
      url =
          'https://www.giantessnight.com/gnforum2012/forum.php?mod=forumdisplay&fid=${widget.fid}&page=$page&mobile=no';
    }
    print("🚀 加载: $url");
    _hiddenController.loadRequest(Uri.parse(url));
  }

  Future<void> _refresh() async {
    setState(() {
      _currentPage = 1;
      _hasMore = true;
      _errorMsg = "";
      _isFirstLoading = true;
      _threads.clear();
    });
    _loadPage(1);
  }

  void _loadMore() {
    if (_isLoadingMore || !_hasMore || _isFirstLoading) return;
    setState(() {
      _isLoadingMore = true;
    });
    _loadPage(_currentPage + 1);
  }

  Future<void> _tryParseData() async {
    try {
      final String bodyText =
          await _hiddenController.runJavaScriptReturningResult(
                "document.body.innerText",
              )
              as String;
      String cleanText = "";
      try {
        cleanText = jsonDecode(bodyText);
      } catch (e) {
        cleanText = bodyText;
      }

      if (_targetPage == 1 &&
          cleanText.trim().startsWith("{") &&
          cleanText.contains("Variables")) {
        _parseJsonData(cleanText);
      } else {
        final String htmlContent =
            await _hiddenController.runJavaScriptReturningResult(
                  "document.documentElement.outerHTML",
                )
                as String;
        String realHtml = "";
        try {
          realHtml = jsonDecode(htmlContent);
        } catch (e) {
          realHtml = htmlContent;
        }
        _parseHtmlData(realHtml);
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _isFirstLoading = false;
        });
    }
  }

  void _parseJsonData(String jsonString) {
    try {
      var data = jsonDecode(jsonString);
      if (data['Variables'] != null) {
        var list = data['Variables']['forum_threadlist'] as List<dynamic>;
        List<Thread> newThreads = list.map((e) => Thread.fromJson(e)).toList();
        _updateList(newThreads);
      } else {
        // JSON 解析失败转 HTML
        _hiddenController
            .runJavaScriptReturningResult("document.documentElement.outerHTML")
            .then((val) {
              String html = jsonDecode(val.toString());
              _parseHtmlData(html);
            });
      }
    } catch (e) {
      _parseHtmlData("");
    }
  }

  void _parseHtmlData(String htmlString) {
    try {
      var document = html_parser.parse(htmlString);
      List<Thread> newThreads = [];
      var tbodies = document.getElementsByTagName('tbody');

      for (var tbody in tbodies) {
        String id = tbody.id;
        if (id.startsWith('normalthread_') || id.startsWith('stickthread_')) {
          String tid = id.split('_').last;
          var titleNode =
              tbody.querySelector('a.xst') ?? tbody.querySelector('a.s');
          var authorNode = tbody.querySelector('td.by cite a');
          var replyNode = tbody.querySelector('td.num a');
          var viewNode = tbody.querySelector('td.num em');

          if (titleNode != null) {
            newThreads.add(
              Thread(
                tid: tid,
                subject: titleNode.text.trim(),
                author: authorNode?.text.trim() ?? "匿名",
                replies: replyNode?.text.trim() ?? "0",
                views: viewNode?.text.trim() ?? "0",
                readperm: tbody.querySelector('img[src*="lock"]') != null
                    ? "1"
                    : "0",
              ),
            );
          }
        }
      }

      // 检测是否有下一页
      var nextBtn = document.querySelector('.pg .nxt');
      if (nextBtn == null) {
        // 如果没找到下一页按钮，且不是第一页，说明真到底了
        if (_targetPage > 1) _hasMore = false;
      }

      _updateList(newThreads);
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoadingMore = false;
          _isFirstLoading = false;
        });
    }
  }

  void _updateList(List<Thread> newThreads) {
    if (!mounted) return;
    setState(() {
      if (_targetPage == 1) {
        _threads = newThreads;
        _currentPage = 1;
      } else {
        Set<String> existingIds = _threads.map((t) => t.tid).toSet();
        int added = 0;
        for (var t in newThreads) {
          if (!existingIds.contains(t.tid)) {
            _threads.add(t);
            added++;
          }
        }
        if (added > 0) _currentPage = _targetPage;
      }

      // 如果数据少，说明到底了
      if (newThreads.length < 5) _hasMore = false;

      _isFirstLoading = false;
      _isLoadingMore = false;
      _errorMsg = "";
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: customWallpaperPath,
      builder: (context, wallpaperPath, _) {
        return Scaffold(
          // 如果有全局壁纸，这里设为透明
          backgroundColor: wallpaperPath != null ? Colors.transparent : null,
          body: Stack(
            children: [
              // 如果是独立页面（非 main tab），需要在这里也显示背景？
              // 不，通常 ThreadListPage 是 push 进来的，覆盖了 MainScreen。
              // 所以如果 MainScreen 的背景要透过来，ThreadListPage 必须透明。
              // 但是 Navigator push 会把下面的页面遮挡（默认是不透明的？不，是 stack）。
              // 实际上，如果不再次绘制背景，底下可能是黑的或者上一个页面。
              // 为了统一体验，建议在这里也绘制背景。
              if (wallpaperPath != null)
                Positioned.fill(
                  child: Image.file(
                    File(wallpaperPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox(),
                  ),
                ),
              if (wallpaperPath != null)
                Positioned.fill(
                  child: ValueListenableBuilder<ThemeMode>(
                    valueListenable: currentTheme,
                    builder: (context, mode, _) {
                      bool isDark = mode == ThemeMode.dark;
                      if (mode == ThemeMode.system) {
                        isDark =
                            MediaQuery.of(context).platformBrightness ==
                            Brightness.dark;
                      }
                      return Container(
                        color: isDark
                            ? Colors.black.withOpacity(0.6)
                            : Colors.white.withOpacity(0.3),
                      );
                    },
                  ),
                ),

              NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverAppBar.large(
                      title: Text(widget.forumName),
                      backgroundColor:
                          (wallpaperPath != null &&
                              transparentBarsEnabled.value)
                          ? Colors.transparent
                          : null,
                      actions: [
                        Center(
                          child: Padding(
                            padding: EdgeInsets.only(right: 16),
                            child: Text("${_threads.length} 帖"),
                          ),
                        ),
                      ],
                    ),
                  ];
                },
                body: _buildList(),
              ),
              SizedBox(
                height: 0,
                width: 0,
                child: WebViewWidget(controller: _hiddenController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildList() {
    if (_isFirstLoading)
      return const Center(child: CircularProgressIndicator());
    if (_errorMsg.isNotEmpty && _threads.isEmpty)
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_errorMsg),
            ElevatedButton(onPressed: _refresh, child: const Text("重试")),
          ],
        ),
      );

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 8, bottom: 30),
        itemCount: _threads.length + 1,
        itemBuilder: (context, index) {
          if (index == _threads.length) return _buildFooter();
          return _buildCard(_threads[index]);
        },
      ),
    );
  }

  Widget _buildFooter() {
    // 【核心修复】平板加载卡住
    // 如果还有更多(_hasMore)，但没显示加载圈，说明屏幕太长没触发滚动监听
    // 显示一个按钮让用户手动点击加载
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: _isLoadingMore
              ? const CircularProgressIndicator()
              : TextButton(
                  onPressed: _loadMore,
                  child: const Text("点击加载下一页", style: TextStyle(fontSize: 16)),
                ),
        ),
      );
    } else {
      return const Padding(
        padding: EdgeInsets.all(24.0),
        child: Center(
          child: Text("--- 到底啦 ---", style: TextStyle(color: Colors.grey)),
        ),
      );
    }
  }

  // 还需要引入 import 'dart:io';
  Widget _buildCard(Thread thread) {
    // (保持不变，省略以节省篇幅，复制之前的即可)
    return ValueListenableBuilder<String?>(
      valueListenable: customWallpaperPath,
      builder: (context, wallpaperPath, _) {
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          elevation: 0,
          color: wallpaperPath != null
              ? Theme.of(
                  context,
                ).colorScheme.surfaceContainerLow.withOpacity(0.7)
              : Theme.of(context).colorScheme.surfaceContainerLow,
          child: ListTile(
            title: Text(
              thread.subject,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              "${thread.author} • ${thread.replies} 回复",
              style: TextStyle(
                fontSize: 12,
                color: wallpaperPath != null
                    ? Theme.of(context).colorScheme.onSurface.withOpacity(0.6)
                    : Colors.grey,
              ),
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    ThreadDetailPage(tid: thread.tid, subject: thread.subject),
              ),
            ),
          ),
        );
      },
    );
  }
}
