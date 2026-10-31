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
  /// 检测脚本：两类页面命中后携带诊断数据上报 Dart——
  /// 1. 错误页（「手机连接已失效」）：handler zrStalePairing；
  /// 2. 登录视图（「登录后继续使用 Web 远程控制」）：handler
  ///    zrStalePairingLogin。jwt 过期时 bootstrap 直接路由到登录视图，
  ///    不经过错误页，两处都要观测才能算出真实 TTL。
  /// 诊断含 jwt 的 iat/exp（页面本地看到的）与页面存活秒数。
  static const String stalePairingDetectScript = '''
(function () {
  var firedError = false, firedLogin = false;
  var ERR = ['手机连接已失效', '当前页面的二维码参数无效'];
  var LOGIN = ['登录后继续使用 Web 远程控制'];
  function has(list) {
    var t = document.body ? document.body.innerText : '';
    if (!t) return false;
    for (var i = 0; i < list.length; i++) {
      if (t.indexOf(list[i]) !== -1) return true;
    }
    return false;
  }
  function diag(kind) {
    var d = { kind: kind, pageAgeSec: 0, iat: 0, exp: 0 };
    try {
      d.pageAgeSec = Math.round((Date.now() - performance.timeOrigin) / 1000);
    } catch (e) {}
    try {
      var p = (window.localStorage.getItem('zcodejwttoken') || '').split('.');
      if (p.length >= 2) {
        var o = JSON.parse(atob(p[1].replace(/-/g, '+').replace(/_/g, '/')));
        d.iat = o.iat || 0;
        d.exp = o.exp || 0;
      }
    } catch (e) {}
    return JSON.stringify(d);
  }
  function report(kind) {
    try {
      window.flutter_inappwebview.callHandler(
        kind === 'error' ? 'zrStalePairing' : 'zrStalePairingLogin',
        diag(kind)
      );
    } catch (e) {}
  }
  var mo = new MutationObserver(function () {
    if (!firedError && has(ERR)) { firedError = true; report('error'); return; }
    if (!firedLogin && !firedError && has(LOGIN)) { firedLogin = true; report('login'); }
  });
  function arm() {
    if (has(ERR)) { firedError = true; report('error'); return; }
    if (has(LOGIN)) { firedLogin = true; report('login'); return; }
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

  /// 自愈放弃后标记「需重新连接」的设备。
  ///
  /// relay 页面的登录态（jwt）按 origin（zcode.z.ai）全局只有一份：
  /// 若多台设备分属不同账号/平台，各设备页面会互相顶掉登录态。自愈
  /// 放弃后必须停止对该页面的一切自动整页重载（手动 ⟳ 不受限，属
  /// 用户显式操作），直到链接被更换/重新导入。
  static final Set<String> _relinkRequired = {};

  static bool isRelinkRequired(String deviceId) =>
      _relinkRequired.contains(deviceId);

  static void markRelinkRequired(String deviceId) {
    _relinkRequired.add(deviceId);
    debugPrint('[zr-webreset] relink required dev=$deviceId');
  }

  static void clearRelinkRequired(String deviceId) =>
      _relinkRequired.remove(deviceId);

  static Future<void> _guard(Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      debugPrint('[zr-webreset] step failed: $e');
    }
  }
}
