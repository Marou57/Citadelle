// Configuration lue dans les variables d'environnement.
// Rien de secret ne doit être écrit dans le code : tout passe par l'hébergeur (onglet « Environment variables »).

const num = (v, d) => (v === undefined || v === "" || isNaN(Number(v)) ? d : Number(v));
const list = (v, d) => (v ? v.split(",").map(s => s.trim().toUpperCase()).filter(Boolean) : d);
const json = (v, d) => { if (!v) return d; try { return JSON.parse(v); } catch { console.warn("[config] JSON invalide, valeur par défaut utilisée :", v); return d; } };

export const config = {
  port: num(process.env.PORT, 8080),
  dataDir: process.env.DATA_DIR || "./data",
  timezone: process.env.TIMEZONE || "Europe/Paris",

  // Secrets
  webhookSecret: process.env.WEBHOOK_SECRET || "",   // à mettre dans le message d'alerte TradingView
  bridgeKey: process.env.BRIDGE_KEY || "",           // partagé avec le robot MetaTrader
  dashboardKey: process.env.DASHBOARD_KEY || "",     // pour ouvrir le tableau de bord et valider
  telegramToken: process.env.TELEGRAM_BOT_TOKEN || "",
  telegramChatId: process.env.TELEGRAM_CHAT_ID || "",
  publicUrl: (process.env.PUBLIC_URL || "").replace(/\/$/, ""),

  // Compte et règles du Sniper System (à ajuster à ton compte FTMO)
  accountSize: num(process.env.ACCOUNT_SIZE, 40000),
  currency: process.env.ACCOUNT_CURRENCY || "EUR",
  riskPct: num(process.env.RISK_PCT, 1),
  minRR: num(process.env.MIN_RR, 2),
  maxDailyLossPct: num(process.env.MAX_DAILY_LOSS_PCT, 5),   // à vérifier dans les règles de ton compte
  maxLossPct: num(process.env.MAX_LOSS_PCT, 10),             // à vérifier dans les règles de ton compte
  dailyBufferPct: num(process.env.DAILY_BUFFER_PCT, 1),      // marge de sécurité avant la limite du jour
  maxOpen: num(process.env.MAX_OPEN, 2),
  noMonday: (process.env.NO_MONDAY || "true") !== "false",
  allowedSymbols: list(process.env.ALLOWED_SYMBOLS, ["XAUUSD", "EURUSD", "BTCUSD"]),
  symbolMap: json(process.env.SYMBOL_MAP, {}),               // ex. {"XAUUSD":"XAUUSD.r"} si le nom diffère sur MT5
  newsBlocks: json(process.env.NEWS_BLOCKS, []),             // ex. [{"from":"2026-11-14T14:15:00+01:00","to":"2026-11-14T14:45:00+01:00","label":"CPI US"}]
  signalTtlMin: num(process.env.SIGNAL_TTL_MIN, 30),

  // Exécution : "off" par défaut. Les ordres ne partent QUE vers le compte EXECUTION_LOGIN.
  executionMode: (process.env.EXECUTION_MODE || "off").toLowerCase(), // off | demo | live
  executionLogin: process.env.EXECUTION_LOGIN || "",
};

export function checkConfig() {
  const warn = [];
  if (config.webhookSecret.length < 16) warn.push("WEBHOOK_SECRET manquant ou trop court (16 caractères minimum).");
  if (config.bridgeKey.length < 16) warn.push("BRIDGE_KEY manquante ou trop courte (16 caractères minimum).");
  if (config.dashboardKey.length < 16) warn.push("DASHBOARD_KEY manquante ou trop courte (16 caractères minimum).");
  if (!config.telegramToken || !config.telegramChatId) warn.push("Telegram non configuré : la validation se fera seulement par la page web.");
  if (!["off", "demo", "live"].includes(config.executionMode)) { warn.push(`EXECUTION_MODE inconnu (${config.executionMode}) : remis sur "off".`); config.executionMode = "off"; }
  if (config.executionMode !== "off" && !config.executionLogin) { warn.push("EXECUTION_MODE actif sans EXECUTION_LOGIN : exécution désactivée."); config.executionMode = "off"; }
  warn.forEach(w => console.warn("[config] " + w));
  return warn;
}
