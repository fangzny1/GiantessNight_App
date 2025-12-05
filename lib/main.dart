import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'login_page.dart';
import 'forum_model.dart';
import 'thread_list_page.dart';
import 'search_page.dart';
import 'favorite_page.dart';
import 'bookmark_page.dart';

// 全局状态
final ValueNotifier<String> currentUser = ValueNotifier("未登录");
// 全局主题状态
final ValueNotifier<ThemeMode> currentTheme = ValueNotifier(ThemeMode.system);
final GlobalKey<_ForumHomePageState> forumKey = GlobalKey();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();

  currentUser.value = prefs.getString('username') ?? "未登录";

  String? themeStr = prefs.getString('theme_mode');
  if (themeStr == 'dark')
    currentTheme.value = ThemeMode.dark;
  else if (themeStr == 'light')
    currentTheme.value = ThemeMode.light;

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: currentTheme,
      builder: (context, mode, child) {
        return MaterialApp(
          title: 'GiantessNight',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6750A4),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6750A4),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: const MainScreen(),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  final List<Widget> _pages = [
    ForumHomePage(key: forumKey),
    const SearchPage(),
    const ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) =>
            setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '大厅',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

// ================== 首页 ==================

class ForumHomePage extends StatefulWidget {
  const ForumHomePage({super.key});
  @override
  State<ForumHomePage> createState() => _ForumHomePageState();
}

class _ForumHomePageState extends State<ForumHomePage> {
  List<Category> _categories = [];
  Map<String, Forum> _forumsMap = {};
  bool _isLoading = true;
  late final WebViewController _hiddenController;

  @override
  void initState() {
    super.initState();
    _initHiddenWebView();
  }

  // 【修复点】这就是之前报错缺失的方法，现在补上了
  void refreshData() {
    if (!mounted) return;
    print("🔄 收到外部刷新请求...");
    _fetchData();
  }

  void _initHiddenWebView() {
    _hiddenController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            if (url.contains("forumindex") || url.contains("forum.php")) {
              _parsePageContent();
            }
          },
        ),
      );
    _fetchData();
  }

  void _fetchData() {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });
    _hiddenController.loadRequest(
      Uri.parse(
        'https://www.giantessnight.com/gnforum2012/api/mobile/index.php?version=4&module=forumindex',
      ),
    );
  }

  Future<void> _parsePageContent() async {
    try {
      final String content =
          await _hiddenController.runJavaScriptReturningResult(
                "document.body.innerText",
              )
              as String;
      String jsonString = content;
      if (jsonString.startsWith('"') && jsonString.endsWith('"')) {
        jsonString = jsonString.substring(1, jsonString.length - 1);
        jsonString = jsonString.replaceAll('\\"', '"').replaceAll('\\\\', '\\');
      }

      var data = jsonDecode(jsonString);

      if (data['Variables'] == null) {
        if (currentUser.value != "未登录") {
          currentUser.value = "未登录";
          (await SharedPreferences.getInstance()).remove('username');
        }
        if (mounted)
          setState(() {
            _isLoading = false;
          });
        return;
      }

      var variables = data['Variables'];
      String newName = variables['member_username'].toString();
      if (newName.isNotEmpty && newName != currentUser.value) {
        currentUser.value = newName;
        (await SharedPreferences.getInstance()).setString('username', newName);
      }

      List<dynamic> catJsonList = variables['catlist'] ?? [];
      List<Category> tempCats = catJsonList
          .map((e) => Category.fromJson(e))
          .toList();
      List<dynamic> forumJsonList = variables['forumlist'] ?? [];
      Map<String, Forum> tempForumMap = {};
      for (var f in forumJsonList) {
        var forum = Forum.fromJson(f);
        tempForumMap[forum.fid] = forum;
      }

      if (mounted) {
        setState(() {
          _categories = tempCats;
          _forumsMap = tempForumMap;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            _fetchData();
            await Future.delayed(const Duration(seconds: 1));
          },
          child: CustomScrollView(
            slivers: [
              const SliverAppBar.large(title: Text("GiantessNight")),
              if (_isLoading)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (_categories.isEmpty && !_isLoading)
                SliverFillRemaining(
                  child: Center(
                    child: ElevatedButton(
                      onPressed: _fetchData,
                      child: const Text("刷新数据"),
                    ),
                  ),
                ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final category = _categories[index];
                  return _buildCategoryCard(category);
                }, childCount: _categories.length),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          ),
        ),
        SizedBox(
          height: 0,
          width: 0,
          child: WebViewWidget(controller: _hiddenController),
        ),
      ],
    );
  }

  Widget _buildCategoryCard(Category category) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 16, 8),
          child: Text(
            category.name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...category.forumIds.map((fid) {
          final forum = _forumsMap[fid];
          if (forum == null) return const SizedBox.shrink();
          return _buildForumTile(forum);
        }),
      ],
    );
  }

  Widget _buildForumTile(Forum forum) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                ThreadListPage(fid: forum.fid, forumName: forum.name),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      forum.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (int.tryParse(forum.todayposts) != null &&
                      int.parse(forum.todayposts) > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        "+${forum.todayposts}",
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              if (forum.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  forum.description,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.grey[600]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  void _toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (currentTheme.value == ThemeMode.light) {
      currentTheme.value = ThemeMode.dark;
      await prefs.setString('theme_mode', 'dark');
    } else {
      currentTheme.value = ThemeMode.light;
      await prefs.setString('theme_mode', 'light');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("个人中心"),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: currentTheme,
            builder: (context, mode, _) {
              bool isDark = mode == ThemeMode.dark;
              if (mode == ThemeMode.system)
                isDark =
                    MediaQuery.of(context).platformBrightness ==
                    Brightness.dark;
              return IconButton(
                icon: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
                onPressed: _toggleTheme,
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ValueListenableBuilder<String>(
        valueListenable: currentUser,
        builder: (context, username, child) {
          bool isLogin = username != "未登录";
          return ListView(
            children: [
              const SizedBox(height: 40),
              Center(
                child: CircleAvatar(
                  radius: 45,
                  child: Icon(Icons.person, size: 50),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  username,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (isLogin)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green),
                    ),
                    child: const Text(
                      "已登录",
                      style: TextStyle(color: Colors.green, fontSize: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 30),
              ListTile(
                leading: const Icon(
                  Icons.bookmark_border,
                  color: Colors.purple,
                ),
                title: const Text("阅读书签"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const BookmarkPage()),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.star_outline, color: Colors.orange),
                title: const Text("我的收藏"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const FavoritePage()),
                ),
              ),
              const Divider(),
              if (!isLogin)
                ListTile(
                  leading: const Icon(Icons.login),
                  title: const Text("登录账号"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final result = await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const LoginPage(),
                      ),
                    );
                    if (result == true) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text("登录成功！")));
                      forumKey.currentState?.refreshData();
                    }
                  },
                ),
              if (isLogin)
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.red),
                  title: const Text(
                    "退出登录",
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () async {
                    await WebViewCookieManager().clearCookies();
                    (await SharedPreferences.getInstance()).remove('username');
                    currentUser.value = "未登录";
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class PlaceholderPage extends StatelessWidget {
  final String title;
  const PlaceholderPage({super.key, required this.title});
  @override
  Widget build(BuildContext context) => Center(child: Text(title));
}
