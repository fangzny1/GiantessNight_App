📱 GiantessNight 第三方客户端 (GN Forum App)

为了在被窝里看帖更爽，我手搓了一个 GN 论坛专属 APP！

这是一个基于 Flutter 开发的 GiantessNight 论坛第三方客户端。旨在解决 Discuz! 原生手机网页版体验不佳、翻页繁琐、图片加载失败等痛点，提供丝滑的原生阅读体验。

✨ 核心亮点
🎨 现代化 UI 设计

采用 Google Material Design 3 设计语言，界面干净清爽。

完美适配 深色模式 (Dark Mode)，夜间刷帖不刺眼。

📖 沉浸式阅读体验

无限瀑布流：告别繁琐的“下一页”，帖子列表和回复自动加载，一滑到底。

阅读模式：一键隐藏无关 UI，提供羊皮纸护眼背景，支持长按复制文本。

本地书签：自动记录阅读进度（精确到页码），随时继续阅读。

🖼️ 图片加载“黑科技”

智能解析：自动识别 Discuz 的动态图片链接、静态附件和手机端上传图片。

防盗链/WAF 绕过：通过注入 Cookie 和伪装 Header，完美解决 loading 占位图和权限拦截问题。

高清优先：自动提取 zoomfile 高清大图，而非模糊缩略图。

原生查看：点击图片可调用系统浏览器查看原图。

🛠️ 实用功能

只看楼主：一键过滤水贴，专注作者更新。

全站搜索：支持关键词搜索，搜索结果同样支持无限翻页。

个人中心：查看用户信息、发帖记录、收藏列表。

安全登录：基于 WebView 的 Cookie 同步登录，不收集任何账号密码信息。


📥 下载安装

前往 Releases 页面下载最新版本的 APK 安装包。

或者访问蓝奏云下载：

https://wwbnh.lanzout.com/iqnoG3cydk8b
密码:6e35

🛠️ 技术栈 (Tech Stack)

本项目使用 Flutter 构建，主要依赖以下开源库：

核心框架: flutter

网络请求: dio, cookie_jar, dio_cookie_manager

网页加载: webview_flutter (用于登录鉴权和部分数据抓取)

HTML 解析: html, flutter_widget_from_html (核心内容渲染)

图片加载: cached_network_image (即将加入), flutter_cache_manager

本地存储: shared_preferences

其他: url_launcher

🚀 本地构建 (Build)

如果你也是开发者，想自己编译或贡献代码：

克隆项目

code
Bash
download
content_copy
expand_less
git clone https://github.com/fangzny1/GiantessNight_App.git
cd GiantessNight_App

安装依赖

code
Bash
download
content_copy
expand_less
flutter pub get

运行

code
Bash
download
content_copy
expand_less
flutter run

打包 APK

code
Bash
download
content_copy
expand_less
flutter build apk --release
🔒 隐私与安全声明

本应用为非官方第三方客户端。

账号安全：登录操作直接在 GN 论坛原版网页 (WebView) 中进行，App 仅在本地获取登录成功后的 Cookie 用于请求数据。

隐私保护：App 不会将您的任何个人信息上传至除 GN 论坛以外的任何服务器。

无广告：本项目纯粹为爱发电，无任何商业行为。

🤝 贡献与反馈

欢迎提交 Issues 反馈 Bug 或建议功能。如果你有 iOS 开发环境 (Mac + Xcode)，欢迎帮忙编译 iOS 版本！

📄 开源协议

本项目遵循 MIT License 开源协议。

Created with ❤️ by fangzny
