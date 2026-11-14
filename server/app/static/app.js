'use strict';

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const esc = value => String(value ?? '').replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
const state = {user:null, csrf:null, status:null, catalog:null, reviewDrafts:{}, cases:null, currentCase:null, filter:'all', search:'', offset:0, quickOffset:0, auditOffset:0};
let navigation = 0, pollTimer, toastTimer;
const iconPaths = {
  arrow:'<path d="M5 12h14m-5-5 5 5-5 5"/>', back:'<path d="M19 12H5m5-5-5 5 5 5"/>',
  plus:'<path d="M12 5v14M5 12h14"/>', logout:'<path d="M9 5H5v14h4m6-11 4 4-4 4m-6-4h10"/>',
  folder:'<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3z"/>',
  shield:'<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6z"/><path d="m8 12 3 3 5-6"/>',
  photo:'<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8" cy="9" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/>',
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  check:'<path d="m5 12 4 4L19 6"/>', refresh:'<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 7a7 7 0 0 1 11.6-1L20 9M4 15l2.3 3A7 7 0 0 0 18 17"/>',
  search:'<circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/>', help:'<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 1 1 4.2 1.8c-1.2.8-1.7 1.2-1.7 2.7M12 17h.01"/>',
  upload:'<path d="M12 16V3m-5 5 5-5 5 5M4 16v5h16v-5"/>',
  key:'<circle cx="8" cy="9" r="4"/><path d="m11 12 8 8m-3-3 3-3m-6 0 3-3"/>',
  users:'<circle cx="9" cy="8" r="3"/><path d="M3 21v-4a6 6 0 0 1 12 0v4m2-16a3 3 0 0 1 0 6m3 10v-4a5 5 0 0 0-3-4"/>',
  list:'<path d="M8 6h12M8 12h12M8 18h12M3 6h1M3 12h1M3 18h1"/>',
  close:'<path d="m6 6 12 12M6 18 18 6"/>', lock:'<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4M12 14v3"/>',
  model:'<path d="M8 3H3v5m13-5h5v5M8 21H3v-5m13 5h5v-5"/><circle cx="12" cy="12" r="5"/><path d="m10 12 2 2 3-4"/>',
};
function icon(name) { return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${iconPaths[name] || iconPaths.folder}</svg>`; }
function brand() { return '<a class="brand" href="#"><img class="brand-icon" src="/static/icon.svg" alt=""><div><div class="brand-name">Tele<span>Derma</span></div><div class="brand-caption">Uno spazio di cura condiviso</div></div></a>'; }
const roleNames = {patient:'Area paziente', doctor:'Area medico', admin:'Amministrazione'};
const statusNames = {draft:'In preparazione', queued:'Analisi in coda', waiting_model:'In attesa del modello', analysis_failed:'Analisi da ripetere', awaiting_review:'In valutazione medica', needs_images:'Nuove foto richieste', released:'Risposta disponibile'};
const runNames = {queued:'Analisi in coda', running:'Analisi in corso', waiting_model:'Modello non disponibile', completed:'Analisi completata', failed:'Analisi non completata'};
function pill(value) { return `<span class="pill ${esc(value)}">${esc(statusNames[value] || value)}</span>`; }
function date(value, time = false) { if (!value) return '—'; return new Intl.DateTimeFormat('it-IT', {day:'2-digit', month:'short', year:'numeric', ...(time ? {hour:'2-digit',minute:'2-digit'} : {})}).format(new Date(value)); }
function toast(message, error = false) { const element = $('#toast'); clearTimeout(toastTimer); element.textContent = message; element.className = `toast${error ? ' toast-error' : ''}`; element.hidden = false; toastTimer = setTimeout(() => {element.hidden = true;}, error ? 8000 : 5000); }

async function api(path, options = {}) {
  const method = options.method || 'GET';
  const headers = new Headers(options.headers || {});
  if (!['GET','HEAD'].includes(method)) {
    headers.set('X-Requested-With', 'Telederm');
    if (state.csrf) headers.set('X-CSRF-Token', state.csrf);
  }
  let body = options.body;
  if (body !== undefined && !(body instanceof FormData)) { headers.set('Content-Type','application/json'); body = JSON.stringify(body); }
  let response;
  try { response = await fetch(path, {...options, method, headers, body, credentials:'same-origin', cache:'no-store'}); }
  catch { throw new Error('Collegamento non disponibile. Controlla la connessione e riprova.'); }
  const data = response.status === 204 ? null : await response.json().catch(() => ({}));
  if (!response.ok) {
    if (response.status === 401 && path !== '/api/login') { state.user = null; state.csrf = null; clearTimeout(pollTimer); renderLogin(); }
    let message = typeof data.detail === 'string' ? data.detail : 'Operazione non riuscita. Riprova.';
    if (data.errors?.length) message += ' ' + data.errors.map(error => `${error.field}: ${error.message}`).join(' · ');
    const error = new Error(message); error.status = response.status; throw error;
  }
  return data;
}

function showDialog(title, content, className = '') {
  const dialog = $('#dialog'); if (dialog.open) dialog.close();
  dialog.className = className;
  dialog.innerHTML = `<div class="dialog-header"><h2 id="dialog-title">${esc(title)}</h2><button class="btn btn-ghost icon-button" type="button" data-close-dialog aria-label="Chiudi">${icon('close')}</button></div>${content}`;
  $('[data-close-dialog]', dialog).onclick = () => dialog.close();
  dialog.showModal();
  return dialog;
}

function renderLogin(message = '') {
  $('#app').innerHTML = `<main class="login-layout">
    <section class="login-story">${brand()}<div class="story-content"><div class="eyebrow">Teledermatologia, insieme</div><h1>Dalla tua foto,<br>al parere<br><em>del medico.</em></h1><p class="story-description">Uno spazio per inviare le immagini cliniche o dermatoscopiche, seguire il tuo caso e ricevere una valutazione validata dal medico.</p>
    <div class="story-steps"><div class="story-step"><span class="step-number">01</span><div><strong>Carica le tue immagini</strong><p>Accedi dal computer o dal tablet.</p></div></div><div class="story-step"><span class="step-number">02</span><div><strong>Il medico valuta il caso</strong><p>Le predizioni vengono revisionate prima della risposta.</p></div></div><div class="story-step"><span class="step-number">03</span><div><strong>Ritrova qui la valutazione</strong><p>La risposta resta nel tuo spazio personale.</p></div></div></div></div><div class="story-footer">PROGETTO PILOTA &nbsp; / &nbsp; TELEDERMATOLOGIA</div></section>
    <section class="login-form-side"><div class="login-card"><div class="eyebrow">Il tuo spazio personale</div><h2>Bentornato.</h2><p class="muted">Accedi con le credenziali ricevute dal referente del progetto.</p><form id="login-form"><div id="login-error" class="error" role="alert">${esc(message)}</div><div class="field"><label for="username">Nome utente</label><input id="username" name="username" autocomplete="username" minlength="3" maxlength="64" placeholder="Il tuo nome utente" required autocapitalize="none" spellcheck="false"></div><div class="field"><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" maxlength="256" placeholder="La tua password" required></div><button class="btn btn-primary full-width" type="submit">Accedi al tuo spazio ${icon('arrow')}</button></form><div class="login-help">Non hai ancora un account o hai dimenticato la password?<br>Rivolgiti al referente del progetto per ricevere assistenza.</div></div><div class="login-note">${icon('lock')}<span>Le immagini e i risultati sono accessibili solo all’account del paziente e ai medici autorizzati.</span></div></section></main>`;
  $('#login-form').onsubmit = async event => {
    event.preventDefault(); const form = event.currentTarget, button = $('button[type=submit]', form); button.disabled = true; $('#login-error').textContent = '';
    try { const data = await api('/api/login', {method:'POST', body:{username:form.username.value, password:form.password.value}}); state.user = data.user; state.csrf = data.csrf_token; state.catalog = null; state.reviewDrafts = {}; state.status = await api('/api/status'); state.filter = 'all'; state.offset = 0; location.hash = ''; await route(); }
    catch (error) { $('#login-error').textContent = error.message; button.disabled = false; }
  };
}

function shell(content, section = 'cases') {
  const user = state.user;
  const admin = user.role === 'admin';
  const navigationItems = admin
    ? `<a href="#accounts" class="nav-item ${section === 'accounts' ? 'active' : ''}">${icon('users')}Account</a><a href="#audit" class="nav-item ${section === 'audit' ? 'active' : ''}">${icon('list')}Registro attività</a>`
    : `<a href="#" class="nav-item ${section === 'cases' ? 'active' : ''}">${icon('folder')}${user.role === 'doctor' ? 'Casi ricevuti' : 'I miei casi'}</a>${user.role === 'doctor' ? `<a href="#quick" class="nav-item ${section === 'quick' ? 'active' : ''}">${icon('model')}Analisi rapide</a>` : ''}`;
  $('#app').innerHTML = `<header class="app-header">${brand()}<div class="header-right"><div class="user-chip"><span class="avatar">${esc(user.role === 'doctor' ? 'MD' : user.role === 'admin' ? 'AD' : user.username.slice(0,2).toUpperCase())}</span><div class="user-info"><div class="username">${esc(user.username)}</div><div class="role-label">${roleNames[user.role]}</div></div></div><span class="header-divider"></span><button class="btn btn-ghost icon-button" id="password-button" aria-label="Cambia password" title="Cambia password">${icon('key')}</button><button class="btn btn-ghost" id="logout-button">${icon('logout')}Esci</button></div></header>
  <div class="workspace"><nav class="sidebar" aria-label="Navigazione principale"><div class="nav-heading">${roleNames[user.role]}</div>${navigationItems}<button class="nav-item" id="help-button">${icon('help')}Come funziona</button><div class="sidebar-note"><strong><span class="status-led"></span>${state.status?.model === 'not_installed' ? 'Modello in preparazione' : 'Modello configurato'}</strong>Le valutazioni vengono pubblicate soltanto dopo la revisione del medico.</div></nav><main class="main-content" id="main-content">${content}</main></div>`;
  $('#logout-button').onclick = async () => { try { await api('/api/logout', {method:'POST'}); state.user = null; state.csrf = null; state.currentCase = null; state.catalog = null; state.reviewDrafts = {}; clearTimeout(pollTimer); location.hash = ''; renderLogin(); } catch(error) { toast(error.message,true); } };
  $('#password-button').onclick = passwordDialog;
  $('#help-button').onclick = helpDialog;
}

function footer() { return `<p class="footer-note">${icon('shield')}Progetto pilota · Il risultato del modello è preliminare fino alla validazione del medico.</p>`; }
function callout(title, message, info = false) { return `<div class="callout${info ? ' info' : ''}">${icon(info ? 'shield' : 'clock')}<div><strong>${esc(title)}</strong><p>${esc(message)}</p></div></div>`; }

async function route() {
  const currentNavigation = ++navigation; clearTimeout(pollTimer);
  window.scrollTo(0,0);
  if (!state.user) { renderLogin(); return; }
  const hash = location.hash.slice(1);
  try {
    if (state.user.role === 'admin') {
      if (hash === 'audit') { const [events,users] = await Promise.all([api(`/api/admin/audit?offset=${state.auditOffset}`),api('/api/admin/users')]); if (currentNavigation === navigation) renderAudit(events,users); }
      else { const users = await api('/api/admin/users'); if (currentNavigation === navigation) renderAccounts(users); }
    } else if (hash === 'new' && state.user.role === 'patient') { renderNewCase(); }
    else if (state.user.role === 'doctor' && hash === 'quick') {
      const data = await api(`/api/mobile-submissions?offset=${state.quickOffset}`);
      if (currentNavigation === navigation) renderQuickList(data);
    } else if (state.user.role === 'doctor' && hash.startsWith('quick/')) {
      const data = await api(`/api/mobile-submissions/${encodeURIComponent(hash.slice(6))}`);
      if (currentNavigation === navigation) renderQuickDetail(data);
    } else if (hash.startsWith('case/')) {
      if (state.user.role === 'doctor' && !state.catalog) state.catalog = (await api('/api/models')).models;
      const id = hash.slice(5); const data = await api(`/api/cases/${encodeURIComponent(id)}`);
      if (currentNavigation === navigation) { state.currentCase = data; renderCase(data); schedulePoll(data); }
    } else {
      const data = await api(`/api/cases?offset=${state.offset}`);
      if (currentNavigation === navigation) { state.cases = data; renderCases(); }
    }
  } catch (error) {
    if (error.status === 401 || !state.user) return;
    shell(`<div class="view-error"><h1>Non è stato possibile aprire questa pagina.</h1><p class="muted">${esc(error.message)}</p><a class="btn btn-secondary" href="#">Torna ai casi</a></div>`);
  }
}

function schedulePoll(data) {
  if (data.state !== 'queued') return;
  const id = data.id;
  pollTimer = setTimeout(async () => {
    if (!state.user || location.hash !== `#case/${id}`) return;
    try {
      const fresh = await api(`/api/cases/${id}`);
      if (location.hash !== `#case/${id}`) return;
      if (fresh.version !== state.currentCase.version) { state.currentCase = fresh; renderCase(fresh); }
      schedulePoll(fresh);
    } catch(error) { toast(error.message,true); }
  }, 4000);
}

function renderCases() {
  const doctor = state.user.role === 'doctor', data = state.cases, counts = data.counts || {};
  const count = key => counts[key] || 0;
  const total = Object.values(counts).reduce((a,b) => a+b,0);
  const stats = doctor ? [['Casi ricevuti',total],['In attesa di analisi',count('queued')+count('waiting_model')+count('analysis_failed')],['Da validare',count('awaiting_review')],['Risposte pubblicate',count('released')]] : [['I tuoi casi',total],['In preparazione',count('draft')+count('needs_images')],['In valutazione',count('queued')+count('waiting_model')+count('analysis_failed')+count('awaiting_review')],['Risposte disponibili',count('released')]];
  const filters = doctor ? [['all','Tutti'],['review','Da validare'],['inprogress','In attesa'],['released','Pubblicati']] : [['all','Tutti'],['draft','Da completare'],['inprogress','In valutazione'],['released','Risposte']];
  shell(`<div class="eyebrow">${doctor ? 'La tua area di lavoro' : 'Il tuo percorso, un passo alla volta'}</div><div class="page-title-row"><div><h1>${doctor ? 'Casi da seguire.' : 'Il tuo spazio di teledermatologia.'}</h1><p class="page-subtitle">${doctor ? 'Esamina le immagini, verifica classificazione e segmentazione e condividi la tua valutazione.' : 'Invia le immagini cliniche o dermatoscopiche e ritrova qui la risposta del medico.'}</p></div>${doctor ? `<button class="btn btn-secondary" id="refresh-list">${icon('refresh')}Aggiorna</button>` : `<a class="btn btn-primary" href="#new">${icon('plus')}Nuovo caso</a>`}</div><div class="stats">${stats.map(([label,value]) => `<div class="stat-card"><div class="stat-label">${esc(label)}</div><div class="stat-value">${value}</div></div>`).join('')}</div>
  <section class="section-panel"><div class="panel-heading"><h2>${doctor ? 'Casi ricevuti' : 'I tuoi casi'}</h2><span class="muted">${total} ${total === 1 ? 'caso' : 'casi'}</span></div><div class="filter-row"><div class="filters">${filters.map(([value,label]) => `<button class="filter-btn ${state.filter === value ? 'active' : ''}" data-filter="${value}" aria-pressed="${state.filter === value}">${label}</button>`).join('')}</div><div class="search-box">${icon('search')}<input id="case-search" type="search" aria-label="Cerca in questa pagina" placeholder="Cerca in questa pagina" value="${esc(state.search)}" maxlength="80"></div></div><div id="case-results"></div>${data.total > data.limit ? `<div class="pagination"><span>${data.offset+1}–${Math.min(data.offset+data.limit,data.total)} di ${data.total}</span><div class="button-row"><button class="btn btn-ghost btn-small" id="previous-page" ${data.offset === 0 ? 'disabled' : ''}>Precedenti</button><button class="btn btn-ghost btn-small" id="next-page" ${data.offset+data.limit >= data.total ? 'disabled' : ''}>Successivi</button></div></div>` : ''}</section>${footer()}`);
  $$('[data-filter]').forEach(button => button.onclick = () => { state.filter = button.dataset.filter; $$('[data-filter]').forEach(item => {const selected = item.dataset.filter === state.filter; item.classList.toggle('active', selected); item.setAttribute('aria-pressed',String(selected));}); filterCases(); });
  $('#case-search').oninput = event => {state.search = event.target.value; filterCases();};
  if ($('#refresh-list')) $('#refresh-list').onclick = route;
  if ($('#previous-page')) $('#previous-page').onclick = () => {state.offset = Math.max(0,state.offset-data.limit); route();};
  if ($('#next-page')) $('#next-page').onclick = () => {state.offset += data.limit; route();};
  filterCases();
}

function filterCases() {
  const doctor = state.user.role === 'doctor', query = state.search.toLowerCase();
  const items = state.cases.items.filter(item => {
    const included = state.filter === 'all' || (state.filter === 'draft' && ['draft','needs_images'].includes(item.state)) || (state.filter === 'review' && item.state === 'awaiting_review') || (state.filter === 'inprogress' && ['queued','waiting_model','analysis_failed',...(doctor ? [] : ['awaiting_review'])].includes(item.state)) || (state.filter === 'released' && item.state === 'released');
    return included && [item.code,item.body_site,item.patient_code || ''].join(' ').toLowerCase().includes(query);
  });
  if (!items.length) { $('#case-results').innerHTML = `<div class="empty"><div class="empty-icon">${icon('folder')}</div><h3>${state.cases.items.length ? 'Nessun caso in questa vista' : doctor ? 'I nuovi casi arriveranno qui' : 'Il primo passo parte da una foto'}</h3><p>${state.cases.items.length ? 'Prova a cambiare filtro o ricerca.' : doctor ? 'Quando un paziente invia le immagini, il caso sarà disponibile per la valutazione.' : 'Crea un caso, aggiungi le immagini cliniche o dermatoscopiche e inviale per la valutazione.'}</p>${!doctor && !state.cases.items.length ? `<a class="btn btn-primary" href="#new">${icon('plus')}Crea il tuo primo caso</a>` : ''}</div>`; return; }
  $('#case-results').innerHTML = `<div class="table-wrap"><table><thead><tr><th>Caso</th>${doctor ? '<th>Paziente</th>' : ''}<th>Stato</th><th class="hide-mobile">Immagini</th><th class="hide-mobile">Aggiornato</th><th><span class="visually-hidden">Apri caso</span></th></tr></thead><tbody>${items.map(item => `<tr><td><a class="case-link" href="#case/${item.id}"><strong>${esc(item.code)}</strong><span>${esc(item.body_site || 'Sede non indicata')}</span></a></td>${doctor ? `<td>${esc(item.patient_code)}</td>` : ''}<td>${pill(item.state)}</td><td class="hide-mobile">${item.image_count} ${item.image_count === 1 ? 'foto' : 'foto'}</td><td class="hide-mobile muted">${date(item.updated_at)}</td><td><a class="btn btn-ghost btn-small" href="#case/${item.id}" aria-label="Apri ${esc(item.code)}">${icon('arrow')}</a></td></tr>`).join('')}</tbody></table></div>`;
}


function quickWarning() {
  return callout('Solo area medico', 'Analisi sperimentale per ricerca: non è una diagnosi clinica validata e non viene comunicata al paziente.', true);
}
function quickMode(mode) { return mode === 'clinical' ? 'Foto clinica' : 'Dermatoscopica'; }
function quickState(value) { return `<span class="pill ${esc(value)}">${esc(runNames[value] || value)}</span>`; }
function score(value) { return (Number(value)*100).toLocaleString('it-IT',{maximumFractionDigits:1})+'%'; }

function renderQuickList(data) {
  const rows = data.items.map(item => `<tr><td><a class="case-link" href="#quick/${encodeURIComponent(item.submission_id)}"><strong>${esc(item.case_code)}</strong></a></td><td>${quickMode(item.mode)}</td><td>${esc(item.model_id)}</td><td>${quickState(item.state)}</td><td>${date(item.received_at,true)}</td><td>${item.top_label ? `${esc(item.top_label.label)} · ${score(item.top_label.score)}` : '—'}</td></tr>`).join('');
  shell(`<div class="eyebrow">La tua area di lavoro</div><div class="page-title-row"><div><h1>Analisi rapide.</h1><p class="page-subtitle">Invii effettuati dall’app con il tuo account medico, consultabili in sola lettura.</p></div><button class="btn btn-secondary" id="refresh-quick">${icon('refresh')}Aggiorna</button></div>${quickWarning()}<section class="section-panel">${rows ? `<div class="table-wrap"><table><thead><tr><th>Codice caso</th><th>Modalità</th><th>Modello</th><th>Stato</th><th>Data</th><th>Etichetta principale</th></tr></thead><tbody>${rows}</tbody></table></div>` : '<div class="empty"><div class="empty-icon">'+icon('model')+'</div><h3>Nessuna analisi rapida</h3><p>Gli invii rapidi si effettuano dall’app. Accedi con questo stesso account medico per ritrovarli qui.</p></div>'}<div class="pagination"><span>${data.total} invii · fino a 50 per pagina</span><div class="button-row"><button class="btn btn-ghost btn-small" id="quick-previous" ${data.offset === 0 ? 'disabled' : ''}>Precedenti</button><button class="btn btn-ghost btn-small" id="quick-next" ${data.offset+data.limit >= data.total ? 'disabled' : ''}>Successivi</button></div></div></section>`, 'quick');
  $('#refresh-quick').onclick = route;
  $('#quick-previous').onclick = () => {state.quickOffset = Math.max(0,state.quickOffset-data.limit); route();};
  $('#quick-next').onclick = () => {state.quickOffset += data.limit; route();};
}

function renderQuickDetail(data) {
  const result = data.state === 'completed' ? data.result : null;
  const artifacts = result?.artifacts || {};
  const failures = {model_unavailable:'Il modello richiesto non è disponibile sul server.', inference_error:'Il server non ha completato l’elaborazione dell’immagine.'};
  let notice = '';
  if (['queued','running'].includes(data.state)) notice = callout(runNames[data.state], 'L’invio è salvato. Premi Aggiorna per verificare il completamento.');
  if (data.state === 'failed') notice = callout('Analisi non completata', `${failures[data.failure_code] || 'L’elaborazione non è riuscita.'} Codice: ${data.failure_code || 'non disponibile'}. Per una nuova analisi effettua un nuovo invio dall’app.`);
  let images = '', classification = '';
  if (result) {
    const stage = overlay => `<div class="image-stage"><img src="${esc(artifacts.normalized_image)}" alt="Immagine normalizzata">${overlay ? `<img class="overlay" src="${esc(overlay)}" alt="Mappa sovrapposta">` : ''}</div>`;
    const card = (title, body) => `<section class="section-panel"><div class="panel-heading"><h2>${esc(title)}</h2></div><div class="panel-body">${body}</div></section>`;
    if (artifacts.normalized_image) images += card('Immagine normalizzata', stage());
    if (artifacts.heatmap) images += card('Mappa Grad-CAM', `<div class="image-stage"><img src="${esc(artifacts.heatmap)}" alt="Mappa Grad-CAM"></div><p class="field-help">Spiegazione relativa alla classe ${esc(result.explanation?.target_class || 'selezionata')}. Non è una segmentazione né una probabilità per pixel.</p>`);
    if (artifacts.heatmap_overlay && artifacts.normalized_image) images += card('Grad-CAM sull’immagine', stage(artifacts.heatmap_overlay));
    if (result.segmentation?.available) {
      if (artifacts.segmentation_mask) images += card('Maschera di segmentazione FTN', `<div class="image-stage"><img src="${esc(artifacts.segmentation_mask)}" alt="Maschera di segmentazione FTN"></div>`);
      if (artifacts.segmentation_overlay && artifacts.normalized_image) images += card('Segmentazione FTN sull’immagine', stage(artifacts.segmentation_overlay));
    }
    const labels = result.classification?.labels || [];
    classification = card('Classificazione sperimentale', labels.map(item => `<div class="score-row"><div class="score-label"><strong>${esc(item.label)}</strong><span>${score(item.score)}</span></div><progress max="1" value="${Number(item.score)}" aria-label="Punteggio di ${esc(item.label)}"></progress></div>`).join('')+`<p class="model-version">${esc(result.classification?.model_name)} · versione ${esc(result.classification?.model_version)}</p><p class="field-help">${result.segmentation?.available ? 'Segmentazione ottenuta dal modello FTN separato.' : 'Questo modello produce classificazione, senza segmentazione.'} ${result.explanation?.status === 'no_positive_signal' ? 'Grad-CAM senza segnale positivo: non indica assenza di lesione.' : !artifacts.heatmap ? 'Mappa Grad-CAM non disponibile per questo invio.' : ''}</p>`);
  }
  shell(`<a class="back-link" href="#quick">${icon('back')}Analisi rapide</a><div class="page-title-row"><div><h1>${esc(data.case_code)}</h1><p class="detail-meta">${quickMode(data.mode)} · ${esc(data.model_id)} · ${date(data.received_at,true)}</p>${quickState(data.state)}</div><button class="btn btn-secondary" id="refresh-quick">${icon('refresh')}Aggiorna</button></div>${quickWarning()}${notice}<div class="detail-layout"><div class="detail-column">${images}</div><aside class="detail-column">${classification}</aside></div>`, 'quick');
  $('#refresh-quick').onclick = route;
}

function renderNewCase() {
  shell(`<a class="back-link" href="#">${icon('back')}I miei casi</a><div class="eyebrow">Un nuovo invio</div><div class="page-title-row"><div><h1>Iniziamo dalle immagini.</h1><p class="page-subtitle">Dedica un caso a una sola lesione. Puoi aggiungere fino a quattro immagini della stessa sede.</p></div></div><div class="form-grid"><section class="section-panel"><div class="panel-heading"><h2>Il tuo nuovo caso</h2><span class="muted">1 di 2 · Preparazione</span></div><div class="panel-body"><form id="new-case-form"><div class="error" id="new-case-error" role="alert"></div><div class="field"><label for="acquisition-mode">Modalità di acquisizione</label><select id="acquisition-mode" name="mode" required>${modeOptions(null)}</select><p class="field-help">Foto da smartphone, anche macro: clinica. Smartphone con adattatore dermatoscopico: dermatoscopica. Tutte le foto del caso devono avere la stessa modalità.</p></div><div class="field"><label for="body-site">Dove si trova la lesione? <span class="muted small">Facoltativo</span></label><input id="body-site" name="body_site" maxlength="80" placeholder="Es. avambraccio sinistro" autocomplete="off"></div><div class="field"><label for="case-notes">Vuoi aggiungere una nota? <span class="muted small">Facoltativo</span></label><textarea id="case-notes" name="notes" maxlength="4000" placeholder="Aggiungi le informazioni che vuoi condividere con il medico."></textarea><p class="field-help">Nelle prove evita nomi, date di nascita e altri dati personali.</p></div><div class="field"><label>Immagini</label><label class="upload-area" for="new-photos" tabindex="0">${icon('upload')}<strong>Scegli le foto dal dispositivo</strong><span>JPEG, PNG, WebP, HEIC/HEIF · fino a ${esc(state.status?.max_upload_mb ?? 40)} MiB per foto · massimo 4 foto</span></label><input class="visually-hidden" type="file" id="new-photos" name="photos" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" multiple required><div class="selected-files" id="selected-files"></div></div><label class="check-label"><input type="checkbox" name="demo_confirmed" required><span>Confermo che questo invio contiene soltanto immagini sintetiche e dati di prova.</span></label><div class="form-actions"><a class="btn btn-ghost" href="#">Annulla</a><button class="btn btn-primary" type="submit">Salva e controlla le foto ${icon('arrow')}</button></div></form></div></section><aside class="guide-card"><h3>Come prosegue il caso</h3><ol class="guide-list"><li><span class="step-number">1</span><div><strong>Prepara le foto</strong>Una macro senza adattatore è clinica; con adattatore dermatoscopico scegli dermatoscopica.</div></li><li><span class="step-number">2</span><div><strong>Controlla e invia</strong>Nella schermata successiva puoi verificare le foto prima dell’invio.</div></li><li><span class="step-number">3</span><div><strong>Attendi il medico</strong>La classificazione sarà visibile dopo la validazione medica.</div></li></ol></aside></div>${footer()}`);
  $('#new-photos').onchange = event => { $('#selected-files').textContent = [...event.target.files].map(file => file.name).join(' · '); };
  wireUploadArea($('.upload-area'),$('#new-photos'));
  $('#new-case-form').onsubmit = createCase;
}

function validateFiles(files, remaining = 4) {
  if (!files.length) throw new Error('Seleziona almeno una foto.');
  if (files.length > remaining) throw new Error(`Puoi aggiungere ancora ${remaining} ${remaining === 1 ? 'foto' : 'foto'}.`);
  if (files.some(file => file.size > (state.status?.max_upload_mb ?? 40)*1024*1024)) throw new Error(`Ogni foto deve essere al massimo di ${state.status?.max_upload_mb ?? 40} MiB.`);
}
async function sendFiles(data, files) {
  let current = data;
  for (let index = 0; index < files.length; index++) {
    toast(`Caricamento foto ${index+1} di ${files.length}…`);
    const form = new FormData(); form.set('expected_version',String(current.version)); form.set('file',files[index]);
    current = await api(`/api/cases/${current.id}/images`,{method:'POST',body:form}); state.currentCase = current;
  }
  return current;
}
async function createCase(event) {
  event.preventDefault(); const form = event.currentTarget, button = $('button[type=submit]',form), errorElement = $('#new-case-error'); let created;
  try {
    const files = [...form.photos.files]; validateFiles(files); button.disabled = true; errorElement.textContent = '';
    created = await api('/api/cases',{method:'POST',body:{mode:form.elements.mode.value,body_site:form.body_site.value,notes:form.notes.value,demo_confirmed:form.demo_confirmed.checked}});
    state.currentCase = created; await sendFiles(created,files); state.offset = 0; state.filter = 'all'; state.search = ''; location.hash = `case/${created.id}`; toast('Foto salvate. Controllale e invia il caso quando sei pronto.');
  } catch(error) {
    if (created) {location.hash = `case/${created.id}`; toast(`Caso salvato. ${error.message}`,true);}
    else { errorElement.textContent = error.message; button.disabled = false; }
  }
}

function wireUploadArea(area, input) {
  if (!area || !input) return;
  area.onkeydown = event => {if (['Enter',' '].includes(event.key)) {event.preventDefault(); input.click();}};
  area.ondragover = event => {event.preventDefault(); area.classList.add('dragging');};
  area.ondragleave = () => area.classList.remove('dragging');
  area.ondrop = event => {event.preventDefault(); area.classList.remove('dragging'); if(event.dataTransfer.files.length) {input.files = event.dataTransfer.files; input.dispatchEvent(new Event('change'));}};
}

function flow(data) {
  const index = {draft:0,needs_images:0,queued:2,waiting_model:2,analysis_failed:2,awaiting_review:3,released:4}[data.state];
  const steps = ['Preparazione','Invio delle foto','Analisi','Valutazione medica'];
  return `<div class="flow" aria-label="Avanzamento del caso">${steps.map((label,i) => `<div class="flow-item ${i < index ? 'done' : i === index ? 'current' : ''}"><span class="flow-icon">${i < index ? '✓' : i+1}</span><span>${label}</span></div>`).join('')}</div>`;
}

function caseMode(mode) { return mode === 'clinical' ? 'Foto clinica' : mode === 'dermoscopic' ? 'Dermatoscopica' : 'Modalità da confermare'; }
function modeOptions(mode) { return `<option value="" ${!mode ? 'selected' : ''}>Seleziona la modalità</option><option value="clinical" ${mode === 'clinical' ? 'selected' : ''}>Foto clinica da smartphone, anche macro</option><option value="dermoscopic" ${mode === 'dermoscopic' ? 'selected' : ''}>Immagine dermatoscopica, anche con adattatore</option>`; }
function acquisitionPanel(data) { return `<div class="field"><label for="case-mode">Modalità di tutte le immagini del caso</label><select id="case-mode">${modeOptions(data.mode)}</select><button type="button" class="btn btn-secondary btn-small" id="set-case-mode">Conferma modalità</button><p class="field-help">Prima dell’invio conferma clinical per foto senza dermatoscopio e dermoscopic per acquisizione con dermatoscopio/adattatore.</p></div>`; }
function analysisControls(data,run) { return `<form id="analysis-form"><div class="field"><label for="analysis-mode">Modalità di acquisizione confermata</label><select id="analysis-mode" name="mode" required>${modeOptions(data.mode)}</select></div><div class="field"><label for="analysis-model">Modello</label><select id="analysis-model" name="model_id" required></select></div><div class="field"><label for="analysis-target">Classe da spiegare con Grad-CAM</label><select id="analysis-target" name="explanation_target"></select></div><p class="field-help">Una nuova analisi resta riservata al medico fino alla pubblicazione. La modalità va confermata dai dati di acquisizione, senza dedurla dalla foto.</p><button class="btn btn-secondary full-width btn-small" type="submit">${icon('refresh')}Analizza / genera Grad-CAM</button></form>`; }
function wireAnalysisControls(data,run) {
  const form = $('#analysis-form'); if (!form) return;
  const populateTargets = () => {
    const model = (state.catalog || []).find(item => item.id === form.elements.model_id.value);
    form.elements.explanation_target.innerHTML = `<option value="">Classe predetta per ogni foto</option>`+(model?.classes || []).map(label => `<option value="${esc(label)}" ${label === run?.explanation_target ? 'selected' : ''}>${esc(label)}</option>`).join('');
  };
  const populateModels = () => {
    const models = (state.catalog || []).filter(item => item.mode === form.elements.mode.value);
    const selected = models.find(item => item.id === run?.model_id)?.id || models.find(item => item.default)?.id;
    form.elements.model_id.innerHTML = models.map(item => `<option value="${esc(item.id)}" ${item.id === selected ? 'selected' : ''}>${esc(item.name)}${!item.available ? ' · non installato' : ''}</option>`).join('');
    populateTargets();
  };
  form.elements.mode.onchange = populateModels; form.elements.model_id.onchange = populateTargets; populateModels();
  form.onsubmit = async event => {
    event.preventDefault(); const button = $('button[type=submit]',form); button.disabled = true;
    const body = {expected_version:data.version,mode:form.elements.mode.value,model_id:form.elements.model_id.value};
    if (form.elements.explanation_target.value) body.explanation_target = form.elements.explanation_target.value;
    try {delete state.reviewDrafts[data.id]; state.currentCase = await api(`/api/cases/${data.id}/reanalyze`,{method:'POST',body}); renderCase(state.currentCase); schedulePoll(state.currentCase); toast('Analisi richiesta con modalità e modello selezionati.');}
    catch(error) {toast(error.message,true); button.disabled = false;}
  };
}

function gallery(data, segmentations, explanations) {
  const editable = state.user.role === 'patient' && data.state === 'draft';
  return data.images.length ? `<div class="image-grid${data.images.length === 1 ? ' single-image' : ''}">${data.images.map((image,index) => {
    const segmentation = segmentations.find(item => item.image_id === image.id && item.overlay_url);
    const explanation = explanations.find(item => item.image_id === image.id);
    return `<article class="image-card"><button class="image-stage" data-view-image="${image.id}" aria-label="Ingrandisci foto ${index+1}"><img src="${esc(image.url)}" alt="Foto ${index+1}" loading="lazy">${explanation ? `<img class="overlay" id="cam-overlay-${image.id}" src="${esc(explanation.overlay_url)}" alt="Grad-CAM per ${esc(explanation.target_class)}" hidden>` : ''}${segmentation ? `<img class="overlay" id="overlay-${image.id}" src="${esc(segmentation.overlay_url)}" alt="Segmentazione della foto ${index+1}" hidden>` : ''}</button><div class="image-caption"><strong>Foto ${String(index+1).padStart(2,'0')}</strong><span>${image.width} × ${image.height} px</span></div>${segmentation || explanation || editable ? `<div class="image-tools">${explanation ? `<label class="check-label"><input type="checkbox" data-cam-overlay="${image.id}"><span>Grad-CAM · ${esc(explanation.target_class)}</span></label><button type="button" class="btn btn-ghost btn-small" data-view-cam="${image.id}">Apri Grad-CAM</button><a class="btn btn-ghost btn-small" href="${esc(explanation.composite_url)}" download="gradcam-${image.id}.png">Scarica foto con mappa</a>` : ''}${segmentation ? `<label class="check-label"><input type="checkbox" data-overlay="${image.id}"><span>Mostra segmentazione</span></label>` : ''}${editable ? `<button type="button" class="btn btn-ghost btn-small" data-remove-image="${image.id}">Rimuovi</button>` : ''}</div>` : ''}</article>`;
  }).join('')}</div>` : '<p class="muted small">Non hai ancora aggiunto immagini.</p>';
}

function renderCase(data) {
  const doctor = state.user.role === 'doctor', editable = !doctor && ['draft','needs_images'].includes(data.state);
  const latest = doctor ? data.analyses[0] : null;
  const segments = doctor ? latest?.images || [] : data.published_segmentations || [];
  const explanations = doctor ? (latest?.images || []).filter(item => item.heatmap_overlay_url && item.heatmap_composite_url).map(item => ({image_id:item.image_id,target_class:item.explanation.target_class,status:item.explanation.status,overlay_url:item.heatmap_overlay_url,heatmap_url:item.heatmap_url,composite_url:item.heatmap_composite_url})) : data.published_explanations || [];
  const lastReview = data.reviews.at(-1);
  let notice = '';
  if (data.state === 'waiting_model') notice = callout('Il caso è salvato. Il modello è in preparazione.',doctor ? 'Le immagini sono disponibili. Classificazione e segmentazione saranno eseguite quando il modello verrà collegato.' : 'In questa fase di prova il modello non è ancora disponibile. Il caso resta in attesa e non viene generata alcuna classificazione.');
  if (data.state === 'queued') notice = callout('Le immagini sono state inviate.','Il caso è nella coda di elaborazione. Questa pagina si aggiorna automaticamente.');
  if (data.state === 'analysis_failed') notice = callout('L’analisi non è stata completata.',doctor ? 'Verifica la disponibilità del modello e ripeti l’analisi. Nessun risultato è stato pubblicato.' : 'Le foto sono salvate. Il servizio deve completare l’elaborazione prima della valutazione.');
  if (data.state === 'awaiting_review' && !doctor) notice = callout('Il tuo caso è in valutazione.','Il medico sta verificando i risultati. La classificazione sarà disponibile qui dopo la validazione.',true);
  if (data.state === 'needs_images' && lastReview) notice = callout('Il medico ha richiesto altre immagini.',lastReview.patient_message,true);
  let right = '';
  if (doctor) {
    right = modelPanel(data,latest);
    if (['waiting_model','analysis_failed','awaiting_review'].includes(data.state)) right += reviewPanel(data,latest);
  } else if (data.state === 'released' && lastReview) {
    right = `<section class="report-card"><div class="report-status">${icon('shield')}Validato dal medico</div><div class="eyebrow">Classificazione comunicata</div><h2 class="report-label">${esc(lastReview.final_label)}</h2><p class="report-message">${esc(lastReview.patient_message)}</p><div class="report-signature">Valutazione di ${esc(lastReview.doctor)}<br>${date(lastReview.created_at,true)}</div></section>`;
  } else if (editable) {
    right = `<section class="submit-panel"><div class="eyebrow">L’ultimo passo prima dell’invio</div><h2>Le foto sono pronte?</h2><p>Controlla le immagini e invia il caso. Dopo l’invio le foto restano disponibili per l’analisi e la revisione medica.</p><button id="submit-case" class="btn btn-primary" ${!data.images.length || !data.mode ? 'disabled' : ''}>Invia al servizio ${icon('arrow')}</button><p class="field-help">Riceverai la risposta in questo spazio dopo la validazione del medico.</p></section>`;
  } else {
    right = `<section class="section-panel"><div class="panel-body"><div class="model-empty">${icon('clock')}<h3>Ti aggiorneremo qui.</h3><p>Puoi tornare nel tuo spazio per seguire lo stato del caso e leggere la risposta del medico.</p><button id="refresh-case" class="btn btn-secondary btn-small">${icon('refresh')}Aggiorna lo stato</button></div></div></section>`;
  }
  const history = data.reviews.length ? `<section class="section-panel"><div class="panel-heading"><h2>Comunicazioni del medico</h2></div><div class="panel-body">${[...data.reviews].reverse().map(review => `<article class="history-item"><small>${date(review.created_at,true)} · ${esc(review.doctor)}${review.decision === 'needs_images' ? ' · Richiesta di immagini' : ' · Valutazione pubblicata'}</small>${review.final_label ? `<h3>${esc(review.final_label)}</h3>` : ''}<p>${esc(review.patient_message)}</p></article>`).join('')}</div></section>` : '';
  shell(`<a class="back-link" href="#">${icon('back')}${doctor ? 'Casi ricevuti' : 'I miei casi'}</a><div class="detail-heading"><h1>${esc(data.code)}</h1>${pill(data.state)}</div><p class="detail-meta">Creato il ${date(data.created_at)}${doctor ? ` · Paziente ${esc(data.patient_code)}` : ''} · ${esc(data.body_site || 'Sede non indicata')} · ${esc(caseMode(data.mode))}</p>${flow(data)}<div class="detail-layout"><div class="detail-column">${notice}<section class="section-panel"><div class="panel-heading"><h2>Immagini del caso</h2><span class="muted">${data.images.length} / 4 foto</span></div><div class="panel-body">${gallery(data,segments,explanations)}${editable ? acquisitionPanel(data) : ''}${editable && data.images.length < 4 ? `<label class="upload-area" for="add-photos" tabindex="0">${icon('upload')}<strong>Aggiungi ${data.images.length ? 'altre foto' : 'le foto'}</strong><span>JPEG, PNG, WebP, HEIC/HEIF · fino a ${esc(state.status?.max_upload_mb ?? 40)} MiB per foto</span></label><input id="add-photos" class="visually-hidden" type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif" multiple>` : ''}${explanations.length ? `<p class="image-help">Grad-CAM è una mappa sperimentale riferita alla classe indicata; non è il contorno della lesione né una misura del rischio.${!doctor ? ' La condivisione è stata autorizzata dal medico.' : ''}</p>` : ''}${segments.some(item => item.overlay_url) ? `<p class="image-help">${doctor ? 'La maschera evidenzia l’area segmentata dal modello. Valuta il contorno insieme all’immagine originale.' : 'La segmentazione è stata condivisa dal medico. La classificazione valida è quella riportata nella risposta.'}</p>` : ''}</div></section>${data.notes ? `<section class="section-panel"><div class="panel-heading"><h2>Nota del paziente</h2></div><div class="panel-body"><p class="notes">${esc(data.notes)}</p></div></section>` : ''}${history}</div><aside class="detail-column">${right}</aside></div>${footer()}`);
  const toggleMap = (input, id, cam) => {
    const other = $(cam ? `[data-overlay="${id}"]` : `[data-cam-overlay="${id}"]`);
    if (input.checked && other) {other.checked = false; $(`#${cam ? 'overlay-' : 'cam-overlay-'}${id}`).hidden = true;}
    $(`#${cam ? 'cam-overlay-' : 'overlay-'}${id}`).hidden = !input.checked;
  };
  $$('[data-overlay]').forEach(input => input.onchange = () => toggleMap(input,input.dataset.overlay,false));
  $$('[data-cam-overlay]').forEach(input => input.onchange = () => toggleMap(input,input.dataset.camOverlay,true));
  $$('[data-view-cam]').forEach(button => button.onclick = () => {
    const item = explanations.find(value => value.image_id === button.dataset.viewCam);
    showDialog(`Grad-CAM · ${item.target_class}`,`<p class="field-help">Mappa sperimentale della classe ${esc(item.target_class)}. Non è una segmentazione né una misura del rischio.${item.status === 'no_positive_signal' ? ' Nessun segnale positivo: non equivale ad assenza di lesione.' : ''}</p><figure><img src="${esc(item.composite_url)}" alt="Foto con Grad-CAM per ${esc(item.target_class)}"><figcaption>Foto con sovrapposizione</figcaption></figure><figure><img src="${esc(item.heatmap_url)}" alt="Intensità Grad-CAM"><figcaption>Intensità relativa, normalizzata per questa immagine</figcaption></figure>`,'image-dialog');
  });
  if ($('#set-case-mode')) $('#set-case-mode').onclick = async event => {
    event.currentTarget.disabled = true;
    try {state.currentCase = await api(`/api/cases/${data.id}/acquisition`,{method:'PATCH',body:{expected_version:data.version,mode:$('#case-mode').value}}); renderCase(state.currentCase); toast('Modalità confermata.');}
    catch(error) {toast(error.message,true); event.currentTarget.disabled = false;}
  };
  $$('[data-view-image]').forEach(button => button.onclick = () => {
    const image = data.images.find(item => item.id === button.dataset.viewImage), index = data.images.indexOf(image)+1;
    showDialog(`Foto ${index} · ${data.code}`,`<img src="${esc(image.url)}" alt="Immagine ingrandita">`,'image-dialog');
  });
  $$('[data-remove-image]').forEach(button => button.onclick = async () => {
    button.disabled = true;
    try {state.currentCase = await api(`/api/cases/${data.id}/images/${button.dataset.removeImage}`,{method:'DELETE',body:{expected_version:data.version}}); renderCase(state.currentCase); toast('Foto rimossa dalla bozza.');}
    catch(error) {toast(error.message,true); button.disabled = false; if (error.status === 409) await route();}
  });
  if ($('#add-photos')) {
    const input = $('#add-photos'); wireUploadArea($('.upload-area'),input);
    input.onchange = async () => {
      try {const files = [...input.files]; if (!files.length) return; validateFiles(files,4-data.images.length); $$('button',$('#main-content')).forEach(button => button.disabled = true); state.currentCase = await sendFiles(data,files); renderCase(state.currentCase); toast('Immagini aggiunte.');}
      catch(error) {toast(error.message,true); await route();}
    };
  }
  if ($('#submit-case')) $('#submit-case').onclick = async event => {
    event.currentTarget.disabled = true;
    try {state.currentCase = await api(`/api/cases/${data.id}/submit`,{method:'POST',body:{expected_version:data.version}}); renderCase(state.currentCase); schedulePoll(state.currentCase); toast('Caso inviato.');}
    catch(error) {toast(error.message,true); await route();}
  };
  if ($('#refresh-case')) $('#refresh-case').onclick = route;
  wireAnalysisControls(data,latest);
  if ($('#review-form')) wireReview(data,latest);
}

function modelPanel(data,run) {
  let body;
  if (run?.state === 'completed') {
    body = `<p class="field-help">Punteggi preliminari del modello, da interpretare e validare.</p>${run.images.map((item,index) => `<div class="prediction-group"><div class="prediction-title">Foto ${index+1} · Classificazione</div>${item.classification.labels.map(label => `<div class="score-row"><div class="score-label"><strong>${esc(label.label)}</strong><span>${(label.score*100).toLocaleString('it-IT',{maximumFractionDigits:1})}%</span></div><progress max="1" value="${Number(label.score)}" aria-label="Punteggio di ${esc(label.label)}"></progress></div>`).join('')}<p class="model-version">${esc(item.classification.model_name)} · versione ${esc(item.classification.model_version)}</p><p class="field-help">${item.heatmap_url ? `Grad-CAM per ${esc(item.explanation.target_class)} · ${esc(item.explanation.status)}. Usa i controlli sulla foto per esaminarla.` : 'Grad-CAM non disponibile in questa analisi storica.'} ${item.segmentation_available ? 'Segmentazione FTN separata disponibile.' : 'Nessuna segmentazione disponibile.'}</p></div>`).join('')}`;
  } else {
    body = `<div class="model-empty">${icon('model')}<h3>${esc(runNames[run?.state] || 'Nessuna analisi disponibile')}</h3><p>${run?.state === 'waiting_model' ? 'Il modello di classificazione e segmentazione non è ancora collegato. Non sono presenti predizioni.' : run?.state === 'failed' ? 'Controllare l’integrazione del modello prima di riprovare.' : 'L’elaborazione viene eseguita dalla coda delle richieste.'}</p></div>`;
  }
  if (!data.mode || (run && !run.mode)) body += callout('Modalità da confermare','Lo storico non dichiara l’acquisizione. Conferma la modalità e ripeti l’analisi prima di pubblicare una nuova valutazione.');
  if (['waiting_model','analysis_failed','awaiting_review','released'].includes(data.state)) body += analysisControls(data,run);
  return `<section class="section-panel"><div class="panel-heading"><h2>Analisi del modello</h2><span class="muted">Solo area medico</span></div><div class="panel-body">${body}</div></section>`;
}

function reviewPanel(data,run) {
  const canValidate = data.state === 'awaiting_review' && run?.state === 'completed' && data.mode && run.mode === data.mode && run.model_id;
  const canRequest = data.images.length < 4;
  if (!canValidate && !canRequest) return '';
  const topLabel = canValidate ? run.images[0].classification.labels[0].label : '';
  return `<section class="section-panel"><div class="panel-heading"><h2>La tua valutazione</h2></div><div class="panel-body"><form class="review-form" id="review-form"><div class="error" id="review-error" role="alert"></div><div class="field"><label for="review-decision">Come vuoi procedere?</label><select id="review-decision" name="decision">${canValidate ? '<option value="approved">Conferma classificazione</option><option value="corrected">Correggi classificazione</option>' : ''}${canRequest ? '<option value="needs_images">Richiedi nuove foto</option>' : ''}</select></div><div class="field" id="final-label-field" ${!canValidate ? 'hidden' : ''}><label for="final-label">Classificazione da comunicare</label><input id="final-label" name="final_label" maxlength="160" value="${esc(topLabel)}" ${canValidate ? 'required' : ''} list="suggested-labels"><datalist id="suggested-labels">${canValidate ? [...new Set(run.images.flatMap(item => item.classification.labels.map(label => label.label)))].map(label => `<option value="${esc(label)}"></option>`).join('') : ''}</datalist></div><div class="field"><label for="patient-message">Messaggio per il paziente</label><textarea id="patient-message" name="patient_message" required minlength="10" maxlength="5000" placeholder="Scrivi la valutazione o specifica quali nuove immagini sono necessarie."></textarea></div><div id="share-segmentation-field" ${!canValidate ? 'hidden' : ''}><label class="check-label"><input type="checkbox" name="share_segmentation" ${!run?.images.every(item => item.segmentation_available) ? 'disabled' : ''}><span>Condividi con il paziente anche la segmentazione.</span></label></div><div id="share-explanation-field" ${!canValidate ? 'hidden' : ''}><label class="check-label"><input type="checkbox" name="share_explanation"><span>Condividi la mappa Grad-CAM con il paziente.</span></label><p class="field-help" id="explanation-sharing-help"></p><button class="btn btn-secondary btn-small" id="prepare-explanation" type="button">Genera Grad-CAM per la classe finale</button></div><p class="field-help">Il testo e la classificazione saranno visibili al paziente dopo la pubblicazione.</p><button class="btn btn-primary full-width" type="submit">Controlla e pubblica ${icon('arrow')}</button></form></div></section>`;
}

function wireReview(data,run) {
  const form = $('#review-form');
  const draft = state.reviewDrafts[data.id];
  if (draft) {form.elements.decision.value = draft.decision; form.elements.final_label.value = draft.final_label; form.elements.patient_message.value = draft.patient_message;}
  const updateSharing = () => {
    const label = form.elements.final_label.value;
    const ready = run?.images.length && run.images.every(item => item.heatmap_composite_url && item.explanation?.target_class === label && ['available','no_positive_signal'].includes(item.explanation?.status));
    const checkbox = form.elements.share_explanation;
    checkbox.disabled = !ready || form.elements.decision.value === 'needs_images';
    if (checkbox.disabled) checkbox.checked = false;
    $('#explanation-sharing-help').textContent = ready ? `La mappa di tutte le foto si riferisce alla classe ${label}. Esaminala prima di autorizzare la condivisione.` : 'Per condividere Grad-CAM occorre prima generare e verificare le mappe per la classe finale su tutte le foto.';
    $('#prepare-explanation').hidden = Boolean(ready);
  };
  if ($('#prepare-explanation')) $('#prepare-explanation').onclick = async event => {
    event.currentTarget.disabled = true;
    state.reviewDrafts[data.id] = {decision:form.elements.decision.value,final_label:form.elements.final_label.value,patient_message:form.elements.patient_message.value};
    try {state.currentCase = await api(`/api/cases/${data.id}/reanalyze`,{method:'POST',body:{expected_version:data.version,mode:data.mode,model_id:run.model_id,explanation_target:form.elements.final_label.value}}); renderCase(state.currentCase); schedulePoll(state.currentCase); toast('Grad-CAM richiesta per la classe finale. La bozza della valutazione è conservata in questa sessione.');}
    catch(error) {toast(error.message,true); event.currentTarget.disabled = false;}
  };
  const toggle = () => {
    const request = form.elements.decision.value === 'needs_images';
    $('#final-label-field').hidden = request; $('#share-segmentation-field').hidden = request; $('#share-explanation-field').hidden = request; form.elements.final_label.required = !request; updateSharing();
  };
  form.elements.decision.onchange = toggle; toggle();
  form.elements.final_label.oninput = () => {
    if (form.elements.decision.value === 'approved' && run && !run.images.some(item => item.classification.labels[0].label === form.elements.final_label.value)) form.elements.decision.value = 'corrected';
    updateSharing();
  };
  form.onsubmit = event => {
    event.preventDefault(); const needsImages = form.elements.decision.value === 'needs_images';
    const payload = {expected_version:data.version,decision:form.elements.decision.value,final_label:needsImages ? null : form.elements.final_label.value,patient_message:form.elements.patient_message.value,share_segmentation:!needsImages && form.elements.share_segmentation.checked,share_explanation:!needsImages && !form.elements.share_explanation.disabled && form.elements.share_explanation.checked};
    const dialog = showDialog(needsImages ? 'Invia la richiesta di nuove foto' : 'Pubblica la valutazione',`<p class="dialog-text muted">Controlla il contenuto che sarà comunicato al paziente.</p>${!needsImages ? `<h3>${esc(payload.final_label)}</h3>` : ''}<p class="dialog-text">${esc(payload.patient_message)}</p>${payload.share_segmentation ? '<p class="field-help">Sarà condivisa anche la segmentazione.</p>' : ''}${payload.share_explanation ? `<p class="field-help">Sarà condivisa Grad-CAM per la classe ${esc(payload.final_label)}.</p>` : ''}<div class="error" id="publish-error" role="alert"></div><div class="button-row"><button type="button" class="btn btn-secondary" id="cancel-publish">Torna alla modifica</button><button type="button" class="btn btn-primary" id="confirm-publish">${needsImages ? 'Invia richiesta' : 'Pubblica per il paziente'}</button></div>`);
    $('#cancel-publish').onclick = () => dialog.close();
    $('#confirm-publish').onclick = async event => {
      event.currentTarget.disabled = true;
      try {state.currentCase = await api(`/api/cases/${data.id}/reviews`,{method:'POST',body:payload}); delete state.reviewDrafts[data.id]; dialog.close(); renderCase(state.currentCase); toast(needsImages ? 'Richiesta inviata al paziente.' : 'Valutazione pubblicata.');}
      catch(error) {$('#publish-error').textContent = error.message; $('#confirm-publish').disabled = false;}
    };
  };
}

function renderAccounts(data) {
  shell(`<div class="eyebrow">Gestione del progetto</div><div class="page-title-row"><div><h1>Gli accessi alla piattaforma.</h1><p class="page-subtitle">Crea account di prova e assegna a ciascuno il proprio ruolo. L’amministratore gestisce gli accessi senza visualizzare i casi clinici.</p></div></div><div class="admin-grid"><section class="section-panel"><div class="panel-heading"><h2>Account</h2><span class="muted">${data.items.length} account</span></div><div class="table-wrap"><table><thead><tr><th>Nome utente</th><th>Ruolo</th><th>Stato</th><th></th></tr></thead><tbody>${data.items.map(user => `<tr><td>${esc(user.username)}</td><td>${esc(roleNames[user.role])}</td><td>${user.active ? 'Attivo' : 'Sospeso'}</td><td><button class="btn btn-ghost btn-small" data-toggle-user="${user.id}" ${user.id === state.user.id ? 'disabled' : ''}>${user.active ? 'Sospendi' : 'Riattiva'}</button></td></tr>`).join('')}</tbody></table></div></section><section class="section-panel"><div class="panel-heading"><h2>Crea un account</h2></div><div class="panel-body"><form id="user-form"><div id="user-error" class="error" role="alert"></div><div class="field"><label for="account-username">Nome utente</label><input id="account-username" name="username" required minlength="3" maxlength="64" pattern="[a-z0-9][a-z0-9_.\-]{2,63}" autocomplete="off" autocapitalize="none" spellcheck="false"><p class="field-help">Usa un codice di prova, senza dati identificativi.</p></div><div class="field"><label for="account-role">Ruolo</label><select id="account-role" name="account_role"><option value="patient">Paziente</option><option value="doctor">Medico</option><option value="admin">Amministratore</option></select></div><div class="field"><label for="account-password">Password iniziale</label><input id="account-password" name="password" type="password" required minlength="12" maxlength="256" autocomplete="new-password"><p class="field-help">Almeno 12 caratteri. L’utente può cambiarla dopo l’accesso.</p></div><button class="btn btn-primary full-width" type="submit">${icon('plus')}Crea account</button></form></div></section></div>${footer()}`,'accounts');
  $$('[data-toggle-user]').forEach(button => button.onclick = async () => {
    const user = data.items.find(item => item.id === button.dataset.toggleUser); button.disabled = true;
    try {await api(`/api/admin/users/${user.id}`,{method:'PATCH',body:{active:!user.active}}); await route(); toast(user.active ? 'Account sospeso.' : 'Account riattivato.');} catch(error) {button.disabled = false; toast(error.message,true);}
  });
  $('#user-form').onsubmit = async event => {
    event.preventDefault(); const form = event.currentTarget, button = $('button[type=submit]',form); button.disabled = true;
    try {await api('/api/admin/users',{method:'POST',body:{username:form.elements.username.value,password:form.elements.password.value,role:form.elements.account_role.value}}); await route(); toast('Account creato.');} catch(error) {$('#user-error').textContent = error.message; button.disabled = false;}
  };
}

function renderAudit(data,users) {
  const names = Object.fromEntries(users.items.map(user => [user.id,user.username]));
  const actions = {login:'Accesso',logout:'Uscita',login_failed:'Accesso non riuscito',case_created:'Creazione caso',case_submitted:'Invio caso',case_viewed:'Visualizzazione caso',image_uploaded:'Caricamento foto',image_removed:'Rimozione foto',image_viewed:'Visualizzazione foto',segmentation_viewed:'Visualizzazione segmentazione',review_published:'Pubblicazione valutazione',user_created:'Creazione account',user_created_cli:'Creazione account',user_activated:'Riattivazione account',user_deactivated:'Sospensione account',password_changed:'Cambio password',password_reset_cli:'Recupero password',analysis_requested:'Richiesta analisi',analysis_completed:'Analisi completata',analysis_failed:'Analisi non riuscita',analysis_waiting_model:'Analisi in attesa del modello',explanation_viewed:'Consultazione Grad-CAM',acquisition_confirmed:'Conferma modalità di acquisizione',mobile_submissions_viewed:'Consultazione analisi rapide',mobile_submission_viewed:'Consultazione analisi rapida',mobile_artifact_viewed:'Consultazione mappa analisi rapida'};
  shell(`<div class="eyebrow">Gestione del progetto</div><div class="page-title-row"><div><h1>Registro delle attività.</h1><p class="page-subtitle">Traccia degli accessi e delle operazioni, senza contenuti delle foto o delle valutazioni.</p></div><button class="btn btn-secondary" id="refresh-audit">${icon('refresh')}Aggiorna</button></div><section class="section-panel"><div class="table-wrap"><table><thead><tr><th>Quando</th><th>Account</th><th>Operazione</th><th class="hide-mobile">Riferimento</th></tr></thead><tbody>${data.items.map(item => `<tr><td>${date(item.created_at,true)}</td><td>${esc(names[item.actor_id] || (item.actor_id ? 'Account' : 'Servizio'))}</td><td>${esc(actions[item.action] || item.action)}</td><td class="hide-mobile muted">${esc(item.target_id?.slice(0,8) || '—')}</td></tr>`).join('')}</tbody></table></div><div class="pagination"><span>Fino a 100 attività per pagina</span><div class="button-row"><button class="btn btn-ghost btn-small" id="audit-previous" ${state.auditOffset === 0 ? 'disabled' : ''}>Precedenti</button><button class="btn btn-ghost btn-small" id="audit-next" ${data.items.length < 100 ? 'disabled' : ''}>Successive</button></div></div></section>${footer()}`,'audit');
  $('#refresh-audit').onclick = route;
  $('#audit-previous').onclick = () => {state.auditOffset = Math.max(0,state.auditOffset-100); route();};
  $('#audit-next').onclick = () => {state.auditOffset += 100; route();};
}

function passwordDialog() {
  const dialog = showDialog('Cambia la password',`<form id="password-form"><div id="password-error" class="error" role="alert"></div><div class="field"><label for="current-password">Password attuale</label><input id="current-password" name="current_password" type="password" autocomplete="current-password" required maxlength="256"></div><div class="field"><label for="new-password">Nuova password</label><input id="new-password" name="new_password" type="password" autocomplete="new-password" required minlength="12" maxlength="256"><p class="field-help">Almeno 12 caratteri. Gli altri accessi saranno chiusi.</p></div><button class="btn btn-primary full-width" type="submit">Salva la password</button></form>`);
  $('#password-form').onsubmit = async event => {
    event.preventDefault(); const form = event.currentTarget, button = $('button[type=submit]',form); button.disabled = true;
    try {await api('/api/me/password',{method:'POST',body:{current_password:form.elements.current_password.value,new_password:form.elements.new_password.value}}); dialog.close(); toast('Password aggiornata.');} catch(error) {$('#password-error').textContent = error.message; button.disabled = false;}
  };
}

function helpDialog() {
  showDialog('Come funziona TeleDerma',`<ol class="guide-list"><li><span class="step-number">1</span><div><strong>Il paziente prepara il caso</strong>Accede dal browser, sceglie le foto della modalità dichiarata e invia un caso per ciascuna lesione.</div></li><li><span class="step-number">2</span><div><strong>Il modello elabora le immagini</strong>Quando sarà disponibile, produrrà classificazione e segmentazione, riservate inizialmente al medico.</div></li><li><span class="step-number">3</span><div><strong>Il medico valida e pubblica</strong>Conferma o corregge la classificazione e scrive un messaggio per il paziente. Può richiedere ulteriori foto.</div></li><li><span class="step-number">4</span><div><strong>Il paziente legge la risposta</strong>Nel proprio spazio trova la classificazione validata e le eventuali segmentazioni condivise dal medico.</div></li></ol><p class="field-help">Questa versione è riservata alle prove tecniche con immagini sintetiche. Non invia notifiche via email.</p>`);
}

window.addEventListener('hashchange',route);
async function boot() {
  try {const data = await api('/api/me'); state.user = data.user; state.csrf = data.csrf_token; state.status = await api('/api/status'); await route();}
  catch(error) {renderLogin(error.status === 401 ? '' : error.message);}
}
boot();
