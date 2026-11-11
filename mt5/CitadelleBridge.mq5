//+------------------------------------------------------------------+
//| CitadelleBridge.mq5                                              |
//| Envoie l'état du compte au serveur de la Citadelle et, seulement |
//| si AllowTrading = true, exécute les ordres validés.              |
//| Avec le mot de passe en lecture seule, aucun ordre n'est possible.|
//+------------------------------------------------------------------+
#property copyright "Citadelle"
#property version   "0.10"
#property strict
#include <Trade/Trade.mqh>

input string ServerUrl    = "https://ton-serveur.exemple.com"; // adresse du serveur, sans / à la fin
input string BridgeKey    = "";                                 // même valeur que BRIDGE_KEY sur le serveur
input bool   AllowTrading = false;                              // laisser sur false tant que la phase 1 n'est pas validée
input int    PollSeconds  = 5;                                  // fréquence d'envoi
input long   Magic        = 57057;                              // identifiant des ordres du robot

CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(StringLen(BridgeKey) < 16)
     {
      Print("Citadelle : BridgeKey manquante ou trop courte.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   trade.SetExpertMagicNumber(Magic);
   EventSetTimer(MathMax(2, PollSeconds));
   Print("Citadelle : robot démarré. Exécution des ordres : ", (AllowTrading ? "ACTIVÉE" : "désactivée"));
   return(INIT_SUCCEEDED);
  }
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer()
  {
   SendSnapshot();
   if(AllowTrading)
      PollOrders();
  }

//+------------------------------------------------------------------+
string Esc(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return(s);
  }
string Num(double v, int digits) { return(DoubleToString(v, digits)); }

bool Http(string method, string path, string body, string &resp)
  {
   char data[], result[];
   string headers = "Content-Type: application/json\r\nX-Bridge-Key: " + BridgeKey + "\r\n";
   string respHeaders;
   if(StringLen(body) > 0)
     {
      int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(n > 0)
         ArrayResize(data, n - 1); // retire le zéro final
     }
   ResetLastError();
   int code = WebRequest(method, ServerUrl + path, headers, 5000, data, result, respHeaders);
   if(code == -1)
     {
      Print("Citadelle : WebRequest impossible (erreur ", GetLastError(), "). Ajoute ", ServerUrl, " dans Outils > Options > Expert Advisors > Autoriser WebRequest.");
      return(false);
     }
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code < 200 || code >= 300)
     {
      Print("Citadelle : le serveur a répondu ", code, " : ", resp);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
void SendSnapshot()
  {
   string j = "{\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
              + ",\"server\":\"" + Esc(AccountInfoString(ACCOUNT_SERVER)) + "\""
              + ",\"currency\":\"" + Esc(AccountInfoString(ACCOUNT_CURRENCY)) + "\""
              + ",\"balance\":" + Num(AccountInfoDouble(ACCOUNT_BALANCE), 2)
              + ",\"equity\":" + Num(AccountInfoDouble(ACCOUNT_EQUITY), 2)
              + ",\"tradeAllowed\":" + (AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "true" : "false")
              + ",\"positions\":[";
   bool first = true;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      string type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
      if(!first)
         j += ",";
      first = false;
      j += "{\"ticket\":" + IntegerToString((long)ticket)
           + ",\"symbol\":\"" + Esc(sym) + "\""
           + ",\"type\":\"" + type + "\""
           + ",\"volume\":" + Num(PositionGetDouble(POSITION_VOLUME), 2)
           + ",\"price\":" + Num(PositionGetDouble(POSITION_PRICE_OPEN), dg)
           + ",\"sl\":" + Num(PositionGetDouble(POSITION_SL), dg)
           + ",\"tp\":" + Num(PositionGetDouble(POSITION_TP), dg)
           + ",\"profit\":" + Num(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP), 2)
           + ",\"time\":" + IntegerToString((long)PositionGetInteger(POSITION_TIME))
           + "}";
     }
   j += "]}";
   string resp;
   Http("POST", "/bridge/snapshot", j, resp);
  }

//+------------------------------------------------------------------+
void PollOrders()
  {
   string resp;
   string path = "/bridge/orders?login=" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   if(!Http("GET", path, "", resp) || StringLen(resp) == 0)
      return;
   string lines[];
   int n = StringSplit(resp, '\n', lines);
   for(int i = 0; i < n; i++)
      if(StringLen(lines[i]) > 0)
         Execute(lines[i]);
  }

void Report(string id, bool ok, ulong ticket, double volume, string message)
  {
   string j = "{\"orderId\":\"" + Esc(id) + "\",\"ok\":" + (ok ? "true" : "false")
              + ",\"ticket\":\"" + IntegerToString((long)ticket) + "\",\"volume\":" + Num(volume, 2)
              + ",\"message\":\"" + Esc(message) + "\"}";
   string resp;
   Http("POST", "/bridge/report", j, resp);
  }

// Ligne reçue : id|symbole|sens|stop|objectif|risque (risque en devise du compte)
void Execute(string line)
  {
   string f[];
   if(StringSplit(line, '|', f) < 6)
      return;
   string id = f[0], sym = f[1], side = f[2];
   double sl = StringToDouble(f[3]), tp = StringToDouble(f[4]), risk = StringToDouble(f[5]);
   if(!SymbolSelect(sym, true))
     { Report(id, false, 0, 0, "symbole introuvable : " + sym); return; }
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, dg);
   tp = (tp > 0) ? NormalizeDouble(tp, dg) : 0;
   MqlTick tk;
   if(!SymbolInfoTick(sym, tk))
     { Report(id, false, 0, 0, "pas de prix pour " + sym); return; }
   double price = (side == "buy") ? tk.ask : tk.bid;
   if((side == "buy" && sl >= price) || (side == "sell" && sl <= price) || sl <= 0)
     { Report(id, false, 0, 0, "stop invalide par rapport au prix actuel"); return; }

   // Taille de position : le risque en devise du compte divisé par la perte par lot si le stop est touché.
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0)
     { Report(id, false, 0, 0, "spécifications du symbole indisponibles"); return; }
   double lossPerLot = MathAbs(price - sl) / tickSize * tickValue;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lots = MathFloor((risk / lossPerLot) / step) * step;
   if(lots < vmin)
     { Report(id, false, 0, 0, "risque trop faible pour le lot minimum"); return; }
   lots = MathMin(lots, vmax);
   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   lots = NormalizeDouble(lots, volDigits);

   bool sent = (side == "buy") ? trade.Buy(lots, sym, 0, sl, tp, "Citadelle " + id)
                               : trade.Sell(lots, sym, 0, sl, tp, "Citadelle " + id);
   uint rc = trade.ResultRetcode();
   bool ok = sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
   Report(id, ok, trade.ResultOrder(), lots, trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
