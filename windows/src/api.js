// How the window talks to the engine. Inside the app that is Tauri (which runs
// `y1sync api`); in a browser during development it is a small local bridge.
const tauri = window.__TAURI__;

export const inApp = !!tauri;

/** Send one request. `onProgress({fraction, label})` is called while it runs. */
export async function call(request, onProgress) {
  if (tauri) {
    const off = await tauri.event.listen('y1-progress', (e) => onProgress && onProgress(e.payload));
    try {
      return await tauri.core.invoke('api_call', { request });
    } finally {
      off();
    }
  }
  const res = await fetch('/api', { method: 'POST', body: JSON.stringify(request) });
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '', last = null;
  for (;;) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
    let i;
    while ((i = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, i).trim();
      buffer = buffer.slice(i + 1);
      if (!line) continue;
      const obj = JSON.parse(line);
      if (obj.event === 'progress') onProgress && onProgress(obj);
      else last = obj;
    }
    if (done) break;
  }
  return last || { ok: false, error: 'The engine did not answer.' };
}

export async function stop() {
  if (tauri) return tauri.core.invoke('api_stop');
  return fetch('/api/stop', { method: 'POST' });
}

export async function pickFolder(title) {
  if (tauri) {
    const picked = await tauri.dialog.open({ directory: true, multiple: false, title });
    return picked || null;
  }
  return window.prompt(title + ' (full path)') || null;
}

export function openUrl(url) {
  if (tauri) return tauri.core.invoke('open_url', { url });
  window.open(url, '_blank');
}
