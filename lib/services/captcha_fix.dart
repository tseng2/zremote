/// 滑块验证码拼图错位修复。
///
/// Z.ai 登录页的滑块拼图验证码（Aliyun Captcha）在移动端 WebView 里，背景图
/// (#aliyunCaptcha-img) 与拼图块 (#aliyunCaptcha-puzzle) 的挑战位图分辨率可能
/// 不一致（按设备 DPR 出图），而 SDK 的 CSS 把两者渲染高度写死为同一像素值，
/// 两者按不同比例压缩后缺口与拼图块严重竖向错位。
///
/// 注入脚本：验证码出现/刷新挑战时，按背景图的实际渲染比例重设拼图块的
/// 渲染宽高，使两者位图缩放一致、横竖双向严格对齐；两者本就一致时脚本
/// 不产生可见变化。
abstract final class CaptchaFix {
  static const _flag = '__zrCaptchaScaleFix';

  static const String script = '''
(function(){
  if (window.$_flag) return; window.$_flag = true;
  var timer = null;
  function fix() {
    timer = null;
    try {
      var bg = document.getElementById('aliyunCaptcha-img');
      var pc = document.getElementById('aliyunCaptcha-puzzle');
      if (!bg || !pc) return;
      if (!bg.naturalWidth || !bg.naturalHeight || !pc.naturalWidth || !pc.naturalHeight) return;
      var br = bg.getBoundingClientRect();
      if (br.width < 10 || br.height < 10) return;
      var sx = br.width / bg.naturalWidth;
      var sy = br.height / bg.naturalHeight;
      var w = (pc.naturalWidth * sx).toFixed(2) + 'px';
      var h = (pc.naturalHeight * sy).toFixed(2) + 'px';
      if (pc.style.width === w && pc.style.height === h) return;
      pc.style.width = w;
      pc.style.height = h;
    } catch (e) {}
  }
  function schedule() { if (!timer) timer = setTimeout(fix, 60); }
  function start() {
    if (!document.body) { setTimeout(start, 200); return; }
    try {
      new MutationObserver(schedule).observe(document.body, {
        childList: true, subtree: true,
        attributes: true, attributeFilter: ['src', 'style', 'class']
      });
    } catch (e) {}
    schedule();
  }
  start();
})()''';
}
