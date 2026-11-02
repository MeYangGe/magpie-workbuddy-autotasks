// 方案 A：把 magpie 的插件页导航到它自己的 service（magpie 反代到守护进程）。
// 本文件必须是外链 —— 页面 CSP 没有 unsafe-inline，内联脚本会被丢。
// 顺序很重要：先等 magpie.ready（握手完成，宿主不会把本页标成「已停止工作」），
// 拿到 magpie.service 后再自导航；桌面窗口下 service 为空，保持入口卡不动。
(async () => {
  const note = (m) => console.info("[workbuddy-tasks] embed:", m);
  try {
    if (!window.magpie || typeof magpie.ready?.then !== "function") {
      note("没有 bridge，保持入口卡（可能不在 magpie 窗口里）");
      return;
    }
    await magpie.ready;
    const svc = magpie.service;
    if (!svc) {
      note("service 为空（桌面窗口或未声明 page.service），保持入口卡");
      return;
    }
    note("跳转到 " + svc);
    location.replace(svc);
  } catch (e) {
    note("失败，退回入口卡：" + (e && e.message));
  }
})();
