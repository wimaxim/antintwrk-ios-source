// Copyright 2026 Maxim Novichkov
// SPDX-License-Identifier: AGPL-3.0-only
window.antintwrkImportNativeShare = async (payload) => {
  const finish = result => { window.antintwrkNativeShareStatus={id:payload.id,result}; return result; };
  try {
    if (window.top !== window || !document.body.classList.contains('antintwrk-app-view')) return finish('unavailable');
    const root = document.querySelector('[data-hero-composer]');
    const surface = root?.querySelector('[data-rich-surface]');
    if (!surface || typeof payload.text !== 'string') return finish('unavailable');
    if (root.dataset.nativeShareId === payload.id) return finish('ok');
    if (root.dataset.sessionBlocked === "1") return finish("unavailable");
    const hasDraft = () => {
    const selected = root.querySelector('[data-publication-type]:checked');
    if ((surface.textContent || '').trim() || (selected && selected.value !== 'post') ||
        Array.from(root.querySelectorAll('input[type=text],textarea')).some(field=>field.value.trim()) || Array.from(root.querySelectorAll('input[type=file]')).some(field=>field.files?.length)) return true;
    return false; };
    if (hasDraft()) return finish('draft');
    const photos = root.querySelector('[data-photo-input]');
    const video = root.querySelector('[data-publication-video-input]');
    const imported = await Promise.all(payload.files.map(async item => {
      if(typeof item.data !== 'string' || item.data.length > 27000000 || !/^(image|video)\//.test(item.mime)) throw Error('Unavailable');
      const bytes=Uint8Array.from(atob(item.data), value=>value.charCodeAt(0));
      return new File([bytes],item.name,{type:item.mime});
    }));
    const images = imported.filter(file=>file.type.startsWith('image/'));
    const videos = imported.filter(file=>file.type.startsWith('video/'));
    if ((images.length && (!photos || photos.disabled)) || (videos.length && (!video || video.disabled))) return finish('unavailable');
    // Recheck the live draft after asynchronous reads; no user edits can be overwritten.
    if (hasDraft() || root.dataset.sessionBlocked === '1') return finish('draft');
    root.dataset.nativeShareId = payload.id;
    if (payload.text) {
      const paragraphs = payload.text.split(/\r?\n/).map(line=>{const p=document.createElement('p');p.textContent=line || '\u00a0';return p;});
      surface.replaceChildren(...paragraphs);
      surface.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertFromPaste'}));
    }
    for (const [input,files] of [[photos,images],[video,videos]]) {
      if (!files.length) continue;
      const transfer = new DataTransfer(); files.forEach(file=>transfer.items.add(file)); input.files=transfer.files;
      input.dispatchEvent(new Event('change',{bubbles:true}));
    }
    surface.scrollIntoView({block:'center',behavior:'auto'});
    return finish('ok');
  } catch (_) { return finish('unavailable'); }
};
