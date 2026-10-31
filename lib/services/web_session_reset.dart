import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// relay 会话页的自愈与站点数据工具。
///
/// 「手机连接已失效」（relay 关闭原因 invalid-mobile-connection）有两类
/// 成因：sid 已被桌面端轮换（加载了死链接），或页面里的登录 jwt 过期
/// （ws 握手 WRONG_PARAM）。恢复阶梯见 session_view._onStalePairingDetected：
/// 先用新鲜参数静默重载（sid 未变时无感恢复），持续失败才移除页面认证
/// 凭据走重新登录。此处提供两者所需的脚本与工具方法。
abstract final class WebSessionReset {
  /// 检测脚本：页面停在「手机连接已失效」错误页时（页面自身的重试只会
  /// 带着同样参数重复失败），上报 Dart（window.flutter_inappwebview
  /// .callHandler），由 Dart 端决定恢复动作。
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

  /// 自愈阶梯的末级：relay 页面的登录态（jwt，localStorage 键
  /// zcodejwttoken）过期后，静默重载无法恢复，此时只移除页面自身的
  /// 认证凭据并重载——页面因无 jwt 进入登录视图，用户重新登录一次即
  /// 恢复。绝不清空整个站点存储或 Cookie：主题、tab 状态、
  /// oauth:active_provider 等全部保留，避免更重的全量重新初始化。
  static const String authResetScript = '''
(function () {
  var KEYS = [
    'zcodejwttoken',
    'oauth:zai:access_token',
    'oauth:bigmodel:access_token',
    'zcode:auth:jwt-invalid-restart'
  ];
  try {
    for (var i = 0; i < KEYS.length; i++) {
      window.localStorage.removeItem(KEYS[i]);
    }
  } catch (e) {}
})();
''';

  /// 核弹级清理（当前无自动调用方）：清站点存储、Cookie 与缓存。
  ///
  /// 应用内 WebView 只承载 relay 会话页；代价是登录态（jwt 存于
  /// localStorage）一并丢失，下次进入会话页需完整重新登录。
  static Future<void> clearSiteData() async {
    if (Platform.isAndroid) {
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
