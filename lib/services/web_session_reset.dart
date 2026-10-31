import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// relay 会话页的自愈、设备级账号隔离与站点数据工具。
///
/// 「手机连接已失效」（relay 关闭原因 invalid-mobile-connection）与反复
/// 重新验证的根因都在 relay 页面自身：登录 jwt 短 TTL + 页面存活时才
/// 静默续期 + 页面对暂时性失败会清除凭据/置位 jwt-invalid-restart 标记，
/// 把下次启动直接路由进登录视图，且恢复重连循环无法逃逸。
///
/// 设备级账号隔离：登录态按 origin 全局只有一份，多台设备分属不同
/// 账号时互相顶掉。`deviceAuthIsolationScript` 在 document start 把认证
/// 键的读写重定向到每设备私有命名空间（`zr:<deviceId>:auth:*`），使每
/// 台设备持有自己的登录态——多账号设备切换零登录，后台设备照常在线。
abstract final class WebSessionReset {
  /// 设备级账号隔离脚本（每设备注入，deviceId 烘焙进脚本）。
  ///
  /// 在 document start：
  /// 1. 迁移——首次运行把全局认证键**移动**（拷贝后清除）到设备私有槽
  ///    `zr:<deviceId>:auth:*` 并置初始化标记（老用户升级兼容；此后
  ///    全局键保持为空，各设备登录态完全独立）；
  /// 2. 重定向——重写 Storage 的 getItem/setItem/removeItem/clear，认证
  ///    键的读写全部路由到设备私有槽；
  /// 3. 撤销缓冲——removeItem/clear 前把认证值存入 `zr:<deviceId>:mirror:`
  ///    （页面清除凭据的过度反应可被 `__zrRestoreAuth()` 回填治愈），
  ///    并安装 `window.__zrRestoreAuth()`。
  ///
  /// 每个 WebView 页面是独立 JS 上下文，原型重定向互不影响；认证键以
  /// 外的读写原样透传。
  static String deviceAuthIsolationScript(String deviceId) {
    final safeId = deviceId.replaceAll("'", '');
    return '''
(function () {
  if (window.__zrAuthIso) return;
  window.__zrAuthIso = true;
  var NS = 'zr:$safeId:auth:';
  var MR = 'zr:$safeId:mirror:';
  var INIT = 'zr:$safeId:init';
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
  try {
    if (_g.call(ls, INIT) !== '1') {
      for (var i = 0; i < AUTH.length; i++) {
        var v0 = _g.call(ls, AUTH[i]);
        if (v0 != null) _s.call(ls, NS + AUTH[i], v0);
      }
      _s.call(ls, INIT, '1');
    }
  } catch (e) {}
  proto.getItem = function (k) {
    if (isAuth(k)) {
      var v = _g.call(ls, NS + k);
      if (v !== null) return v;
    }
    return _g.call(this, k);
  };
  proto.setItem = function (k, v) {
    if (isAuth(k)) {
      try { _s.call(ls, NS + k, v == null ? '' : v); } catch (e) {}
    }
    return _s.call(this, k, v);
  };
  proto.removeItem = function (k) {
    if (isAuth(k)) {
      try {
        var v = _g.call(ls, NS + k);
        if (v != null && v !== '') _s.call(ls, MR + k, v);
        _r.call(ls, NS + k);
      } catch (e) {}
    }
    return _r.call(this, k);
  };
  proto.clear = function () {
    try {
      for (var i = 0; i < AUTH.length; i++) {
        var v = _g.call(ls, NS + AUTH[i]);
        if (v != null && v !== '') _s.call(ls, MR + AUTH[i], v);
        _r.call(ls, NS + AUTH[i]);
      }
    } catch (e) {}
    return _c.call(this);
  };
  window.__zrRestoreAuth = function () {
    var n = 0;
    try {
      for (var i = 0; i < AUTH.length; i++) {
        var v = _g.call(ls, MR + AUTH[i]);
        if (v != null && v !== '') { _s.call(ls, NS + AUTH[i], v); n++; }
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
  /// 注意：须在 deviceAuthIsolationScript 之后注入，诊断才能读到设备
  /// 私有槽的认证键。
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

  /// 自动静默续期脚本：在登录视图上点击「连接 Z.ai（全球）」按钮，
  /// 触发页面自身的 OAuth 流程。chat.z.ai 的会话 Cookie 存活时，授权页
  /// 自动放行并带码回跳，换发新 jwt——全程零交互；Cookie 过期时用户
  /// 才会看到滑块/短信（z.ai 风控，不可避免）。返回是否找到并点击。
  static const String autoReloginScript = '''
(function () {
  var btns = document.querySelectorAll('button');
  for (var i = 0; i < btns.length; i++) {
    var t = btns[i].innerText || '';
    if (t.indexOf('Z.ai') !== -1 && t.indexOf('BigModel') === -1) {
      btns[i].click();
      return 1;
    }
  }
  return 0;
})();
''';

  /// 核弹级清理（当前无自动调用方）：清站点存储、Cookie 与缓存。
  ///
  /// 应用内 WebView 只承载 relay 会话页；代价是登录态（jwt 存于
  /// localStorage，隔离后在各设备私有槽）一并丢失，下次进入会话页需
  /// 完整重新登录。
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
  /// 设备级账号隔离下登录态已按设备分槽，但持续报错的设备（死 sid /
  /// 账号不匹配）仍不应被自动整页重载反复打扰（手动 ⟳ 不受限，属用户
  /// 显式操作），直到链接被更换/重新导入。
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
