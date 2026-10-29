const $ = (id) => document.getElementById(id);
const api = (path, params = {}) =>
  fetch(path + "?" + new URLSearchParams(params)).then((r) => r.json());

const map = L.map("map").setView([48.775, 2.02], 13);
L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 19, attribution: "© OpenStreetMap",
}).addTo(map);

const lineLayer = L.layerGroup().addTo(map);
const vehiclesLayer = L.layerGroup().addTo(map);
const tripLayer = L.layerGroup().addTo(map);
let lines = [], current = {}, selected = null, pollTimer = null, busMarker = null, realtimeOn = false;

// --- horloge simulée ------------------------------------------------------
let simBase = null, simStartedAt = null;
function simParams() {
  if (!$("simOn").checked || !$("simDay").value || !$("simTime").value) return {};
  if (!simBase) {
    simBase = new Date(`${$("simDay").value}T${$("simTime").value}`);
    simStartedAt = Date.now();
  }
  const t = new Date(simBase.getTime() + (Date.now() - simStartedAt));
  const pad = (n) => String(n).padStart(2, "0");
  return {
    day: `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`,
    at: `${pad(t.getHours())}:${pad(t.getMinutes())}:${pad(t.getSeconds())}`,
  };
}
// --- autorisation des requêtes PRIM (mémorisée dans le navigateur) --------
function rtParams() { return $("rtOn").checked ? { rt: 1 } : {}; }
try { $("rtOn").checked = localStorage.getItem("rtOn") === "1"; } catch (e) {}
$("rtOn").addEventListener("change", () => {
  try { localStorage.setItem("rtOn", $("rtOn").checked ? "1" : "0"); } catch (e) {}
  loadDepartures(false);
  refreshVehicles();
  if (selected) refreshTrip();
});

function resetSim() { simBase = null; loadDepartures(); refreshVehicles(); }
["simOn", "simDay", "simTime"].forEach((id) => $(id).addEventListener("change", resetSim));
const now0 = new Date();
$("simDay").value = now0.toISOString().slice(0, 10);
$("simTime").value = "08:00";

// --- formatage --------------------------------------------------------------
const hhmm = (sec) => {
  sec = ((sec % 86400) + 86400) % 86400;
  return `${String(Math.floor(sec / 3600)).padStart(2, "0")}:${String(Math.floor(sec / 60) % 60).padStart(2, "0")}`;
};
const duration = (sec) => {
  if (sec < 60) return `${sec} s`;
  const m = Math.floor(sec / 60);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`;
};

// --- sélecteurs -------------------------------------------------------------
function fillSelect(sel, items, value, label) {
  sel.innerHTML = "";
  items.forEach((it) => sel.add(new Option(label(it), value(it))));
}

async function init() {
  const data = await api("/api/lines");
  lines = data.lines;
  realtimeOn = data.realtime;
  $("source").textContent = data.realtime
    ? "Clé PRIM détectée : temps réel actif (hors simulation)."
    : "Pas de clé PRIM : positions calculées sur l'horaire théorique.";
  fillSelect($("line"), lines, (l) => l.route_id, (l) => `Ligne ${l.name}`);
  $("line").onchange = onLine;
  $("direction").onchange = onDirection;
  $("stop").onchange = loadDepartures;
  onLine();
}

function onLine() {
  current.line = lines.find((l) => l.route_id === $("line").value);
  document.documentElement.style.setProperty("--line", "#" + current.line.color);
  fillSelect($("direction"), current.line.directions, (d) => d.direction_id, (d) => `→ ${d.label}`);
  onDirection();
  refreshVehicles();
}

async function onDirection() {
  current.direction = current.line.directions.find((d) => d.direction_id == $("direction").value);
  const seen = new Set();
  const stops = current.direction.stops.filter((s) => !seen.has(s.key) && seen.add(s.key));
  fillSelect($("stop"), stops.slice(0, -1), (s) => s.key, (s) => s.name);
  await drawLine();
  loadDepartures();
  refreshVehicles();
}

async function drawLine() {
  const g = await api("/api/geometry", { route_id: current.line.route_id, direction_id: current.direction.direction_id });
  lineLayer.clearLayers();
  const color = "#" + current.line.color;
  const bounds = [];
  g.shapes.forEach((pts) => { L.polyline(pts, { color, weight: 4, opacity: 0.5 }).addTo(lineLayer); bounds.push(...pts); });
  g.stops.forEach((s) =>
    L.circleMarker([s.lat, s.lon], { radius: 4, color, fillColor: "#fff", fillOpacity: 1, weight: 2 })
      .bindTooltip(s.name).on("click", () => { $("stop").value = s.key; loadDepartures(); })
      .addTo(lineLayer));
  if (bounds.length) map.fitBounds(bounds, { padding: [20, 20] });
}

// --- horaires ---------------------------------------------------------------
// reset = changement de ligne/arrêt par l'utilisateur ; sinon simple rafraîchissement des retards
async function loadDepartures(reset = true) {
  if (reset) { stopPolling(); selected = null; tripLayer.clearLayers(); $("status").classList.add("hidden"); }
  const sim = simParams();
  const res = await api("/api/departures", {
    route_id: current.line.route_id, direction_id: current.direction.direction_id, stop_key: $("stop").value, ...sim, ...rtParams(),
  });
  current.serviceDay = res.service_day;
  $("dayLabel").textContent = `(${new Date(res.service_day).toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long" })})`;
  const ul = $("departures");
  ul.innerHTML = res.departures.length ? "" : "<p class='hint'>Aucun passage ce jour.</p>";
  let next = null;
  res.departures.forEach((d) => {
    const li = document.createElement("li");
    const real = d.expected ?? d.time;
    let html = hhmm(d.time);
    if (d.passed) html += `<small>passé</small>`;
    else if (d.delay_sec !== undefined) {
      const min = Math.round(d.delay_sec / 60);
      html += min === 0
        ? `<small class="ontime">à l'heure</small>`
        : `<small class="${min > 0 ? "late" : "early"}">${min > 0 ? "+" : ""}${min} min → ${hhmm(real)}</small>`;
    }
    if (d.headsign !== current.direction.label) html += `<small>${d.headsign}</small>`;
    li.innerHTML = html;
    // grisé selon l'heure réelle de passage quand on la connaît
    if (d.passed || real < res.now_sec - 30) li.classList.add("past"); else if (!next) next = li;
    if (selected && selected.trip_id === d.trip_id) li.classList.add("selected");
    li.onclick = () => selectTrip(d, li);
    ul.appendChild(li);
  });
  if (reset && next) next.scrollIntoView({ block: "nearest" });
  if (res.realtime_error) $("source").textContent = `Erreur PRIM : ${res.realtime_error}`;
  else showUsage();
}

async function showUsage() {
  if (!realtimeOn) return;
  const u = await api("/api/prim-usage");
  const state = !$("rtOn").checked ? "Temps réel désactivé : horaires théoriques"
    : simParams().day ? "Temps réel suspendu pendant la simulation"
    : `Temps réel actif (1 requête PRIM max par ligne et par ${u.cache_ttl_sec} s)`;
  $("source").textContent = `${state} · ${u.counts.ligne}/${u.daily_limit} requêtes « ligne » aujourd'hui`;
}

// rafraîchit les retards de la liste chaque minute, seulement si l'onglet est visible
setInterval(() => { if (!document.hidden && current.direction) loadDepartures(false); }, 60000);

// --- suivi d'une course -----------------------------------------------------
function selectTrip(dep, li) {
  document.querySelectorAll("#departures li.selected").forEach((e) => e.classList.remove("selected"));
  li.classList.add("selected");
  selected = dep;
  tripLayer.clearLayers();
  busMarker = null;
  stopPolling();
  refreshTrip(true);
  // toutes les 5 s le serveur recalcule la position ; PRIM n'est rappelé qu'une fois par minute (cache)
  pollTimer = setInterval(() => { if (!document.hidden) refreshTrip(); }, 5000);
}
function stopPolling() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }

async function refreshTrip(fit = false) {
  const s = await api(`/api/trip/${encodeURIComponent(selected.trip_id)}`, {
    stop_id: selected.stop_id, service_day: current.serviceDay, ...simParams(), ...rtParams(),
  });
  const color = "#" + current.line.color;
  if (fit) {
    L.polyline(s.shape, { color, weight: 6 }).addTo(tripLayer);
    const mine = s.stops.find((st) => st.id === selected.stop_id);
    L.circleMarker([mine.lat, mine.lon], { radius: 9, color: "#000", weight: 3, fill: false })
      .bindTooltip("Votre arrêt", { permanent: true, direction: "right" }).addTo(tripLayer);
  }
  const pos = s.vehicle_location?.Latitude ? [s.vehicle_location.Latitude, s.vehicle_location.Longitude] : s.position;
  if (!busMarker) {
    busMarker = L.marker(pos, {
      icon: L.divIcon({ className: "", html: `<div class="bus-icon" style="width:30px;height:30px">${current.line.name.slice(-2)}</div>`, iconSize: [30, 30] }),
      zIndexOffset: 1000,
    }).addTo(tripLayer);
    if (fit) map.setView(pos, 14);
  } else busMarker.setLatLng(pos);
  renderStatus(s);
  if (s.state === "finished") stopPolling(); // course terminée : plus aucune requête
  refreshVehicles();
}

function renderStatus(s) {
  const card = $("status");
  card.classList.remove("hidden");
  const mine = s.stops.findIndex((st) => st.id === selected.stop_id);
  const badge = s.source === "temps_reel"
    ? `<span class="badge rt">temps réel${s.vehicle_location ? " GPS" : ""}</span>`
    : `<span class="badge">théorique</span>`;
  const delay = s.delay_sec ? ` · ${s.delay_sec > 0 ? "retard" : "avance"} ${duration(Math.abs(s.delay_sec))}` : "";
  let html = `${badge}${delay}<br><b>Bus de ${hhmm(selected.time)}</b> → ${s.headsign}<br>`;

  if (s.state === "not_started") {
    html += `Pas encore parti de <b>${s.stops[0].name}</b> (départ dans ${duration(s.starts_in_sec)}).`;
  } else if (s.state === "finished") {
    html += `Arrivé au terminus <b>${s.stops.at(-1).name}</b> il y a ${duration(s.since_sec)}.`;
  } else {
    const last = s.stops[s.last_stop_index], next = s.stops[s.next_stop_index];
    html += `A passé <b>${last.name}</b> il y a ${duration(s.since_sec)}.<br>Prochain arrêt : <b>${next.name}</b> dans ${duration(s.next_in_sec)}.`;
  }
  if (mine >= 0) {
    const passed = s.state === "finished" || (s.state === "running" && s.last_stop_index >= mine);
    const nowSec = s.now_sec;
    html += passed
      ? `<br><i>Ce bus est déjà passé à votre arrêt.</i>`
      : `<br>À votre arrêt dans <b>${duration(Math.max(0, s.stops[mine].time - nowSec))}</b> (${s.state === "running" ? mine - s.last_stop_index : mine} arrêt(s)).`;
  }
  if (s.realtime_note) html += `<br><span class="hint">Temps réel : ${s.realtime_note}.</span>`;
  if (s.realtime_error) html += `<br><span class="hint">Erreur PRIM : ${s.realtime_error}</span>`;
  card.innerHTML = html;
}

// --- tous les bus de la ligne -------------------------------------------------
// la position est recalculée par le serveur ; PRIM n'est rappelé qu'une fois par minute (cache)
let vehiclesBusy = false;
async function refreshVehicles() {
  if (!current.line || vehiclesBusy) return;
  vehiclesBusy = true;
  try {
    const res = await api("/api/vehicles", { route_id: current.line.route_id, ...simParams(), ...rtParams() });
    vehiclesLayer.clearLayers();
    res.vehicles.forEach((v) => {
      if (selected && v.trip_id === selected.trip_id) return; // déjà affiché en grand
      const sameDir = current.direction && v.direction_id == current.direction.direction_id;
      const cls = `bus-icon small${sameDir ? "" : " other"}${v.source === "temps_reel" ? "" : " theo"}`;
      const delay = v.source !== "temps_reel" ? "horaire théorique"
        : v.delay_sec ? `${v.delay_sec > 0 ? "retard" : "avance"} ${duration(Math.abs(v.delay_sec))}` : "à l'heure";
      L.marker(v.position, {
        icon: L.divIcon({ className: "", html: `<div class="${cls}">${sameDir ? "▲" : "▽"}</div>`, iconSize: [20, 20] }),
        zIndexOffset: sameDir ? 500 : 0,
      }).bindPopup(`<b>→ ${v.headsign}</b> (départ ${hhmm(v.first_time)})<br>${delay}<br>` +
        `A passé <b>${v.last_stop}</b> il y a ${duration(v.since_sec)}<br>Prochain : <b>${v.next_stop}</b> dans ${duration(v.next_in_sec)}`)
        .addTo(vehiclesLayer);
    });
    $("busCount").textContent = `${res.vehicles.length} bus en circulation · ▲ sens choisi, ▽ sens inverse, gris = horaire théorique (clic = détails)`;
  } finally { vehiclesBusy = false; }
}
setInterval(() => { if (!document.hidden && !pollTimer) refreshVehicles(); }, 10000);

init();
