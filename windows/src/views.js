import { S } from './state.js';
import { esc, bytes, plural, hours, day, box, btn, tag, stat, notice, check, progressBlocks } from './util.js';

const busy = () => !!S.busy;
const noteHtml = (where) => (S.notes[where] ? notice(S.notes[where].kind, S.notes[where].text) : '');
const player = () => S.devices.find((d) => d.path === S.settings.devicePath);

// ───────────────────────────── Sync ─────────────────────────────

export function syncView() {
  return `<div class="cols">
    <div class="stack">${playerBox()}${musicBox()}</div>
    ${copyBox()}
  </div>`;
}

function playerBox() {
  const d = player();
  let body;
  if (!S.devices.length) {
    body = notice('warn', 'No player found. Turn on USB storage on the player itself; it does not appear until you do.');
  } else {
    const opts = S.devices.map((x) => `<option value="${esc(x.path)}"${x.path === S.settings.devicePath ? ' selected' : ''}>${esc(x.name)} (${esc(x.path)}) · ${bytes(x.freeBytes)} free</option>`).join('');
    body = `<select data-bind="devicePath" ${busy() ? 'disabled' : ''}>${S.settings.devicePath ? '' : '<option value="">Choose a player</option>'}${opts}</select>`;
    if (d) {
      const fw = S.firmwares.map((f) => `<option value="${f.id}"${f.id === d.firmware ? ' selected' : ''}>${esc(f.title)}</option>`).join('');
      body += `<div class="row tight"><span class="small soft">Firmware</span>
        <select data-bind="firmware" data-name="${esc(d.name)}" title="${esc((S.firmwares.find((f) => f.id === d.firmware) || {}).summary || '')}">${fw}</select>
        ${d.firmwareChosen ? tag('chosen') : tag('detected')}</div>`;
    }
  }
  body += `<div class="row">${btn('Refresh', 'refreshDevices', { compact: true, disabled: busy() })}${btn('Pick a folder…', 'pickPlayer', { compact: true, disabled: busy(), title: 'Use a drive or folder the list does not show' })}</div>`;
  return box('Player', body, { step: 1 });
}

function musicBox() {
  const f = S.settings.libraryFolder;
  const body = `<div class="notice info" style="min-height:70px"><span class="ic">♪</span>
      <div><b>${f ? esc(f.split(/[\\/]/).filter(Boolean).pop() || f) : 'No music folder yet'}</b>
      ${f ? `<div class="small soft ellipsis" style="max-width:240px" title="${esc(f)}">${esc(f)}</div>` : '<div class="small soft">Choose the folder your library lives in.</div>'}</div></div>
    <div class="row">${btn('Choose…', 'chooseFolder', { disabled: busy() })}
      ${S.plan ? btn('Rescan', 'scanPlan', { disabled: busy() || !f || !S.settings.devicePath }) : ''}</div>`;
  return box('Music', body, { step: 2 });
}

function copyBox() {
  const p = S.plan;
  const body = `${p ? planSummary(p) : idle()}<div class="sep"></div>${options()}${action()}`;
  return box('Copy', body, { step: 3 });
}

function idle() {
  const row = (done, text) => `<div class="row tight"><b style="font-size:17px;color:${done ? 'var(--good)' : 'var(--soft)'}">${done ? '☑' : '☐'}</b><span style="font-size:15px;font-weight:${done ? 400 : 700}">${esc(text)}</span></div>`;
  return `<div class="stack" style="gap:10px">
    ${row(!!player(), player() ? 'Player connected' : 'Connect the player')}
    ${row(!!S.settings.libraryFolder, S.settings.libraryFolder ? 'Music folder chosen' : 'Choose a music folder')}
    ${row(false, 'Scan to see what will be copied')}
    <div class="soft small" style="margin-top:4px">Nothing is written until you press Sync.</div>
    ${noteHtml('sync')}
  </div>`;
}

function planSummary(p) {
  const st = p.stats;
  const newAlbums = p.artists.flatMap((a) => a.albums).filter((a) => a.pending > 0).length;
  const sel = st.selectedAlbums === st.albums ? `Syncing all ${st.albums} albums` : `Syncing ${st.selectedAlbums} of ${st.albums} albums`;
  let h = `<div class="stats">
      ${stat(st.toCopy, 'to copy')}${stat(st.selectedAlbums === st.albums ? st.albums : `${st.selectedAlbums}/${st.albums}`, 'albums')}
      ${stat(bytes(st.bytesToCopy), `of ${bytes(st.freeBytes)} free`, p.notEnoughSpace ? 'bad' : '')}
      ${stat(st.alreadyThere, 'already there')}
      ${st.broken ? stat(st.broken, 'broken', 'bad') : ''}
    </div>
    <div class="row"><b>${esc(sel)}</b>${newAlbums ? tag(`${newAlbums} new`, 'good') : ''}<span class="grow"></span>
      ${btn('Choose albums…', 'openAlbums', { compact: true, disabled: busy() })}</div>`;
  if (p.notEnoughSpace) h += notice('bad', 'Not enough free space on the player.');
  if (p.collisions.length) h += notice('warn', `${plural(p.collisions.length, 'name collision')}: only the first file of each is copied. Fix the tags to keep both.`);
  if (st.renamedByMerges) h += notice('info', `${plural(st.renamedByMerges, 'track')} will get the spelling from your remembered merges as they are copied. Your library files are not changed.`);

  if (p.broken.length) {
    h += `<details><summary>${notice('bad', `${plural(p.broken.length, 'file')} won't play — skipped`)}</summary>
      <div class="listbox small">${p.broken.map((b) => `<div><b>${esc(b.name)}</b> <span class="soft">${esc(b.reasons.join('; '))}</span></div>`).join('')}</div></details>`;
  }
  if (p.warnings.length || p.albumIssues.length) {
    h += `<details><summary>${notice('warn', 'Worth fixing')}</summary><div class="listbox small">
      ${p.albumIssues.map((r) => `<div><b>${esc(r.artist)} — ${esc(r.album)}</b> <span class="soft">${esc(r.notes.join('; '))}</span></div>`).join('')}
      ${p.warnings.map((w) => `<div><b>${esc(w.name)}</b> <span class="soft">${esc(w.notes.join('; '))}</span></div>`).join('')}</div></details>`;
  }

  if (p.stats.toCopy > 0) {
    h += `<b>Will add ${plural(st.added, 'track')}${st.replaced ? `, replace ${st.replaced}` : ''} (${bytes(st.bytesToCopy)}). ${st.alreadyThere} already there stay as they are. Nothing on the player is deleted.</b>`;
    h += `<details ${S.ui.showAlbums ? 'open' : ''} data-keep="showAlbums"><summary>By album (${p.report.length})</summary><div class="list" style="margin-top:6px">
      ${p.report.map((a) => `<div class="item"><span class="grow ellipsis">${esc(a.artist)} — ${esc(a.album)}</span>
        ${a.added ? tag(`+${a.added}`, 'good') : ''}${a.replaced ? tag(`replace ${a.replaced}`, 'warn') : ''}<span class="small soft" style="width:72px;text-align:right">${bytes(a.bytes)}</span></div>`).join('')}
      <div style="margin-top:6px">${btn('Copy report', 'copyReport', { compact: true })}</div></div></details>`;
    h += `<details ${S.ui.showFiles ? 'open' : ''} data-keep="showFiles"><summary>Files to copy (${p.actionsTotal})</summary>
      <div class="listbox mono" style="margin-top:6px">${p.actions.map((a) => `<div>${a.kind === 'replace' ? '<b style="color:var(--warn)">↻</b>' : '+'} ${esc(a.devicePath)}${a.why ? ` <span style="color:var(--warn)">${esc(a.why)}</span>` : ''}</div>`).join('')}
      ${p.actionsTotal > p.actions.length ? `<div class="soft">… and ${p.actionsTotal - p.actions.length} more</div>` : ''}</div></details>`;
  } else {
    h += notice('good', 'Everything selected is already on the player.');
  }
  return h + noteHtml('sync');
}

function options() {
  const s = S.settings;
  const art = s.maxArtDimension || (player() && player().firmware === 'launcher' ? 1000 : 500);
  return `<div class="row">
    <input type="text" data-bind="playlistName" placeholder="Playlist name (optional)" value="${esc(s.playlistName || '')}" style="width:210px">
    ${check(`Art ≤ ${art}px`, 'resizeArtwork', s.resizeArtwork !== false)}
    ${check('Lyrics', 'fetchLyrics', !!s.fetchLyrics)}
    ${check('Find art', 'fetchCovers', !!s.fetchCovers)}
  </div>`;
}

function action() {
  const p = S.plan;
  let primary, hint;
  if (!p) {
    primary = btn('Scan and compare', 'scanPlan', { primary: true, disabled: busy() || !player() || !S.settings.libraryFolder });
    hint = !player() ? 'Connect the player first' : !S.settings.libraryFolder ? 'Choose a music folder' : 'Press “Scan and compare”';
  } else {
    const n = p.stats.toCopy;
    primary = btn(`Sync ${n} ${n === 1 ? 'track' : 'tracks'}`, 'sync', { primary: true, disabled: busy() || (n === 0 && !S.settings.playlistName) || p.notEnoughSpace });
    hint = p.notEnoughSpace ? 'Not enough free space on the player' : n === 0 ? 'Everything is already on the player' : 'Copies only what’s missing. Nothing on the player is deleted.';
  }
  return `<div class="stack" style="gap:8px">${primary}<div class="soft small">${esc(hint)}</div></div>`;
}

export function albumsModal() {
  const m = S.albumModal;
  const q = m.query.trim().toLowerCase();
  const all = S.plan.artists;
  const rows = all.map((a) => {
    const albums = a.albums.filter((al) => !q || (a.name + ' ' + al.title).toLowerCase().includes(q));
    if (!albums.length) return '';
    const on = albums.filter((al) => !m.excluded.has(al.id)).length;
    return `<div style="margin-top:8px"><label class="check"><input type="checkbox" data-act="albumArtist" data-arg="${esc(a.id)}"${on === albums.length ? ' checked' : ''}><b>${esc(a.name)}</b></label>
      ${albums.map((al) => `<div class="item" style="padding-left:26px"><label class="check"><input type="checkbox" data-act="albumToggle" data-arg="${esc(al.id)}"${m.excluded.has(al.id) ? '' : ' checked'}>
        <span>${esc(al.title)}</span></label>${al.pending ? tag(`${al.pending} new`, 'good') : ''}<span class="small soft" style="margin-left:auto">${plural(al.trackCount, 'song')} · ${bytes(al.bytes)}</span></div>`).join('')}</div>`;
  }).join('');
  const total = all.flatMap((a) => a.albums).length;
  const on = total - m.excluded.size;
  return `<div class="dialog">${box('Choose albums', `
    <div class="row"><input type="text" data-bind="albumQuery" placeholder="Search" value="${esc(m.query)}" class="grow" style="flex:1" id="albumSearch">
      ${btn('Select all', 'albumsAll', { compact: true })}${btn('None', 'albumsNone', { compact: true })}</div>
    <div class="small soft">${on} of ${total} albums selected. Albums you switch off are only skipped; nothing is removed from the player.</div>
    <div class="scroll" id="albumList">${rows || '<div class="soft">No match.</div>'}</div>
    <div class="row">${btn('Done', 'albumsDone', { primary: true })}</div>`)}</div>`;
}

// ───────────────────────────── Results ─────────────────────────────

export function resultsView() {
  const r = S.sync;
  if (!r || !r.changes || !r.changes.length) {
    return `<div class="empty"><h2>Nothing synced yet</h2><div class="soft">Run a sync and every copied file shows up here, with what was fixed on the way.</div></div>`;
  }
  const skipped = (S.plan && S.plan.broken) || [];
  return `<div class="header"><h1>Results</h1>${tag(plural(r.changes.length, 'file'))}</div>
    ${notice(r.failed.length ? 'warn' : 'good', r.summary)}
    <div class="stack" style="margin-top:16px">
    ${box('Copied', `<div class="list">${r.changes.map((c) => `<div class="item" style="align-items:flex-start">
        <span class="grow"><b>${esc(c.title)}</b> <span class="soft">${esc(c.artist)} — ${esc(c.album)}</span>
        <div class="small soft">${esc(c.notes.concat(c.lyrics ? ['lyrics added'] : [], c.cover ? ['cover added'] : []).join(' · '))}</div></span>
        ${c.replaced ? tag('replaced', 'warn') : ''}</div>`).join('')}</div>`)}
    ${r.failed.length ? box('Failed', `<div class="list">${r.failed.map((f) => `<div class="mono">${esc(f.path)} <span class="soft">${esc(f.error)}</span></div>`).join('')}</div>`) : ''}
    ${skipped.length ? box('Skipped (will not play)', `<div class="list">${skipped.map((b) => `<div><b>${esc(b.name)}</b> <span class="soft">${esc(b.reasons.join('; '))}</span></div>`).join('')}</div>`) : ''}
    </div>`;
}

// ───────────────────────────── Dupes ─────────────────────────────

export function dupesView() {
  const sc = S.scan;
  if (!sc || sc.empty) {
    return `<div class="empty"><h2>${sc ? 'No duplicates' : 'Nothing scanned yet'}</h2><div class="soft">${sc ? 'Every song on the player is stored once.' : 'Scan the player on the Device tab to look for duplicates.'}</div></div>`;
  }
  const d = sc.duplicates;
  const total = d.reduce((a, g) => a + g.wasted, 0);
  const safe = d.filter((g) => g.safe);
  const freed = safe.reduce((a, g) => a + g.wasted, 0);
  let h = `<div class="header"><h1>Duplicates</h1>${d.length ? tag(plural(d.length, 'group')) + tag(`${bytes(total)} recoverable`, 'good') : ''}</div>${noteHtml('dupes')}`;
  if (!d.length) return h + `<div class="empty"><h2>No duplicates</h2><div class="soft">Every song on the player is stored once.</div></div>`;
  h += box('Clean up automatically', safe.length
    ? `<div class="soft">${plural(safe.length, 'group')} are the same song on the same album. The best copy stays (lossless first, then larger, then the one in the right folder, and always one the player can play); the rest go to quarantine and free ${bytes(freed)}.${d.length > safe.length ? ` The other ${d.length - safe.length} are marked “check first”: they are on different albums.` : ''}</div>
       <div>${btn(`Clean up ${plural(safe.length, 'group')}`, 'dupesSafe', { primary: true, disabled: busy() })}</div>`
    : `<div class="soft">None of these can be cleaned without a decision: each is the same song on different albums, or has no copy the player can play. Check them below.</div>`);
  h += `<div class="stack" style="margin-top:16px">${d.map((g) => {
    const on = S.ui.dupeSel.has(g.id);
    return box('', `<div class="row"><label class="check"><input type="checkbox" data-act="dupeToggle" data-arg="${esc(g.id)}"${on ? ' checked' : ''}><b>${esc(g.artist)} — ${esc(g.title)}</b></label>
      <span class="grow"></span>${g.safe ? '' : tag('check first', 'warn')}${tag(`frees ${bytes(g.wasted)}`)}</div>
      ${g.tracks.map((t) => `<div class="row tight" style="padding-left:26px">${tag(t.keep ? 'keep' : 'extra', t.keep ? 'good' : 'warn')}<span class="mono" style="width:120px;white-space:nowrap">${esc(t.ext)} · ${bytes(t.size)}</span><span class="ellipsis grow" title="${esc(t.path)}">${esc(t.path)}</span><span class="small soft">${esc(t.album)}</span></div>`).join('')}`);
  }).join('')}
    <div class="row">${btn(`Remove extra copies in ${S.ui.dupeSel.size} group${S.ui.dupeSel.size === 1 ? '' : 's'}`, 'dupesSelected', { disabled: busy() || !S.ui.dupeSel.size })}
      <span class="soft small">Each removed copy goes to the undo folder on the player.</span></div></div>`;
  return h;
}

// ───────────────────────────── Device ─────────────────────────────

export function deviceView() {
  const sc = S.scan;
  const header = `<div class="header"><h1>Device</h1>${sc && !sc.empty ? tag(plural(sc.trackCount, 'track')) : ''}
    <span class="soft small ellipsis grow">${player() ? esc(player().name + ' · ' + player().path) : 'No player'}</span>
    ${btn(sc ? 'Rescan' : 'Scan player', 'scanDevice', { primary: !sc, disabled: busy() || !player() })}</div>`;
  if (!player()) return header + `<div class="empty"><h2>No player</h2><div class="soft">Turn on USB storage on the player itself. It shows up here by itself.</div></div>`;
  if (!sc) {
    return header + `<div class="empty"><h2>${S.busy ? 'Reading the player…' : 'Nothing scanned yet'}</h2><div class="soft">Reads what is already on it. Nothing is changed until you confirm. Then tidy names, fix split albums, find broken files and more.</div></div>`;
  }
  if (sc.empty) return header + `<div class="empty"><h2>No audio found</h2><div class="soft">There are no music files on this player yet.</div></div>`;

  const undo = sc.undo ? `<div class="undo">${notice('info', `You can undo the last ${sc.undo.label} (${plural(sc.undo.changes, 'change')}). Only the latest operation can be undone; the next one replaces it.`)}
    <span class="grow"></span>${btn('Discard', 'undoForget', { compact: true })}${btn('Undo', 'undo', { compact: true, primary: true })}</div>` : '';
  const issues = (sc.tidy.renames ? 1 : 0) + (sc.tidy.junk ? 1 : 0) + sc.similarArtists.length + sc.similarAlbums.length + (sc.songList && !sc.songList.inSync ? 1 : 0);
  const tabs = `<div class="subtabs">
    <button class="tab ${S.devTab === 'fix' ? 'active' : ''}" data-act="devTab" data-arg="fix">Fix${issues ? `<span class="badge">${issues}</span>` : ''}</button>
    <button class="tab ${S.devTab === 'listening' ? 'active' : ''}" data-act="devTab" data-arg="listening">Listening</button>
    <button class="tab ${S.devTab === 'extras' ? 'active' : ''}" data-act="devTab" data-arg="extras">Extras</button></div>`;
  const body = S.devTab === 'fix' ? fixTab(sc) : S.devTab === 'listening' ? listeningTab(sc) : extrasTab(sc);
  return header + undo + noteHtml('device') + tabs + `<div class="stack" style="max-width:820px">${body}</div>`;
}

function fixTab(sc) {
  const t = sc.tidy;
  let out = box('Tidy', `
    <div class="soft">The player shows file names, not tags, so renaming everything into one Artist/Album/NN Title layout changes what you see while browsing.</div>
    <div class="stats">${stat(t.renames, 'to rename')}${stat(t.junk, 'junk files')}${stat(bytes(t.junkBytes), 'reclaims', 'good')}${stat(t.emptyFolders, 'empty folders')}${stat(t.leftovers, 'leftovers')}</div>
    ${t.blocked ? notice('warn', `${plural(t.blocked, 'rename')} will be skipped: a file with that name is already in the target folder, so the same song is on the player twice. Remove the extra copies in the Dupes tab first, then tidy.`) : ''}
    ${check('Also remove hidden macOS files (._*, .DS_Store)', 'removeJunk', t.removeJunk)}
    ${t.folders.length ? `<details><summary>Preview by folder (${t.folders.length})</summary><div class="listbox mono">${t.folders.map((f) => `<div>${esc(f.from)} → ${esc(f.to)} · ${plural(f.count, 'file')}${f.blocked ? ` · ${f.blocked} skipped` : ''}</div>`).join('')}</div></details>` : ''}
    ${t.moveLines.length ? `<details><summary>Preview renames (${t.renames})</summary><div class="listbox mono">${t.moveLines.map((l) => `<div>${esc(l)}</div>`).join('')}</div></details>` : ''}
    ${t.junkLines.length ? `<details><summary>Preview junk files (${t.junk})</summary><div class="listbox mono">${t.junkLines.map((l) => `<div>${esc(l)}</div>`).join('')}</div></details>` : ''}
    <div class="row">${btn('Tidy the player', 'tidy', { primary: true, disabled: busy() || (!t.renames && !t.junk && !t.emptyFolders && !t.leftovers) })}<span class="soft small">Music is only ever moved, never overwritten.</span></div>`);

  if (sc.songList && !sc.songList.inSync) {
    out += box("Player's song list", `${notice('warn', `${plural(sc.songList.missing, 'track')} on the card ${sc.songList.missing === 1 ? 'is' : 'are'} not in the player's own song list, so ${sc.songList.missing === 1 ? 'it doesn’t' : 'they don’t'} show up on the player${sc.songList.stale ? `, and ${sc.songList.stale} entries point at files that are gone` : ''}.`)}
      <div class="soft small">The player lists songs from its own saved list, not from the card. This adds the missing tracks to it (a backup of the list is kept). Your music is not touched.</div>
      <div>${btn('Update the list', 'songlist', { disabled: busy() })}</div>`);
  }
  if (sc.similarArtists.length) {
    out += box('Artists spelled twice', `<div class="soft small">The player lists these as separate artists, but the name is the same apart from “The” or capital letters. Pick the spelling to keep; only the artist tags change.</div>
      ${sc.similarArtists.map((g, gi) => groupPicker(g, 'artist', gi)).join('')}`);
  }
  if (sc.similarAlbums.length) {
    out += box('Albums split in two', `<div class="soft small">These show up on the player as separate albums, but the songs are the same: a typo in the album name, an extra edition, or a song downloaded on its own. Pick the name to keep; only the album tag changes.</div>
      ${sc.similarAlbums.map((g, gi) => groupPicker(g, 'album', gi)).join('')}`);
  }
  out += rulesBox(sc);
  out += healthBox();
  out += formatsBox(sc);
  return out;
}

function groupPicker(g, kind, gi) {
  const chosen = (kind === 'artist' ? S.ui.chosenArtist : S.ui.chosenAlbum)[g.id] || g.suggested;
  const label = (v) => (kind === 'artist' ? v.name : v.title);
  return `<div class="stack" style="gap:6px;padding:4px 0">
    ${kind === 'album' ? `<div class="small soft">${esc(g.albumArtist)}</div>` : ''}
    <div class="picker">${g.variants.map((v, vi) => `<div class="item ${label(v) === chosen ? 'sel' : ''}" data-act="pickName" data-arg="${kind}|${gi}|${vi}"><span class="ellipsis">${esc(label(v))}</span><span class="count">${plural(v.count, 'song')}</span></div>`).join('')}</div>
    <div>${btn(`Merge into “${esc(chosen)}”`, kind === 'artist' ? 'mergeArtists' : 'mergeAlbums', { arg: g.id, compact: true, disabled: busy() })}</div></div>`;
}

function rulesBox(sc) {
  const rules = sc.mergeRules || [];
  if (!rules.length && !S.suggested.length) return '';
  return box('Remembered merges', `
    <div class="soft small">Your merges are repeated on every sync: files are renamed as they are copied, so the old spellings in your library do not come back. The library itself is never changed.</div>
    ${S.suggested.length ? `${notice('warn', `Your library spells ${plural(S.suggested.length, 'name')} differently from the player. Remember them, or the next sync copies the old spelling back and splits the album again.`)}
      ${S.suggested.map((r, i) => `<div class="row">${tag(r.kind, 'warn')}<span class="grow ellipsis">“${esc(r.from)}” → “${esc(r.to)}”</span>${btn('Remember', 'ruleAdd', { arg: i, compact: true })}</div>`).join('')}
      ${S.suggested.length > 1 ? `<div>${btn('Remember all', 'ruleAddAll', { compact: true })}</div>` : ''}` : ''}
    ${rules.map((r) => `<div class="row">${tag(r.kind)}<span class="grow ellipsis">“${esc(r.from)}” → “${esc(r.to)}”</span>${btn('Forget', 'ruleRemove', { arg: r.id, compact: true })}</div>`).join('')}`);
}

function healthBox() {
  const h = S.health;
  return box('Broken files', `
    <div class="soft small">Checks the start and end of every file on the player and lists the ones that will not play: cut-off copies from an interrupted transfer, damaged files. Nothing is changed by checking.</div>
    <div>${btn(h ? 'Check again' : 'Check files', 'healthCheck', { disabled: busy() })}</div>
    ${h && !h.length ? notice('good', 'Every file on the player plays fine.') : ''}
    ${h && h.length ? `${notice('warn', `${plural(h.length, 'broken file')} found. ${h.filter((b) => b.replacement).length} can be replaced from your library.`)}
      <div class="listbox small">${h.map((b) => `<div><b>${esc(b.path)}</b> <span class="soft">${esc(b.reasons.join('; '))}</span> ${b.replacement ? tag('has an intact copy', 'good') : tag('no copy', 'bad')}</div>`).join('')}</div>
      <div class="row">${btn('Replace from library', 'healthFix', { primary: true, disabled: busy() || !h.some((b) => b.replacement) })}
        ${btn('Also remove ones with no copy', 'healthFixRemove', { disabled: busy(), danger: true })}</div>` : ''}`);
}

function formatsBox(sc) {
  const L = S.settings.limits || {};
  const rates = [[0, 'any'], [44100, '≤ 44.1 kHz'], [48000, '≤ 48 kHz'], [96000, '≤ 96 kHz'], [192000, '≤ 192 kHz']];
  const bits = [[0, 'any'], [16, '≤ 16'], [24, '≤ 24']];
  const sel = (id, list, cur) => `<select data-bind="${id}">${list.map(([v, l]) => `<option value="${v}"${(cur || 0) === v ? ' selected' : ''}>${l}</option>`).join('')}</select>`;
  return box('Formats on the player', `
    <div class="soft small">Which formats and qualities are on the player. If some files will not play, set the highest quality it handles: files above it are flagged under Broken files, replaced from your library when a copy within the limit exists, and skipped on sync. Nothing is converted.</div>
    <div class="list">${sc.formats.slice(0, 8).map((f) => `<div class="item"><span class="grow">${esc(f.label)}</span><span class="soft">${plural(f.count, 'song')}</span></div>`).join('')}
      ${sc.formats.length > 8 ? `<div class="soft small">… and ${sc.formats.length - 8} more formats</div>` : ''}</div>
    <div class="row"><span class="small soft">Sample rate</span>${sel('maxSampleRate', rates, L.maxSampleRate)}
      <span class="small soft">Bit depth</span>${sel('maxBitDepth', bits, L.maxBitDepth)}
      ${check('Allow ALAC', 'allowALAC', L.allowALAC !== false)}</div>
    ${sc.flagged ? notice('warn', `${plural(sc.flagged, 'song')} above these limits. Press “Check files” to see them and replace what can be replaced.`) : ''}`);
}

function listeningTab(sc) {
  const l = sc.listening;
  if (!l.plays) {
    return box('Listening', `<div class="soft">The player keeps a log of what you play (.scrobbler.log), but it is empty or missing. Listen to some music and scan again.${S.devices.find((d) => d.path === S.settings.devicePath)?.firmware === 'rockbox' ? ' On Rockbox, switch the scrobbler on in its settings first.' : ''}</div>`);
  }
  const top = (rows, key) => { const m = Math.max(...rows.map((r) => r.plays), 1); return `<div class="bars">${rows.map((r) => `<div class="rowbar"><span class="name">${esc(key ? r.artist + ' — ' + r.name : r.name)}</span><div class="bar"><div style="width:${(r.plays / m) * 100}%"></div></div><span class="n">${r.plays}</span></div>`).join('')}</div>`; };
  const pickBytes = [...S.ui.freePick].reduce((a, id) => a + ((l.albums.find((x) => x.id === id) || {}).bytes || 0), 0);
  const shown = l.albums.slice(0, 80);
  return box('What you listen to', `<div class="stats">${stat(l.plays, 'plays')}${stat(hours(l.seconds), 'listened')}${stat(`${l.albumCount - l.never}/${l.albumCount}`, 'albums played')}${stat(l.never, 'never played', l.never ? 'warn' : '')}</div>
      <div class="soft small">From the player's own log, ${day(l.first)} – ${day(l.last)}. Anything played before the log started is not counted.</div>`)
    + box('Most played artists', top(l.topArtists)) + box('Most played albums', top(l.topAlbums.map((a) => ({ ...a })), true))
    + box('Free up space', `<div class="soft small">Albums are listed from the least listened to: never played first, then the ones not touched for longest. Pick how much to free, tick or untick, then remove. Removed albums go to the undo folder and sync will not copy them back.</div>
      <div class="row"><select data-bind="freeGB">${[5, 10, 20, 50, 100].map((g) => `<option value="${g}"${S.ui.freeGB === g ? ' selected' : ''}>Free ${g} GB</option>`).join('')}</select>
        ${btn('Pick the least listened', 'freePick', { compact: true })}${S.ui.freePick.size ? btn('Clear', 'freeClear', { compact: true }) : ''}</div>
      <div class="list">${shown.map((a) => `<div class="item"><label class="check grow"><input type="checkbox" data-act="freeToggle" data-arg="${esc(a.id)}"${S.ui.freePick.has(a.id) ? ' checked' : ''}><span class="ellipsis">${esc(a.artist)} — ${esc(a.title)}</span></label>
        <span class="small" style="color:${a.plays ? 'var(--soft)' : 'var(--warn)'}">${a.plays ? `${a.plays} plays · ${day(a.lastPlayed)}` : 'never played'}</span><span class="small soft" style="width:70px;text-align:right">${bytes(a.bytes)}</span></div>`).join('')}
        ${l.albums.length > shown.length ? `<div class="soft small">… and ${l.albums.length - shown.length} more albums, played more</div>` : ''}</div>
      <div class="row">${btn(`Remove ${plural(S.ui.freePick.size, 'album')}`, 'freeRemove', { primary: true, disabled: busy() || !S.ui.freePick.size })}<span class="soft small">${S.ui.freePick.size ? 'Frees ' + bytes(pickBytes) + '.' : 'Nothing ticked.'}</span></div>`);
}

function extrasTab() {
  const s = S.settings;
  return box('Lyrics + covers', `<div class="soft small">Looks up synced lyrics (LRCLIB) and missing cover art (Cover Art Archive) for what is already on the player. This sends artist, album and track names to those services.</div>
      <div class="row">${check('Lyrics', 'extraLyrics', S.ui.extraLyrics !== false)}${check('Missing covers', 'extraCovers', S.ui.extraCovers !== false)}
        ${btn('Add to the player', 'enrich', { disabled: busy() })}</div>`)
    + box('Smart playlists', `<div class="soft small">Builds playlists from mood, tempo (BPM) and genre tags already in your files. Nothing goes online; files without the tag are skipped.</div>
      <div class="row">${check('Mood', 'plMood', S.ui.plMood !== false)}${check('Tempo', 'plTempo', S.ui.plTempo !== false)}${check('Genre', 'plGenre', S.ui.plGenre !== false)}
        ${btn('Build playlists', 'playlists', { disabled: busy() })}</div>`);
}

// ───────────────────────────── Chrome ─────────────────────────────

export function topbar() {
  const tab = (id, label, badge) => `<button class="tab ${S.tab === id ? 'active' : ''}" data-act="tab" data-arg="${id}">${label}${badge ? `<span class="badge">${badge}</span>` : ''}</button>`;
  const dupes = S.scan && S.scan.duplicates ? S.scan.duplicates.length : 0;
  const changed = S.sync && S.sync.changes ? S.sync.changes.length : 0;
  return `<div class="topbar"><div class="brand"><img src="icon.png" alt="">Y1 SYNC</div>
    <div class="tabs">${tab('sync', 'Sync')}${tab('results', 'Results', changed)}${tab('device', 'Device')}${tab('dupes', 'Dupes', dupes)}</div><span class="spacer"></span>
    ${btn('♥', 'support', { compact: true, title: 'Support the author (Ko-fi)' })}${btn(S.theme === 'auto' ? 'Auto' : S.theme === 'night' ? 'Night' : 'Day', 'theme', { compact: true, title: 'Appearance' })}</div><div class="rule"></div>`;
}

export function statusbar() {
  const d = player();
  const left = d ? `<span class="dot good"></span>${esc(d.name)} connected · ${bytes(d.freeBytes)} free` : `<span class="dot warn"></span>No player found. Turn on USB storage on the player.`;
  let right = '';
  if (S.busy) {
    right = `<span class="small soft ellipsis" style="max-width:520px">${esc(S.busy.label)}</span>${S.busy.fraction != null ? progressBlocks(S.busy.fraction) : ''}${S.busy.stoppable ? btn('Stop', 'stop', { compact: true }) : ''}`;
  }
  return `<div class="statusbar"><span class="small ellipsis">${left}</span><span class="spacer"></span>${right}</div>`;
}

export function engineWarning() {
  if (S.engine && S.engine.ok) return '';
  return `<div style="padding:12px 20px">${notice('bad', 'ffmpeg was not found. Y1 Sync needs it to read music files on Windows. Put ffmpeg.exe and ffprobe.exe next to Y1 Sync.exe, or add them to PATH.')}</div>`;
}
