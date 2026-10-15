export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export function bytes(n) {
  n = Number(n) || 0;
  if (n >= 1e9) return (n / 1e9).toFixed(2).replace(/\.?0+$/, '') + ' GB';
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, '') + ' MB';
  if (n >= 1e3) return Math.round(n / 1e3) + ' KB';
  return n + ' B';
}
export const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
export const hours = (s) => (s / 3600).toFixed(1) + ' h';
export function day(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}

/** A pixel box with a title. */
export function box(title, body, { step, id } = {}) {
  const num = step ? `<span class="step">${step}</span>` : '';
  const head = title ? `<h2>${num}${esc(title)}</h2>` : '';
  return `<section class="box"${id ? ` id="${id}"` : ''}><div class="inner">${head}${body}</div></section>`;
}
/** A pixel button. `arg` rides along as data-arg. */
export function btn(label, act, { arg, primary, compact, disabled, danger, title } = {}) {
  const cls = ['btn', primary ? 'primary' : '', compact ? 'compact' : '', danger ? 'danger' : ''].join(' ').trim();
  return `<button class="${cls}" data-act="${act}"${arg !== undefined ? ` data-arg="${esc(arg)}"` : ''}${disabled ? ' disabled' : ''}${title ? ` title="${esc(title)}"` : ''}><span>${label}</span></button>`;
}
export const tag = (text, kind = '') => `<span class="tag ${kind}">${esc(text)}</span>`;
export const stat = (value, caption, kind = '') => `<div class="stat ${kind}"><div class="v">${esc(value)}</div><div class="c">${esc(caption)}</div></div>`;
const icons = { good: '✓', warn: '!', bad: '✕', info: 'i' };
export const notice = (kind, text) => `<div class="notice ${kind}"><span class="ic">${icons[kind] || 'i'}</span><div>${esc(text)}</div></div>`;
export function check(label, bind, on, extra = '') {
  return `<label class="check"><input type="checkbox" data-bind="${bind}"${on ? ' checked' : ''}${extra}><span>${label}</span></label>`;
}
export function progressBlocks(fraction) {
  const n = 20, on = Math.round((fraction ?? 0) * n);
  return `<span class="progress">${Array.from({ length: n }, (_, i) => `<i class="${i < on ? 'on' : ''}"></i>`).join('')}</span>`;
}
