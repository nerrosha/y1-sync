import { S, support } from './state.js';
import * as api from './api.js';
import { esc } from './util.js';
import { syncView, resultsView, deviceView, dupesView, topbar, statusbar, engineWarning, albumsModal } from './views.js';

const $ = (id) => document.getElementById(id);

// ───────────────────────────── Rendering ─────────────────────────────

function applyTheme() {
  const dark = S.theme === 'night' || (S.theme === 'auto' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'night' : 'day';
}

function render() {
  applyTheme();
  const view = S.tab === 'sync' ? syncView() : S.tab === 'results' ? resultsView() : S.tab === 'device' ? deviceView() : dupesView();
  const scroll = document.querySelector('.main');
  const top = scroll ? scroll.scrollTop : 0;
  $('app').innerHTML = `${topbar()}${engineWarning()}<main class="main">${view}</main>${statusbar()}`;
  const main = document.querySelector('.main');
  if (main) main.scrollTop = top;
  renderModal();
}

function renderModal() {
  const m = $('modal');
  if (S.confirm) {
    m.innerHTML = `<div class="dialog"><section class="box"><div class="inner"><h2>${esc(S.confirm.title)}</h2><div>${esc(S.confirm.message)}</div>
      <div class="row" style="justify-content:flex-end"><button class="btn" data-act="confirmNo"><span>Cancel</span></button>
      <button class="btn primary" data-act="confirmYes" autofocus><span>${esc(S.confirm.okLabel)}</span></button></div></div></section></div>`;
  } else if (S.albumModal) {
    m.innerHTML = albumsModal();
  } else {
    m.innerHTML = '';
  }
}

function renderStatus() {
  const el = document.querySelector('.statusbar');
  if (el) el.outerHTML = statusbar();
}

// ───────────────────────────── Running commands ─────────────────────────────

/** Run an engine command with a status line. Returns the data, or null after showing the error. */
async function run(cmd, args = {}, { label, stoppable = false, where = 'sync', quiet = false } = {}) {
  if (S.busy) return null;
  S.busy = { label: label || 'Working…', fraction: null, stoppable };
  S.notes[where] = null;
  render();
  try {
    const res = await api.call({ cmd, ...args }, (p) => {
      if (!S.busy) return;
      S.busy.label = p.label || S.busy.label;
      S.busy.fraction = p.fraction ?? null;
      renderStatus();
    });
    S.busy = null;
    if (!res.ok) {
      if (!quiet) S.notes[where] = { kind: 'bad', text: res.error || 'Something went wrong.' };
      render();
      return null;
    }
    return res.data;
  } catch (e) {
    S.busy = null;
    S.notes[where] = { kind: 'bad', text: 'The engine could not be started: ' + (e && e.message ? e.message : e) };
    render();
    return null;
  }
}

async function patchSettings(patch) {
  const res = await api.call({ cmd: 'settings.set', patch });
  if (res.ok) S.settings = res.data;
}

async function loadDevices(keepChoice = true) {
  const res = await api.call({ cmd: 'devices' });
  if (!res.ok) return;
  S.devices = res.data.devices;
  S.firmwares = res.data.firmwares;
  const have = S.devices.some((d) => d.path === S.settings.devicePath);
  if (!have && S.devices.length === 1) await patchSettings({ devicePath: S.devices[0].path });
  else if (!have && !keepChoice) await patchSettings({ devicePath: null });
}

async function scanDevice() {
  const data = await run('device.scan', {}, { label: 'Reading the player…', where: 'device' });
  if (data) {
    S.scan = data;
    S.settings = { ...S.settings, mergeRules: data.mergeRules, limits: data.limits };
    S.health = null;
    S.ui.freePick = new Set();
    S.ui.dupeSel = new Set();
    render();
    suggestRules();
  }
  return data;
}

async function suggestRules() {
  if (!S.settings.libraryFolder) return;
  const res = await api.call({ cmd: 'rules.suggest' });
  if (res.ok) { S.suggested = res.data.suggested; render(); }
}

/** After a change on the player: show the message, rescan quietly. */
async function afterDevice(data, where = 'device') {
  if (!data) return;
  S.notes[where] = { kind: data.failures || data.failed ? 'warn' : 'good', text: data.message };
  S.plan = null;
  const scan = await api.call({ cmd: 'device.scan' });
  if (scan.ok) S.scan = scan.data;
  render();
  suggestRules();
}

// ───────────────────────────── Actions ─────────────────────────────

const actions = {
  tab: ({ arg }) => { S.tab = arg; render(); },
  devTab: ({ arg }) => { S.devTab = arg; render(); },
  theme: () => {
    S.theme = S.theme === 'auto' ? 'night' : S.theme === 'night' ? 'day' : 'auto';
    localStorage.setItem('theme', S.theme);
    render();
  },
  support: () => api.openUrl(support.url),

  async refreshDevices() { await loadDevices(); render(); },
  async chooseFolder() {
    const f = await api.pickFolder('Choose your music folder');
    if (!f) return;
    await patchSettings({ libraryFolder: f });
    S.plan = null; S.suggested = [];
    render();
  },
  async pickPlayer() {
    const f = await api.pickFolder('Choose the player (its drive or folder)');
    if (!f) return;
    await patchSettings({ devicePath: f });
    await loadDevices();
    S.plan = null; S.scan = null;
    render();
  },
  async scanPlan() {
    const data = await run('plan', {}, { label: 'Reading tags…', where: 'sync' });
    if (data) { S.plan = data; render(); }
  },
  async sync() {
    const data = await run('sync', {}, { label: 'Copying…', stoppable: true, where: 'sync' });
    if (!data) return;
    S.sync = data;
    S.notes.sync = { kind: data.failed.length || data.cancelled ? 'warn' : 'good', text: data.summary + (data.copied ? ' Eject the player before unplugging.' : '') };
    S.plan = null;
    S.scan = null;
    const note = S.notes.sync;
    const plan = await run('plan', {}, { label: 'Comparing again…', where: 'sync' });
    if (plan) S.plan = plan;
    S.notes.sync = note;
    render();
  },
  async stop() { if (S.busy) { S.busy.label = 'Stopping…'; S.busy.stoppable = false; renderStatus(); await api.stop(); } },

  copyReport: () => { if (S.plan) navigator.clipboard && navigator.clipboard.writeText(S.plan.text); },

  // Albums picker
  openAlbums: () => { S.albumModal = { query: '', excluded: new Set(S.settings.excludedAlbums || []) }; render(); },
  albumToggle: ({ arg }) => { const e = S.albumModal.excluded; e.has(arg) ? e.delete(arg) : e.add(arg); refreshAlbums(); },
  albumArtist: ({ arg }) => {
    const a = S.plan.artists.find((x) => x.id === arg);
    const allOn = a.albums.every((al) => !S.albumModal.excluded.has(al.id));
    a.albums.forEach((al) => (allOn ? S.albumModal.excluded.add(al.id) : S.albumModal.excluded.delete(al.id)));
    refreshAlbums();
  },
  albumsAll: () => { S.albumModal.excluded.clear(); refreshAlbums(); },
  albumsNone: () => { S.plan.artists.forEach((a) => a.albums.forEach((al) => S.albumModal.excluded.add(al.id))); refreshAlbums(); },
  async albumsDone() {
    const excluded = [...S.albumModal.excluded];
    S.albumModal = null;
    await patchSettings({ excludedAlbums: excluded });
    render();
    await actions.scanPlan();
  },

  // Device
  scanDevice,
  tidy: () => ask('Tidy the player', 'Renames files into one Artist/Album/NN Title layout and clears junk. Music is only ever moved, never overwritten, and Undo puts everything back.', 'Tidy', async () => {
    afterDevice(await run('tidy.apply', { removeJunk: S.scan.tidy.removeJunk }, { label: 'Tidying…', where: 'device' }));
  }),
  async songlist() { afterDevice(await run('songlist.update', {}, { label: 'Updating the song list…', where: 'device' })); },
  pickName: ({ arg }) => {
    const [kind, gi, vi] = arg.split('|');
    const g = (kind === 'artist' ? S.scan.similarArtists : S.scan.similarAlbums)[Number(gi)];
    const v = g.variants[Number(vi)];
    (kind === 'artist' ? S.ui.chosenArtist : S.ui.chosenAlbum)[g.id] = kind === 'artist' ? v.name : v.title;
    render();
  },
  mergeAlbums: ({ arg }) => {
    const g = S.scan.similarAlbums.find((x) => x.id === arg);
    const into = S.ui.chosenAlbum[arg] || g.suggested;
    ask('Merge albums', `Sets the album name of ${g.trackCount} songs to “${into}”. Only the tag changes, the audio is untouched, and Undo puts every old name back.`, 'Merge', async () => {
      afterDevice(await run('merge.albums', { groupId: arg, into }, { label: 'Merging…', where: 'device' }));
    });
  },
  mergeArtists: ({ arg }) => {
    const g = S.scan.similarArtists.find((x) => x.id === arg);
    const into = S.ui.chosenArtist[arg] || g.suggested;
    ask('Merge artists', `Sets the artist of ${g.trackCount} songs to “${into}”. Only tags change, the audio is untouched, and Undo puts every old spelling back.`, 'Merge', async () => {
      afterDevice(await run('merge.artists', { groupId: arg, into }, { label: 'Merging…', where: 'device' }));
    });
  },
  async ruleAdd({ arg }) { await addRules([S.suggested[Number(arg)]]); },
  async ruleAddAll() { await addRules(S.suggested); },
  async ruleRemove({ arg }) {
    const res = await api.call({ cmd: 'rules.remove', id: arg });
    if (res.ok) { S.settings.mergeRules = res.data.mergeRules; if (S.scan) S.scan.mergeRules = res.data.mergeRules; S.plan = null; suggestRules(); render(); }
  },

  async healthCheck() {
    const data = await run('health.check', {}, { label: 'Checking files…', where: 'device' });
    if (data) { S.health = data.broken; render(); }
  },
  healthFix: () => ask('Replace broken files', 'Each broken file moves to the undo folder and the intact copy from your library is copied in its place. Files without a replacement stay as they are.', 'Replace', async () => {
    afterDevice(await run('health.fix', { removeUnrepairable: false }, { label: 'Repairing…', where: 'device' })); S.health = null;
  }),
  healthFixRemove: () => ask('Remove broken files', 'Replaces the broken files that have a copy and moves the ones without any copy to the undo folder. Undo brings them back.', 'Remove', async () => {
    afterDevice(await run('health.fix', { removeUnrepairable: true }, { label: 'Repairing…', where: 'device' })); S.health = null;
  }),

  async undo() { afterDevice(await run('undo', {}, { label: 'Undoing…', where: 'device' })); },
  async undoForget() { const res = await api.call({ cmd: 'undo.forget' }); if (res.ok) { S.scan.undo = null; render(); } },

  freePick: () => {
    const need = S.ui.freeGB * 1e9;
    let sum = 0;
    S.ui.freePick = new Set();
    for (const a of S.scan.listening.albums) { if (sum >= need) break; S.ui.freePick.add(a.id); sum += a.bytes; }
    render();
  },
  freeClear: () => { S.ui.freePick = new Set(); render(); },
  freeToggle: ({ arg }) => { const p = S.ui.freePick; p.has(arg) ? p.delete(arg) : p.add(arg); render(); },
  freeRemove: () => ask('Free up space', `Moves ${S.ui.freePick.size} albums into the hidden undo folder on the player and stops sync from copying them back. Your library is not touched, and Undo brings everything back until the next cleanup.`, 'Remove', async () => {
    afterDevice(await run('free.remove', { albumIds: [...S.ui.freePick] }, { label: 'Removing…', where: 'device' }));
  }),

  async enrich() {
    afterDevice(await run('enrich', { lyrics: S.ui.extraLyrics !== false, covers: S.ui.extraCovers !== false }, { label: 'Looking things up…', where: 'device' }));
  },
  async playlists() {
    afterDevice(await run('playlists', { moods: S.ui.plMood !== false, tempo: S.ui.plTempo !== false, genres: S.ui.plGenre !== false }, { label: 'Building playlists…', where: 'device' }));
  },

  // Dupes
  dupeToggle: ({ arg }) => { const s = S.ui.dupeSel; s.has(arg) ? s.delete(arg) : s.add(arg); render(); },
  dupesSafe: () => {
    const n = S.scan.duplicates.filter((g) => g.safe).length;
    ask('Clean up duplicates', `Keeps the best copy in each of ${n} groups. The others move to a hidden undo folder on the player; Undo is on the Device tab.`, 'Clean up', async () => {
      afterDevice(await run('dupes.clean', { safe: true }, { label: 'Removing extra copies…', where: 'dupes' }), 'dupes');
    });
  },
  dupesSelected: () => ask('Remove extra copies', `Keeps the copy marked keep in each of ${S.ui.dupeSel.size} groups. The others move to a hidden undo folder on the player.`, 'Remove', async () => {
    afterDevice(await run('dupes.clean', { ids: [...S.ui.dupeSel] }, { label: 'Removing extra copies…', where: 'dupes' }), 'dupes');
  }),

  confirmNo: () => { S.confirm = null; render(); },
  async confirmYes() { const c = S.confirm; S.confirm = null; render(); await c.run(); },
};

function ask(title, message, okLabel, run) { S.confirm = { title, message, okLabel, run }; render(); }

async function addRules(list) {
  const res = await api.call({ cmd: 'rules.add', rules: list });
  if (res.ok) { S.settings.mergeRules = res.data.mergeRules; if (S.scan) S.scan.mergeRules = res.data.mergeRules; S.plan = null; await suggestRules(); render(); }
}

function refreshAlbums() {
  // Re-render only the dialog so the search box keeps its focus.
  const box = $('modal');
  const focus = document.activeElement && document.activeElement.id === 'albumSearch';
  const pos = focus ? document.activeElement.selectionStart : 0;
  const scroll = document.getElementById('albumList');
  const top = scroll ? scroll.scrollTop : 0;
  box.innerHTML = albumsModal();
  const list = document.getElementById('albumList');
  if (list) list.scrollTop = top;
  if (focus) { const i = $('albumSearch'); i.focus(); i.setSelectionRange(pos, pos); }
}

// ───────────────────────────── Events ─────────────────────────────

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-act]');
  if (!el || el.disabled) return;
  if (el.tagName === 'INPUT' && el.type === 'checkbox') return; // handled on change
  const fn = actions[el.dataset.act];
  if (fn) fn({ arg: el.dataset.arg });
});

document.addEventListener('change', async (e) => {
  const el = e.target;
  if (el.dataset && el.dataset.act && el.type === 'checkbox') {
    const fn = actions[el.dataset.act];
    if (fn) fn({ arg: el.dataset.arg });
    return;
  }
  const bind = el.dataset && el.dataset.bind;
  if (!bind) return;
  const v = el.type === 'checkbox' ? el.checked : el.value;
  switch (bind) {
    case 'devicePath':
      await patchSettings({ devicePath: v || null });
      S.plan = null; S.scan = null; S.health = null;
      render();
      break;
    case 'firmware': {
      const res = await api.call({ cmd: 'firmware.set', name: el.dataset.name, firmware: v });
      if (res.ok) { S.devices = res.data.devices; S.plan = null; S.scan = null; render(); }
      break;
    }
    case 'resizeArtwork': case 'fetchLyrics': case 'fetchCovers':
      await patchSettings({ [bind]: v }); S.plan = null; render(); break;
    case 'removeJunk': await patchSettings({ removeJunk: v }); if (S.scan) S.scan.tidy.removeJunk = v; break;
    case 'maxSampleRate': case 'maxBitDepth': {
      const limits = { ...(S.settings.limits || {}), [bind]: Number(v) || null };
      await patchSettings({ limits });
      S.plan = null; await scanDevice(); break;
    }
    case 'allowALAC': {
      await patchSettings({ limits: { ...(S.settings.limits || {}), allowALAC: v } });
      S.plan = null; await scanDevice(); break;
    }
    case 'freeGB': S.ui.freeGB = Number(v); break;
    case 'extraLyrics': S.ui.extraLyrics = v; break;
    case 'extraCovers': S.ui.extraCovers = v; break;
    case 'plMood': S.ui.plMood = v; break;
    case 'plTempo': S.ui.plTempo = v; break;
    case 'plGenre': S.ui.plGenre = v; break;
  }
});

document.addEventListener('input', (e) => {
  const el = e.target;
  if (el.dataset.bind === 'playlistName') {
    S.settings.playlistName = el.value;
    clearTimeout(window.__plTimer);
    window.__plTimer = setTimeout(() => patchSettings({ playlistName: el.value }), 400);
  } else if (el.dataset.bind === 'albumQuery') {
    S.albumModal.query = el.value;
    refreshAlbums();
  }
});

// Remember which collapsible sections the person opened.
document.addEventListener('toggle', (e) => {
  const k = e.target.dataset && e.target.dataset.keep;
  if (k) S.ui[k] = e.target.open;
}, true);

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (S.confirm) actions.confirmNo();
    else if (S.albumModal) { S.albumModal = null; render(); }
  }
});

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (S.theme === 'auto') render(); });

// ───────────────────────────── Start ─────────────────────────────

(async function init() {
  render();
  const ping = await api.call({ cmd: 'ping' }).catch(() => null);
  S.engine = { ok: !!(ping && ping.ok && ping.data.ffmpeg) };
  const settings = await api.call({ cmd: 'settings.get' }).catch(() => null);
  if (settings && settings.ok) S.settings = settings.data;
  await loadDevices();
  render();
})();
