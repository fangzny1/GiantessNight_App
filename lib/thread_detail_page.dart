import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'login_page.dart';
import 'user_detail_page.dart';
import 'forum_model.dart';

class PostItem {
  final String pid;
  final String author;
  final String authorId;
  final String avatarUrl;
  final String time;
  final String contentHtml;
  final String floor;
  final String device;

  PostItem({
    required this.pid,
    required this.author,
    required this.authorId,
    required this.avatarUrl,
    required this.time,
    required this.contentHtml,
    required this.floor,
    required this.device,
  });
}

class ThreadDetailPage extends StatefulWidget {
  final String tid;
  final String subject;
  final int initialPage;

  const ThreadDetailPage({
    super.key,
    required this.tid,
    required this.subject,
    this.initialPage = 1,
  });

  @override
  State<ThreadDetailPage> createState() => _ThreadDetailPageState();
}

class _ThreadDetailPageState extends State<ThreadDetailPage>
    with SingleTickerProviderStateMixin {
  late final WebViewController _hiddenController;
  late final WebViewController _favCheckController;
  final ScrollController _scrollController = ScrollController();

  List<PostItem> _posts = [];

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  bool _isOnlyLandlord = false;
  bool _isReaderMode = false;
  bool _isFabOpen = false;

  bool _isFavorited = false;
  String? _favid;

  double _fontSize = 16.0;
  Color _readerBgColor = const Color(0xFFFAF9DE);
  Color _readerTextColor = Colors.black87;

  late AnimationController _fabAnimationController;
  late Animation<double> _fabAnimation;

  String _errorMsg = "";
  late int _currentPage;
  String? _landlordUid;

  final String _baseUrl = "https://www.giantessnight.com/gnforum2012/";

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _fabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _fabAnimation = CurvedAnimation(
      parent: _fabAnimationController,
      curve: Curves.easeInOut,
    );

    _initWebView();
    _initFavCheck();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.dispose();
    _fabAnimationController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  void _toggleFab() {
    setState(() {
      _isFabOpen = !_isFabOpen;
      if (_isFabOpen) {
        _fabAnimationController.forward();
      } else {
        _fabAnimationController.reverse();
      }
    });
  }

  void _toggleReaderMode() {
    setState(() {
      _isReaderMode = !_isReaderMode;
      if (_isReaderMode) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    });
    _toggleFab();
  }

  void _initWebView() {
    _hiddenController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            _parseHtmlData();
          },
        ),
      );
    _loadPage(_currentPage);
  }

  void _initFavCheck() {
    _favCheckController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (url.contains("do=favorite")) {
              _parseFavList();
            } else if (url.contains("op=delete") &&
                url.contains("ac=favorite")) {
              _favCheckController.runJavaScript(
                "var btn = document.querySelector('button[name=\"deletesubmitbtn\"]'); if(btn) btn.click();",
              );
            }
          },
        ),
      );
    _favCheckController.loadRequest(
      Uri.parse('${_baseUrl}home.php?mod=space&do=favorite&view=me&mobile=no'),
    );
  }

  Future<void> _parseFavList() async {
    try {
      final String rawHtml =
          await _favCheckController.runJavaScriptReturningResult(
                "document.documentElement.outerHTML",
              )
              as String;
      String cleanHtml = _cleanHtml(rawHtml);
      var document = html_parser.parse(cleanHtml);
      var items = document.querySelectorAll('ul[id="favorite_ul"] li');
      String? foundFavid;

      for (var item in items) {
        var link = item.querySelector('a[href*="tid=${widget.tid}"]');
        if (link != null) {
          var delLink = item.querySelector('a[href*="op=delete"]');
          if (delLink != null) {
            String href = delLink.attributes['href'] ?? "";
            RegExp favidReg = RegExp(r'favid=(\d+)');
            var match = favidReg.firstMatch(href);
            if (match != null) {
              foundFavid = match.group(1);
              break;
            }
          }
        }
      }
      if (mounted) {
        if (foundFavid != null) {
          setState(() {
            _isFavorited = true;
            _favid = foundFavid;
          });
        } else if (_isFavorited) {
          setState(() {
            _isFavorited = false;
            _favid = null;
          });
        }
      }
    } catch (e) {
      // 忽略错误
    }
  }

  void _loadPage(int page) {
    if (!_hasMore && page > _currentPage) return;
    String url =
        '${_baseUrl}forum.php?mod=viewthread&tid=${widget.tid}&extra=page%3D1&page=$page&mobile=no';
    if (_isOnlyLandlord && _landlordUid != null)
      url += '&authorid=$_landlordUid';
    print("🚀 加载: $url");
    _hiddenController.loadRequest(Uri.parse(url));
  }

  void _toggleOnlyLandlord() {
    if (_landlordUid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("未找到楼主")));
      return;
    }
    setState(() {
      _isOnlyLandlord = !_isOnlyLandlord;
      _posts.clear();
      _currentPage = 1;
      _hasMore = true;
      _isLoading = true;
      _isFabOpen = false;
      _fabAnimationController.reverse();
    });
    _loadPage(1);
  }

  void _loadMore() {
    if (_isLoading || _isLoadingMore || !_hasMore) return;
    setState(() {
      _isLoadingMore = true;
    });
    _loadPage(_currentPage + 1);
  }

  void _handleFavorite() {
    _toggleFab();
    if (_isFavorited) {
      if (_favid != null) {
        String delUrl =
            "${_baseUrl}home.php?mod=spacecp&ac=favorite&op=delete&favid=$_favid&type=all";
        _favCheckController.loadRequest(Uri.parse(delUrl));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("正在取消收藏...")));
        Future.delayed(
          const Duration(seconds: 3),
          () => _favCheckController.reload(),
        );
        setState(() {
          _isFavorited = false;
          _favid = null;
        });
      }
    } else {
      _hiddenController.runJavaScript(
        "if(document.querySelector('#k_favorite')) document.querySelector('#k_favorite').click();",
      );
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("已发送收藏请求")));
      setState(() {
        _isFavorited = true;
      });
      Future.delayed(
        const Duration(seconds: 3),
        () => _favCheckController.reload(),
      );
    }
  }

  Future<void> _parseHtmlData() async {
    try {
      final String rawHtml =
          await _hiddenController.runJavaScriptReturningResult(
                "document.documentElement.outerHTML",
              )
              as String;
      String cleanHtml = _cleanHtml(rawHtml);

      var document = html_parser.parse(cleanHtml);
      List<PostItem> newPosts = [];
      var postDivs = document.querySelectorAll('div[id^="post_"]');

      int floorIndex = (_currentPage - 1) * 10 + 1;

      for (var div in postDivs) {
        try {
          if (div.id.contains("new") || div.id.contains("rate")) continue;
          String pid = div.id.split('_').last;

          var authorNode =
              div.querySelector('.authi .xw1') ?? div.querySelector('.authi a');
          String author = authorNode?.text.trim() ?? "匿名";
          String authorHref = authorNode?.attributes['href'] ?? "";
          RegExp uidReg = RegExp(r'uid=(\d+)');
          String authorId = uidReg.firstMatch(authorHref)?.group(1) ?? "";

          if (_landlordUid == null &&
              _currentPage == 1 &&
              newPosts.isEmpty &&
              _posts.isEmpty) {
            _landlordUid = authorId;
          }

          var avatarNode = div.querySelector('.avatar img');
          String avatarUrl = avatarNode?.attributes['src'] ?? "";
          if (avatarUrl.isNotEmpty && !avatarUrl.startsWith("http")) {
            avatarUrl = "$_baseUrl$avatarUrl";
          }

          var timeNode = div.querySelector('em[id^="authorposton"]');
          String time = timeNode?.text.replaceAll("发表于 ", "").trim() ?? "";
          var spanTime = timeNode?.querySelector('span');
          if (spanTime != null && spanTime.attributes.containsKey('title')) {
            time = spanTime.attributes['title']!;
          }

          var floorNode = div.querySelector('.pi strong a em');
          String floorText = floorNode?.text ?? "${floorIndex++}楼";

          var contentNode = div.querySelector('td.t_f');
          String content = contentNode?.innerHtml ?? "";

          content = content.replaceAll(r'\n', '<br>');
          content = content.replaceAll('<div class="mbn savephotop">', '<div>');
          content = content.replaceAll(
            'src="data/attachment',
            'src="${_baseUrl}data/attachment',
          );
          content = content.replaceAll(
            'file="data/attachment',
            'file="${_baseUrl}data/attachment',
          );
          content = content.replaceAll(
            'zoomfile="data/attachment',
            'zoomfile="${_baseUrl}data/attachment',
          );

          content = content.replaceAllMapped(RegExp(r'<img[^>]+>'), (match) {
            String imgTag = match.group(0)!;

            RegExp zoomReg = RegExp(r'zoomfile="([^"]+)"');
            RegExp fileReg = RegExp(r'file="([^"]+)"');
            RegExp srcReg = RegExp(r'src="([^"]+)"');

            String? zoomUrl = zoomReg.firstMatch(imgTag)?.group(1);
            String? fileUrl = fileReg.firstMatch(imgTag)?.group(1);
            String? srcUrl = srcReg.firstMatch(imgTag)?.group(1);

            String bestUrl = "";

            if (zoomUrl != null && zoomUrl.isNotEmpty)
              bestUrl = zoomUrl;
            else if (fileUrl != null && fileUrl.isNotEmpty)
              bestUrl = fileUrl;
            else if (srcUrl != null &&
                !srcUrl.contains("loading.gif") &&
                !srcUrl.contains("none.gif"))
              bestUrl = srcUrl;

            if (bestUrl.isNotEmpty) {
              if (!bestUrl.startsWith('http')) bestUrl = _baseUrl + bestUrl;
              return '<img src="$bestUrl" style="max-width:100%; height:auto; display:block; margin: 8px 0;">';
            }
            return "";
          });

          content = content.replaceAll(
            RegExp(r'<script.*?>.*?</script>', dotAll: true),
            '',
          );
          content = content.replaceAll('ignore_js_op', 'div');

          newPosts.add(
            PostItem(
              pid: pid,
              author: author,
              authorId: authorId,
              avatarUrl: avatarUrl,
              time: time,
              contentHtml: content,
              floor: floorText,
              device: div.innerHtml.contains("来自手机") ? "手机端" : "",
            ),
          );
        } catch (e) {
          continue;
        }
      }

      var nextBtn = document.querySelector('.pg .nxt');
      bool hasNextPage = nextBtn != null;

      if (mounted) {
        setState(() {
          if (_currentPage == widget.initialPage &&
              newPosts.isNotEmpty &&
              _posts.isEmpty) {
            _posts = newPosts;
          } else {
            for (var p in newPosts) {
              if (!_posts.any((old) => old.pid == p.pid)) _posts.add(p);
            }
          }
          if (!hasNextPage)
            _hasMore = false;
          else if (newPosts.isNotEmpty)
            _currentPage++;
          if (newPosts.isEmpty) _hasMore = false;
          _isLoading = false;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
        });
    }
  }

  String _cleanHtml(String raw) {
    String clean = raw;
    if (clean.startsWith('"')) clean = clean.substring(1, clean.length - 1);
    clean = clean
        .replaceAll('\\u003C', '<')
        .replaceAll('\\"', '"')
        .replaceAll('\\\\', '\\');
    return clean;
  }

  Future<void> _saveBookmark() async {
    final prefs = await SharedPreferences.getInstance();
    String? jsonStr = prefs.getString('local_bookmarks');
    List<dynamic> jsonList = [];
    if (jsonStr != null && jsonStr.startsWith("[")) {
      jsonList = jsonDecode(jsonStr);
    }
    final newMark = BookmarkItem(
      tid: widget.tid,
      subject: widget.subject,
      author: _posts.isNotEmpty ? _posts.first.author : "未知",
      page: _currentPage,
      savedTime: DateTime.now().toString().substring(0, 16),
    );
    jsonList.removeWhere((e) => e['tid'] == widget.tid);
    jsonList.insert(0, newMark.toJson());
    await prefs.setString('local_bookmarks', jsonEncode(jsonList));

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("进度已保存到书签")));
    }
    _toggleFab();
  }

  // 设置面板
  void _showDisplaySettings() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.all(20),
              height: 250,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "字体大小",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Slider(
                    value: _fontSize,
                    min: 12.0,
                    max: 30.0,
                    divisions: 18,
                    label: _fontSize.toStringAsFixed(0),
                    onChanged: (val) {
                      setSheetState(() => _fontSize = val);
                      setState(() => _fontSize = val);
                    },
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "背景颜色",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildColorBtn(
                        const Color(0xFFFFFFFF),
                        Colors.black87,
                        "白昼",
                      ),
                      _buildColorBtn(
                        const Color(0xFFFAF9DE),
                        Colors.black87,
                        "护眼",
                      ),
                      _buildColorBtn(
                        const Color(0xFF1A1A1A),
                        Colors.white70,
                        "夜间",
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    _toggleFab();
  }

  // 构建颜色按钮
  Widget _buildColorBtn(Color bg, Color text, String label) {
    bool isSelected = _readerBgColor == bg;
    return GestureDetector(
      onTap: () {
        setState(() {
          _readerBgColor = bg;
          _readerTextColor = text;
        });
        Navigator.pop(context);
      },
      child: Column(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(
                color: isSelected
                    ? Theme.of(context).primaryColor
                    : Colors.grey,
                width: 2,
              ),
              shape: BoxShape.circle,
            ),
            child: isSelected ? Icon(Icons.check, color: text) : null,
          ),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _launchURL(String? url) async {
    if (url == null || url.isEmpty) return;
    final Uri uri = Uri.parse(url.trim());
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {}
  }

  @override
  Widget build(BuildContext context) {
    Color bgColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.black
        : const Color(0xFFF5F5F5);
    if (_isReaderMode) bgColor = _readerBgColor;

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          NestedScrollView(
            controller: _scrollController,
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                SliverAppBar(
                  floating: false,
                  pinned: false,
                  snap: false,
                  title: Text(
                    widget.subject,
                    style: TextStyle(
                      fontSize: 16,
                      color: _isReaderMode ? _readerTextColor : null,
                    ),
                  ),
                  centerTitle: false,
                  elevation: 0,
                  backgroundColor: bgColor,
                  surfaceTintColor: Colors.transparent,
                  iconTheme: IconThemeData(
                    color: _isReaderMode ? _readerTextColor : null,
                  ),
                ),
              ];
            },
            body: _isReaderMode ? _buildReaderMode() : _buildNativeList(),
          ),
          _buildFabMenu(),
          SizedBox(
            height: 0,
            width: 0,
            child: WebViewWidget(controller: _hiddenController),
          ),
          SizedBox(
            height: 0,
            width: 0,
            child: WebViewWidget(controller: _favCheckController),
          ),
        ],
      ),
    );
  }

  Widget _buildFabMenu() {
    return Positioned(
      right: 16,
      bottom: 32,
      child: Opacity(
        opacity: (_isReaderMode && !_isFabOpen) ? 0.3 : 1.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_isFabOpen) ...[
              _buildFabItem(
                icon: Icons.refresh,
                label: "刷新",
                onTap: () {
                  setState(() {
                    _isLoading = true;
                    _posts.clear();
                    _currentPage = 1;
                  });
                  _hiddenController.reload();
                  _toggleFab();
                },
              ),
              const SizedBox(height: 12),
              _buildFabItem(
                icon: Icons.bookmark_add,
                label: "保存进度",
                onTap: _saveBookmark,
              ),
              const SizedBox(height: 12),
              _buildFabItem(
                icon: _isFavorited ? Icons.star : Icons.star_border,
                label: _isFavorited ? "取消收藏" : "收藏本帖",
                color: _isFavorited ? Colors.yellow : null,
                onTap: _handleFavorite,
              ),
              const SizedBox(height: 12),
              if (_isReaderMode) ...[
                _buildFabItem(
                  icon: Icons.settings,
                  label: "阅读设置",
                  onTap: _showDisplaySettings,
                ),
                const SizedBox(height: 12),
              ],
              _buildFabItem(
                icon: _isOnlyLandlord ? Icons.people : Icons.person,
                label: _isOnlyLandlord ? "看全部" : "只看楼主",
                color: _isOnlyLandlord ? Colors.orange : null,
                onTap: _toggleOnlyLandlord,
              ),
              const SizedBox(height: 12),
              _buildFabItem(
                icon: _isReaderMode ? Icons.view_list : Icons.article,
                label: _isReaderMode ? "列表" : "阅读",
                onTap: _toggleReaderMode,
              ),
              const SizedBox(height: 12),
            ],
            FloatingActionButton(
              heroTag: "main_fab",
              onPressed: _toggleFab,
              backgroundColor: _isReaderMode
                  ? Colors.brown.shade300
                  : Theme.of(context).colorScheme.primaryContainer,
              child: AnimatedIcon(
                icon: AnimatedIcons.menu_close,
                progress: _fabAnimation,
                color: _isReaderMode ? Colors.white : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFabItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return ScaleTransition(
      scale: _fabAnimation,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.small(
            heroTag: label,
            onPressed: onTap,
            backgroundColor: color ?? Theme.of(context).colorScheme.surface,
            child: Icon(icon, color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildNativeList() {
    if (_isLoading && _posts.isEmpty)
      return const Center(child: CircularProgressIndicator());
    if (_errorMsg.isNotEmpty) return Center(child: Text(_errorMsg)); // 显示错误信息

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: _posts.length + 1,
      separatorBuilder: (ctx, i) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == _posts.length) return _buildFooter();
        return _buildPostCard(_posts[index]);
      },
    );
  }

  Widget _buildFooter() {
    if (_hasMore)
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    return const Padding(
      padding: EdgeInsets.all(30),
      child: Center(
        child: Text("--- 全文完 ---", style: TextStyle(color: Colors.grey)),
      ),
    );
  }

  Widget _buildPostCard(PostItem post) {
    final isLandlord = post.authorId == _landlordUid;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => _jumpToUser(post),
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.grey.shade200,
                    backgroundImage: post.avatarUrl.isNotEmpty
                        ? NetworkImage(post.avatarUrl)
                        : null,
                    child: post.avatarUrl.isEmpty
                        ? const Icon(Icons.person, color: Colors.grey)
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          InkWell(
                            onTap: () => _jumpToUser(post),
                            child: Text(
                              post.author,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (isLandlord) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                "楼主",
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        "${post.floor} · ${post.time}",
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectionArea(
              child: HtmlWidget(
                post.contentHtml,
                textStyle: const TextStyle(fontSize: 16, height: 1.6),
                customWidgetBuilder: (element) {
                  if (element.localName == 'img') {
                    String src = element.attributes['src'] ?? '';
                    if (src.isNotEmpty) {
                      // 尝试带 UA 访问，提高成功率
                      return Image.network(
                        src,
                        headers: const {'User-Agent': kUserAgent},
                        loadingBuilder: (ctx, child, p) => p == null
                            ? child
                            : Container(
                                height: 150,
                                color: Colors.grey.shade100,
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                        errorBuilder: (ctx, err, stack) => Container(
                          height: 100,
                          color: Colors.grey.shade200,
                          alignment: Alignment.center,
                          child: const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.broken_image, color: Colors.grey),
                              Text(
                                "图片加载失败",
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                  }
                  return null;
                },
                customStylesBuilder: (element) {
                  if (element.localName == 'blockquote')
                    return {
                      'background-color': '#F5F5F5',
                      'border-left': '3px solid #DDD',
                      'padding': '8px',
                    };
                  return null;
                },
                onTapImage: (data) => print("查看: ${data.sources.first.url}"),
                onTapUrl: (url) async {
                  await _launchURL(url);
                  return true;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _jumpToUser(PostItem post) {
    if (post.authorId.isNotEmpty)
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => UserDetailPage(
            uid: post.authorId,
            username: post.author,
            avatarUrl: post.avatarUrl,
          ),
        ),
      );
  }

  Widget _buildReaderMode() {
    if (_posts.isEmpty) return const Center(child: Text("暂无内容"));
    return Container(
      color: _readerBgColor,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
        itemCount: _posts.length + 1,
        itemBuilder: (context, index) {
          if (index == _posts.length) return _buildFooter();
          final post = _posts[index];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (index > 0)
                Divider(height: 40, color: _readerTextColor.withOpacity(0.1)),
              Text(
                "${post.floor} ${post.author}",
                style: TextStyle(
                  color: _readerTextColor.withOpacity(0.4),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              HtmlWidget(
                post.contentHtml,
                textStyle: TextStyle(
                  fontSize: _fontSize,
                  height: 1.8,
                  color: _readerTextColor,
                  fontFamily: "Serif",
                ),
                customWidgetBuilder: (element) {
                  if (element.localName == 'img') {
                    String src = element.attributes['src'] ?? '';
                    if (src.isNotEmpty)
                      return Image.network(
                        src,
                        headers: const {'User-Agent': kUserAgent},
                      );
                  }
                  return null;
                },
                onTapUrl: (url) async {
                  await _launchURL(url);
                  return true;
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
