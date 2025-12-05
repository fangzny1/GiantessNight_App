import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'forum_model.dart';
import 'thread_detail_page.dart';

class BookmarkPage extends StatefulWidget {
  const BookmarkPage({super.key});

  @override
  State<BookmarkPage> createState() => _BookmarkPageState();
}

class _BookmarkPageState extends State<BookmarkPage> {
  List<BookmarkItem> _bookmarks = [];

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
  }

  Future<void> _loadBookmarks() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonStr = prefs.getString('local_bookmarks');
    if (jsonStr != null) {
      List<dynamic> list = jsonDecode(jsonStr);
      setState(() {
        _bookmarks = list.map((e) => BookmarkItem.fromJson(e)).toList();
      });
    }
  }

  Future<void> _deleteBookmark(int index) async {
    setState(() {
      _bookmarks.removeAt(index);
    });
    final prefs = await SharedPreferences.getInstance();
    String jsonStr = jsonEncode(_bookmarks.map((e) => e.toJson()).toList());
    await prefs.setString('local_bookmarks', jsonStr);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("阅读书签")),
      body: _bookmarks.isEmpty
          ? const Center(child: Text("暂无书签"))
          : ListView.builder(
              itemCount: _bookmarks.length,
              itemBuilder: (context, index) {
                final item = _bookmarks[index];
                return Dismissible(
                  key: Key(item.tid + item.savedTime),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  onDismissed: (direction) => _deleteBookmark(index),
                  child: ListTile(
                    leading: const Icon(Icons.bookmark, color: Colors.teal),
                    title: Text(
                      item.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      "看到第 ${item.page} 页 • ${item.author}\n保存于: ${item.savedTime}",
                      style: const TextStyle(fontSize: 12),
                    ),
                    isThreeLine: true,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          // 点击直接跳到保存的那一页
                          builder: (context) => ThreadDetailPage(
                            tid: item.tid,
                            subject: item.subject,
                            initialPage: item.page,
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
    );
  }
}
