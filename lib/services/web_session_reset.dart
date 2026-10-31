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

  /// 检测脚本：relay 设备会话被服务端重置（闲置回收 / 重启）后，后台
  /// 活着的页面用旧参数重连会被 relay 拒绝（ws 返回 WRONG_PARAM），页面
  /// 停在「手机连接已失效」错误页且自身重试无效。此处只负责识别该错误
  /// 页并上报 Dart（window.flutter_inappwebview.callHandler），由 Dart
  /// 端决定恢复动作：默认用新鲜参数静默重载（sid 未变时不重新登录、
  /// 不重新配对，站点存储原样保留），连续失败才升级为清站点数据。
  static const String stalePairingDetectScript = '''
(function () {
  var fired = false;
  var MARKERS = ['手机连接已失效', '当前页面的二维码参数无效'];
  function hit() {
    var text = document.body ? document.body.textContent : '';
    if (!text) return false;
    for (var i = 0; i < MARKERS.length; i++) {
      if (text.indexOf(MARKERS[i]) !== -1) return true;
    }
    return false;
  }
  var mo = new MutationObserver(function () {
    if (fired || !hit()) return;
    fired = true;
    try {
      window.flutter_inappwebview.callHandler('zrStalePairing');
    } catch (e) {}
  });
  function arm() {
    if (hit()) {
      fired = true;
      try {
        window.flutter_inappwebview.callHandler('zrStalePairing');
      } catch (e) {}
      return;
    }
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
