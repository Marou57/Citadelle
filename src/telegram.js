// Bot Telegram : envoie les signaux avec deux boutons (Valider / Refuser) et écoute les réponses.
// Fonctionne en « long polling » : pas besoin de configurer de webhook Telegram.

export class Telegram {
  constructor({ token, chatId, onDecision, log }) {
    this.token = token; this.chatId = String(chatId || ""); this.onDecision = onDecision; this.log = log || console.log;
    this.offset = 0; this.running = false;
  }
  get enabled() { return !!(this.token && this.chatId); }
  async call(method, body) {
    const r = await fetch(`https://api.telegram.org/bot${this.token}/${method}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    if (!j.ok) throw new Error(`Telegram ${method} : ${j.description || r.status}`);
    return j.result;
  }
  async sendSignal(sig, text) {
    if (!this.enabled) return null;
    const buttons = sig.status === "en attente" ? [[{ text: "✅ Valider", callback_data: "v:" + sig.id }, { text: "❌ Refuser", callback_data: "r:" + sig.id }]] : [];
    const m = await this.call("sendMessage", { chat_id: this.chatId, text, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: { inline_keyboard: buttons } });
    return m.message_id;
  }
  async edit(messageId, text) {
    if (!this.enabled || !messageId) return;
    await this.call("editMessageText", { chat_id: this.chatId, message_id: messageId, text, parse_mode: "HTML", disable_web_page_preview: true, reply_markup: { inline_keyboard: [] } }).catch(e => this.log("telegram", e.message));
  }
  async send(text) { if (this.enabled) await this.call("sendMessage", { chat_id: this.chatId, text, parse_mode: "HTML" }).catch(e => this.log("telegram", e.message)); }
  start() {
    if (!this.enabled || this.running) return;
    this.running = true;
    const loop = async () => {
      while (this.running) {
        try {
          const updates = await this.call("getUpdates", { offset: this.offset, timeout: 30, allowed_updates: ["callback_query", "message"] });
          for (const u of updates) {
            this.offset = u.update_id + 1;
            const q = u.callback_query;
            if (q) {
              if (String(q.message?.chat?.id) !== this.chatId) { await this.call("answerCallbackQuery", { callback_query_id: q.id, text: "Non autorisé" }).catch(() => {}); continue; }
              const [kind, id] = String(q.data || "").split(":");
              const res = await this.onDecision(id, kind === "v" ? "valider" : "refuser", "Telegram");
              await this.call("answerCallbackQuery", { callback_query_id: q.id, text: res.message }).catch(() => {});
            } else if (u.message && String(u.message.chat.id) === this.chatId && /^\/start|^\/id/.test(u.message.text || "")) {
              await this.send(`Citadelle connectée. Ton identifiant de discussion : <code>${u.message.chat.id}</code>`);
            }
          }
        } catch (e) {
          this.log("telegram", e.message);
          await new Promise(r => setTimeout(r, 5000));
        }
      }
    };
    loop();
  }
  stop() { this.running = false; }
}
