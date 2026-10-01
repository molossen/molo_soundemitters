// molo_soundemitters — NUI
const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'molo_soundemitters';
const $ = (s, r = document) => r.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const postJ = (name, data = {}) => fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }).then(r => r.json()).catch(() => ({}));
const post = (name, data = {}) => fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }).catch(() => {});

// Jenkins one-at-a-time hash (joaat) used by GTA
function joaat(str) {
  let h = 0;
  const s = str.toLowerCase();
  for (let i = 0; i < s.length; i++) {
    h = (h + s.charCodeAt(i)) >>> 0;
    h = (h + (h << 10)) >>> 0;
    h = (h ^ (h >>> 6)) >>> 0;
  }
  h = (h + (h << 3)) >>> 0;
  h = (h ^ (h >>> 11)) >>> 0;
  h = (h + (h << 15)) >>> 0;
  return h;
}
const hex = h => 'hash_' + ((h >>> 0).toString(16).toUpperCase().padStart(8, '0'));

const S = {
  sounds: [], radios: [], natives: [], banks: [], bankKind: {}, objects: [], vanillaInt: new Map(),
  emitters: [], interior: { inside: false, player: { x: 0, y: 0, z: 0 } }, intNames: {},
  group: 'default', range: 15, tab: 'interior', sel: null, editId: null, lastAudio: null,
  q: { sounds: '', set: '', cat: '', radios: '', natives: '', placed: '', pgroup: '', objects: '', here: false, amb: '', acat: '' },
  showHidden: false, audioOnly: true, lastExport: null, intKey: '',
  failed: new Set(),  // "set|name" of sounds that didn't play during this session
  check: { bad: new Set(), hidden: new Set(), checked: 0, at: null },
  showRemoved: false, scan: null,
  audio: { status: {}, interiors: {} }, doorPresets: [], mlo: null, mloDraft: null,
};
const skey = s => ((s.r || '') + '|' + s.n).toLowerCase();
const isRemoved = s => S.check.bad.has(skey(s)) || S.check.hidden.has(skey(s));
const LIMIT = 250;
const TYPE_LABEL = { sound: 'Sound', ambient: 'Vanilla emitter', radio: 'Radio', static: 'Vanilla emitter', prop: 'Object' };
const AUDIO_PROP_RE = /speaker|boombox|ghettoblast|jukebox|radio|hifi|stereo|_tv_|tv_flat|tapeplayer|subwoof|amp_|dj_|turntable|mixer|megaphone|alarm|siren|bell/i;
const QUICK_PROPS = ['prop_boombox_01', 'prop_ghettoblast_02', 'prop_speaker_06', 'prop_speaker_01', 'ba_prop_battle_club_speaker_large', 'ba_prop_battle_club_speaker_small', 'bkr_prop_clubhouse_jukebox_01a', 'prop_radio_01'];

// ─── Catalog data ────────────────────────────────────────────────────
Promise.all(['sounds', 'radios', 'static_emitters', 'banks', 'objects', 'interiors', 'door_presets'].map(f => fetch(`../data/${f}.json`).then(r => r.json()).catch(() => null)))
  .then(([sounds, radios, natives, banks, objects, interiors, doorPresets]) => {
    S.doorPresets = doorPresets || [];
    S.sounds = sounds || [];
    S.radios = radios || [];
    S.natives = natives || [];
    S.objects = objects || [];
    if (banks) {
      banks.script.forEach(b => S.bankKind[b] = 'script');
      banks.ambient.forEach(b => S.bankKind[b] = 'ambient');
      S.banks = Object.keys(S.bankKind).sort((a, b) => a.localeCompare(b));
    }
    (interiors || []).forEach(n => S.vanillaInt.set(joaat(n), n));
    S.soundSets = [...new Set(S.sounds.map(s => s.r))].sort((a, b) => a.localeCompare(b));
    S.soundCats = countBy(S.sounds, s => s.c);
    S.ambCats = countBy(S.natives, n => n.c);
    if (panelVisible()) render();
  });

function countBy(arr, fn) {
  const m = {};
  arr.forEach(x => { const k = fn(x) || 'Misc'; m[k] = (m[k] || 0) + 1; });
  return Object.entries(m).sort((a, b) => b[1] - a[1]);
}
const pretty = n => n.replace(/^(se_|dlc_)/i, '').replace(/_/g, ' ').toLowerCase().replace(/\b\w/g, c => c.toUpperCase());

// ─── Interiors ───────────────────────────────────────────────────────
function intName(hash) {
  if (!hash) return null;
  const h = hash >>> 0;
  return S.intNames[String(h)] || S.vanillaInt.get(h) || null;
}
function intLabel(i) {
  if (!i || !i.inside) return 'Outside';
  return intName(i.hash) || 'Unnamed MLO';
}
const inThisInterior = e => S.interior.inside && e.interiorHash && ((e.interiorHash >>> 0) === (S.interior.hash >>> 0));

// ─── Toasts ──────────────────────────────────────────────────────────
function toast(msg, kind = 'info') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  $('#toasts').appendChild(el);
  setTimeout(() => el.remove(), kind === 'warn' ? 6000 : 3500);
}

// ─── HUD ─────────────────────────────────────────────────────────────
function renderHudInterior() {
  const i = S.interior;
  let h = i.inside
    ? `<span class="pill in">Interior</span><b>${esc(intLabel(i))}</b>${i.rooms && i.roomIndex >= 0 ? ` · ${esc(i.rooms[i.roomIndex] || '')}` : ''}`
    : `<span class="pill">Outside</span>`;
  if (i.aimInside !== undefined) {
    if (i.inside && !i.aimSame) h += ` <span class="pill warn">aiming outside this interior</span>`;
    else if (!i.inside && i.aimInside) h += ` <span class="pill warn">aiming into an interior</span>`;
  }
  $('#hudInt').innerHTML = h;
  $('#hdrInt').textContent = i.inside ? `${intLabel(i)} · ${hex(i.hash)}${i.rooms && i.roomIndex >= 0 ? ' · ' + (i.rooms[i.roomIndex] || '') : ''}` : 'Outside';
}

function renderHud(d) {
  $('#hudGroup').textContent = `Group: ${d.group}`;
  const sel = $('#hudSel');
  sel.querySelector('.dot').className = `dot ${d.type || ''}`;
  sel.querySelector('.txt').textContent = d.template || 'Nothing selected — TAB to open the menu';
  $('#hudRange').textContent = `${(+d.range).toFixed(1)} m`;
  $('#hudHeight').textContent = `${d.height >= 0 ? '+' : ''}${(+d.height).toFixed(1)} m`;
  $('#hudHeading').textContent = `${Math.round(d.heading)}°`;
  $('#hudHeadBox').classList.toggle('hidden', !d.showHeading);
  let st = '';
  if (d.moving) st = `<span class="moving">Moving "${esc(d.moving)}" — E to confirm, ⌫ to cancel</span>`;
  else if (d.hover) st = `Aiming at: <b>${esc(d.hover.label)}</b> · ${esc(d.hover.what || '')}${d.hover.pack ? ' <span class="tag">pack</span>' : ''}`;
  $('#hudState').innerHTML = st;
}

// ─── Navigation ──────────────────────────────────────────────────────
document.querySelectorAll('#tabs button').forEach(b => b.onclick = () => { S.tab = b.dataset.tab; S.sel = null; S.editId = null; if (MLO_TABS.includes(S.tab) && (!S.mlo || !S.mloDraft || (S.mlo.inside && (S.mlo.hash >>> 0) !== (S.interior.hash >>> 0)) || (!S.mlo.inside && S.interior.inside))) loadMlo(); render(); });
$('#btnAim').onclick = () => closePanel();
$('#btnQuit').onclick = () => { post('stopPreview'); post('exitEditor'); };
document.addEventListener('keydown', e => { if (e.key === 'Escape' && panelVisible()) closePanel(); });

function panelVisible() { return !$('#panel').classList.contains('hidden'); }
function closePanel() {
  post('stopPreview');
  $('#panel').classList.add('hidden');
  post('close');
}

const dist = e => Math.hypot(e.x - S.interior.player.x, e.y - S.interior.player.y, e.z - S.interior.player.z);
const fmtD = d => d < 1000 ? `${d.toFixed(0)} m` : `${(d / 1000).toFixed(1)} km`;

function render() {
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === S.tab));
  renderHudInterior();
  const view = $('#view'), detail = $('#detail');
  view.classList.remove('hidden');
  detail.classList.remove('full');

  if (S.editId) {
    const e = S.emitters.find(x => x.id === S.editId);
    if (!e) { S.editId = null; return render(); }
    view.classList.add('hidden');
    detail.classList.add('full');
    return renderDetail(e, true);
  }
  ({ interior: viewInterior, mlo: viewMlo, doors: viewDoors, occl: viewOccl, sounds: viewSounds, ambient: viewAmbient, radios: viewRadios, objects: viewObjects, natives: viewNatives, placed: viewPlaced, export: viewExport })[S.tab]();
  if (S.sel) renderDetail(S.sel, false); else detail.classList.add('hidden');
}

function bindSearch(id, key, fn) {
  const el = $(id);
  el.value = S.q[key];
  el.oninput = () => { S.q[key] = el.value; fn(); };
}

function listRows(items, rowFn, emptyMsg) {
  if (!items.length) return `<div class="more">${emptyMsg}</div>`;
  return items.slice(0, LIMIT).map(rowFn).join('') + (items.length > LIMIT ? `<div class="more">${items.length - LIMIT} more results — refine your search</div>` : '');
}

function chips(id, cats, current, onPick, totalLabel) {
  const el = $(id);
  const total = cats.reduce((a, [, n]) => a + n, 0);
  el.innerHTML = `<span class="chip ${!current ? 'on' : ''}" data-c="">${totalLabel}<small>${total}</small></span>` +
    cats.map(([c, n]) => `<span class="chip ${current === c ? 'on' : ''}" data-c="${esc(c)}">${esc(c)}<small>${n}</small></span>`).join('');
  el.querySelectorAll('.chip').forEach(ch => ch.onclick = () => onPick(ch.dataset.c));
}

function describe(e) {
  let base;
  if (e.type === 'sound') base = (e.sound.set ? e.sound.set + ' › ' : '') + e.sound.name;
  else if (e.type === 'ambient') base = `Ambient · ${e.ambient.emitter}`;
  else if (e.type === 'radio') base = `📻 ${e.radio.station}${e.radio.emitter ? ' · ' + e.radio.emitter : ''}`;
  else if (e.type === 'static') base = `${e.static.name} → ${e.static.enabled ? 'ON' : 'OFF'}`;
  else return `Object · ${e.prop.model}`;
  return e.prop && e.prop.model ? `${base} + ${e.prop.model}` : base;
}

function placedRow({ e, d }) {
  return `
    <div class="row" data-id="${esc(e.id)}">
      <span class="dot ${e.enabled ? e.type : ''}"></span>
      <div class="main"><div class="name">${esc(e.label || e.id)}<span class="tag">${esc(e.group)}</span>${e.pack ? '<span class="tag">pack</span>' : ''}</div><div class="sub">${esc(describe(e))}</div></div>
      <div class="side">${fmtD(d)}</div>
      <div class="acts"><button class="sm" data-tp title="Teleport">TP</button></div>
    </div>`;
}
function bindPlacedRows(root) {
  root.querySelectorAll('.row[data-id]').forEach(row => {
    row.onclick = ev => {
      if (ev.target.closest('[data-tp]')) return post('teleport', { id: row.dataset.id });
      S.editId = row.dataset.id; render();
    };
  });
}

// ─── Interior tab ────────────────────────────────────────────────────
function viewInterior() {
  const i = S.interior;
  const here = S.emitters.filter(inThisInterior).map(e => ({ e, d: dist(e) })).sort((a, b) => a.d - b.d);
  const vanilla = i.inside && S.vanillaInt.get(i.hash >>> 0);
  const custom = i.inside && S.intNames[String(i.hash >>> 0)];

  $('#view').innerHTML = `
    <div class="scroll">
      <div class="int-hero">
        ${i.inside ? `
          <span class="pill in">You are inside an interior</span>
          <h2>${esc(intLabel(i))}</h2>
          <div class="mono">${hex(i.hash)} · ID ${i.id}${vanilla ? ' · vanilla' : ''}</div>
          <div class="kv">
            <div><small>Room</small><b title="${esc(i.rooms?.[i.roomIndex] || '')}">${esc(i.rooms?.[i.roomIndex] || '?')}</b></div>
            <div><small>Rooms</small><b>${i.roomIndex >= 0 ? i.roomIndex + ' / ' : ''}${(i.rooms || []).length}</b></div>
            <div><small>Portals</small><b>${i.portals ?? '?'}</b></div>
            <div><small>Room hash</small><b class="mono">${hex(i.roomHash)}</b></div>
            <div><small>Origin</small><b>${i.pos ? `${i.pos.x.toFixed(1)}, ${i.pos.y.toFixed(1)}` : '?'}</b></div>
            <div><small>Placed</small><b>${here.length}</b></div>
          </div>
          <div class="sec-title">Rooms</div>
          <div class="rooms">${(i.rooms || []).map((r, idx) => `<span class="room ${idx === i.roomIndex ? 'cur' : ''}">${esc(r)}</span>`).join('')}</div>
          ${vanilla ? '' : `
          <div class="sec-title">Name this MLO</div>
          <div class="filters" style="margin:0"><input id="intName" value="${esc(custom || '')}" placeholder="e.g. Bahama Mamas"><button class="sm" id="intNameGo">Save</button></div>`}
        ` : `
          <span class="pill">Outside</span>
          <h2>You're not inside any interior</h2>
          <div class="hint">Walk into your MLO: its name, room, portals and everything placed inside will show up here.</div>
        `}
      </div>

      <div class="sec-title">Place here</div>
      <div class="quick">
        <button data-go="sounds">🔊 Ambience & sounds</button>
        <button data-go="ambient">🎵 Vanilla emitter</button>
        <button data-go="radios">📻 A radio</button>
        <button data-go="objects">📦 An object</button>
        <button data-go="natives">⛔ Mute vanilla sound</button>
        <button data-go="mlo">🏠 Room ambience</button>
        <button data-go="doors">🚪 Door sounds</button>
        <button data-go="occl">🧱 Occlusion</button>
      </div>

      <div class="sec-title">${i.inside ? 'Placed in this interior' : 'Placed nearby'} <span>${i.inside ? here.length : ''}</span></div>
      <div id="hereList">${
        i.inside
          ? (here.length ? here.map(placedRow).join('') : `<div class="empty">Nothing placed in this interior yet.</div>`)
          : (() => { const near = S.emitters.map(e => ({ e, d: dist(e) })).filter(x => x.d < 60).sort((a, b) => a.d - b.d);
              return near.length ? near.slice(0, 30).map(placedRow).join('') : `<div class="empty">Nothing within 60 m.</div>`; })()
      }</div>
    </div>`;

  document.querySelectorAll('[data-go]').forEach(b => b.onclick = () => { S.tab = b.dataset.go; S.sel = null; if (MLO_TABS.includes(S.tab)) loadMlo(); render(); });
  bindPlacedRows($('#hereList'));
  const go = $('#intNameGo');
  if (go) go.onclick = () => post('nameInterior', { hash: i.hash, name: $('#intName').value.trim() });
  S.intKey = interiorKey();
}

function interiorKey() {
  const i = S.interior;
  return [i.inside, i.hash, i.roomIndex, S.emitters.filter(inThisInterior).length, S.intNames[String(i.hash >>> 0)] || ''].join('|');
}

// ─── MLO tabs: rooms (ambience), doors, occlusion → native .dat151.rel + .ymt ──
const REVERBS = [
  { id: 'default', l: 'Default', v: [0.35, 0, 0] },
  { id: 'none', l: 'Dry (no reverb)', v: [0, 0, 0] },
  { id: 'small', l: 'Small room', v: [0.6, 0, 0] },
  { id: 'medium', l: 'Medium room', v: [0.2, 0.5, 0] },
  { id: 'large', l: 'Large hall', v: [0, 0.3, 0.6] },
  { id: 'huge', l: 'Warehouse / hangar', v: [0, 0.1, 0.9] },
];
const reverbId = r => (REVERBS.find(x => x.v[0] === +r.reverbSmall && x.v[1] === +r.reverbMedium && x.v[2] === +r.reverbLarge) || { id: 'custom' }).id;
const presetLabel = n => (S.doorPresets.find(p => p.n === n) || { l: n }).l;
const MLO_TABS = ['mlo', 'doors', 'occl'];
const TONE_CATS = ['Room tones', 'HVAC & machinery', 'Electrical & tech', 'Appliances', 'Crowd & walla', 'Music', 'Water', 'Fire', 'Weather & creaks'];

const DOOR_KINDS = {
  swing:    { l: 'Swing door',        i: '🚪' },
  sliding:  { l: 'Sliding door',      i: '↔' },
  vertical: { l: 'Vertical / roller', i: '↕' },
  garage:   { l: 'Garage door',       i: '⬆' },
  barrier:  { l: 'Barrier arm',       i: '⤴' },
  gate:     { l: 'Gate',              i: '⊞' },
};
const HOW = { probed: 'detected by opening it', name: 'guessed from the name', size: 'guessed from the size', manual: 'set by you' };

function guessKind(model, size) {
  const m = (model || '').toLowerCase();
  if (/barrier|arm_|boom/.test(m)) return { kind: 'barrier', how: 'name' };
  if (/garage|gar_door|roller|shutter/.test(m)) return { kind: 'garage', how: 'name' };
  if (/slid|elev|lift|auto/.test(m)) return { kind: 'sliding', how: 'name' };
  if (/gate|fence|fnc/.test(m)) return { kind: 'gate', how: 'name' };
  if (size) {
    const w = Math.max(size.x, size.y), h = size.z;
    if (w > 3.5 && h < 1.2) return { kind: 'barrier', how: 'size' };
    if (w > 2.6 && h > 2.2) return { kind: 'garage', how: 'size' };
  }
  return { kind: 'swing', how: 'name' };
}

function presetFor(kind, model) {
  const m = (model || '').toLowerCase();
  const glass = /glass|shop|store|247|window/.test(m), metal = /metal|steel|sec|vault|fire|iron/.test(m), bars = /cell|jail|bars|pris/.test(m), chain = /chain|fnclink|fence/.test(m);
  switch (kind) {
    case 'sliding':  return /gate/.test(m) ? 'DEFAULT_DOOR_SLIDING_METAL_GATE' : bars ? 'DEFAULT_DOOR_SLIDING_METAL_GATE_BARS' : 'DEFAULT_DOOR_SLIDING_POWERED_INTERIOR';
    case 'vertical': return /lift|elev/.test(m) ? 'DEFAULT_DOOR_SLIDING_LIFT' : 'DEFAULT_DOOR_SLIDING_VERTICAL_METAL_SECURITY_FENCE';
    case 'garage':   return 'DEFAULT_DOOR_GARAGE';
    case 'barrier':  return 'D_PROP_SEC_BARRIER_LD_01A';
    case 'gate':     return chain ? 'DEFAULT_DOOR_CHAINLINK_SWING' : /wood/.test(m) ? 'DEFAULT_DOOR_SWING_WOOD_FENCE_GATE' : 'DEFAULT_DOOR_METAL_GATE_SWING_SMALL';
    default:         return bars ? 'DEFAULT_DOOR_METAL_BAR_DOOR_SWING' : glass ? 'DEFAULT_DOOR_SWING_GLASS_AND_METAL' : metal ? 'DEFAULT_DOOR_SWING_METAL' : 'DEFAULT_DOOR_SWING_WOOD';
  }
}
function guessPreset(model) { return presetFor(guessKind(model).kind, model); }

function loadMlo() {
  S.mlo = null;
  postJ('getMlo').then(info => {
    S.mlo = info || { inside: false };
    if (S.mlo.inside) {
      const key = String(S.mlo.hash >>> 0);
      const saved = S.audio.interiors[key];
      const d = saved ? JSON.parse(JSON.stringify(saved)) : { group: S.group, enabled: true, rooms: {}, doors: {} };
      d.hash = S.mlo.hash; d.roomList = S.mlo.rooms.slice();
      d.rooms = d.rooms || {}; d.doors = d.doors || {};
      S.mlo.rooms.forEach(r => { if (r !== 'limbo' && !d.rooms[r.toLowerCase()]) d.rooms[r.toLowerCase()] = { tone: '', reverbSmall: 0.35, reverbMedium: 0, reverbLarge: 0, exteriorAudibility: 0, portalOcclusion: 0.7 }; });
      // First visit: every detected door gets a sound, typed from its name / size
      if (!saved) (S.mlo.doors || []).forEach(x => {
        const g = guessKind(x.model, x.size);
        d.doors[String(x.hash)] = { model: x.model, kind: g.kind, how: g.how, preset: presetFor(g.kind, x.model) };
      });
      // Occlusion: fresh structure from the game, with the user's saved per-entity settings re-applied
      if (S.mlo.occl) {
        const prev = (saved && saved.occl) || null;
        const o = JSON.parse(JSON.stringify(S.mlo.occl));
        o.enabled = prev ? prev.enabled !== false : true;
        o.portals.forEach((p, i) => p.entities.forEach((e, j) => {
          const pe = prev && prev.portals[i] && prev.portals[i].entities[j];
          if (pe && (pe.model >>> 0) === (e.model >>> 0)) Object.assign(e, { isDoor: pe.isDoor, isGlass: pe.isGlass, maxOcclusion: pe.maxOcclusion });
          else if (d.doors[String(e.model >>> 0)]) e.isDoor = true;
        }));
        d.occl = o;
      }
      S.mloDraft = d;
    }
    if (MLO_TABS.includes(S.tab) && !S.editId) render();
  });
}

function mloGuard() {
  const v = $('#view');
  if (!S.mlo) { v.innerHTML = `<div class="empty">Reading the MLO…</div>`; return false; }
  if (!S.mlo.inside) { v.innerHTML = `<div class="empty">Walk into your MLO to set up its rooms, doors and occlusion.</div>`; return false; }
  return true;
}

function mloFooter() {
  const d = S.mloDraft, st = S.audio.status[d.group];
  return `<div class="mlo-foot">
    <span class="hint">${st ? `Last export ${esc(st.at)}${st.pending ? ' · <b>restart needed</b>' : ' · loaded'}` : 'Not exported yet'} · group <b>${esc(d.group)}</b></span>
    <span class="grow"></span><button class="sm" id="mRescan">Rescan</button><button class="primary" id="mSave">Save</button>
  </div>`;
}
function bindFooter() {
  $('#mRescan').onclick = () => loadMlo();
  $('#mSave').onclick = () => post('saveInteriorAudio', S.mloDraft);
}

// ── Rooms (MLO tab): ambience per room
function viewMlo() {
  if (!mloGuard()) return;
  const d = S.mloDraft, v = $('#view');
  const curName = (S.interior.rooms || [])[S.interior.roomIndex];
  const rooms = S.mlo.rooms.filter(r => r !== 'limbo').sort((a, b) => (b === curName) - (a === curName));
  v.innerHTML = `
    <div class="scroll">
      <div class="notice">Ambience of each room: a <b>room tone</b> that loops while you're inside and the <b>reverb</b>. Written as InteriorRoom entries in <b>audio/${esc(d.group)}_game.dat151.rel</b> on Export.</div>
      <div class="card">
        <label class="check"><input type="checkbox" id="mEnabled" ${d.enabled !== false ? 'checked' : ''}> Generate the rooms of this MLO</label>
        <div class="hint">Untick if the MLO already ships its own audio dat151 (rooms would be defined twice).</div>
        <div class="field"><label>Group (export file)</label><input id="mGroup" value="${esc(d.group)}"></div>
      </div>
      ${rooms.map(r => {
        const rr = d.rooms[r.toLowerCase()], rid = reverbId(rr), here = r === curName;
        return `<div class="card room-card ${here ? 'here' : ''}" data-room="${esc(r.toLowerCase())}">
          <div class="d-head" style="margin:0"><b>${esc(r)}</b>${here ? '<span class="pill in" style="margin-left:8px">You are here</span>' : ''}</div>
          <div class="field full"><label>Room tone</label>
            <div class="tone-wrap">
              <div class="filters" style="margin:0"><input data-k="tone" value="${esc(rr.tone || '')}" placeholder="Search: room tone, aircon, neon, fridge, walla…" autocomplete="off"><button class="sm" data-play title="Preview">▶</button><button class="sm" data-clear title="No room tone">✕</button></div>
              <div class="picker hidden"></div>
            </div></div>
          <div class="grid">
            <div class="field"><label>Reverb</label><select data-k="reverb">${REVERBS.map(x => `<option value="${x.id}" ${x.id === rid ? 'selected' : ''}>${x.l}</option>`).join('')}${rid === 'custom' ? '<option value="custom" selected>Custom</option>' : ''}</select></div>
            <div class="field"><label>Heard from outside (0-1)</label><input data-k="exteriorAudibility" type="number" min="0" max="1" step="0.1" value="${rr.exteriorAudibility}"></div>
          </div>
        </div>`;
      }).join('')}
    </div>
    ${mloFooter()}`;

  const tones = S.sounds.filter(x => x.s === 'amb' && TONE_CATS.includes(x.c) && !isRemoved(x));
  v.querySelectorAll('.room-card').forEach(card => {
    const rr = d.rooms[card.dataset.room];
    const input = card.querySelector('[data-k="tone"]'), picker = card.querySelector('.picker');
    const show = () => {
      const q = input.value.trim().toLowerCase();
      const words = q.split(/\s+/).filter(Boolean);
      const hits = tones.filter(x => words.every(w => x.n.toLowerCase().includes(w) || x.c.toLowerCase().includes(w)))
        .sort((a, b) => (a.c === 'Room tones' ? 0 : 1) - (b.c === 'Room tones' ? 0 : 1)).slice(0, 40);
      picker.innerHTML = hits.length ? hits.map(x => `<div class="pick" data-n="${esc(x.n)}"><span class="name">${esc(x.n)}</span><span class="tag">${esc(x.c)}</span><button class="sm" data-pp>▶</button></div>`).join('') : '<div class="hint" style="padding:8px">No match</div>';
      picker.classList.remove('hidden');
      picker.querySelectorAll('.pick').forEach(el => el.onmousedown = ev => {
        ev.preventDefault();
        if (ev.target.closest('[data-pp]')) return post('preview', { type: 'sound', sound: { name: el.dataset.n, set: '' }, atPlayer: true });
        input.value = rr.tone = el.dataset.n;
        picker.classList.add('hidden');
      });
    };
    input.onfocus = show;
    input.oninput = () => { rr.tone = input.value.trim(); show(); };
    input.onblur = () => setTimeout(() => picker.classList.add('hidden'), 150);
    card.querySelector('[data-play]').onclick = () => { if (rr.tone) post('preview', { type: 'sound', sound: { name: rr.tone, set: '' }, atPlayer: true }); };
    card.querySelector('[data-clear]').onclick = () => { rr.tone = ''; input.value = ''; post('stopPreview'); };
    card.querySelector('[data-k="exteriorAudibility"]').oninput = e => { rr.exteriorAudibility = Math.max(0, Math.min(1, parseFloat(e.target.value) || 0)); };
    card.querySelector('[data-k="reverb"]').onchange = e => {
      const p = REVERBS.find(x => x.id === e.target.value);
      if (p) [rr.reverbSmall, rr.reverbMedium, rr.reverbLarge] = p.v;
    };
  });
  $('#mEnabled').onchange = e => { d.enabled = e.target.checked; };
  $('#mGroup').oninput = e => { d.group = e.target.value.trim().replace(/[^\w\-]/g, '_') || S.group; };
  bindFooter();
  const here = v.querySelector('.room-card.here'); if (here) here.scrollIntoView({ block: 'nearest' });
}

// ── Doors tab: type detection + door sound preset
// Simple door sounds: one vanilla preset per material / kind of door
const DOOR_SOUNDS = [
  { n: 'DEFAULT_DOOR_SWING_WOOD',               l: 'Wood',            i: '🪵', kind: 'swing' },
  { n: 'DEFAULT_DOOR_SWING_METAL',              l: 'Metal',           i: '🔩', kind: 'swing' },
  { n: 'DEFAULT_DOOR_SWING_GLASS_AND_METAL',    l: 'Glass',           i: '🪟', kind: 'swing' },
  { n: 'DEFAULT_DOOR_METAL_BAR_DOOR_SWING',     l: 'Bars / cell',     i: '⛓', kind: 'swing' },
  { n: 'DEFAULT_DOOR_SLIDING_POWERED_INTERIOR', l: 'Sliding (auto)',  i: '↔', kind: 'sliding' },
  { n: 'DEFAULT_DOOR_SLIDING_METAL_GATE_BARS',  l: 'Sliding bars',    i: '⛓', kind: 'sliding' },
  { n: 'DEFAULT_DOOR_SLIDING_LIFT',             l: 'Elevator',        i: '↕', kind: 'vertical' },
  { n: 'DEFAULT_DOOR_GARAGE',                   l: 'Garage',          i: '⬆', kind: 'garage' },
  { n: 'DEFAULT_DOOR_METAL_GATE_SWING_SMALL',   l: 'Metal gate',      i: '⊞', kind: 'gate' },
  { n: 'DEFAULT_DOOR_SWING_WOOD_FENCE_GATE',    l: 'Wooden gate',     i: '⊞', kind: 'gate' },
  { n: 'DEFAULT_DOOR_CHAINLINK_SWING',          l: 'Chain-link gate', i: '⊞', kind: 'gate' },
  { n: 'D_PROP_SEC_BARRIER_LD_01A',             l: 'Barrier arm',     i: '⤴', kind: 'barrier' },
];

function viewDoors() {
  if (!mloGuard()) return;
  const d = S.mloDraft, v = $('#view');
  const det = {}; (S.mlo.doors || []).forEach(x => det[String(x.hash)] = x);
  const list = Object.entries(d.doors);
  const extra = (S.mlo.doors || []).filter(x => !d.doors[String(x.hash)]);
  const soundSelect = cur => {
    const known = DOOR_SOUNDS.some(x => x.n === cur);
    return `<select data-sound>${known ? '' : `<option value="${esc(cur)}" selected>${esc(presetLabel(cur))}</option>`}${DOOR_SOUNDS.map(x => `<option value="${x.n}" ${x.n === cur ? 'selected' : ''}>${x.i} ${x.l}</option>`).join('')}</select>`;
  };

  v.innerHTML = `
    <div class="scroll">
      <div class="notice">Pick the sound of each door: wood, metal, glass… It plays when the door opens and closes. A first guess is made from the model name.</div>
      <div class="actions" style="margin:0 0 8px"><button class="sm" id="mAim">+ Add the door I'm aiming at</button></div>
      ${list.length ? list.map(([h, x]) => `<div class="card door-card" data-h="${h}">
          <div class="d-head" style="margin:0">
            <span class="kind-ico">${(DOOR_SOUNDS.find(s => s.n === x.preset) || { i: '🚪' }).i}</span>
            <div class="t"><b>${esc(x.model || h)}</b>${det[h] ? '' : '<small>not seen in this scan</small>'}</div>
            <div style="flex:1;max-width:190px">${soundSelect(x.preset || 'DEFAULT_DOOR_SWING_WOOD')}</div>
            <button class="sm" data-play title="Open / close it to hear">▶</button>
            <button class="sm danger" data-del title="No sound for this door">✕</button>
          </div>
        </div>`).join('') : `<div class="empty">No door found in this MLO. Aim at one and use "+ Add".</div>`}
      ${extra.length ? `<div class="sec-title">Other objects found</div>${extra.map(x => `
        <div class="row" data-add="${x.hash}"><span class="dot"></span>
          <div class="main"><div class="name">${esc(x.model)}</div><div class="sub">${x.source === 'portal' ? 'In a doorway' : 'Door-like name'}</div></div>
          <button class="sm">+ Add</button></div>`).join('')}` : ''}
    </div>
    ${mloFooter()}`;

  v.querySelectorAll('.door-card').forEach(card => {
    const h = card.dataset.h, door = d.doors[h];
    card.querySelector('[data-sound]').onchange = e => {
      door.preset = e.target.value; door.how = 'manual';
      const s = DOOR_SOUNDS.find(x => x.n === door.preset); if (s) door.kind = s.kind;
      viewDoors();
    };
    card.querySelector('[data-del]').onclick = () => { delete d.doors[h]; viewDoors(); };
    // ▶: open the door for 2 s through the door system (same as detection), so you can hear the current game sound
    card.querySelector('[data-play]').onclick = () => {
      const x = det[h];
      if (!x || !x.pos) return toast('Walk closer to this door, then Rescan', 'warn');
      postJ('probeDoor', { hash: x.hash, pos: x.pos });
    };
  });
  v.querySelectorAll('[data-add]').forEach(row => row.onclick = () => {
    const x = det[row.dataset.add], g = guessKind(x.model, x.size);
    d.doors[row.dataset.add] = { model: x.model, kind: g.kind, how: g.how, preset: presetFor(g.kind, x.model) };
    viewDoors();
  });
  $('#mAim').onclick = () => postJ('aimedObject').then(x => {
    if (!x || !x.hash) return toast('Aim at a door first (Esc, aim, then TAB)', 'warn');
    const model = x.model || ('hash_' + (x.hash >>> 0).toString(16).toUpperCase()), g = guessKind(model);
    d.doors[String(x.hash >>> 0)] = { model, kind: g.kind, how: g.how, preset: presetFor(g.kind, model) };
    viewDoors();
  });
  bindFooter();
}

// ── Occlusion tab
function viewOccl() {
  if (!mloGuard()) return;
  const d = S.mloDraft, v = $('#view');
  if (!d.occl) { v.innerHTML = `<div class="empty">No portal data for this MLO.</div>`; return; }
  const o = d.occl, rn = i => (S.mlo.rooms[i] || ('room ' + i));
  const real = o.portals.map((p, i) => ({ p, i })).filter(x => !x.p.mirror);
  v.innerHTML = `
    <div class="scroll">
      <div class="notice">Audio occlusion: sound is muffled through walls and only travels room to room through portals. Written to <b>stream/${o.proxy >>> 0}.ymt</b> on Export.</div>
      <div class="card">
        <label class="check"><input type="checkbox" id="oEnabled" ${o.enabled !== false ? 'checked' : ''}> Generate the occlusion file</label>
        <div class="hint">${real.length} portals, ${S.mlo.rooms.length} rooms (limbo = outside). <b>Door</b>: blocks sound when shut. <b>Glass</b>: lets some through. Untick if the MLO already ships its own occlusion .ymt.</div>
        <div class="actions" style="margin:6px 0 0"><button class="sm" id="oAll1">All to 1.0 (fully muffled when shut)</button></div>
      </div>
      ${real.map(({ p, i }) => `
        <div class="card portal-card" data-p="${i}">
          <div class="d-head" style="margin:0"><b>Portal ${i}</b><small style="margin-left:8px;color:var(--mute)">${esc(rn(p.from))} ↔ ${esc(rn(p.to))}</small></div>
          ${p.entities.length ? p.entities.map((e, j) => `
            <div class="ent-row" data-e="${j}">
              <span class="name">${esc(e.name)}</span>
              <label class="check"><input type="checkbox" data-k="isDoor" ${e.isDoor ? 'checked' : ''}> Door</label>
              <label class="check"><input type="checkbox" data-k="isGlass" ${e.isGlass ? 'checked' : ''}> Glass</label>
              <label class="occ">Max occlusion <input type="number" data-k="maxOcclusion" min="0" max="1" step="0.05" value="${e.maxOcclusion}"></label>
            </div>`).join('') : '<div class="hint">Open portal (no door / window)</div>'}
        </div>`).join('')}
    </div>
    ${mloFooter()}`;
  $('#oEnabled').onchange = e => { o.enabled = e.target.checked; };
  $('#oAll1').onclick = () => { o.portals.forEach(p => p.entities.forEach(e => { e.maxOcclusion = 1.0; })); viewOccl(); toast('Max occlusion set to 1.0 everywhere: click Save', 'info'); };
  v.querySelectorAll('.portal-card').forEach(card => {
    const portal = o.portals[+card.dataset.p];
    card.querySelectorAll('.ent-row').forEach(row => {
      const ent = portal.entities[+row.dataset.e];
      row.querySelector('[data-k="isDoor"]').onchange = e => { ent.isDoor = e.target.checked; };
      row.querySelector('[data-k="isGlass"]').onchange = e => { ent.isGlass = e.target.checked; };
      row.querySelector('[data-k="maxOcclusion"]').oninput = e => { ent.maxOcclusion = Math.max(0, Math.min(1, parseFloat(e.target.value) || 0)); };
    });
  });
  bindFooter();
}

// ─── Sounds tab ──────────────────────────────────────────────────────
function visibleSounds() {
  return S.sounds.map((s, i) => ({ s, i })).filter(({ s }) => S.showRemoved || !isRemoved(s));
}

function checkBanner() {
  if (S.scan) {
    const pct = Math.round(100 * S.scan.done / Math.max(1, S.scan.total));
    return `<div class="notice scan"><b>Checking sounds… ${S.scan.done} / ${S.scan.total}</b> · ${S.scan.bad} not playable so far
      <div class="bar"><span style="width:${pct}%"></span></div>
      Stand still and keep the game focused. <button class="sm" id="scanStop">Stop</button></div>`;
  }
  if (!S.check.at) {
    return `<div class="notice warn"><b>Run the sound check once.</b> It plays every sound for a split second (about 1 min, lower your volume) and removes the ones that don't play. The result is saved on the server for everyone.
      <div class="actions" style="margin-top:8px"><button class="primary sm" data-scan="all">Check all sounds</button>${S.q.cat ? `<button class="sm" data-scan="cat">Check "${esc(S.q.cat)}" only</button>` : ''}</div></div>`;
  }
  const removed = S.check.bad.size + S.check.hidden.size;
  return `<div class="notice">Checked ${esc(S.check.at)} · <b>${removed}</b> sounds removed (${S.check.bad.size} unplayable, ${S.check.hidden.size} hidden by you).
    <span class="links"><a data-scan="all">Re-check all</a>${S.q.cat ? ` · <a data-scan="cat">Re-check "${esc(S.q.cat)}"</a>` : ''} · <a id="toggleRemoved">${S.showRemoved ? 'Hide removed' : 'Show removed'}</a></span></div>`;
}

function startScan(scope) {
  const pool = S.sounds.filter(s => !S.check.hidden.has(skey(s)) && (scope === 'all' || s.c === S.q.cat));
  if (!pool.length) return;
  S.scan = { done: 0, total: pool.length, bad: 0 };
  post('scanSounds', { items: pool.map(s => ({ k: skey(s), n: s.n, r: s.r })), full: scope === 'all' });
  viewSounds();
}

function viewSounds() {
  const vis = visibleSounds();
  $('#view').innerHTML = `
    <div id="banner">${checkBanner()}</div>
    <div class="chips" id="cats"></div>
    <div class="filters">
      <input id="qs" placeholder="Search a sound (fridge, aircon, neon, walla, fountain…)">
      <select id="qsrc"><option value="">All sources</option><option value="amb">Ambience loops</option><option value="set">Game soundsets</option></select>
    </div>
    <div class="count" id="cnt"></div>
    <div class="list" id="lst"></div>
    <div class="custom">
      <label>Custom</label>
      <input id="cName" placeholder="Sound name">
      <input id="cSet" placeholder="SoundSet (optional)">
      <button class="sm" id="cGo">OK</button>
    </div>`;
  const order = ['Room tones', 'HVAC & machinery', 'Electrical & tech', 'Appliances', 'Crowd & walla', 'Music', 'Water', 'Fire', 'Alarms & bells', 'Doors & elevators', 'Construction & tools', 'Weather & creaks', 'Animals', 'Nature'];
  const cats = countBy(vis.map(x => x.s), x => x.c).sort((a, b) => {
    const ia = order.indexOf(a[0]), ib = order.indexOf(b[0]);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || b[1] - a[1];
  });
  chips('#cats', cats, S.q.cat, c => { S.q.cat = c; viewSounds(); if (S.sel) renderDetail(S.sel, false); }, 'All');
  $('#qsrc').value = S.q.src || '';
  $('#qsrc').onchange = () => { S.q.src = $('#qsrc').value; fill(); };
  bindSearch('#qs', 'sounds', () => fill());
  bindBanner();
  $('#cGo').onclick = () => {
    const n = $('#cName').value.trim();
    if (!n) return toast('Enter a sound name', 'error');
    selectItem({ type: 'sound', sound: { name: n, set: $('#cSet').value.trim() } });
  };
  function fill() {
    const q = S.q.sounds.toLowerCase(), cat = S.q.cat, src = S.q.src;
    const items = vis.filter(({ s }) => (!cat || s.c === cat) && (!src || s.s === src) &&
      (!q || s.n.toLowerCase().includes(q) || s.r.toLowerCase().includes(q)));
    $('#cnt').textContent = `${items.length} sounds`;
    $('#lst').innerHTML = listRows(items, ({ s, i }) => {
      const removed = isRemoved(s), k = skey(s);
      return `
      <div class="row ${removed ? 'removed' : ''} ${S.sel && S.sel.type === 'sound' && S.sel.sound.name === s.n && (S.sel.sound.set || '') === s.r ? 'sel' : ''}" data-i="${i}">
        <span class="dot sound"></span>
        <div class="main"><div class="name">${esc(s.n)}${s.v ? `<span class="tag">${s.v} variants</span>` : ''}${S.failed.has(s.r + '|' + s.n) ? '<span class="tag bad">didn\'t play</span>' : ''}${S.check.bad.has(k) ? '<span class="tag bad">unplayable</span>' : ''}${S.check.hidden.has(k) ? '<span class="tag">hidden</span>' : ''}</div>
          <div class="sub">${s.s === 'amb' ? 'Ambience' : esc(s.r || 'no soundset')} · ${esc(s.c)}</div></div>
        <div class="acts">
          <button class="sm" data-play title="Preview">▶</button>
          ${S.check.hidden.has(k) ? `<button class="sm" data-unhide title="Put back in the list">↺</button>` : `<button class="sm" data-hide title="Can't hear it / don't want it: remove from the list">✕</button>`}
        </div>
      </div>`;
    }, S.showRemoved ? 'No sound' : 'No sound — try "Show removed" or another category');
    $('#lst').querySelectorAll('.row').forEach(r => {
      const s = S.sounds[+r.dataset.i];
      const t = { type: 'sound', sound: { name: s.n, set: s.r }, label: s.s === 'amb' ? pretty(s.n) : '' };
      r.onclick = ev => {
        if (ev.target.closest('[data-play]')) return post('preview', { ...t, atPlayer: true });
        if (ev.target.closest('[data-hide]')) { S.check.hidden.add(skey(s)); post('hideSound', { key: skey(s), state: true }); return fill(); }
        if (ev.target.closest('[data-unhide]')) { S.check.hidden.delete(skey(s)); post('hideSound', { key: skey(s), state: false }); return fill(); }
        selectItem(t);
      };
    });
  }
  fill();
}

function bindBanner() {
  const b = $('#banner');
  if (!b) return;
  b.querySelectorAll('[data-scan]').forEach(x => x.onclick = () => startScan(x.dataset.scan));
  const st = $('#scanStop'); if (st) st.onclick = () => post('stopScan');
  const tr = $('#toggleRemoved'); if (tr) tr.onclick = () => { S.showRemoved = !S.showRemoved; viewSounds(); };
}

// ─── Ambient tab (relocated vanilla static emitters) ─────────────────
function viewAmbient() {
  $('#view').innerHTML = `
    <div class="notice">Vanilla <b>static emitters</b> (club/bar/restaurant music, TVs, alarms, crowds). Pick one: it's moved onto your point and keeps playing its own sound. Its vanilla location goes silent while it's in use. For room tones, hums, fridges, AC, water… use the <b>Sounds</b> tab.</div>
    <div class="chips" id="cats"></div>
    <div class="filters"><input id="qa" placeholder="Search (name, interior, station)…"></div>
    <div class="count" id="cnt"></div>
    <div class="list" id="lst"></div>
    <div class="custom">
      <label>Custom</label>
      <input id="cEm" placeholder="Emitter name (also works with your own dat151 emitters)">
      <button class="sm" id="cGo">OK</button>
    </div>`;
  chips('#cats', S.ambCats || [], S.q.acat, c => { S.q.acat = c; viewAmbient(); if (S.sel) renderDetail(S.sel, false); }, 'All');
  bindSearch('#qa', 'amb', () => fill());
  $('#cGo').onclick = () => {
    const n = $('#cEm').value.trim();
    if (!n) return toast('Enter an emitter name', 'error');
    selectItem({ type: 'ambient', ambient: { emitter: n } });
  };
  const used = new Set(S.emitters.flatMap(e => [e.ambient?.emitter, e.radio?.emitter, e.static?.name]).filter(Boolean).map(n => n.toLowerCase()));
  function fill() {
    const q = S.q.amb.toLowerCase(), cat = S.q.acat;
    const items = S.natives.filter(n => (!cat || n.c === cat) &&
      (!q || n.n.toLowerCase().includes(q) || (n.i || '').toLowerCase().includes(q) || (n.rs || '').toLowerCase().includes(q) || (n.a || '').toLowerCase().includes(q)))
      .sort((a, b) => (!!a.i - !!b.i) || a.n.localeCompare(b.n));
    $('#cnt').textContent = `${items.length} emitters`;
    $('#lst').innerHTML = listRows(items, n => `
      <div class="row ${S.sel && S.sel.type === 'ambient' && S.sel.ambient.emitter === n.n ? 'sel' : ''}" data-n="${esc(n.n)}">
        <span class="dot ambient"></span>
        <div class="main"><div class="name">${esc(pretty(n.n))}<span class="tag">${esc(n.c)}</span>${n.i ? '<span class="tag">interior</span>' : ''}${used.has(n.n.toLowerCase()) ? '<span class="tag bad">in use</span>' : ''}</div>
          <div class="sub">${esc([n.n, n.rs && '📻 ' + n.rs, n.a && '🚨 ' + n.a, n.i].filter(Boolean).join(' · '))}</div></div>
        <button class="sm" data-play>▶</button>
      </div>`, 'No emitter');
    $('#lst').querySelectorAll('.row').forEach(row => {
      const n = S.natives.find(x => x.n === row.dataset.n);
      const t = { type: 'ambient', ambient: { emitter: n.n, alarm: n.a || undefined }, label: pretty(n.n) };
      row.onclick = ev => { if (ev.target.closest('[data-play]')) return post('preview', { ...t, atPlayer: true }); selectItem(t); };
    });
  }
  fill();
}

// ─── Radios tab ──────────────────────────────────────────────────────
function viewRadios() {
  $('#view').innerHTML = `
    <div class="filters">
      <input id="qr" placeholder="Search a station…">
      <label class="check"><input type="checkbox" id="hid" ${S.showHidden ? 'checked' : ''}> Hidden stations</label>
    </div>
    <div class="count" id="cnt"></div>
    <div class="list" id="lst"></div>
    <div class="custom">
      <label>Custom</label>
      <input id="cSt" placeholder="Station name (e.g. RADIO_01_CLASS_ROCK)">
      <button class="sm" id="cGo">OK</button>
    </div>`;
  bindSearch('#qr', 'radios', () => fill());
  $('#hid').onchange = () => { S.showHidden = $('#hid').checked; fill(); };
  $('#cGo').onclick = () => {
    const n = $('#cSt').value.trim();
    if (!n) return toast('Enter a station name', 'error');
    selectItem({ type: 'radio', radio: { station: n } });
  };
  function fill() {
    const q = S.q.radios.toLowerCase();
    const items = S.radios.filter(r => (S.showHidden || !r.h) && (!q || r.n.toLowerCase().includes(q) || r.l.toLowerCase().includes(q)));
    $('#cnt').textContent = `${items.length} stations`;
    $('#lst').innerHTML = listRows(items, r => `
      <div class="row ${S.sel && S.sel.type === 'radio' && S.sel.radio.station === r.n ? 'sel' : ''}" data-n="${esc(r.n)}">
        <span class="dot radio"></span>
        <div class="main"><div class="name">${esc(r.l)}${r.h ? '<span class="tag">hidden</span>' : ''}</div><div class="sub">${esc(r.n)}</div></div>
        <button class="sm" data-play>▶</button>
      </div>`, 'No station');
    $('#lst').querySelectorAll('.row').forEach(row => {
      const t = { type: 'radio', radio: { station: row.dataset.n } };
      row.onclick = ev => { if (ev.target.closest('[data-play]')) return post('preview', { ...t, atPlayer: true }); selectItem(t); };
    });
  }
  fill();
}

// ─── Objects tab ─────────────────────────────────────────────────────
function viewObjects() {
  $('#view').innerHTML = `
    <div class="filters">
      <input id="qo" placeholder="Search an object (prop_, ba_prop_…)">
      <label class="check"><input type="checkbox" id="ao" ${S.audioOnly ? 'checked' : ''}> Audio props only</label>
    </div>
    <div class="count" id="cnt"></div>
    <div class="list" id="lst"></div>
    <div class="custom">
      <label>Custom</label>
      <input id="cObj" placeholder="Model name (even a prop from your MLO)">
      <button class="sm" id="cGo">OK</button>
    </div>`;
  bindSearch('#qo', 'objects', () => fill());
  $('#ao').onchange = () => { S.audioOnly = $('#ao').checked; fill(); };
  $('#cGo').onclick = () => {
    const n = $('#cObj').value.trim();
    if (!n) return toast('Enter a model name', 'error');
    selectItem({ type: 'prop', prop: { model: n } });
  };
  function fill() {
    const q = S.q.objects.toLowerCase();
    const items = S.objects.filter(o => (!S.audioOnly || AUDIO_PROP_RE.test(o)) && (!q || o.toLowerCase().includes(q)));
    $('#cnt').textContent = `${items.length} objects${S.audioOnly ? ' (audio filter)' : ''}`;
    $('#lst').innerHTML = listRows(items, o => `
      <div class="row ${S.sel && S.sel.type === 'prop' && S.sel.prop.model === o ? 'sel' : ''}" data-n="${esc(o)}">
        <span class="dot prop"></span>
        <div class="main"><div class="name">${esc(o)}</div></div>
      </div>`, 'No object');
    $('#lst').querySelectorAll('.row').forEach(row => row.onclick = () => selectItem({ type: 'prop', prop: { model: row.dataset.n } }));
  }
  fill();
}

// ─── Vanilla tab (mute / enable a vanilla emitter in a zone) ─────────
function viewNatives() {
  $('#view').innerHTML = `
    <div class="notice">Place a zone: while the player is inside it, the chosen vanilla emitter is <b>muted</b> (or turned on), then restored on exit. Great for killing vanilla music that leaks into your MLO.</div>
    <div class="filters"><input id="qn" placeholder="Search a vanilla emitter (name, interior, station)…"></div>
    <div class="count" id="cnt"></div>
    <div class="list" id="lst"></div>
    <div class="custom">
      <label>Custom</label>
      <input id="cEm" placeholder="Emitter name (e.g. LOS_SANTOS_VANILLA_UNICORN_01_STAGE)">
      <button class="sm" id="cGo">OK</button>
    </div>`;
  bindSearch('#qn', 'natives', () => fill());
  $('#cGo').onclick = () => {
    const n = $('#cEm').value.trim();
    if (!n) return toast('Enter an emitter name', 'error');
    selectItem({ type: 'static', static: { name: n, enabled: false, default: true } });
  };
  function fill() {
    const q = S.q.natives.toLowerCase();
    const items = S.natives
      .filter(n => !q || n.n.toLowerCase().includes(q) || (n.i || '').toLowerCase().includes(q) || (n.rs || '').toLowerCase().includes(q))
      .map(n => ({ n, d: dist(n) })).sort((a, b) => a.d - b.d);
    $('#cnt').textContent = `${items.length} vanilla emitters · sorted by distance`;
    $('#lst').innerHTML = listRows(items, ({ n, d }) => `
      <div class="row ${S.sel && S.sel.type === 'static' && S.sel.static.name === n.n ? 'sel' : ''}" data-n="${esc(n.n)}">
        <span class="dot static"></span>
        <div class="main"><div class="name">${esc(n.n)}${n.on ? '' : '<span class="tag">off by default</span>'}</div>
          <div class="sub">${esc([n.rs && '📻 ' + n.rs, n.i, n.a && 'alarm ' + n.a].filter(Boolean).join(' · ') || '—')}</div></div>
        <div class="side">${fmtD(d)}</div>
      </div>`, 'No emitter');
    $('#lst').querySelectorAll('.row').forEach(row => {
      const n = S.natives.find(x => x.n === row.dataset.n);
      row.onclick = () => selectItem({ type: 'static', static: { name: n.n, enabled: !n.on, default: n.on, vx: n.x, vy: n.y, vz: n.z } });
    });
  }
  fill();
}

// ─── Placed tab ──────────────────────────────────────────────────────
function viewPlaced() {
  const groups = [...new Set(S.emitters.map(e => e.group))].sort();
  $('#view').innerHTML = `
    <div class="filters">
      <input id="qp" placeholder="Search…">
      <select id="pg"><option value="">All groups</option>${groups.map(g => `<option>${esc(g)}</option>`).join('')}</select>
      <label class="check"><input type="checkbox" id="ph" ${S.q.here ? 'checked' : ''}> This interior</label>
    </div>
    <div class="count" id="cnt"></div>
    <div class="list" id="lst"></div>`;
  $('#pg').value = S.q.pgroup;
  $('#pg').onchange = () => { S.q.pgroup = $('#pg').value; fill(); };
  $('#ph').onchange = () => { S.q.here = $('#ph').checked; fill(); };
  bindSearch('#qp', 'placed', () => fill());
  function fill() {
    const q = S.q.placed.toLowerCase();
    const items = S.emitters
      .filter(e => (!S.q.pgroup || e.group === S.q.pgroup) && (!S.q.here || inThisInterior(e)) && (!q || (e.label || e.id).toLowerCase().includes(q) || describe(e).toLowerCase().includes(q)))
      .map(e => ({ e, d: dist(e) })).sort((a, b) => a.d - b.d);
    $('#cnt').textContent = `${items.length} placed elements`;
    $('#lst').innerHTML = listRows(items, placedRow, 'Nothing placed yet — pick something, aim and press E');
    bindPlacedRows($('#lst'));
  }
  fill();
}

// ─── Export tab ──────────────────────────────────────────────────────
function viewExport() {
  const groups = [...new Set([S.group, ...S.emitters.filter(e => !e.pack).map(e => e.group), ...Object.values(S.audio.interiors || {}).map(p => p.group), ...Object.keys(S.audio.status || {})].filter(Boolean))].sort();
  $('#view').innerHTML = `
    <div class="exp">
      <div class="card">
        <div class="field"><label>Active group (applied to what you place next)</label>
          <div class="filters" style="margin:0"><input id="grp" value="${esc(S.group)}" placeholder="e.g. molo_bahamas"><button class="sm" id="grpGo">Apply</button></div></div>
        <div class="hint">Use your MLO name: everything you place afterwards goes into it, and exports are done per group.</div>
      </div>
      <div class="card">
        <div class="field"><label>Export a group</label>
          <select id="exg" style="width:100%">${groups.map(g => `<option ${g === S.group ? 'selected' : ''}>${esc(g)}</option>`).join('')}</select></div>
        <div class="field"><label>Into resource (your MLO)</label>
          <div class="filters" style="margin:0"><select id="ext" style="flex:1;max-width:none"></select><button class="primary sm" id="exGo">Export</button></div></div>
        <div class="hint">Everything is written <b>into the MLO's resource</b> and its <b>fxmanifest.lua</b> is patched, so it all works <b>without molo_soundemitters</b>:
          <b>audio/molo_se_&lt;group&gt;_game.dat151.rel</b> (rooms, door sounds), <b>stream/&lt;hash&gt;.ymt</b> (occlusion), and <b>audio/molo_se_&lt;group&gt;_player.lua</b>, a small client script that plays your placed sounds, radios, TV / music emitters and objects.
          If the MLO already has its own audio .dat151 / .ymt for this interior, they are merged and the originals are kept in <b>audio/_molo_backup/</b>.</div>
      </div>
      <div class="card">
        <h4>Native audio files</h4>
        ${Object.keys(S.audio.status).length ? Object.entries(S.audio.status).map(([g, st]) => `<div class="row"><span class="dot ${st.pending ? 'radio' : 'static'}"></span><div class="main"><div class="name">${esc(g)} → ${esc(st.target || '?')}</div><div class="sub">${st.count || 0} audio items${(st.ymts || []).length ? ' · occlusion ' + st.ymts.map(y => y + '.ymt').join(', ') : ''} · ${esc(st.at || '')}</div></div><div class="side">${st.manifest === false ? '<b style="color:#e66">fxmanifest NOT patched</b>' : st.pending ? '<b>restart needed</b>' : 'loaded'}</div></div>${st.manifest === false ? `<div class="hint" style="color:#e66">FiveM doesn't let a resource write into another one. Add to <b>server.cfg</b>, restart the server, then export again:<br><code style="user-select:all">${esc(st.perm || '')}</code></div>` : ''}`).join('') : '<div class="hint">None yet.</div>'}
        <div class="hint">After an export: <b>refresh</b>, restart the MLO resource and <b>reconnect</b> (the game only reads audio files when you join).</div>
      </div>
      <div id="exRes"></div>
    </div>`;
  $('#grpGo').onclick = () => {
    const g = $('#grp').value.trim().replace(/[^\w\-]/g, '_');
    if (!g) return;
    S.group = g; post('setGroup', { group: g }); toast(`Active group: ${g}`, 'success');
  };
  const fillTargets = () => {
    const g = $('#exg').value, st = S.audio.status[g] || {};
    const cur = st.wantedTarget || (st.target && st.target !== 'molo_soundemitters' ? st.target : '') || ((S.resources || []).includes(g) ? g : '');
    $('#ext').innerHTML = `<option value="">molo_soundemitters (editor only: stops when it stops)</option>` +
      (S.resources || []).map(r => `<option value="${esc(r)}" ${r === cur ? 'selected' : ''}>${esc(r)}</option>`).join('');
  };
  fillTargets();
  $('#exg').onchange = fillTargets;
  if (!S.resources) post('getResources');
  $('#exGo').onclick = () => { const g = $('#exg').value; if (g) post('export', { group: g, target: $('#ext').value }); };
  if (S.lastExport) showExport(S.lastExport);
}

function showExport(r) {
  const box = $('#exRes');
  if (!box) return;
  box.innerHTML = `
    <div class="card">
      <h4>JSON pack · ${r.count} elements <button class="sm" data-copy="j">Copy</button></h4>
      <textarea id="exJ" readonly>${esc(r.json)}</textarea>
      <h4>Native audio</h4>
      <div class="hint">${esc(r.native || '')}</div>
    </div>`;
  box.querySelectorAll('[data-copy]').forEach(b => b.onclick = () => {
    const ta = $('#exJ');
    ta.select(); document.execCommand('copy'); toast('Copied', 'success');
  });
}

// ─── Detail: settings before placing, or editing ─────────────────────
function selectItem(t) {
  S.sel = {
    type: t.type, label: t.label || '', range: S.range, interiorOnly: !!S.interior.inside, hours: { from: 0, to: 24 },
    sound: t.sound ? { repeat: true, delayMin: 0, delayMax: 0, bank: '', bankType: 'script', ...t.sound } : undefined,
    ambient: t.ambient ? { ...t.ambient } : undefined,
    radio: t.radio ? { ...t.radio } : undefined,
    static: t.static,
    prop: t.prop ? { heading: 0, ...t.prop } : undefined,
  };
  if (['sound', 'ambient', 'radio'].includes(t.type)) S.lastAudio = S.sel;
  render();
}

function stationOptions(cur) {
  const list = S.radios.slice();
  if (cur && !list.find(r => r.n === cur)) list.unshift({ n: cur, l: cur });
  return list.map(r => `<option value="${esc(r.n)}" ${r.n === cur ? 'selected' : ''}>${esc(r.l)}${r.l !== r.n ? ' — ' + esc(r.n) : ''}</option>`).join('');
}

function propField(e) {
  const cur = e.prop?.model || '';
  return `
    <div class="field full"><label>Visible object (optional)</label>
      <input id="fProp" value="${esc(cur)}" placeholder="none — e.g. prop_speaker_06">
      <div class="quick" style="margin-top:6px">${QUICK_PROPS.map(p => `<button class="sm" data-qp="${p}">${p.replace(/^(prop_|ba_prop_battle_|bkr_prop_clubhouse_)/, '')}</button>`).join('')}</div>
    </div>`;
}

function renderDetail(e, editing) {
  const d = $('#detail');
  d.classList.remove('hidden');
  const hours = e.hours || { from: 0, to: 24 };
  const ro = editing && e.pack;
  const audio = e.type !== 'prop';
  let specific = '';

  if (e.type === 'sound') {
    specific = `
      <div class="field"><label>AudioName</label><input id="fName" value="${esc(e.sound.name)}"></div>
      <div class="field"><label>SoundSet</label><input id="fSet" value="${esc(e.sound.set || '')}" placeholder="none"></div>
      <div class="field full"><label>Audio bank (if the sound doesn't play without it)</label>
        <input id="fBank" list="bankList" value="${esc(e.sound.bank || '')}" placeholder="optional">
        <datalist id="bankList">${S.banks.map(b => `<option value="${esc(b)}">`).join('')}</datalist></div>
      <label class="check full"><input type="checkbox" id="fRepeat" ${e.sound.repeat !== false ? 'checked' : ''}> Replay in a loop when the sound ends</label>
      <div class="field"><label>Min pause (s)</label><input id="fDmin" type="number" min="0" step="0.5" value="${e.sound.delayMin || 0}"></div>
      <div class="field"><label>Max pause (s)</label><input id="fDmax" type="number" min="0" step="0.5" value="${e.sound.delayMax || 0}"></div>
      ${propField(e)}`;
  } else if (e.type === 'ambient') {
    const n = S.natives.find(x => x.n === e.ambient.emitter);
    specific = `
      <div class="field full"><label>Vanilla emitter</label><input id="fEmitter" value="${esc(e.ambient.emitter)}"></div>
      ${e.ambient.alarm ? `<div class="hint full">🚨 This is an alarm emitter: the alarm <b>${esc(e.ambient.alarm)}</b> is started while it plays.</div>` : ''}
      ${n && n.i ? `<div class="hint full">⚠ Originally bound to the interior <b>${esc(n.i)}</b>: it may be quieter or silent elsewhere. Exterior emitters are the safest.</div>` : ''}
      ${propField(e)}
      <div class="hint full">The emitter is moved onto your point (or your object) and keeps its original sound. Its vanilla location goes silent while in use, and each emitter can only be placed once.</div>`;
  } else if (e.type === 'radio') {
    specific = `
      <div class="field full"><label>Station</label><select id="fStation">${stationOptions(e.radio.station)}</select></div>
      ${propField(e)}
      <div class="hint full">${editing ? `Vanilla emitter used: <b>${esc(e.radio.emitter)}</b>.` : 'A free vanilla emitter is reserved and moved to your point (its vanilla location goes silent).'} With an object, the sound comes out of the object.</div>`;
  } else if (e.type === 'static') {
    specific = `
      <div class="field full"><label>Action inside the zone</label>
        <div class="seg" id="fSeg"><button data-v="0" class="${!e.static.enabled ? 'on' : ''}">Mute the emitter</button><button data-v="1" class="${e.static.enabled ? 'on' : ''}">Turn it on</button></div></div>
      <div class="field full"><label>Force a station (if turned on)</label><select id="fStation"><option value="">— original station —</option>${stationOptions(e.static.station)}</select></div>
      <div class="hint full">Place the point where the player should be (e.g. the centre of your MLO): inside the range, the vanilla emitter <b>${esc(e.static.name)}</b> is muted or turned on, then restored on exit.</div>`;
  } else {
    specific = `
      <div class="field full"><label>Model</label><input id="fModel" value="${esc(e.prop.model)}"></div>
      <div class="hint full">Aim where the object goes, rotate it with ← → and raise / lower it with Shift + wheel.</div>
      ${!editing && S.lastAudio ? `<div class="full"><button class="sm" id="dAttach">Put this object on "${esc(describe(S.lastAudio))}"</button></div>` : ''}`;
  }

  d.innerHTML = `
    <div class="d-head">
      <span class="dot ${e.type}"></span>
      <div class="t"><b>${esc(editing ? (e.label || e.id) : TYPE_LABEL[e.type] + ' selected')}</b><small>${esc(describe(e))}</small></div>
      ${editing ? `<button class="sm" id="dBack">← List</button>` : ''}
    </div>
    ${ro ? `<div class="hint" style="margin-bottom:10px">Element from pack <b>${esc(e.pack)}</b>: read-only.</div>` : ''}
    ${editing && e.interiorHash ? `<div class="hint" style="margin-bottom:10px">Interior: <b>${esc(intName(e.interiorHash) || 'Unnamed MLO')}</b> · ${hex(e.interiorHash)}</div>` : ''}
    <div class="grid">
      <div class="field ${audio ? '' : 'full'}"><label>Name (optional)</label><input id="fLabel" value="${esc(e.label || '')}" placeholder="e.g. Bar speaker"></div>
      ${audio ? `<div class="field"><label>Range (m)</label><input id="fRange" type="number" min="1" max="300" step="0.5" value="${e.range}"></div>` : ''}
      ${audio && e.type !== 'static' ? `<div class="field"><label>Volume in export (dB)</label><input id="fVol" type="number" min="-30" max="24" step="1" value="${e.volume ?? ''}" placeholder="${e.type === 'sound' ? '0' : '+12'} (default)"></div>` : ''}
      ${editing ? `<div class="field full"><label>Group</label><input id="fGroup" value="${esc(e.group)}"></div>` : ''}
      ${specific}
      ${audio ? `
        <label class="check full"><input type="checkbox" id="fInt" ${e.interiorOnly ? 'checked' : ''}> Only when the player is in the same interior (no leaking outside)</label>
        <div class="field"><label>Active from (h)</label><input id="fFrom" type="number" min="0" max="23" value="${hours.from}"></div>
        <div class="field"><label>to (h)</label><input id="fTo" type="number" min="0" max="24" value="${hours.to}"></div>` : ''}
      ${editing ? `<label class="check full"><input type="checkbox" id="fEnabled" ${e.enabled ? 'checked' : ''}> Enabled</label>` : ''}
    </div>
    <div class="actions">
      ${audio ? `<button id="dPlay">▶ Preview</button><button id="dStop">■</button>` : ''}
      ${editing ? `
        <button id="dTp">TP</button>
        ${ro ? '' : `<button id="dMove">Move</button><button class="danger" id="dDel">Delete</button>`}
        <span class="grow"></span>
        ${ro ? '' : `<button class="primary" id="dSave">Save</button>`}`
      : `<span class="grow"></span><button class="primary" id="dUse">Place it →</button>`}
    </div>`;

  const seg = $('#fSeg');
  if (seg) seg.querySelectorAll('button').forEach(b => b.onclick = () => { seg.querySelectorAll('button').forEach(x => x.classList.remove('on')); b.classList.add('on'); });
  d.querySelectorAll('[data-qp]').forEach(b => b.onclick = () => { $('#fProp').value = b.dataset.qp; });

  if (audio) {
    $('#dPlay').onclick = () => post('preview', { ...readForm(e), atPlayer: editing });
    $('#dStop').onclick = () => post('stopPreview');
  }
  const attach = $('#dAttach');
  if (attach) attach.onclick = () => {
    const a = JSON.parse(JSON.stringify(S.lastAudio));
    a.prop = { model: $('#fModel').value.trim(), heading: 0 };
    S.sel = a; S.lastAudio = a;
    S.tab = { radio: 'radios', ambient: 'ambient' }[a.type] || 'sounds';
    render();
  };
  if (editing) {
    $('#dBack').onclick = () => { S.editId = null; render(); };
    $('#dTp').onclick = () => post('teleport', { id: e.id });
    if (!ro) {
      $('#dMove').onclick = () => post('moveEmitter', { id: e.id });
      $('#dDel').onclick = ev => {
        if (ev.target.dataset.armed) { post('deleteEmitter', { id: e.id }); S.editId = null; return; }
        ev.target.dataset.armed = 1; ev.target.textContent = 'Confirm?';
      };
      $('#dSave').onclick = () => post('saveEmitter', readForm(e));
    }
  } else {
    $('#dUse').onclick = () => {
      const t = readForm(e);
      if (t.range) S.range = t.range;
      if (['sound', 'ambient', 'radio'].includes(t.type)) S.lastAudio = t;
      post('setTemplate', t);
    };
  }
}

function readForm(base) {
  const v = id => { const el = $(id); return el ? el.value : undefined; };
  const c = id => { const el = $(id); return el ? el.checked : undefined; };
  const out = JSON.parse(JSON.stringify(base));
  out.label = (v('#fLabel') || '').trim() || undefined;
  if ($('#fRange')) out.range = Math.max(1, Math.min(300, parseFloat(v('#fRange')) || 15));
  if ($('#fInt')) out.interiorOnly = c('#fInt');
  if ($('#fVol')) { const vol = parseFloat(v('#fVol')); out.volume = isNaN(vol) ? undefined : Math.max(-30, Math.min(24, vol)); }
  if ($('#fFrom')) {
    out.hours = { from: parseInt(v('#fFrom')) || 0, to: parseInt(v('#fTo')) };
    if (isNaN(out.hours.to)) out.hours.to = 24;
  }
  if ($('#fGroup')) out.group = v('#fGroup').trim() || out.group;
  if ($('#fEnabled')) out.enabled = c('#fEnabled');

  if ($('#fProp')) {
    const m = v('#fProp').trim();
    out.prop = m ? { ...(out.prop || {}), model: m, heading: out.prop?.heading || 0 } : undefined;
  }
  if (out.type === 'sound') {
    const bank = v('#fBank').trim();
    out.sound = { ...out.sound, name: v('#fName').trim(), set: v('#fSet').trim(), bank: bank || undefined,
      bankType: S.bankKind[bank] || 'script', repeat: c('#fRepeat'),
      delayMin: parseFloat(v('#fDmin')) || 0, delayMax: parseFloat(v('#fDmax')) || 0 };
  } else if (out.type === 'ambient') {
    const name = v('#fEmitter').trim();
    const n = S.natives.find(x => x.n.toLowerCase() === name.toLowerCase());
    out.ambient = { emitter: name, alarm: n ? (n.a || undefined) : out.ambient.alarm };
  } else if (out.type === 'radio') {
    out.radio = { ...out.radio, station: v('#fStation') };
  } else if (out.type === 'static') {
    const on = $('#fSeg .on');
    out.static = { ...out.static, enabled: on ? on.dataset.v === '1' : false, station: v('#fStation') || undefined };
  } else if (out.type === 'prop') {
    out.prop = { ...out.prop, model: v('#fModel').trim() };
  }
  return out;
}

// ─── Messages from Lua ───────────────────────────────────────────────
window.addEventListener('message', ({ data: m }) => {
  const d = m.data || {};
  switch (m.action) {
    case 'open':
      S.group = d.group; S.range = d.range;
      $('#hud').classList.remove('hidden');
      break;
    case 'close':
      $('#hud').classList.add('hidden');
      $('#panel').classList.add('hidden');
      break;
    case 'hud':
      S.group = d.group; S.range = d.range;
      renderHud(d);
      break;
    case 'interior':
      S.interior = d;
      renderHudInterior();
      if (panelVisible() && S.tab === 'interior' && !S.sel && !S.editId && interiorKey() !== S.intKey) render();
      break;
    case 'panel':
      S.emitters = d.emitters || []; S.group = d.group; S.range = d.range;
      if (d.interior) S.interior = d.interior;
      if (d.tab === 'edit') { S.editId = d.editId; S.tab = 'placed'; }
      else { S.editId = null; if (d.tab) { S.tab = d.tab; S.sel = null; } }
      $('#panel').classList.remove('hidden');
      render();
      break;
    case 'panelClose':
      $('#panel').classList.add('hidden');
      break;
    case 'emitters':
      S.emitters = d.emitters || [];
      if (d.interior) S.interior = d.interior;
      if (panelVisible() && (S.tab === 'placed' || S.tab === 'interior' || S.editId)) render();
      break;
    case 'names':
      S.intNames = d || {};
      break;
    case 'resources':
      S.resources = d || [];
      if (panelVisible() && S.tab === 'export') viewExport();
      break;
    case 'audioState':
      S.audio = { status: d.status || {}, interiors: d.interiors || {} };
      if (panelVisible() && S.tab === 'export') viewExport();
      break;
    case 'soundCheck':
      S.check = { bad: new Set(d.bad || []), hidden: new Set(d.hidden || []), checked: d.checked || 0, at: d.at || null };
      if (panelVisible() && S.tab === 'sounds' && !S.editId) { const sel = S.sel; viewSounds(); if (sel) renderDetail(sel, false); }
      break;
    case 'scanProgress':
      S.scan = d.finished ? null : d;
      if (d.finished && d.aborted) toast('Sound check stopped', 'info');
      if (panelVisible() && S.tab === 'sounds' && !S.editId) {
        if (d.finished) { const sel = S.sel; viewSounds(); if (sel) renderDetail(sel, false); }
        else { const b = $('#banner'); if (b) { b.innerHTML = checkBanner(); bindBanner(); } }
      }
      break;
    case 'soundFailed':
      S.failed.add((d.set || '') + '|' + d.name);
      if (panelVisible() && S.tab === 'sounds' && !S.editId) {
        const sel = S.sel; viewSounds(); if (sel) renderDetail(sel, false);
      }
      break;
    case 'exported':
      S.lastExport = d;
      toast(`Exported "${d.group}": ${d.count} elements → exports/${d.file}.json`, 'success');
      if (S.tab === 'export') showExport(d);
      break;
    case 'notify':
      toast(d.msg, d.kind);
      break;
  }
});
