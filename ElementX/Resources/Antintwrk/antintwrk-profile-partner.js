(() => {
  'use strict';
  if (location.protocol !== 'https:' || !['antimsg.com', 'antintwrk.com'].includes(location.hostname)) return;
  const id = 'antintwrk-app-profile-partner-style';
  const install = () => {
    if (!document.documentElement || document.getElementById(id)) return;
    const style = document.createElement('style');
    style.id = id;
    style.textContent = '[data-hero-profile] .ant-profile-ecosystem{display:none!important}';
    document.documentElement.appendChild(style);
  };
  install();
  new MutationObserver(install).observe(document, {childList: true, subtree: true});
})();
