// Règles du Sniper System appliquées à chaque alerte TradingView.
// Chaque règle renvoie { regle, ok, detail, bloquante }.

export function dayInfo(date, timezone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", { timeZone: timezone, weekday: "short", year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(date).map(p => [p.type, p.value]));
  return { weekday: parts.weekday, dayKey: `${parts.year}-${parts.month}-${parts.day}` };
}

export function normalizeAlert(body) {
  const side = String(body.side || body.action || "").toLowerCase();
  const n = v => (v === undefined || v === null || v === "" ? NaN : Number(v));
  return {
    symbol: String(body.symbol || body.ticker || "").toUpperCase().replace(/^[A-Z]+:/, ""),
    side: side === "buy" || side === "long" || side === "achat" ? "buy" : side === "sell" || side === "short" || side === "vente" ? "sell" : "",
    entry: n(body.entry ?? body.price), sl: n(body.sl), tp: n(body.tp),
    timeframe: String(body.timeframe || "").slice(0, 10), note: String(body.note || "").slice(0, 200),
  };
}

export function evaluateSignal(sig, ctx) {
  const { config, account, now = new Date() } = ctx;
  const checks = [];
  const add = (regle, ok, detail, bloquante = true) => checks.push({ regle, ok, detail, bloquante });

  add("Actif autorisé", config.allowedSymbols.includes(sig.symbol), config.allowedSymbols.includes(sig.symbol) ? sig.symbol : `${sig.symbol || "?"} n'est pas dans la liste (${config.allowedSymbols.join(", ")})`);
  add("Sens de l'ordre", !!sig.side, sig.side ? (sig.side === "buy" ? "Achat" : "Vente") : "sens manquant (buy ou sell)");

  const okNums = [sig.entry, sig.sl].every(Number.isFinite) && sig.entry > 0;
  const slSide = okNums && (sig.side === "buy" ? sig.sl < sig.entry : sig.side === "sell" ? sig.sl > sig.entry : false);
  add("Stop cohérent", slSide, slSide ? `stop à ${sig.sl}` : "stop absent ou du mauvais côté de l'entrée");

  let rr = NaN;
  if (slSide && Number.isFinite(sig.tp)) rr = Math.abs(sig.tp - sig.entry) / Math.abs(sig.entry - sig.sl);
  const tpSide = Number.isFinite(sig.tp) && (sig.side === "buy" ? sig.tp > sig.entry : sig.tp < sig.entry);
  add("Ratio gain/risque", tpSide && rr >= config.minRR, tpSide ? `${rr.toFixed(2)} (minimum ${config.minRR})` : "objectif absent ou du mauvais côté");

  const { weekday } = dayInfo(now, config.timezone);
  if (config.noMonday) add("Pas de trade le lundi", weekday !== "Mon", weekday === "Mon" ? "on est lundi" : "ok");

  const news = (config.newsBlocks || []).find(b => { const f = Date.parse(b.from), t = Date.parse(b.to); return f <= now.getTime() && now.getTime() <= t; });
  add("Annonces économiques", !news, news ? `fenêtre bloquée : ${news.label || "annonce"}` : "aucune fenêtre bloquée");

  const balance = account ? account.balance : config.accountSize;
  const riskAmount = Math.round(balance * config.riskPct) / 100;
  if (account) {
    const dayLossPct = Math.max(0, -account.dayPnlPct);
    const after = dayLossPct + config.riskPct;
    const limit = config.maxDailyLossPct - config.dailyBufferPct;
    add("Perte du jour", after <= limit, `${dayLossPct.toFixed(2)} % aujourd'hui, ${after.toFixed(2)} % si le stop est touché (seuil ${limit} %)`);
    const totalLossPct = Math.max(0, (config.accountSize - account.equity) / config.accountSize * 100);
    add("Perte maximale", totalLossPct + config.riskPct <= config.maxLossPct - config.dailyBufferPct, `${totalLossPct.toFixed(2)} % sous le capital de départ (limite ${config.maxLossPct} %)`);
    const positions = account.positions || [];
    const mt5Symbol = config.symbolMap[sig.symbol] || sig.symbol;
    const already = positions.some(p => String(p.symbol).toUpperCase() === mt5Symbol.toUpperCase());
    add("Une position par actif", !already, already ? `position déjà ouverte sur ${mt5Symbol}` : "ok");
    add("Positions ouvertes", positions.length < config.maxOpen, `${positions.length} ouverte(s), maximum ${config.maxOpen}`);
  } else {
    add("Compte connecté", false, "le robot MetaTrader n'envoie pas encore le compte : limites de perte non vérifiées", false);
  }

  const blocked = checks.filter(c => !c.ok && c.bloquante);
  return { ok: blocked.length === 0, checks, riskAmount, rr: Number.isFinite(rr) ? Math.round(rr * 100) / 100 : null };
}
