// Serveur central de la Citadelle.
// Alertes TradingView → règles du Sniper System → validation (Telegram ou page web) → robot MetaTrader 5.
// Par défaut, AUCUN ordre n'est envoyé : EXECUTION_MODE vaut "off".
import express from "express";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config, checkConfig } from "./src/config.js";
import { Store } from "./src/store.js";
import { evaluateSignal, normalizeAlert, dayInfo } from "./src/rules.js";
import { Telegram } from "./src/telegram.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
checkConfig();
const store = new Store(config.dataDir);
const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "200kb" }));
app.use(express.text({ type: "text/plain", limit: "50kb" }));

const id = () => crypto.randomBytes(5).toString("hex");
const safeEq = (a, b) => { const A = Buffer.from(String(a || "")), B = Buffer.from(String(b || "")); return A.length === B.length && A.length > 0 && crypto.timingSafeEqual(A, B); };
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const fmt = n => (Number.isFinite(n) ? String(n) : "?");

// ---------- authentification
const needDashboard = (req, res, next) => {
  const k = req.get("x-dashboard-key") || req.query.k;
  if (!config.dashboardKey || !safeEq(k, config.dashboardKey)) return res.status(401).json({ error: "clé du tableau de bord invalide" });
  next();
};
const needBridge = (req, res, next) => {
  if (!config.bridgeKey || !safeEq(req.get("x-bridge-key"), config.bridgeKey)) return res.status(401).send("clé du pont invalide");
  next();
};

// ---------- Telegram
const validationLink = sig => (config.publicUrl && config.dashboardKey ? `${config.publicUrl}/valider/${sig.id}?k=${encodeURIComponent(config.dashboardKey)}` : "");
function signalText(sig) {
  const head = (sig.test ? "🧪 <b>TEST</b> · " : "") + (sig.status === "bloqué" ? "⛔ <b>Signal bloqué par les règles</b>" : sig.status === "en attente" ? "🔔 <b>Nouveau signal à valider</b>" : `ℹ️ <b>Signal ${esc(sig.status)}</b>`);
  const lines = [
    head,
    `${sig.side === "buy" ? "Achat" : "Vente"} <b>${esc(sig.symbol)}</b> ${sig.timeframe ? "(" + esc(sig.timeframe) + ")" : ""}`,
    `Entrée ${fmt(sig.entry)} · Stop ${fmt(sig.sl)} · Objectif ${fmt(sig.tp)}`,
    `Risque : ${sig.riskAmount} ${config.currency} (${config.riskPct} %)${sig.rr ? " · R:R " + sig.rr : ""}`,
    "",
    ...sig.checks.map(c => `${c.ok ? "✅" : c.bloquante ? "❌" : "⚠️"} ${esc(c.regle)} : ${esc(c.detail)}`),
  ];
  if (sig.status === "en attente") {
    lines.push("", `Expire dans ${config.signalTtlMin} min.`, config.executionMode === "off" ? "Mode simulation : aucun ordre ne sera passé." : `Exécution : ${config.executionMode}.`);
    const link = validationLink(sig); if (link) lines.push(`<a href="${link}">Valider depuis le navigateur</a>`);
  }
  return lines.join("\n");
}
async function decide(sid, decision, via) {
  const sig = store.getSignal(sid);
  if (!sig) return { ok: false, message: "Signal introuvable" };
  if (sig.status !== "en attente") return { ok: false, message: `Déjà traité : ${sig.status}` };
  if (decision === "refuser") {
    store.updateSignal(sid, { status: "refusé", decidedVia: via });
    store.log("signal", `Signal ${sig.symbol} refusé (${via})`, { signalId: sid });
  } else {
    if (sig.test) {
      store.updateSignal(sid, { status: "validé · test", decidedVia: via });
      store.log("signal", `Signal de test validé (${via}) : jamais d'ordre pour un test`, { signalId: sid });
    } else if (config.executionMode === "off") {
      store.updateSignal(sid, { status: "validé · simulation", decidedVia: via });
      store.log("signal", `Signal ${sig.symbol} validé en simulation (${via}) : aucun ordre envoyé`, { signalId: sid });
    } else {
      const o = store.addOrder({ id: id(), signalId: sid, symbol: config.symbolMap[sig.symbol] || sig.symbol, side: sig.side, sl: sig.sl, tp: sig.tp, riskAmount: sig.riskAmount, status: "à envoyer", createdAt: Date.now() });
      store.updateSignal(sid, { status: "validé", decidedVia: via, orderId: o.id });
      store.log("ordre", `Ordre ${o.symbol} mis en file pour le robot (${config.executionMode})`, { orderId: o.id });
    }
  }
  const s2 = store.getSignal(sid);
  telegram.edit(s2.telegramMessageId, signalText(s2));
  return { ok: true, message: s2.status };
}
const telegram = new Telegram({ token: config.telegramToken, chatId: config.telegramChatId, onDecision: decide, log: (t, m) => console.warn(`[${t}] ${m}`) });

// ---------- routes publiques
app.get("/health", (req, res) => res.json({ ok: true, executionMode: config.executionMode, compte: !!store.s.account, derniereMaj: store.s.accountAt || null }));

// TradingView : le message d'alerte doit être un JSON contenant "secret".
app.post("/webhook/tradingview", async (req, res) => {
  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch { return res.status(400).send("JSON invalide"); } }
  if (!body || !safeEq(body.secret, config.webhookSecret)) return res.status(401).send("secret invalide");
  const sig = createSignal(normalizeAlert(body), false);
  res.json({ ok: true, id: sig.id, status: sig.status });
});
function createSignal(a, test) {
  const ev = evaluateSignal(a, { config, account: store.publicAccount() });
  const sig = store.addSignal({ id: id(), ...a, ...ev, test, status: ev.ok ? "en attente" : "bloqué", createdAt: Date.now(), expiresAt: Date.now() + config.signalTtlMin * 60000 });
  const label = (test ? "Signal de test " : "Signal ") + a.symbol;
  store.log("signal", ev.ok ? `${label} ${a.side === "buy" ? "achat" : "vente"} en attente de validation` : `${label} bloqué : ${ev.checks.filter(c => !c.ok && c.bloquante).map(c => c.regle).join(", ")}`, { signalId: sig.id });
  telegram.sendSignal(sig, signalText(sig)).then(mid => { if (mid) store.updateSignal(sig.id, { telegramMessageId: mid }); }).catch(e => console.warn("[telegram]", e.message));
  return sig;
}
// Signal de test : passe par les mêmes règles et la même validation, mais ne crée JAMAIS d'ordre.
app.post("/api/test-signal", needDashboard, (req, res) => {
  const side = (req.body && req.body.side) === "sell" ? "sell" : "buy";
  const entry = 2000, sl = side === "buy" ? 1990 : 2010, tp = side === "buy" ? 2030 : 1970;
  const sig = createSignal({ symbol: "XAUUSD", side, entry, sl, tp, timeframe: "240", note: "test" }, true);
  res.json({ ok: true, id: sig.id, status: sig.status });
});

// ---------- pont MetaTrader 5 (robot CitadelleBridge.mq5)
app.post("/bridge/snapshot", needBridge, (req, res) => {
  const b = req.body || {};
  const num = v => (Number.isFinite(Number(v)) ? Number(v) : 0);
  const snap = {
    login: String(b.login || ""), server: String(b.server || "").slice(0, 80), currency: String(b.currency || config.currency).slice(0, 8),
    balance: num(b.balance), equity: num(b.equity), tradeAllowed: !!b.tradeAllowed,
    positions: (Array.isArray(b.positions) ? b.positions : []).slice(0, 50).map(p => ({ ticket: String(p.ticket), symbol: String(p.symbol).slice(0, 20), type: p.type === "sell" ? "sell" : "buy", volume: num(p.volume), price: num(p.price), sl: num(p.sl), tp: num(p.tp), profit: num(p.profit), time: num(p.time) })),
  };
  store.setSnapshot(snap, dayInfo(new Date(), config.timezone).dayKey);
  res.json({ ok: true });
});
// Format texte simple pour le robot : une ligne par ordre « id|symbole|sens|stop|objectif|risque ».
app.get("/bridge/orders", needBridge, (req, res) => {
  const login = String(req.query.login || "");
  if (config.executionMode === "off" || !login || login !== config.executionLogin) return res.type("text/plain").send("");
  const pending = store.s.orders.filter(o => o.status === "à envoyer");
  pending.forEach(o => store.updateOrder(o.id, { status: "envoyé au robot", sentAt: Date.now() }));
  res.type("text/plain").send(pending.map(o => [o.id, o.symbol, o.side, o.sl, o.tp ?? 0, o.riskAmount].join("|")).join("\n"));
});
app.post("/bridge/report", needBridge, (req, res) => {
  const b = req.body || {};
  const o = store.updateOrder(String(b.orderId || ""), { status: b.ok ? "exécuté" : "échec", ticket: String(b.ticket || ""), volume: Number(b.volume) || 0, message: String(b.message || "").slice(0, 200) });
  if (!o) return res.status(404).json({ error: "ordre inconnu" });
  const txt = b.ok ? `Ordre ${o.symbol} exécuté : ${o.volume} lot(s), ticket ${o.ticket}` : `Échec de l'ordre ${o.symbol} : ${o.message}`;
  store.log("ordre", txt, { orderId: o.id });
  telegram.send((b.ok ? "✅ " : "❌ ") + esc(txt));
  res.json({ ok: true });
});

// ---------- API du tableau de bord et de la citadelle en direct
app.get("/api/state", needDashboard, (req, res) => res.json({ ...store.summary(), config: { executionMode: config.executionMode, riskPct: config.riskPct, maxDailyLossPct: config.maxDailyLossPct, maxLossPct: config.maxLossPct, accountSize: config.accountSize, currency: config.currency } }));
app.post("/api/decide/:id", needDashboard, async (req, res) => {
  const d = String((req.body && req.body.decision) || "");
  if (!["valider", "refuser"].includes(d)) return res.status(400).json({ error: "décision invalide" });
  res.json(await decide(req.params.id, d, "page web"));
});
app.get("/api/stream", needDashboard, (req, res) => {
  res.set({ "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive", "X-Accel-Buffering": "no" });
  res.flushHeaders();
  const send = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`);
  send("state", store.summary());
  const on = { snapshot: d => send("snapshot", d), signal: d => send("signal", d), order: d => send("order", d), event: d => send("event", d) };
  Object.entries(on).forEach(([k, f]) => store.on(k, f));
  const ping = setInterval(() => res.write(": ping\n\n"), 25000);
  req.on("close", () => { clearInterval(ping); Object.entries(on).forEach(([k, f]) => store.off(k, f)); });
});

// ---------- pages
app.get("/valider/:id", (req, res) => res.sendFile(path.join(__dirname, "public", "valider.html")));
app.get("/tableau", (req, res) => res.sendFile(path.join(__dirname, "public", "tableau.html")));
app.get("/citadelle", (req, res) => res.sendFile(path.join(__dirname, "public", "citadelle.html")));
app.get("/", (req, res) => res.redirect("/citadelle"));

// ---------- tâches de fond : expiration des signaux, alerte si le robot se tait
setInterval(() => {
  const now = Date.now();
  store.s.signals.filter(s => s.status === "en attente" && s.expiresAt < now).forEach(s => {
    store.updateSignal(s.id, { status: "expiré" });
    store.log("signal", `Signal ${s.symbol} expiré sans décision`, { signalId: s.id });
    telegram.edit(s.telegramMessageId, signalText(store.getSignal(s.id)));
  });
  const silent = store.s.accountAt && now - store.s.accountAt > 5 * 60000;
  if (silent && !store.silentWarned) { store.silentWarned = true; store.log("compte", "Le robot MetaTrader ne répond plus depuis 5 minutes"); telegram.send("⚠️ Le robot MetaTrader ne répond plus depuis 5 minutes."); }
  if (!silent) store.silentWarned = false;
}, 15000);

app.listen(config.port, () => {
  console.log(`Citadelle : serveur démarré sur le port ${config.port} · exécution : ${config.executionMode}`);
  telegram.start();
});
