// SPDX-License-Identifier: AGPL-3.0-only
// App-local viewport correction. No input values, selection mutations or network requests.
(() => {
  if (window.antintwrkIme) return;
  let visible = false, frame = 0;
  const field = () => {
    const active = document.activeElement;
    if (!active || active.disabled || active.readOnly) return null;
    if (active.isContentEditable) return active.closest('[contenteditable="true"]') || active;
    return active.matches('textarea,input:not([type=checkbox]):not([type=radio]):not([type=button]):not([type=submit]):not([type=file]):not([type=hidden]):not([type=range]):not([type=color])') ? active : null;
  };
  const reveal = () => {
    frame = 0;
    if (!visible || document.visibilityState === 'hidden') return;
    const active = field();
    if (!active) return;
    const viewport = window.visualViewport;
    const top = (viewport?.offsetTop || 0) + 12;
    const bottom = (viewport?.offsetTop || 0) + (viewport?.height || window.innerHeight) - 16;
    if (bottom <= top) return;
    const editor = active.closest('[data-rich-editor],.hw-rich-editor') || active;
    const rect = editor.getBoundingClientRect();
    if (rect.height <= bottom - top) {
      // Reveal toolbar + editor when they fit, matching the compact composer layout.
      if (rect.bottom > bottom || rect.top < top) editor.scrollIntoView({block:'center',inline:'nearest',behavior:'instant'});
      return;
    }
    // A long contenteditable must follow the caret, not keep jumping to the editor's start.
    const selection = window.getSelection();
    if (active.isContentEditable && selection?.rangeCount && active.contains(selection.focusNode)) {
      const range = selection.getRangeAt(0).cloneRange();
      range.setStart(selection.focusNode, selection.focusOffset);
      range.collapse(true);
      let caret = range.getBoundingClientRect();
      if (!caret.height) caret = range.startContainer.parentElement?.getBoundingClientRect() || caret;
      if (caret.height) {
        const delta = caret.bottom > bottom ? caret.bottom - bottom : caret.top < top ? caret.top - top : 0;
        if (delta) {
          // Scroll only the necessary nested containers, then the document.
          let remaining = delta;
          for (let node = active; node && node !== document.scrollingElement; node = node.parentElement) {
            if (/auto|scroll/.test(getComputedStyle(node).overflowY) && node.scrollHeight > node.clientHeight) {
              const previous = node.scrollTop;
              node.scrollTop += remaining;
              remaining -= node.scrollTop - previous;
            }
          }
          if (Math.abs(remaining) > 1) window.scrollBy({top:remaining,behavior:'instant'});
        }
        return;
      }
    }
    // Textareas manage their internal caret scrolling; keep their visible top in the viewport.
    if (rect.top < top || rect.top >= bottom) active.scrollIntoView({block:'start',inline:'nearest',behavior:'instant'});
  };
  const schedule = () => {
    if (!visible) return;
    cancelAnimationFrame(frame);
    // Run after native IME padding and the WebView/visual viewport have settled for this frame.
    frame = requestAnimationFrame(() => { frame = requestAnimationFrame(reveal); });
  };
  window.antintwrkIme = {update(value) { visible = value === true; if (!visible) cancelAnimationFrame(frame); else schedule(); }};
  window.addEventListener('resize', schedule, {passive:true});
  window.visualViewport?.addEventListener('resize', schedule, {passive:true});
  document.addEventListener('focusin', schedule);
  document.addEventListener('input', schedule);
  // A boolean only: protect edited forms even after the keyboard closes. Never expose their contents.
  const markDraft = event => {
    const target = event.target;
    if (!event.isTrusted || !(target instanceof Element) ||
        !target.matches('input,textarea,select,[contenteditable]') || target.matches('[type=search],[type=hidden]')) return;
    window.antintwrkNative?.postMessage(JSON.stringify({type:'draft'}));
  };
  document.addEventListener('input', markDraft);
  document.addEventListener('change', markDraft);
  document.addEventListener('selectionchange', schedule);
})();
