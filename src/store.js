// Mémoire du serveur : compte, signaux, ordres et journal d'événements.
// Sauvegardée dans un fichier JSON (DATA_DIR/state.json).
import fs from "node:fs";
import path from "node:path";
import { EventEmitter } from "node:events";

const MAX_SIGNALS = 300, MAX_EVENTS = 500;

export class Store extends EventEmitter {
  constructor(dir) {
    super();
    this.file = path.join(dir, "state.json");
    fs.mkdirSync(dir, { recursive: true });
    this.s = { account: null, accountAt: 0, dayStart: null, signals: [], orders: [], events: [] };
    try { Object.assign(this.s, JSON.parse(fs.readFileSync(this.file, "utf8"))); } catch { /* premier démarrage */ }
    this.timer = null;
  }
  save() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      const tmp = this.file + ".tmp";
      fs.writeFileSync(tmp, JSON.stringify(this.s));
      fs.renameSync(tmp, this.file);
    }, 500);
  }
  log(type, text, data = {}) {
    const e = { at: Date.now(), type, text, ...data };
    this.s.events.unshift(e);
    this.s.events.length = Math.min(this.s.events.length, MAX_EVENTS);
    this.save();
    this.emit("event", e);
    return e;
  }

  // --- compte (instantanés envoyés par le robot MetaTrader)
  setSnapshot(snap, dayKey) {
    this.s.account = snap; this.s.accountAt = Date.now();
    if (!this.s.dayStart || this.s.dayStart.day !== dayKey || this.s.dayStart.login !== snap.login) {
      this.s.dayStart = { day: dayKey, login: snap.login, balance: snap.balance };
      this.log("compte", `Nouvelle journée : solde de départ ${snap.balance} ${snap.currency || ""}`.trim());
    }
    this.save();
    this.emit("snapshot", this.publicAccount());
  }
  publicAccount() {
    const a = this.s.account; if (!a) return null;
    const start = this.s.dayStart ? this.s.dayStart.balance : a.balance;
    const dayPnl = a.equity - start;
    return { ...a, at: this.s.accountAt, dayStartBalance: start, dayPnl, dayPnlPct: start ? dayPnl / start * 100 : 0 };
  }

  // --- signaux
  addSignal(sig) {
    this.s.signals.unshift(sig);
    this.s.signals.length = Math.min(this.s.signals.length, MAX_SIGNALS);
    this.save(); this.emit("signal", sig); return sig;
  }
  getSignal(id) { return this.s.signals.find(x => x.id === id); }
  updateSignal(id, patch) {
    const s = this.getSignal(id); if (!s) return null;
    Object.assign(s, patch, { updatedAt: Date.now() });
    this.save(); this.emit("signal", s); return s;
  }

  // --- ordres (file d'attente lue par le robot)
  addOrder(o) { this.s.orders.unshift(o); this.s.orders.length = Math.min(this.s.orders.length, MAX_SIGNALS); this.save(); this.emit("order", o); return o; }
  getOrder(id) { return this.s.orders.find(x => x.id === id); }
  updateOrder(id, patch) {
    const o = this.getOrder(id); if (!o) return null;
    Object.assign(o, patch, { updatedAt: Date.now() });
    this.save(); this.emit("order", o); return o;
  }
  summary() {
    return { account: this.publicAccount(), signals: this.s.signals.slice(0, 50), orders: this.s.orders.slice(0, 50), events: this.s.events.slice(0, 100) };
  }
}
