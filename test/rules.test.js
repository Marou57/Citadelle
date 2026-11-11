import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluateSignal, normalizeAlert } from "../src/rules.js";

const config = { allowedSymbols: ["XAUUSD", "EURUSD", "BTCUSD"], minRR: 2, noMonday: true, timezone: "Europe/Paris", newsBlocks: [],
  accountSize: 40000, riskPct: 1, maxDailyLossPct: 5, maxLossPct: 10, dailyBufferPct: 1, maxOpen: 2, symbolMap: {} };
const tuesday = new Date("2026-11-10T10:00:00+01:00"), monday = new Date("2026-11-09T10:00:00+01:00");
const good = normalizeAlert({ symbol: "OANDA:XAUUSD", side: "buy", entry: 2000, sl: 1990, tp: 2030 });
const acct = (o = {}) => ({ balance: 40000, equity: 40000, dayPnl: 0, dayPnlPct: 0, positions: [], ...o });

test("signal propre accepté, risque de 1 %", () => {
  const r = evaluateSignal(good, { config, account: acct(), now: tuesday });
  assert.equal(r.ok, true); assert.equal(r.riskAmount, 400); assert.equal(r.rr, 3);
});
test("lundi bloqué", () => assert.equal(evaluateSignal(good, { config, account: acct(), now: monday }).ok, false));
test("stop du mauvais côté bloqué", () => assert.equal(evaluateSignal({ ...good, sl: 2010 }, { config, account: acct(), now: tuesday }).ok, false));
test("R:R trop faible bloqué", () => assert.equal(evaluateSignal({ ...good, tp: 2015 }, { config, account: acct(), now: tuesday }).ok, false));
test("perte du jour proche de la limite bloquée", () => assert.equal(evaluateSignal(good, { config, account: acct({ equity: 38700, dayPnl: -1300, dayPnlPct: -3.25 }), now: tuesday }).ok, false));
test("position déjà ouverte sur l'actif bloquée", () => assert.equal(evaluateSignal(good, { config, account: acct({ positions: [{ symbol: "XAUUSD" }] }), now: tuesday }).ok, false));
test("fenêtre d'annonce bloquée", () => {
  const c = { ...config, newsBlocks: [{ from: "2026-11-10T09:45:00+01:00", to: "2026-11-10T10:15:00+01:00", label: "CPI" }] };
  assert.equal(evaluateSignal(good, { config: c, account: acct(), now: tuesday }).ok, false);
});
test("sans compte connecté : accepté avec avertissement non bloquant", () => {
  const r = evaluateSignal(good, { config, account: null, now: tuesday });
  assert.equal(r.ok, true); assert.ok(r.checks.some(c => !c.ok && !c.bloquante));
});
