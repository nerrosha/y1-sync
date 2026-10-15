// One shared object the views read and the actions change.
export const S = {
  tab: 'sync',
  devTab: 'fix',
  settings: {},
  devices: [],
  firmwares: [],
  engine: { ok: true },
  plan: null,
  scan: null,
  sync: null,          // result of the last sync (drives the Results tab)
  suggested: [],       // merge rules the player already has but the app has not remembered
  busy: null,          // { label, fraction, stoppable }
  notes: {},           // { sync, device, dupes } -> { kind, text }
  confirm: null,       // { title, message, okLabel, run }
  albumModal: null,    // { query, excluded:Set }
  ui: {
    showFiles: false,
    showAlbums: true,
    freeGB: 20,
    freePick: new Set(),
    dupeSel: new Set(),
    chosenAlbum: {},
    chosenArtist: {},
  },
  theme: localStorage.getItem('theme') || 'auto',
};

export const support = { title: 'Ko-fi', url: 'https://ko-fi.com/nerrosha' };
