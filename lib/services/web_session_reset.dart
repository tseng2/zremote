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

  /// 自愈脚本：relay 设备会话被重置（闲置回收 / 服务端重启）后，页面
  /// 本地残留的旧「手机连接记录」会让恢复失败，停在「手机连接已失效」
  /// 错误页；页面自身的「重新连接」只会带着同一份失效记录重复失败，
  /// 也不会回退到用 URL 里的有效 sid 重新配对。注入后检测到该错误页
  /// 即清空站点存储并带 zr_healed=1 重载一次：重载后走登录重新配对
  /// （zr_healed 标记防止错误持续时无限自愈循环）。
  static const String stalePairingHealScript = '''
(function () {
  if (/[?&]zr_healed=1/.test(location.search)) return;
  var MARKERS = ['手机连接已失效', '当前页面的二维码参数无效'];
  function hit() {
    var text = document.body ? document.body.textContent : '';
    if (!text) return false;
    for (var i = 0; i < MARKERS.length; i++) {
      if (text.indexOf(MARKERS[i]) !== -1) return true;
    }
    return false;
  }
  var healed = false;
  function heal() {
    if (healed) return;
    healed = true;
    try { window.localStorage.clear(); window.sessionStorage.clear(); } catch (e) {}
    try {
      var u = new URL(location.href);
      u.searchParams.set('zr_healed', '1');
      location.replace(u.toString());
    } catch (e) { location.reload(); }
  }
  var mo = new MutationObserver(function () { if (hit()) heal(); });
  function arm() {
    if (hit()) { heal(); return; }
    mo.observe(document.documentElement, { childList: true, subtree: true });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', arm);
  } else {
    arm();
  }
})();
''';
}
