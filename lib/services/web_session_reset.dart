import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// relay 页面的 WebView 站点数据清理。
///
/// relay 页面会把上一次配对的「手机连接记录」存进本地存储，并在打开
/// 链接时优先恢复旧记录；桌面端 V2 认证重新注册后 sid 会轮换，旧记录
/// 失效时页面报「手机连接已失效」，且不会回退到 URL 里的新 sid。因此
/// 凡是 sid 发生变化的导入（扫码 / 粘贴）与更换连接配置，都必须先清
/// 站点数据再加载新链接（等同于系统「清除应用数据」后的首次打开）。
abstract final class WebSessionReset {
  /// 清理 WebView 的站点存储（localStorage 等）、Cookie 与缓存。
  ///
  /// 应用内 WebView 只承载 relay 会话页，整体清理不影响其他功能；
  /// 代价是各会话页在下次重载时需在页面里重新登录一次。
  static Future<void> clearSiteData() async {
    if (Platform.isAndroid) {
      // Android 专有：清掉各 origin 的 localStorage / IndexedDB，
      // 是移除残留「手机连接记录」的关键一步。
      await _guard(() => WebStorageManager.instance().deleteAllData());
    }
    await _guard(() => CookieManager.instance().deleteAllCookies());
    await _guard(
      () => InAppWebViewController.clearAllCache(includeDiskFiles: true),
    );
    debugPrint('[zr-webreset] relay site data cleared');
  }

  static Future<void> _guard(Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      debugPrint('[zr-webreset] step failed: $e');
    }
  }
}
