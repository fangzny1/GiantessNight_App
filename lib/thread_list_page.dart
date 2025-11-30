import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:html/parser.dart' as html_parser;
import 'dart:convert';
import 'forum_model.dart';
import 'login_page.dart';
import 'thread_detail_page.dart'; // 引入详情页
import 'user_detail_page.dart'; // 引入用户页

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
            _tryParseData();
          },
        ),
      );
    _loadPage(1);
  }

  void _loadPage(int page) {
    if (!_hasMore && page > 1) return;

    _targetPage = page;
    String url;

    // 第1页走API，第2页走网页爬虫(绕过重定向bug)
    if (page == 1) {
      url =
          'https://www.giantessnight.com/gnforum2012/api/mobile/index.php?version=4&module=forumdisplay&fid=${widget.fid}&page=1';
    } else {
      url =
          'https://www.giantessnight.com/gnforum2012/forum.php?mod=forumdisplay&fid=${widget.fid}&page=$page&mobile=no';
    }

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
      _handleError("读取错误");
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
        // API无数据转HTML
        _hiddenController
            .runJavaScriptReturningResult("document.documentElement.outerHTML")
            .then((val) {
              String html = jsonDecode(val.toString());
              _parseHtmlData(html);
            });
      }
    } catch (e) {
      _handleError("JSON错误");
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
      _updateList(newThreads);
    } catch (e) {
      _handleError("HTML错误");
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

      if (newThreads.length < 5) _hasMore = false;
      _isFirstLoading = false;
      _isLoadingMore = false;
      _errorMsg = "";
    });
  }

  void _handleError(String msg) {
    if (!mounted) return;
    setState(() {
      _isLoadingMore = false;
      _isFirstLoading = false;
      if (_currentPage == 1) _errorMsg = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar.large(
                  title: Text(widget.forumName),
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
  }

  Widget _buildList() {
    if (_isFirstLoading)
      return const Center(child: CircularProgressIndicator());
    if (_errorMsg.isNotEmpty && _threads.isEmpty)
      return Center(child: Text(_errorMsg));

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
    if (_hasMore)
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Text("--- 到底啦 ---", style: TextStyle(color: Colors.grey)),
      ),
    );
  }

  Widget _buildCard(Thread thread) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          // 跳转详情页
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  ThreadDetailPage(tid: thread.tid, subject: thread.subject),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                thread.subject,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  // 点击作者跳转用户页
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            UserDetailPage(username: thread.author),
                      ),
                    ),
                    child: Text(
                      thread.author,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).primaryColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.remove_red_eye,
                    size: 12,
                    color: Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    thread.views,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(width: 12),
                  const Icon(Icons.chat_bubble, size: 12, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    thread.replies,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  if (int.tryParse(thread.readperm) != null &&
                      int.parse(thread.readperm) > 0) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.lock, size: 14, color: Colors.orange),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
