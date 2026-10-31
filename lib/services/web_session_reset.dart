import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// relay 会话页的自愈与站点数据工具。
///
/// 「手机连接已失效」（relay 关闭原因 invalid-mobile-connection）与反复
/// 重新验证的根因都在 relay 页面自身：登录 jwt 短 TTL（实测 ~15 分钟量
/// 级）+ 页面存活时才静默续期 + 页面对暂时性失败会清除凭据/置位
/// jwt-invalid-restart 标记，把下次启动直接路由进登录视图，且恢复重连
/// 循环无法逃逸。恢复策略（见 session_view._onStalePairingDetected /
/// _onStalePairingLogin）：静默重载优先，凭据镜像回填次之，最后才是
/// 用户重新登录。此处提供注入脚本与工具方法。
abstract final class WebSessionReset {
  /// 认证镜像钩子脚本（每设备注入，deviceId 烘焙进脚本）。
  ///
  /// 在 document start 重写 Storage 的 setItem/removeItem/clear：6 个
  /// 认证键的每次写入都镜像到 `zr:<deviceId>:mirror:<key>`（removeItem
  /// 与 clear 不删镜像——页面清除凭据的过度反应要能被回填治愈）。同时
  /// 安装 `window.__zrRestoreAuth()`：把镜像值回填到标准键，返回回填数。
  static String authMirrorScript(String deviceId) {
    final safeId = deviceId.replaceAll("'", '');
    return '''
(function () {
  if (window.__zrAuthMirror) return;
  window.__zrAuthMirror = true;
  var NS = 'zr:$safeId:mirror:';
  var AUTH = [
    'zcodejwttoken',
    'oauth:zai:access_token',
    'oauth:bigmodel:access_token',
    'oauth:active_provider',
    'oauth:zai:user_info',
    'zcode:auth:jwt-invalid-restart'
  ];
  var ls = window.localStorage;
  var proto = Object.getPrototypeOf(ls) || Storage.prototype;
  var _g = proto.getItem, _s = proto.setItem, _r = proto.removeItem,
      _c = proto.clear;
  function isAuth(k) { return AUTH.indexOf(k) !== -1; }
  proto.setItem = function (k, v) {
    if (isAuth(k)) { try { _s.call(ls, NS + k, v == null ? '' : v); } catch (e) {} }
    return _s.call(this, k, v);
  };
  proto.removeItem = function (k) {
    // 认证键的删除不删镜像：页面清除凭据的过度反应要能被回填治愈
    return _r.call(this, k);
  };
  proto.clear = function () {
    // 保留镜像
    return _c.call(this);
  };
  window.__zrRestoreAuth = function () {
    var n = 0;
    try {
      for (var i = 0; i < AUTH.length; i++) {
        var v = _g.call(ls, NS + AUTH[i]);
        if (v != null && v !== '') { _s.call(ls, AUTH[i], v); n++; }
      }
    } catch (e) {}
    return n;
  };
})();
''';
  }

  /// 检测脚本：两类页面命中后携带诊断数据上报 Dart——
  /// 1. 错误页（「手机连接已失效」）：handler zrStalePairing；
  /// 2. 登录视图（「登录后继续使用 Web 远程控制」）：handler
  ///    zrStalePairingLogin。jwt 过期/缺失时 bootstrap 直接路由到登录
  ///    视图，不经过错误页，两处都要观测。
  /// 诊断含 jwt 的 iat/exp（页面本地看到的）与页面存活秒数。
  /// innerText 只取可见文本，避免 SPA 隐藏视图残留导致误判。
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
