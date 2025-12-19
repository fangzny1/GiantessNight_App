import 'dart:convert';
import 'package:flutter/foundation.dart'; // For compute
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // Add this for ScrollDirection
import 'package:flutter/services.dart';
import 'package:flutter_giantessnight_1/image_preview_page.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart'; // Add Dio
import 'package:cached_network_image/cached_network_image.dart'; // 建议引入这个库
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:scroll_to_index/scroll_to_index.dart'; // 引入库
import 'login_page.dart';
import 'user_detail_page.dart';
import 'forum_model.dart';
import 'reply_native_page.dart'; // 引入原生回复页面
import 'main.dart'; // Import main.dart for global variables

// Helper function for cleaning HTML (moved from class)
String _cleanHtml(String raw) {
  String clean = raw;
  if (clean.startsWith('"')) {
    clean = clean.substring(1, clean.length - 1);
  }
  clean = clean
      .replaceAll('\\u003C', '<')
      .replaceAll('\\"', '"')
      .replaceAll('\\\\', '\\');
  return clean;
}

class ParseResult {
  final List<PostItem> posts;
  final String? fid;
  final String? formhash;
  final String? posttime;
  final int postMinChars;
  final int postMaxChars;
  final bool hasNextPage;
  final String? landlordUid;
  final int totalPages;

  ParseResult({
    required this.posts,
    this.fid,
    this.formhash,
    this.posttime,
    required this.postMinChars,
    required this.postMaxChars,
    required this.hasNextPage,
    this.landlordUid,
    required this.totalPages,
  });
}

// Background parsing function
Future<ParseResult> _parseHtmlBackground(Map<String, dynamic> params) async {
  String rawHtml = params['rawHtml'];
  String baseUrl = params['baseUrl'];
  int targetPage = params['targetPage'];
  bool postsIsEmpty = params['postsIsEmpty'];
  String? landlordUid = params['landlordUid'];

  String cleanHtml = _cleanHtml(rawHtml);
  var document = html_parser.parse(cleanHtml);

  String? fid;
  var fidMatch = RegExp(r'fid=(\d+)').firstMatch(cleanHtml);
  if (fidMatch != null) {
    fid = fidMatch.group(1);
  }

  String? formhash;
  var hashMatch = RegExp(
    r'name="formhash" value="([^"]+)"',
  ).firstMatch(cleanHtml);
  if (hashMatch != null) {
    formhash = hashMatch.group(1);
  } else {
    hashMatch = RegExp(r'formhash=([a-zA-Z0-9]+)').firstMatch(cleanHtml);
    if (hashMatch != null) {
      formhash = hashMatch.group(1);
    }
  }

  String? posttime;
  var timeMatch = RegExp(r'id="posttime" value="(\d+)"').firstMatch(cleanHtml);
  if (timeMatch != null) {
    posttime = timeMatch.group(1);
  }

  int postMinChars = 0;
  var minCharsMatch = RegExp(
    r"var postminchars = parseInt\('(\d+)'\);",
  ).firstMatch(cleanHtml);
  if (minCharsMatch != null) {
    postMinChars = int.tryParse(minCharsMatch.group(1)!) ?? 0;
  }

  int postMaxChars = 0;
  var maxCharsMatch = RegExp(
    r"var postmaxchars = parseInt\('(\d+)'\);",
  ).firstMatch(cleanHtml);
  if (maxCharsMatch != null) {
    postMaxChars = int.tryParse(maxCharsMatch.group(1)!) ?? 0;
  }

  Map<String, String> aidToStaticUrl = {};
  var attachmentImgs = document.querySelectorAll('img[aid][zoomfile]');
  for (var img in attachmentImgs) {
    String? aid = img.attributes['aid'];
    String? url = img.attributes['zoomfile'];
    if (aid != null && url != null && url.contains("data/attachment")) {
      aidToStaticUrl[aid] = url;
    }
  }
  for (var img in attachmentImgs) {
    String? aid = img.attributes['aid'];
    String? url = img.attributes['file'];
    if (aid != null && url != null && url.contains("data/attachment")) {
      if (!aidToStaticUrl.containsKey(aid)) {
        aidToStaticUrl[aid] = url;
      }
    }
  }

  List<PostItem> newPosts = [];
  var postDivs = document.querySelectorAll('div[id^="post_"]');
  int floorIndex = (targetPage - 1) * 10 + 1;

  // 临时变量，用于本次解析中找到楼主
  String? foundLandlordUid = landlordUid;

  for (var div in postDivs) {
    try {
      if (div.id.contains("new") || div.id.contains("rate")) continue;
      String pid = div.id.split('_').last;

      var authorNode =
          div.querySelector('.authi .xw1') ?? div.querySelector('.authi a');
      String author = authorNode?.text.trim() ?? "匿名";
      String authorHref = authorNode?.attributes['href'] ?? "";
      String authorId =
          RegExp(r'uid=(\d+)').firstMatch(authorHref)?.group(1) ?? "";

      // 提取楼层号 (例如 "1#", "2#")
      var floorNode = div.querySelector('.pi strong a em');
      String floorText = floorNode?.text ?? "${floorIndex++}楼";

      // 【核心修复】如果这一楼是 "1#"，那这个人绝对是楼主！
      // 只要这页有 1 楼，我们就能锁定楼主 ID。
      if (floorText.contains("1") &&
          (floorText.contains("#") || floorText.contains("楼"))) {
        // 进一步确认是 "1" 开头，防止 "11#" 误判
        // 通常 Discuz 的 1 楼就是 "1#"
        if (floorText.trim() == "1#" ||
            floorText.trim() == "1" ||
            floorText.contains("1<sup>#</sup>")) {
          foundLandlordUid = authorId;
        }
      }

      // 如果还没找到，且当前是第1页的第1个帖子，做一个保底猜测
      if (foundLandlordUid == null && targetPage == 1 && newPosts.isEmpty) {
        foundLandlordUid = authorId;
      }

      var avatarNode = div.querySelector('.avatar img');
      String avatarUrl = avatarNode?.attributes['src'] ?? "";
      if (avatarUrl.isNotEmpty && !avatarUrl.startsWith("http")) {
        avatarUrl = "$baseUrl$avatarUrl";
      }

      var timeNode = div.querySelector('em[id^="authorposton"]');
      String time = timeNode?.text.replaceAll("发表于 ", "").trim() ?? "";

      var contentNode = div.querySelector('td.t_f');
      String content = contentNode?.innerHtml ?? "";
      var attachmentNode = div.querySelector('.pattl');
      if (attachmentNode != null) {
        content +=
            "<br><div class='attachments'>${attachmentNode.innerHtml}</div>";
      }

      content = content.replaceAll(r'\n', '<br>');
      content = content.replaceAll('<div class="mbn savephotop">', '<div>');

      content = content.replaceAllMapped(RegExp(r'<img[^>]+>', dotAll: true), (
        match,
      ) {
        String imgTag = match.group(0)!;
        String? zoomUrl = RegExp(
          r'zoomfile="([^"]+)"',
        ).firstMatch(imgTag)?.group(1);
        String? fileUrl = RegExp(
          r'file="([^"]+)"',
        ).firstMatch(imgTag)?.group(1);
        String? srcUrl = RegExp(r'src="([^"]+)"').firstMatch(imgTag)?.group(1);

        String? aidFromUrl;
        RegExp aidReg = RegExp(r'aid=(\d+)');
        if (fileUrl != null) {
          aidFromUrl = aidReg.firstMatch(fileUrl)?.group(1);
        }
        if (aidFromUrl == null && srcUrl != null) {
          aidFromUrl = aidReg.firstMatch(srcUrl)?.group(1);
        }

        String bestUrl = "";

        if (aidFromUrl != null && aidToStaticUrl.containsKey(aidFromUrl)) {
          bestUrl = aidToStaticUrl[aidFromUrl]!;
        } else if (zoomUrl != null && zoomUrl.contains("data/attachment")) {
          bestUrl = zoomUrl;
        } else if (fileUrl != null && fileUrl.contains("data/attachment")) {
          bestUrl = fileUrl;
        } else if (srcUrl != null && srcUrl.contains("data/attachment")) {
          bestUrl = srcUrl;
        } else if (fileUrl != null && fileUrl.isNotEmpty) {
          bestUrl = fileUrl;
        } else if (srcUrl != null && srcUrl.isNotEmpty) {
          if (!srcUrl.contains("loading.gif") &&
              !srcUrl.contains("none.gif") &&
              !srcUrl.contains("common.gif")) {
            bestUrl = srcUrl;
          }
        }

        if (bestUrl.isNotEmpty) {
          bestUrl = bestUrl.replaceAll('&amp;', '&');
          if (bestUrl.contains("mod=image")) {
            bestUrl = bestUrl.replaceAll(RegExp(r'&mobile=[0-9]+'), '');
            bestUrl = bestUrl.replaceAll(RegExp(r'&mobile=yes'), '');
            bestUrl = bestUrl.replaceAll(RegExp(r'&mobile=no'), '');
            bestUrl = bestUrl.replaceAll('&type=fixnone', '');
          }
          if (!bestUrl.startsWith('http')) {
            String base = baseUrl.endsWith('/') ? baseUrl : "$baseUrl/";
            String path = bestUrl.startsWith('/')
                ? bestUrl.substring(1)
                : bestUrl;
            bestUrl = base + path;
          }
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

  // Parse total pages
  int totalPages = 1;
  var pgNode = document.querySelector('.pg');
  if (pgNode != null) {
    // Try to find the "last" link first (e.g., "... 50")
    var lastNode = pgNode.querySelector('.last');
    if (lastNode != null) {
      String text = lastNode.text.replaceAll('... ', '').trim();
      totalPages = int.tryParse(text) ?? 1;
    } else {
      // If no "last" class, iterate all numbers to find max
      var links = pgNode.querySelectorAll('a, strong');
      for (var link in links) {
        int? p = int.tryParse(link.text.trim());
        if (p != null && p > totalPages) {
          totalPages = p;
        }
      }
    }
  }

  return ParseResult(
    posts: newPosts,
    fid: fid,
    formhash: formhash,
    posttime: posttime,
    postMinChars: postMinChars,
    postMaxChars: postMaxChars,
    hasNextPage: hasNextPage,
    landlordUid: foundLandlordUid,
    totalPages: totalPages,
  );
}

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
  final bool initialNovelMode;
  final String? initialAuthorId;
  final String? initialTargetFloor;
  final String? initialTargetPid;
  const ThreadDetailPage({
    super.key,
    required this.tid,
    required this.subject,
    this.initialPage = 1,
    this.initialNovelMode = false,
    this.initialAuthorId,
    this.initialTargetFloor,
    this.initialTargetPid,
  });

  @override
  State<ThreadDetailPage> createState() => _ThreadDetailPageState();
}

class _ThreadDetailPageState extends State<ThreadDetailPage>
    with TickerProviderStateMixin {
  WebViewController? _hiddenController;
  WebViewController? _favCheckController;
  // 使用 AutoScrollController 替换原生的 ScrollController
  late AutoScrollController _scrollController;

  bool _hasPerformedInitialJump = false; // Task 3

  List<PostItem> _posts = [];

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _isLoadingPrev = false;

  // 功能开关
  bool _isOnlyLandlord = false;
  bool _isReaderMode = false;
  bool _isNovelMode = false; // 【新增】小说模式
  bool _isFabOpen = false;

  bool _isFavorited = false;
  String? _favid;

  double _fontSize = 18.0; // 默认字体调大一点点，适合阅读
  Color _readerBgColor = const Color(0xFFFAF9DE); // 默认羊皮纸
  Color _readerTextColor = Colors.black87;

  late AnimationController _fabAnimationController;
  late Animation<double> _fabAnimation;

  late int _minPage;
  int _targetPage = 1;

  String? _landlordUid;
  String? _fid; // 板块ID
  String? _formhash; // 表单哈希，用于回复
  String? _posttime;
  int _postMinChars = 0;
  int _postMaxChars = 0;
  final String _baseUrl = "https://www.giantessnight.com/gnforum2012/";
  String _userCookies = "";
  final Map<String, GlobalKey> _floorKeys = {};
  final Map<String, GlobalKey> _pidKeys = {};

  // Task 1 & 3: UI State
  late AnimationController _hideController;
  bool _isBarsVisible = true;
  int _totalPages = 1;

  DateTime _lastAutoPageTurn = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isScrubbingScroll = false;
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    // 1. 初始化页码：非常关键，要信赖传入的 initialPage
    _minPage = widget.initialPage;
    _targetPage = widget.initialPage;

    // 初始化 AutoScrollController
    _scrollController = AutoScrollController(
      viewportBoundaryGetter: () =>
          Rect.fromLTRB(0, 0, 0, MediaQuery.of(context).padding.bottom),
      axis: Axis.vertical,
      suggestedRowHeight: 200, // 估算高度
    );

    _fabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _fabAnimation = CurvedAnimation(
      parent: _fabAnimationController,
      curve: Curves.easeInOut,
    );

    // Task 3: Auto-Hide Controller
    _hideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1.0, // Initially visible
    );

    _loadSettings();

    // 2. 初始化模式
    if (widget.initialNovelMode) {
      _isNovelMode = true;
      _isOnlyLandlord = true;
      _isReaderMode = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      // 3. 楼主ID注入
      if (widget.initialAuthorId != null &&
          widget.initialAuthorId!.isNotEmpty) {
        _landlordUid = widget.initialAuthorId;
      }
    }

    _loadLocalCookie().then((_) {
      _initWebView();
      _initFavCheck(); // 等 Cookie 加载完再初始化

      // 【新增】启动后台侦探
      _fetchLandlordUidBackground();
    });
    _scrollController.addListener(_handleEdgePaging);
  }

  void _handleEdgePaging() {
    if (_isLoading) return;
    if (_isScrubbingScroll) return;
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final now = DateTime.now();
    if (now.difference(_lastAutoPageTurn).inMilliseconds < 800) return;

    if (position.pixels >= position.maxScrollExtent - 24) {
      if (_targetPage < _totalPages) {
        _lastAutoPageTurn = now;
        if (!_isLoadingMore) {
          setState(() {
            _isLoadingMore = true;
          });
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadPage(_targetPage + 1);
        });
      }
      return;
    }

    if (position.pixels <= position.minScrollExtent + 24) {
      if (_targetPage > 1) {
        _lastAutoPageTurn = now;
        if (!_isLoadingPrev) {
          setState(() {
            _isLoadingPrev = true;
          });
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadPage(_targetPage - 1);
        });
      }
    }
  }

  // 修改加载逻辑
  void _loadPage(int page, {bool resetScroll = false}) async {
    _targetPage = page;

    // UI 状态更新
    if (mounted) {
      setState(() {
        _isLoading = true;
        // 注意：这里不要清空 _posts，否则翻页时会闪烁
        // 除非是跳转跨度很大
      });
    }

    if (resetScroll && _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }

    // 构造 URL (强制使用电脑版 mobile=no 以便解析)
    String url =
        '${_baseUrl}forum.php?mod=viewthread&tid=${widget.tid}&mobile=no';
    if (_isOnlyLandlord && _landlordUid != null) {
      url += '&authorid=$_landlordUid';
    }
    url += '&page=$page';

    print("🚀 加载帖子(第$page页): $url");

    // ============================================================
    // 【核心修复】强力模式：Dio 下载 -> 校验 -> 注入 WebView
    // ============================================================
    if (useDioProxyLoader.value) {
      print("⚡️ [DioProxy] 详情页正在通过 Dio 下载 HTML...");
      try {
        final dio = Dio();
        dio.options.headers['Cookie'] = _userCookies;
        dio.options.headers['User-Agent'] = kUserAgent;
        dio.options.connectTimeout = const Duration(seconds: 15);
        dio.options.receiveTimeout = const Duration(seconds: 15);

        final response = await dio.get<String>(url);

        // 【新增】保存新 Cookie
        List<String>? newCookies = response.headers['set-cookie'];
        if (newCookies != null && newCookies.isNotEmpty) {
          String combined = newCookies.map((c) => c.split(';')[0]).join('; ');
          if (combined.contains('auth')) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('saved_cookie_string', combined);
          }
        }

        if (response.statusCode == 200 && response.data != null) {
          String html = response.data!;

          // --- 【新增：安检门】 ---
          // 检查 HTML 是否包含关键内容，防止"假成功"
          // 1. 检查是否变成了登录页
          if (html.contains('action=login') &&
              !html.contains('id="postlist"')) {
            print("💨 [DioProxy] 抓取到了登录页，Cookie 可能失效");
            throw Exception("Session expired"); // 抛出异常，触发 catch，降级回 WebView
          }

          // 2. 检查是否包含帖子列表容器
          // 正常的帖子页面一定有 id="postlist" 或 class="pl"
          if (!html.contains('id="postlist"') && !html.contains('class="pl"')) {
            print("💨 [DioProxy] 抓取内容异常（可能是WAF验证页），降级处理");
            throw Exception("Invalid content");
          }
          // -----------------------

          // 如果通过安检，再注入
          _hiddenController?.loadHtmlString(html, baseUrl: url);

          // 2. 直接调用解析逻辑 (不等待 WebView 的 onPageFinished)
          // 这样速度最快，且绕过了 WebView 的网络层
          _parseHtmlData(html);

          // 保存缓存 (Dio 模式单独保存，避免与 WebView 模式重复)
          final prefs = await SharedPreferences.getInstance();
          final cacheKey =
              'thread_cache_${widget.tid}_${page}_${_isOnlyLandlord ? "landlord" : "all"}';
          await prefs.setString(cacheKey, html);

          print("✅ [DioProxy] 详情页 HTML 下载并注入成功");
          return; // 成功后直接退出，不走下面的 loadRequest
        }
      } catch (e) {
        print("❌ [DioProxy] 加载失败/校验未通过: $e");
        print("🔄 自动降级：尝试使用 WebView 原生加载...");
        if (mounted) {
          // 可选：给个小提示
          // ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("强力加载失败，尝试原生重试..."), duration: Duration(milliseconds: 500)));
        }
      }
    }

    // ============================================================
    // 原生模式 (默认)：WebView 直接加载
    // ============================================================

    // 尝试读取缓存 (极速加载) - 仅在原生模式或 Dio 失败后尝试
    // (逻辑保持你原来的不变，略...)
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey =
          'thread_cache_${widget.tid}_${page}_${_isOnlyLandlord ? "landlord" : "all"}';
      final cachedHtml = prefs.getString(cacheKey);
      if (cachedHtml != null && cachedHtml.isNotEmpty) {
        if (mounted) _parseHtmlData(cachedHtml);
      }
    } catch (e) {}

    // WebView 发起请求
    _hiddenController?.loadRequest(
      Uri.parse(url),
      headers: {'Cookie': _userCookies, 'User-Agent': kUserAgent},
    );
  }

  Future<void> _loadLocalCookie() async {
    final prefs = await SharedPreferences.getInstance();
    final String saved = prefs.getString('saved_cookie_string') ?? "";
    if (mounted) {
      setState(() {
        _userCookies = saved; // 赋值给全局变量，供图片加载使用
      });
    }
  }

  // 【API 方案】后台获取楼主 ID (最快、最准、最省流)
  Future<void> _fetchLandlordUidBackground() async {
    // 如果已经有了，或者不需要，直接退出
    if (_landlordUid != null && _landlordUid!.isNotEmpty) return;
    if (widget.initialAuthorId != null && widget.initialAuthorId!.isNotEmpty) {
      if (mounted) setState(() => _landlordUid = widget.initialAuthorId);
      return;
    }

    // print("🕵️‍♂️ 后台启动：尝试通过官方 API 获取楼主 ID...");

    try {
      final dio = Dio();
      // 带上 Cookie，防止 API 报权限错误
      dio.options.headers['Cookie'] = _userCookies;
      dio.options.headers['User-Agent'] = kUserAgent;

      // 生成时间戳防缓存
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();

      // 【关键】URL 拼接，确保 tid 是纯数字
      String url =
          'https://www.giantessnight.com/gnforum2012/api/mobile/index.php?version=4&module=viewthread&tid=${widget.tid}&page=1&t=$timestamp';

      final response = await dio.get<String>(url);

      if (response.statusCode == 200 && response.data != null) {
        String rawData = response.data!;

        // 1. 清洗数据 (Discuz API 有时候会包一层引号)
        if (rawData.startsWith('"') && rawData.endsWith('"')) {
          rawData = rawData.substring(1, rawData.length - 1);
          rawData = rawData.replaceAll('\\"', '"').replaceAll('\\\\', '\\');
        }

        try {
          var json = jsonDecode(rawData);

          // 2. 直接读取 Variables -> thread -> authorid
          // 这是最直接的证据，比去 postlist 里猜靠谱多了
          if (json['Variables'] != null &&
              json['Variables']['thread'] != null) {
            String apiUid = json['Variables']['thread']['authorid'].toString();

            if (apiUid.isNotEmpty && apiUid != "0") {
              // print("✅ API 破案成功！楼主 UID 是: $apiUid");
              if (mounted) {
                setState(() {
                  _landlordUid = apiUid;
                });
              }
            }
          }
          // 如果 thread 里没有，再尝试去 postlist 第一个找
          else if (json['Variables']['postlist'] != null &&
              (json['Variables']['postlist'] as List).isNotEmpty) {
            var firstPost = json['Variables']['postlist'][0];
            if (firstPost['first'] == '1' || firstPost['first'] == 1) {
              String fallbackUid = firstPost['authorid'].toString();
              // print("⚠️ API thread 信息缺失，从 1 楼获取到 UID: $fallbackUid");
              if (mounted) setState(() => _landlordUid = fallbackUid);
            }
          }
        } catch (e) {
          // print("❌ JSON 解析失败: $e");
        }
      }
    } catch (e) {
      // print("❌ API 请求失败: $e");
    }
  }

  // 加载用户之前的阅读偏好
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    int? colorVal = prefs.getInt('reader_bg_color');
    if (colorVal != null) {
      setState(() {
        _readerBgColor = Color(colorVal);
        // 简单的反色逻辑，如果是深色背景，字变白
        if (_readerBgColor.computeLuminance() < 0.5) {
          _readerTextColor = Colors.white70;
        } else {
          _readerTextColor = Colors.black87;
        }
      });
    }
  }

  // 保存设置
  Future<void> _saveSettings(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('reader_bg_color', color.toARGB32());
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scrollController.dispose();
    _fabAnimationController.dispose();
    _hideController.dispose();
    super.dispose();
  }

  void _initWebView() {
    // 1. 先创建对象
    final controller = WebViewController(); //

    // 2. 再配置 (这时候 controller 已经存在了，回调里可以用了)
    // 【修复：将级联操作符拆分，避免引用歧义】
    controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    controller.setUserAgent(kUserAgent);
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (url) async {
          try {
            // 这里现在可以安全使用 controller 了
            final String cookies =
                await controller.runJavaScriptReturningResult(
                      //
                      'document.cookie',
                    )
                    as String;
            String cleanCookies = cookies;
            if (cleanCookies.startsWith('"') && cleanCookies.endsWith('"')) {
              cleanCookies = cleanCookies.substring(1, cleanCookies.length - 1);
            }
            if (mounted) {
              setState(() {
                _userCookies = cleanCookies;
              });
            }
          } catch (e) {
            // Cookie 同步失败
          }
          _parseHtmlData();
        },
      ),
    );
    // 3. 赋值给全局变量并刷新 UI
    setState(() {
      _hiddenController = controller;
    }); //
    _loadPage(_targetPage); //
  }

  void _initFavCheck() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            // 如果加载的是收藏列表页，解析它
            if (url.contains("do=favorite")) {
              _parseFavList();
            }
            // 如果是执行删除后的刷新
            else if (url.contains("op=delete") && url.contains("ac=favorite")) {
              // 自动点击“确定删除”按钮
              // 修复: 必须在 _favCheckController (加载收藏页面的WebView) 中执行点击，而不是主 WebView
              _favCheckController?.runJavaScript(
                "var btn = document.querySelector('button[name=\"deletesubmitbtn\"]'); if(btn) btn.click();",
              );
            }
          },
        ),
      );

    // 加载收藏页面 (用于检查当前帖子是否已收藏)
    controller.loadRequest(
      Uri.parse('${_baseUrl}home.php?mod=space&do=favorite&view=me&mobile=no'),
      headers: {'Cookie': _userCookies, 'User-Agent': kUserAgent},
    );

    setState(() {
      _favCheckController = controller;
    });
  }

  void _loadNext() {
    if (_isLoading || _isLoadingMore) {
      return;
    }
    if (_targetPage >= _totalPages) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("已经是最后一页了")));
      return;
    }
    setState(() {
      _isLoadingMore = true;
    });
    _loadPage(_targetPage + 1);
  }

  void _loadPrev() {
    if (_isLoading || _isLoadingPrev) {
      return;
    }
    if (_targetPage <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("已经是第一页了")));
      return;
    }
    setState(() {
      _isLoadingPrev = true;
    });
    _loadPage(_targetPage - 1);
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

  // 【核心功能】切换小说模式
  void _toggleNovelMode() {
    if (_landlordUid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("正在获取楼主信息，请稍候...")));
      return;
    }

    setState(() {
      _isNovelMode = !_isNovelMode;

      // 1. 设置模式标记
      if (_isNovelMode) {
        _isOnlyLandlord = true;
        _isReaderMode = true;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

        // 【关键策略】开启小说模式时，通常用户想从头看楼主的故事
        // 且为了避免"普通模式第50页 -> 楼主只有3页"导致的越界
        // 我们强制重置回第 1 页
        _targetPage = 1;
      } else {
        _isOnlyLandlord = false;
        _isReaderMode = false;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        // 关闭时，保留当前页码（尝试回到普通模式的对应页）
      }

      // 2. 清空数据 & 重置总页数状态
      _posts.clear();
      _pidKeys.clear();
      _floorKeys.clear();

      // 【关键修复】重置总页数！
      // 否则切换后进度条还会显示 "1/50"，实际上楼主可能只有 "1/3"
      // 等数据加载完，解析器会更新成正确的总页数
      _totalPages = 1;

      _isLoading = true;

      // 3. 关闭菜单并加载
      if (_isFabOpen) _toggleFab();
      _loadPage(_targetPage);
    });
  }

  // 切换普通阅读模式（不强制只看楼主）
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

  void _handleFavorite() {
    _toggleFab(); // 关菜单

    if (_isFavorited) {
      // === 取消收藏逻辑 ===
      if (_favid != null) {
        String delUrl =
            "${_baseUrl}home.php?mod=spacecp&ac=favorite&op=delete&favid=$_favid&type=all";
        // 后台 WebView 去请求删除链接
        _favCheckController?.loadRequest(Uri.parse(delUrl));

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("正在取消收藏...")));

        // 3秒后刷新列表确认状态
        Future.delayed(const Duration(seconds: 3), () {
          _favCheckController?.loadRequest(
            Uri.parse(
              '${_baseUrl}home.php?mod=space&do=favorite&view=me&mobile=no',
            ),
            headers: {'Cookie': _userCookies, 'User-Agent': kUserAgent},
          );
        });

        setState(() {
          _isFavorited = false;
          _favid = null;
        });
      }
    } else {
      // === 添加收藏逻辑 ===
      // 借用主 WebView 执行 JS 点击收藏按钮 (因为主 WebView 就在帖子页面)
      _hiddenController?.runJavaScript(
        "if(document.querySelector('#k_favorite')) document.querySelector('#k_favorite').click();",
      );

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("已发送收藏请求")));
      setState(() {
        _isFavorited = true;
      });

      // 3秒后刷新收藏列表获取 favid
      Future.delayed(const Duration(seconds: 3), () {
        _favCheckController?.loadRequest(
          Uri.parse(
            '${_baseUrl}home.php?mod=space&do=favorite&view=me&mobile=no',
          ),
          headers: {'Cookie': _userCookies, 'User-Agent': kUserAgent},
        );
      });
    }
  }

  void _showSaveBookmarkDialog() {
    if (_posts.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                "选择你读到的楼层进行存档",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: _posts.length,
                itemBuilder: (context, index) {
                  // 倒序显示，因为大家通常是看到最新的（最底下）
                  // 如果想正序（从第1楼开始），就用 final post = _posts[index];
                  final int reverseIndex = _posts.length - 1 - index;
                  final post = _posts[reverseIndex];

                  // 简单的摘要提取
                  String summary = post.contentHtml
                      .replaceAll(RegExp(r'<[^>]*>'), '') // 去掉HTML标签
                      .replaceAll('&nbsp;', ' ')
                      .trim();
                  if (summary.length > 30) {
                    summary = "${summary.substring(0, 30)}...";
                  }
                  if (summary.isEmpty) summary = "[图片/表情]";

                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      child: Text(
                        post.floor.replaceAll("楼", ""),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    title: Text(
                      post.author,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.bookmark_add_outlined),
                    onTap: () {
                      // 解析楼层号并反推页码（Discuz 默认每页10楼）
                      int pageToSave = _targetPage;
                      final m = RegExp(r'(\\d+)').firstMatch(post.floor);
                      if (m != null) {
                        int floorNum = int.tryParse(m.group(1)!) ?? 0;
                        if (floorNum > 0) {
                          pageToSave = ((floorNum - 1) ~/ 10) + 1;
                        }
                      }
                      _saveBookmarkWithFloor(
                        post.floor,
                        pageToSave,
                        pid: post.pid,
                      );
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveBookmarkWithFloor(
    String floorName,
    int pageToSave, {
    String? pid,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    String? jsonStr = prefs.getString('local_bookmarks');
    List<dynamic> jsonList = [];
    if (jsonStr != null && jsonStr.startsWith("[")) {
      jsonList = jsonDecode(jsonStr);
    }

    String subjectSuffix = _isNovelMode ? " (小说)" : "";

    final newMark = BookmarkItem(
      tid: widget.tid,
      subject: widget.subject.replaceAll(" (小说)", "") + subjectSuffix,
      author: _posts.isNotEmpty ? _posts.first.author : "未知",
      authorId: _landlordUid ?? "",
      page: pageToSave, // 保存当前最大页码
      // 这里的 savedTime 我们利用一下，存入具体的楼层信息，方便列表显示
      savedTime:
          "${DateTime.now().toString().substring(5, 16)} · 读至 $floorName",
      isNovelMode: _isNovelMode,
      targetPid: pid,
      targetFloor: floorName,
    );

    jsonList.removeWhere((e) => e['tid'] == widget.tid);
    jsonList.insert(0, newMark.toJson());
    await prefs.setString('local_bookmarks', jsonEncode(jsonList));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("已保存进度：第 $pageToSave 页 - $floorName")),
      );
    }
  }

  // _saveBookmark unused

  void _toggleOnlyLandlord() {
    if (_landlordUid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("未找到楼主信息")));
      return;
    }
    setState(() {
      _isOnlyLandlord = !_isOnlyLandlord;
      // 如果手动关闭只看楼主，退出小说模式状态
      if (!_isOnlyLandlord) _isNovelMode = false;

      // 1. 策略同上：开启只看楼主 -> 重置回第 1 页
      if (_isOnlyLandlord) {
        _targetPage = 1;
      }

      // 2. 清空数据 & 重置总页数状态
      _posts.clear();
      _pidKeys.clear();
      _floorKeys.clear();
      _minPage = _targetPage;

      // 3. 【关键修复】重置总页数，防止进度条显示错误
      _totalPages = 1;

      _isLoading = true;
      _toggleFab();
    });

    // 加载
    _loadPage(_targetPage);
  }

  Future<void> _parseFavList() async {
    if (_favCheckController == null) return;
    try {
      final String rawHtml =
          await _favCheckController!.runJavaScriptReturningResult(
                "document.documentElement.outerHTML",
              )
              as String;

      String cleanHtml = _cleanHtml(rawHtml);
      var document = html_parser.parse(cleanHtml);

      // Discuz 收藏列表通常在 id="favorite_ul"
      var items = document.querySelectorAll('ul[id="favorite_ul"] li');
      String? foundFavid;

      for (var item in items) {
        // 检查有没有当前 TID 的链接
        var link = item.querySelector('a[href*="tid=${widget.tid}"]');
        if (link != null) {
          // 如果找到了，提取 favid (用于删除)
          var delLink = item.querySelector('a[href*="op=delete"]');
          if (delLink != null) {
            String href = delLink.attributes['href'] ?? "";
            String favid =
                RegExp(r'favid=(\d+)').firstMatch(href)?.group(1) ?? "";
            if (favid.isNotEmpty) {
              foundFavid = favid;
              break;
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _isFavorited = (foundFavid != null);
          _favid = foundFavid;
        });
      }
    } catch (e) {
      // 收藏解析出错
    }
  }

  // === 核心解析逻辑 ===
  Future<void> _parseHtmlData([String? inputHtml]) async {
    // 允许传入 HTML 字符串（来自 Dio 或 Cache），或者从 WebView 提取
    if (inputHtml == null && _hiddenController == null) return;
    try {
      String rawHtml;
      if (inputHtml != null) {
        rawHtml = inputHtml;
      } else {
        final result = await _hiddenController!.runJavaScriptReturningResult(
          "document.documentElement.outerHTML",
        );
        rawHtml = result as String;
        // WebView 返回的是 JSON 字符串 (带双引号)，需要反序列化
        if (rawHtml.startsWith('"') && rawHtml.endsWith('"')) {
          rawHtml = jsonDecode(rawHtml);
        }
      }

      // 【新增】统一缓存保存逻辑
      // 只有当页面看起来像是正常的帖子页面时才保存
      if (rawHtml.contains('id="postlist"') || rawHtml.contains('class="pl"')) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final cacheKey =
              'thread_cache_${widget.tid}_${_targetPage}_${_isOnlyLandlord ? "landlord" : "all"}';
          // 只有当 inputHtml 为空 (即 WebView 模式) 时才在这里保存，Dio 模式已经在 _loadPage 里保存过了
          if (inputHtml == null) {
            await prefs.setString(cacheKey, rawHtml);
          }
        } catch (e) {
          // 缓存保存失败忽略
        }
      }

      // Task 2: Use compute for background parsing
      final result = await compute(_parseHtmlBackground, {
        'rawHtml': rawHtml,
        'baseUrl': _baseUrl,
        'targetPage': _targetPage,
        'postsIsEmpty': _posts.isEmpty,
        'landlordUid': _landlordUid,
      });

      if (!mounted) return;

      // Task 4: Auto-load nearest valid page if current is empty
      // If we are on a page that exceeds total pages (common when switching to Only Landlord),
      // jump to the last available page.
      if (result.posts.isEmpty &&
          result.totalPages > 0 &&
          _targetPage > result.totalPages) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("当前页为空，自动跳转至第 ${result.totalPages} 页")),
        );
        _loadPage(result.totalPages);
        return;
      }

      setState(() {
        // Update metadata
        if (result.fid != null) _fid = result.fid;
        if (result.formhash != null) _formhash = result.formhash;
        if (result.posttime != null) _posttime = result.posttime;
        _postMinChars = result.postMinChars;
        _postMaxChars = result.postMaxChars;
        if (_landlordUid == null && result.landlordUid != null) {
          _landlordUid = result.landlordUid;
        }

        if (result.totalPages > 0) {
          _totalPages = result.totalPages;
        }

        List<PostItem> newPosts = result.posts;

        // 【修复】回归无限瀑布流逻辑
        if (_targetPage == widget.initialPage && _posts.isEmpty) {
          // 第一次加载，或者从外部跳进来
          _posts = newPosts;
        } else if (_targetPage < _minPage) {
          // 加载上一页，插到头部
          _posts.insertAll(0, newPosts);
          _minPage = _targetPage;
        } else {
          // 加载下一页，追加到尾部 (去重)
          for (var p in newPosts) {
            if (!_posts.any((old) => old.pid == p.pid)) _posts.add(p);
          }
        }

        _isLoading = false;
        _isLoadingMore = false;
        _isLoadingPrev = false;
      });

      // 渲染完成后定位到目标楼层
      if (widget.initialTargetFloor != null ||
          widget.initialTargetPid != null) {
        _scrollToTargetFloor();
      }
    } catch (e) {
      // print("Parse error: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isLoadingMore = false;
          _isLoadingPrev = false;
        });
      }
      // 解析异常时不再尝试自动定位
    }
  }

  // 滚动的重试逻辑 (现在使用 scroll_to_index)
  Future<void> _scrollToTargetFloor() async {
    if (_posts.isEmpty) return;
    if (_hasPerformedInitialJump) return; // Task 3: Prevent double jump

    int targetIndex = -1;

    // 1. 优先尝试 PID 定位
    if (widget.initialTargetPid != null) {
      targetIndex = _posts.indexWhere((p) => p.pid == widget.initialTargetPid);
    }

    // 2. 降级尝试楼层号定位
    if (targetIndex == -1 && widget.initialTargetFloor != null) {
      targetIndex = _posts.indexWhere(
        (p) => p.floor == widget.initialTargetFloor,
      );
    }

    if (targetIndex != -1) {
      // 稍微延迟一下等待列表构建
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;

      await _scrollController.scrollToIndex(
        targetIndex,
        preferPosition: AutoScrollPosition.begin,
        duration: const Duration(milliseconds: 800),
      );

      _hasPerformedInitialJump = true; // Task 3: Mark as done

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("已定位到上次阅读位置"),
            duration: const Duration(milliseconds: 1000),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      if (_isLoading || _isLoadingMore) return; // 正在加载就等等

      // 简单判断：如果还没到最后一页，就继续往下加载
      if (_targetPage < _totalPages) {
        _loadNext();
      } else {
        // 到底了还没找到，放弃治疗（可能是楼层被删了）
        _hasPerformedInitialJump = true;
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text("未找到目标楼层，可能已被删除")));
        }
      }
    }
  }

  // 【核心升级】使用 CachedNetworkImage + 弱网点击重试
  Widget _buildClickableImage(String url) {
    if (url.isEmpty) return const SizedBox();
    String fullUrl = url;
    if (!fullUrl.startsWith('http')) {
      String base = _baseUrl.endsWith('/') ? _baseUrl : "$_baseUrl/";
      String path = fullUrl.startsWith('/') ? fullUrl.substring(1) : fullUrl;
      fullUrl = base + path;
    }

    // 这里直接使用文件底部的 RetryableImage 组件
    return RetryableImage(
      imageUrl: fullUrl,
      cacheManager: globalImageCache, // 确保这个变量在 forum_model.dart 里定义了
      headers: {
        'Cookie': _userCookies,
        'User-Agent': kUserAgent,
        'Referer': _baseUrl,
        'Accept':
            'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
      },
      onTap: (previewUrl) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ImagePreviewPage(
              imageUrl: previewUrl,
              headers: {
                'Cookie': _userCookies,
                'User-Agent': kUserAgent,
                'Referer': _baseUrl,
              },
              // 如果 ImagePreviewPage 支持 cacheManager 参数最好传进去，不支持也没事
            ),
          ),
        );
      },
    );
  }

  String _cleanHtml(String raw) {
    String clean = raw;
    if (clean.startsWith('"')) {
      clean = clean.substring(1, clean.length - 1);
    }
    clean = clean
        .replaceAll('\\u003C', '<')
        .replaceAll('\\"', '"')
        .replaceAll('\\\\', '\\');
    return clean;
  }

  Future<void> _launchURL(String? url) async {
    if (url == null || url.isEmpty) return;
    final Uri uri = Uri.parse(url.trim());
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      // ignore: empty_catches
    }
  }

  void _showDisplaySettings() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.all(20),
              height: 320,
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
                    "背景颜色 (自动保存)",
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
                      ), // 羊皮纸
                      _buildColorBtn(
                        const Color(0xFFC7EDCC),
                        Colors.black87,
                        "豆沙",
                      ), // 护眼绿
                      _buildColorBtn(
                        const Color(0xFF1A1A1A),
                        Colors.white70,
                        "夜间",
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            );
          },
        );
      },
    );
    _toggleFab();
  }

  Widget _buildColorBtn(Color bg, Color text, String label) {
    bool isSelected = _readerBgColor.toARGB32() == bg.toARGB32();
    return GestureDetector(
      onTap: () {
        setState(() {
          _readerBgColor = bg;
          _readerTextColor = text;
        });
        _saveSettings(bg); // 保存设置
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

  void _jumpToUser(PostItem post) {
    if (post.authorId.isNotEmpty) {
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
  }

  // Task 2: Page Jump Dialog
  // Task 1 & 2: Bottom Control Bar & Dual Slider System
  // 【最终楼层版】底部控制栏
  Widget _buildBottomControlBar() {
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(_hideController),
      child: Material(
        elevation: 16,
        color: Theme.of(context).colorScheme.surface,
        child: Container(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom,
          ),
          height: 56 + MediaQuery.of(context).padding.bottom,
          child: Row(
            children: [
              // 1. 菜单按钮
              IconButton(
                icon: Icon(_isFabOpen ? Icons.close : Icons.menu),
                onPressed: _toggleFab,
              ),

              // 2. 【核心修改】楼层进度滑块
              Expanded(
                child: AnimatedBuilder(
                  animation: _scrollController,
                  builder: (context, child) {
                    // 准备数据
                    int totalCount = _posts.length;
                    if (totalCount == 0) {
                      return const Slider(value: 0, onChanged: null);
                    }

                    // 计算当前 UI 显示的值
                    // 如果正在拖动，显示拖动值；如果没拖动，估算当前在第几楼
                    double uiValue;
                    if (_isScrubbingScroll && _dragValue != null) {
                      uiValue = _dragValue!;
                    } else {
                      // 这里做一个简单的估算用于回显，不需要太精确，避免抽搐
                      // 我们不再反向计算像素，而是默认显示上次跳转的位置，或者保持 0
                      // 为了体验最好，这里我们只在拖动时更新滑块，平时让滑块停留在"当前可视区域最上面的楼层"
                      // 由于获取"可视楼层"比较耗性能，这里我们简化：
                      // 滑块默认不跟随滚动乱跳，只作为"定位器"使用
                      uiValue = (_dragValue ?? 0.0).clamp(
                        0.0,
                        (totalCount - 1).toDouble(),
                      );
                    }

                    // 获取滑块当前指向的楼层名（用于显示 Label）
                    String label = "";
                    int targetIndex = uiValue.round();
                    if (targetIndex >= 0 && targetIndex < totalCount) {
                      label = _posts[targetIndex].floor;
                    }

                    return Slider(
                      value: uiValue,
                      min: 0.0,
                      max: (totalCount - 1).toDouble(), // 范围：0 到 最后一个索引
                      divisions: totalCount > 1
                          ? totalCount - 1
                          : 1, // 变成离散的格子，一格一楼
                      label: label, // 显示 "23楼"

                      onChangeStart: (val) {
                        setState(() {
                          _isScrubbingScroll = true;
                          _dragValue = val;
                        });
                      },

                      onChanged: (val) {
                        setState(() {
                          _dragValue = val;
                        });
                        // 实时跳转逻辑：使用 scrollToIndex 精准定位到楼层顶部
                        // 注意：这里可能会有些频繁，如果卡顿可以放到 onChangeEnd 里
                        _scrollController.scrollToIndex(
                          val.round(),
                          preferPosition: AutoScrollPosition.begin,
                          duration: const Duration(milliseconds: 100), // 快速动画
                        );
                      },

                      onChangeEnd: (val) {
                        setState(() {
                          _isScrubbingScroll = false;
                          // _dragValue 不清空，让滑块停在刚才选的位置，防止跳变
                        });
                        // 最终确认定位
                        _scrollController.scrollToIndex(
                          val.round(),
                          preferPosition: AutoScrollPosition.begin,
                          duration: const Duration(milliseconds: 300),
                        );
                      },
                    );
                  },
                ),
              ),

              // 3. 页码按钮
              InkWell(
                onTap: _showPageJumpDialog,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.import_contacts,
                        size: 16,
                        color: Colors.grey,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "$_targetPage / $_totalPages",
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Task 2 & 3: Page Jump Dialog with Pagination Fix
  void _showPageJumpDialog() {
    int dialogPage = _targetPage;
    final TextEditingController pageController = TextEditingController(
      text: _targetPage.toString(),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final double max = _totalPages < 1 ? 1.0 : _totalPages.toDouble();

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: SizedBox(
                height: 280,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      "快速翻页",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text("1", style: TextStyle(color: Colors.grey)),
                        Expanded(
                          child: Slider(
                            value: dialogPage.toDouble().clamp(1.0, max),
                            min: 1.0,
                            max: max,
                            divisions: _totalPages < 1 ? 1 : _totalPages,
                            label: "第 $dialogPage 页",
                            onChanged: (val) {
                              setStateDialog(() {
                                dialogPage = val.toInt();
                                pageController.text = dialogPage.toString();
                              });
                            },
                          ),
                        ),
                        Text(
                          "$_totalPages",
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        TextButton(
                          onPressed: dialogPage > 1
                              ? () {
                                  setStateDialog(() {
                                    dialogPage -= 1;
                                    pageController.text = dialogPage.toString();
                                  });
                                }
                              : null,
                          child: const Text("上一页"),
                        ),
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: pageController,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            onChanged: (val) {
                              final p = int.tryParse(val);
                              if (p == null) return;
                              if (p < 1 || p > _totalPages) return;
                              setStateDialog(() {
                                dialogPage = p;
                              });
                            },
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: dialogPage < _totalPages
                              ? () {
                                  setStateDialog(() {
                                    dialogPage += 1;
                                    pageController.text = dialogPage.toString();
                                  });
                                }
                              : null,
                          child: const Text("下一页"),
                        ),
                      ],
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          Navigator.pop(context);
                          if (dialogPage != _targetPage) {
                            if (mounted) {
                              setState(() {
                                _targetPage = dialogPage;
                                _minPage = dialogPage;
                                _posts = [];
                                _pidKeys.clear();
                                _floorKeys.clear();
                                _isLoading = true;
                              });
                            }
                            _loadPage(dialogPage);
                          }
                        },
                        child: const Text("跳转"),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    Color bgColor = Theme.of(context).colorScheme.surface;
    if (_isReaderMode) bgColor = _readerBgColor;

    return Scaffold(
      backgroundColor: bgColor,
      body: NotificationListener<UserScrollNotification>(
        onNotification: (notification) {
          if (notification.direction == ScrollDirection.reverse) {
            if (_isBarsVisible) {
              setState(() {
                _isBarsVisible = false;
                _hideController.reverse();
              });
            }
          } else if (notification.direction == ScrollDirection.forward) {
            if (!_isBarsVisible) {
              setState(() {
                _isBarsVisible = true;
                _hideController.forward();
              });
            }
          }
          return true;
        },
        child: GestureDetector(
          onTap: () {
            setState(() {
              _isBarsVisible = !_isBarsVisible;
              if (_isBarsVisible) {
                _hideController.forward();
              } else {
                _hideController.reverse();
              }
            });
          },
          child: Stack(
            children: [
              CustomScrollView(
                controller: _scrollController,
                cacheExtent: 2000.0,
                slivers: [
                  if (!_isReaderMode)
                    SliverAppBar(
                      floating: true,
                      pinned: false,
                      snap: true,
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

                  if (_isReaderMode)
                    _buildReaderSliver()
                  else
                    _buildNativeSliver(),
                ],
              ),

              // Bottom Control Bar
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomControlBar(),
              ),

              // Task 4: Scrim for Closing Menu
              if (_isFabOpen)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _toggleFab,
                    child: Container(color: Colors.black54),
                  ),
                ),

              _buildFabMenu(),

              if (_hiddenController != null)
                SizedBox(
                  height: 0,
                  width: 0,
                  child: WebViewWidget(controller: _hiddenController!),
                ),

              if (_favCheckController != null)
                SizedBox(
                  height: 0,
                  width: 0,
                  child: WebViewWidget(controller: _favCheckController!),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFabMenu() {
    // Only show if open
    if (!_isFabOpen) return const SizedBox();

    return Positioned(
      right: 16,
      bottom: 90, // Adjusted to sit above the bottom bar
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildFabItem(
            icon: Icons.refresh,
            label: "刷新",
            onTap: () {
              setState(() {
                _isLoading = true;
                _posts.clear();
                _pidKeys.clear();
                _floorKeys.clear();
              });
              _loadPage(_targetPage);
              _toggleFab();
            },
          ),
          const SizedBox(height: 12),

          // === 手动书签 ===
          _buildFabItem(
            icon: Icons.bookmark_add,
            label: "保存进度",
            onTap: () {
              _toggleFab();
              _showSaveBookmarkDialog();
            },
          ),
          const SizedBox(height: 12),

          // === 收藏 ===
          _buildFabItem(
            icon: _isFavorited ? Icons.star : Icons.star_border,
            label: _isFavorited ? "取消收藏" : "收藏本帖",
            color: _isFavorited
                ? (Theme.of(context).brightness == Brightness.dark
                      ? Colors.yellow.shade700
                      : Colors.yellow.shade200)
                : null,
            onTap: _handleFavorite,
          ),
          const SizedBox(height: 12),

          // ===================================
          _buildFabItem(
            icon: _isNovelMode ? Icons.auto_stories : Icons.menu_book,
            label: _isNovelMode ? "退出小说" : "小说模式",
            color: _isNovelMode ? Colors.purpleAccent : null,
            onTap: _toggleNovelMode,
          ),
          const SizedBox(height: 12),

          // 只有非小说模式才显示“只看楼主”和“纯净阅读”
          if (!_isNovelMode) ...[
            _buildFabItem(
              icon: _isOnlyLandlord ? Icons.people : Icons.person,
              label: _isOnlyLandlord ? "看全部" : "只看楼主",
              color: _isOnlyLandlord ? Colors.orange : null,
              onTap: _toggleOnlyLandlord,
            ),
            const SizedBox(height: 12),
            _buildFabItem(
              icon: _isReaderMode ? Icons.view_list : Icons.article,
              label: _isReaderMode ? "列表" : "纯净阅读",
              onTap: _toggleReaderMode,
            ),
            const SizedBox(height: 12),
          ],

          if (_isReaderMode) ...[
            _buildFabItem(
              icon: Icons.settings,
              label: "设置",
              onTap: _showDisplaySettings,
            ),
            const SizedBox(height: 12),
          ],
        ],
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

  Widget _buildNativeSliver() {
    if (_isLoading && _posts.isEmpty) {
      return const SliverFillRemaining(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    bool showPrevBtn = _targetPage > 1;

    List<Widget> children = [];

    if (showPrevBtn) {
      children.add(
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Center(
            child: _isLoadingPrev
                ? const CircularProgressIndicator()
                : TextButton.icon(
                    icon: const Icon(Icons.arrow_upward),
                    label: Text("加载上一页 (第 ${_targetPage - 1} 页)"),
                    onPressed: _loadPrev,
                  ),
          ),
        ),
      );
    }

    for (var post in _posts) {
      children.add(_buildPostCard(post));
      children.add(const SizedBox(height: 8));
    }

    children.add(_buildFooter());

    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 100),
      sliver: SliverList(delegate: SliverChildListDelegate(children)),
    );
  }

  Widget _buildFooter() {
    final bool hasNext = _targetPage < _totalPages;

    if (!hasNext) {
      return const Padding(
        padding: EdgeInsets.all(30),
        child: Center(
          child: Text("--- 全文完 ---", style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: _isLoadingMore
            ? const CircularProgressIndicator()
            : TextButton.icon(
                icon: const Icon(Icons.arrow_downward),
                label: Text("加载下一页 (第 ${_targetPage + 1} 页)"),
                onPressed: _loadNext,
              ),
      ),
    );
  }

  void _onReply(String? pid) {
    if (_fid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("正在加载板块信息，请稍候...")));
      return;
    }

    if (_formhash == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("缺少安全令牌(formhash)，请刷新页面重试")));
      return;
    }

    // 原生回复页面
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReplyNativePage(
          tid: widget.tid,
          fid: _fid!,
          pid: pid,
          formhash: _formhash!,
          posttime: _posttime,
          minChars: _postMinChars,
          maxChars: _postMaxChars,
          baseUrl: _baseUrl,
          userCookies: _userCookies,
        ),
      ),
    ).then((success) {
      if (success == true) {
        // 刷新页面
        // 如果回复成功，通常想看最新的回复，所以跳转到最后一页
        _loadPage(_totalPages > 0 ? _totalPages : _targetPage);
      }
    });
  }

  Widget _buildPostCard(PostItem post) {
    // 获取当前 post 的索引，用于 AutoScrollTag
    int index = _posts.indexOf(post);

    final GlobalKey anchorKey = _pidKeys.putIfAbsent(
      post.pid,
      () => GlobalKey(),
    );
    _floorKeys[post.floor] = anchorKey;
    final isLandlord = post.authorId == _landlordUid;

    // 使用 AutoScrollTag 包裹
    return RepaintBoundary(
      child: AutoScrollTag(
        key: ValueKey(index),
        controller: _scrollController,
        index: index,
        child: Container(
          key: anchorKey,
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
            elevation: 0,
            color: Theme.of(context).colorScheme.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
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
                      // 回复按钮
                      IconButton(
                        icon: const Icon(Icons.reply, size: 20),
                        onPressed: () => _onReply(post.pid),
                        color: Colors.grey,
                        tooltip: "回复此楼",
                      ),
                    ],
                  ),
                  // ... 在 _buildPostCard 方法里 ...
                  const SizedBox(height: 12),
                  SelectionArea(
                    child: HtmlWidget(
                      post.contentHtml,
                      textStyle: const TextStyle(fontSize: 16, height: 1.6),

                      // 【修复版】样式构建器
                      customStylesBuilder: (element) {
                        bool isDarkMode =
                            Theme.of(context).brightness == Brightness.dark;

                        // 1. 处理引用块 (Discuz 的回复框)
                        if (element.localName == 'blockquote' ||
                            element.classes.contains('quote')) {
                          if (isDarkMode) {
                            // 暗黑模式：深灰底 + 白字
                            return {
                              'background-color': '#303030',
                              'color': '#E0E0E0',
                              'border-left': '3px solid #777',
                              'padding': '10px',
                              'margin': '5px 0',
                              'display': 'block', // 强制块级显示
                            };
                          } else {
                            // 日间模式：浅灰底 + 黑字
                            return {
                              'background-color': '#F5F5F5',
                              'color': '#333333',
                              'border-left': '3px solid #DDD',
                              'padding': '10px',
                              'margin': '5px 0',
                              'display': 'block',
                            };
                          }
                        }

                        // 2. 【关键修复】处理暗黑模式下，作者写死的颜色看不见的问题
                        // 我们检查 style 属性字符串，而不是不存在的 .styles 对象
                        if (isDarkMode &&
                            element.attributes.containsKey('style')) {
                          String style = element.attributes['style']!;
                          // 如果包含了 color 设置（比如作者设了黑色），在暗黑模式下强制反转或者清除
                          if (style.contains('color:')) {
                            // 这里简单粗暴一点：如果是暗黑模式，且不是引用块，
                            // 我们可以强制清除背景色，并将字体设为浅色，防止黑底黑字
                            return {
                              'color': '#CCCCCC', // 强制浅灰色字
                              'background-color': 'transparent', // 清除背景
                            };
                          }
                        }

                        return null;
                      },

                      customWidgetBuilder: (element) {
                        if (element.localName == 'img') {
                          String src = element.attributes['src'] ?? '';
                          if (src.isNotEmpty) return _buildClickableImage(src);
                        }
                        return null;
                      },
                      onTapUrl: (url) async {
                        await _launchURL(url);
                        return true;
                      },
                    ),
                  ),
                  // ...
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReaderSliver() {
    if (_posts.isEmpty) {
      if (_isLoading) {
        return const SliverFillRemaining(child: Center(child: Text("加载中...")));
      } else {
        // 【新增】阅读模式下的空数据兜底
        return SliverFillRemaining(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: _readerTextColor.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 16),
                Text("未获取到内容", style: TextStyle(color: _readerTextColor)),
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                    });
                    _loadPage(_targetPage);
                  },
                  icon: Icon(Icons.refresh, color: _readerTextColor),
                  label: Text("重试", style: TextStyle(color: _readerTextColor)),
                ),
              ],
            ),
          ),
        );
      }
    }

    bool showPrevBtn = _targetPage > 1;

    List<Widget> children = [];

    if (showPrevBtn) {
      children.add(
        Center(
          child: TextButton(onPressed: _loadPrev, child: const Text("加载上一页")),
        ),
      );
    }

    for (int i = 0; i < _posts.length; i++) {
      final post = _posts[i];
      // 注册 Key，用于自动定位
      final GlobalKey anchorKey = _pidKeys.putIfAbsent(
        post.pid,
        () => GlobalKey(),
      );
      _floorKeys[post.floor] = anchorKey;

      children.add(
        AutoScrollTag(
          key: ValueKey(i),
          controller: _scrollController,
          index: i,
          child: Container(
            key: anchorKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (i > 0)
                  Divider(
                    height: 60,
                    color: _readerTextColor.withValues(alpha: 0.1),
                  ),

                // 极简信息栏
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      post.floor,
                      style: TextStyle(
                        color: _readerTextColor.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                    ),
                    if (_isNovelMode)
                      Text(
                        "第 $_targetPage 页", // 小说模式显示页码进度
                        style: TextStyle(
                          color: _readerTextColor.withValues(alpha: 0.4),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 20),

                HtmlWidget(
                  post.contentHtml,
                  textStyle: TextStyle(
                    fontSize: _fontSize,
                    height: 1.8,
                    color: _readerTextColor,
                    fontFamily: "Serif",
                  ),

                  // 【修复点】正确的样式清洗逻辑
                  customStylesBuilder: (element) {
                    // 仅在阅读模式下启用
                    if (_isReaderMode) {
                      // 1. 处理 <font color="..."> 这种老式标签
                      if (element.localName == 'font' ||
                          element.attributes.containsKey('style')) {
                        return {
                          'color': _readerTextColor.toCssColor(),
                          'background-color': 'transparent',
                        };
                      }

                      // 2. 处理 style="..." 属性 (element.attributes 是 Map)
                      if (element.attributes.containsKey('style')) {
                        String style = element.attributes['style']!;
                        // 如果 style 字符串里包含 color 或 background
                        if (style.contains('color') ||
                            style.contains('background')) {
                          return {
                            'color': _readerTextColor.toCssColor(),
                            'background-color': 'transparent',
                          };
                        }
                      }
                    }

                    // 2. 【核心修复】处理引用块
                    if (element.localName == 'blockquote' ||
                        element.classes.contains('quote')) {
                      // 阅读模式下，我们根据背景色深浅来决定引用块颜色
                      // 如果背景很暗（夜间模式），引用块就用深色
                      if (_readerBgColor.computeLuminance() < 0.5) {
                        return {
                          'background-color':
                              'rgba(255, 255, 255, 0.1)', // 半透明白
                          'color': '#E0E0E0',
                          'border-left': '3px solid #777',
                          'padding': '10px',
                        };
                      } else {
                        // 亮色背景（羊皮纸/白昼），引用块用浅色
                        return {
                          'background-color': 'rgba(0, 0, 0, 0.05)', // 半透明黑
                          'color': '#333333',
                          'border-left': '3px solid #999',
                          'padding': '10px',
                        };
                      }
                    }

                    return null;
                  },

                  customWidgetBuilder: (element) {
                    if (element.localName == 'img') {
                      String src = element.attributes['src'] ?? '';
                      if (src.isNotEmpty) return _buildClickableImage(src);
                    }
                    return null;
                  },

                  onTapUrl: (url) async {
                    await _launchURL(url);
                    return true;
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    bool hasNext = _targetPage < _totalPages;

    // 底部下一页
    if (hasNext) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(
            child: _isLoadingMore
                ? const CircularProgressIndicator()
                : TextButton.icon(
                    icon: Icon(Icons.arrow_downward, color: _readerTextColor),
                    label: Text(
                      "下一页",
                      style: TextStyle(color: _readerTextColor),
                    ),
                    onPressed: _loadNext,
                  ),
          ),
        ),
      );
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(
            child: Text(
              "--- 全文完 ---",
              style: TextStyle(color: _readerTextColor.withValues(alpha: 0.5)),
            ),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      sliver: SliverList(delegate: SliverChildListDelegate(children)),
    );
  }
}

extension ColorToCss on Color {
  String toCssColor() {
    return 'rgba(${(r * 255).round()}, ${(g * 255).round()}, ${(b * 255).round()}, $a)';
  }
}

// ==========================================
// 新增：独立的重试图片组件
// ==========================================
class RetryableImage extends StatefulWidget {
  final String imageUrl;
  final BaseCacheManager cacheManager;
  final Map<String, String> headers;
  final Function(String) onTap;

  const RetryableImage({
    super.key,
    required this.imageUrl,
    required this.cacheManager,
    required this.headers,
    required this.onTap,
  });

  @override
  State<RetryableImage> createState() => _RetryableImageState();
}

class _RetryableImageState extends State<RetryableImage> {
  int _retryCount = 0; // 重试计数器

  @override
  Widget build(BuildContext context) {
    // 技巧：每次重试，给 URL 加一个不同的参数，骗过缓存系统
    // 如果 URL 本身有 ? 就加 &t=，否则加 ?t=
    String finalUrl = widget.imageUrl;
    if (_retryCount > 0) {
      final separator = finalUrl.contains('?') ? '&' : '?';
      finalUrl = "$finalUrl${separator}retry=$_retryCount";
    }

    return GestureDetector(
      onTap: () => widget.onTap(widget.imageUrl), // 点击预览时传原图URL
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: CachedNetworkImage(
          // 关键：给 Key 加上计数器，强制组件重建
          key: ValueKey("${widget.imageUrl}_$_retryCount"),
          imageUrl: finalUrl,
          cacheManager: widget.cacheManager,
          httpHeaders: widget.headers,
          fit: BoxFit.contain,

          // 加载中
          placeholder: (context, url) => Container(
            height: 200,
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),

          // 加载失败
          errorWidget: (ctx, url, error) {
            return InkWell(
              onTap: () async {
                // 1. 清理旧缓存
                await widget.cacheManager.removeFile(widget.imageUrl);
                // 2. 增加计数器，触发重绘
                setState(() {
                  _retryCount++;
                });
                // 3. 提示
                if (mounted) {
                  // ignore: use_build_context_synchronously
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("正在尝试重新建立连接..."),
                      duration: Duration(milliseconds: 500),
                    ),
                  );
                }
              },
              child: Container(
                height: 120,
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.broken_image,
                      color: Colors.grey,
                      size: 30,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "图片加载失败",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      "点击此处强制刷新 (第$_retryCount次)",
                      style: const TextStyle(fontSize: 11, color: Colors.blue),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
