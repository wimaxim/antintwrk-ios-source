// SPDX-License-Identifier: AGPL-3.0-only
// Keep HTML dialogs within the actual WebView viewport; never inspect form contents.
(() => {
  document.documentElement.classList.add('antintwrk-native-surface');
  if (window.antintwrkOverlays) { window.antintwrkOverlays.update(); return; }
  const style = document.createElement('style');
  style.textContent = `.antintwrk-native-surface .antintwrk-header,
    .antintwrk-native-surface .antintwrk-footer,
    .antintwrk-native-surface .hw-settings-sections-nav,
    .antintwrk-native-surface .hw-settings-heading [data-public-profile-link],
    .antintwrk-native-surface .ant-support-layout > aside { display:none!important; }
    .antintwrk-native-surface .ant-support-layout { grid-template-columns:minmax(0,1fr)!important; }
    html dialog[open] {
    position:fixed!important;
    inset-block-start:calc(var(--ant-native-dialog-top,0px) + 12px)!important;
    inset-block-end:auto!important;
    margin-block:0!important;
    max-block-size:calc(var(--ant-native-dialog-height,100dvh) - 24px)!important;
    max-inline-size:calc(100vw - 24px)!important;
    box-sizing:border-box!important;
    overflow:auto!important;
    overscroll-behavior:contain;
  }`;
  document.head.append(style);
  const update = () => {
    const viewport = window.visualViewport;
    const height = Math.max(48, viewport?.height || window.innerHeight);
    document.documentElement.style.setProperty('--ant-native-dialog-height', `${height}px`);
    document.documentElement.style.setProperty('--ant-native-dialog-top', `${viewport?.offsetTop || 0}px`);
  };
  window.antintwrkOverlays = {update};
  window.addEventListener('resize', update, {passive:true});
  window.visualViewport?.addEventListener('resize', update, {passive:true});
  window.visualViewport?.addEventListener('scroll', update, {passive:true});
  new MutationObserver(records => {
    if (records.some(record => record.target instanceof HTMLDialogElement)) update();
  }).observe(document.documentElement, {subtree:true,attributes:true,attributeFilter:['open']});
  update();
})();
