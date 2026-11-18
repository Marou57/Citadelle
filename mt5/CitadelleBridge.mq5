//+------------------------------------------------------------------+
//| CitadelleBridge.mq5                                              |
//| 1. Envoie l'état du compte au serveur de la Citadelle.           |
//| 2. Détecte les setups de la stratégie « Gold Swing MTF »         |
//|    (tendance H4 + entrée H1) et les envoie au serveur.           |
//| 3. Seulement si AllowTrading = true : exécute les ordres validés.|
//| Dans le testeur de stratégie : prend les trades lui-même         |
//| (risque fixe, SL/TP) pour mesurer la stratégie sur l'historique. |
//+------------------------------------------------------------------+
#property copyright "Citadelle"
#property version   "0.20"
#property strict
#include <Trade/Trade.mqh>

input group "Connexion au serveur"
input string ServerUrl    = "https://ton-serveur.exemple.com"; // adresse du serveur, sans / à la fin
input string BridgeKey    = "";                                 // même valeur que BRIDGE_KEY sur le serveur
input bool   AllowTrading = false;                              // laisser sur false tant que la phase 1 n'est pas validée
input int    PollSeconds  = 5;                                  // fréquence d'envoi
input long   Magic        = 57057;                              // identifiant des ordres du robot

input group "Stratégie Gold Swing MTF (traduite du script Pine)"
input bool            StrategyEnabled = true;       // détecter les setups et les envoyer au serveur
input ENUM_TIMEFRAMES EntryTF   = PERIOD_H1;        // unité de temps d'entrée
input ENUM_TIMEFRAMES TrendTF   = PERIOD_H4;        // unité de temps de tendance
input int             EmaFast   = 21;
input int             EmaSlow   = 50;
input int             EmaTrend  = 200;
input int             AtrLen    = 14;
input int             RsiLen    = 14;
input double          AtrMultSL = 2.0;              // stop = ATR × 2
input double          RRRatio   = 3.0;              // objectif = 3 × le stop
input double          VolFactor = 1.05;             // volume > moyenne 20 × 1,05

input group "Backtest (testeur de stratégie uniquement)"
input double TestRiskPct  = 1.0;                    // risque par trade en %
input bool   TestNoMonday = true;                   // reproduit la règle « pas de trade le lundi » du serveur

CTrade trade;
int hEmaF = INVALID_HANDLE, hEmaS = INVALID_HANDLE, hRsi = INVALID_HANDLE;
int hT21 = INVALID_HANDLE, hT50 = INVALID_HANDLE, hT200 = INVALID_HANDLE;
bool inTester = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   inTester = (bool)MQLInfoInteger(MQL_TESTER);
   if(!inTester && StringLen(BridgeKey) < 16)
     {
      Print("Citadelle : BridgeKey manquante ou trop courte.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   trade.SetExpertMagicNumber(Magic);
   if(StrategyEnabled)
     {
      hEmaF = iMA(_Symbol, EntryTF, EmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hEmaS = iMA(_Symbol, EntryTF, EmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      hRsi  = iRSI(_Symbol, EntryTF, RsiLen, PRICE_CLOSE);
      hT21  = iMA(_Symbol, TrendTF, EmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hT50  = iMA(_Symbol, TrendTF, EmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      hT200 = iMA(_Symbol, TrendTF, EmaTrend, 0, MODE_EMA, PRICE_CLOSE);
      if(hEmaF == INVALID_HANDLE || hEmaS == INVALID_HANDLE || hRsi == INVALID_HANDLE || hT21 == INVALID_HANDLE || hT50 == INVALID_HANDLE || hT200 == INVALID_HANDLE)
        {
         Print("Citadelle : impossible de créer les indicateurs de la stratégie.");
         return(INIT_FAILED);
        }
     }
   if(!inTester)
      EventSetTimer(MathMax(2, PollSeconds));
   Print("Citadelle : robot démarré sur ", _Symbol, ". Stratégie : ", (StrategyEnabled ? "active" : "désactivée"),
         ". Exécution des ordres : ", (AllowTrading ? "ACTIVÉE" : "désactivée"), (inTester ? " (mode backtest)" : ""));
   return(INIT_SUCCEEDED);
  }
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(hEmaF != INVALID_HANDLE) IndicatorRelease(hEmaF);
   if(hEmaS != INVALID_HANDLE) IndicatorRelease(hEmaS);
   if(hRsi  != INVALID_HANDLE) IndicatorRelease(hRsi);
   if(hT21  != INVALID_HANDLE) IndicatorRelease(hT21);
   if(hT50  != INVALID_HANDLE) IndicatorRelease(hT50);
   if(hT200 != INVALID_HANDLE) IndicatorRelease(hT200);
  }
void OnTimer()
  {
   SendSnapshot();
   if(AllowTrading)
      PollOrders();
  }
void OnTick()
  {
   if(StrategyEnabled)
      CheckStrategy();
  }

//+------------------------------------------------------------------+
//| Outils                                                           |
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

// Taille de lot pour risquer « risk » (devise du compte) entre price et sl. 0 si impossible.
double LotsForRisk(string sym, double price, double sl, double risk, string &why)
  {
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0)
     { why = "spécifications du symbole indisponibles"; return(0); }
   double lossPerLot = MathAbs(price - sl) / tickSize * tickValue;
   if(lossPerLot <= 0)
     { why = "stop trop proche"; return(0); }
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lots = MathFloor((risk / lossPerLot) / step) * step;
   if(lots < vmin)
     { why = "risque trop faible pour le lot minimum"; return(0); }
   lots = MathMin(lots, vmax);
   int volDigits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return(NormalizeDouble(lots, volDigits));
  }

//+------------------------------------------------------------------+
//| Pont : état du compte                                            |
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
//| Pont : ordres validés                                            |
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
   string why;
   double lots = LotsForRisk(sym, price, sl, risk, why);
   if(lots <= 0)
     { Report(id, false, 0, 0, why); return; }
   bool sent = (side == "buy") ? trade.Buy(lots, sym, 0, sl, tp, "Citadelle " + id)
                               : trade.Sell(lots, sym, 0, sl, tp, "Citadelle " + id);
   uint rc = trade.ResultRetcode();
   bool ok = sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
   Report(id, ok, trade.ResultOrder(), lots, trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Stratégie Gold Swing MTF                                         |
//+------------------------------------------------------------------+
double Buf(int handle, int shift)
  {
   double v[1];
   if(CopyBuffer(handle, 0, shift, 1, v) != 1)
      return(EMPTY_VALUE);
   return(v[0]);
  }

// ATR lissé à la manière de TradingView (moyenne de Wilder), pour coller au script Pine.
double AtrWilder(int shift)
  {
   int n = AtrLen * 20;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(_Symbol, EntryTF, shift, n + 1, r);
   if(got < AtrLen + 2)
      return(0);
   double atr = 0;
   for(int i = 1; i < got; i++)
     {
      double tr = MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i <= AtrLen)
        {
         atr += tr;
         if(i == AtrLen)
            atr /= AtrLen;
        }
      else
         atr = (atr * (AtrLen - 1) + tr) / AtrLen;
     }
   return(atr);
  }

void CheckStrategy()
  {
   static datetime lastBar = 0;
   datetime t1 = iTime(_Symbol, EntryTF, 1);
   if(t1 == 0 || t1 == lastBar)
      return;
   lastBar = t1;                                         // une seule analyse par bougie clôturée
   if(Bars(_Symbol, EntryTF) < EmaTrend + 50 || Bars(_Symbol, TrendTF) < EmaTrend + 5)
      return;

   // Tendance : dernière bougie H4 clôturée (aucune information du futur)
   double t21 = Buf(hT21, 1), t50 = Buf(hT50, 1), t200 = Buf(hT200, 1), tc = iClose(_Symbol, TrendTF, 1);
   // Entrée : dernière bougie H1 clôturée
   double e21 = Buf(hEmaF, 1), e50 = Buf(hEmaS, 1), rsi = Buf(hRsi, 1);
   if(t21 == EMPTY_VALUE || t50 == EMPTY_VALUE || t200 == EMPTY_VALUE || e21 == EMPTY_VALUE || e50 == EMPTY_VALUE || rsi == EMPTY_VALUE || tc <= 0)
      return;
   double o = iOpen(_Symbol, EntryTF, 1), h = iHigh(_Symbol, EntryTF, 1), l = iLow(_Symbol, EntryTF, 1), c = iClose(_Symbol, EntryTF, 1);
   double atr = AtrWilder(1);
   if(atr <= 0)
      return;
   double volSum = 0;
   for(int i = 1; i <= 20; i++)
      volSum += (double)iVolume(_Symbol, EntryTF, i);
   double vol = (double)iVolume(_Symbol, EntryTF, 1), volMa = volSum / 20.0;

   bool h4Bull = t21 > t50 && t50 > t200 && tc > t200;
   bool h4Bear = t21 < t50 && t50 < t200 && tc < t200;
   bool h1Bull = e21 > e50 && c > e21;
   bool h1Bear = e21 < e50 && c < e21;
   bool pbBull = l <= e21 + atr * 0.3 && l >= e21 - atr * 0.5 && c > e21;
   bool pbBear = h >= e21 - atr * 0.3 && h <= e21 + atr * 0.5 && c < e21;
   bool bullCd = c > o && (c - o) >= atr * 0.4 && c >= h - atr * 0.25;
   bool bearCd = c < o && (o - c) >= atr * 0.4 && c <= l + atr * 0.25;
   bool volOk  = vol > volMa * VolFactor;
   bool rsiBull = rsi > 40 && rsi < 68;
   bool rsiBear = rsi < 60 && rsi > 32;

   bool longSig  = h4Bull && h1Bull && pbBull && bullCd && volOk && rsiBull;
   bool shortSig = h4Bear && h1Bear && pbBear && bearCd && volOk && rsiBear;
   if(!longSig && !shortSig)
      return;

   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double slDist = atr * AtrMultSL;
   string side = longSig ? "buy" : "sell";
   double sl = NormalizeDouble(longSig ? c - slDist : c + slDist, dg);
   double tp = NormalizeDouble(longSig ? c + slDist * RRRatio : c - slDist * RRRatio, dg);

   if(inTester)
      TestTrade(side, sl, tp);
   else
      SendSignal(side, c, sl, tp, dg);
  }

void SendSignal(string side, double entry, double sl, double tp, int dg)
  {
   string j = "{\"symbol\":\"" + Esc(_Symbol) + "\",\"side\":\"" + side + "\""
              + ",\"entry\":" + Num(entry, dg) + ",\"sl\":" + Num(sl, dg) + ",\"tp\":" + Num(tp, dg)
              + ",\"timeframe\":\"" + EnumToString(EntryTF) + "\",\"note\":\"Robot Gold Swing MTF\"}";
   string resp;
   if(Http("POST", "/bridge/signal", j, resp))
      Print("Citadelle : setup ", side, " envoyé au serveur (entrée ", Num(entry, dg), ", stop ", Num(sl, dg), ", objectif ", Num(tp, dg), ").");
  }

// Backtest : le robot prend le trade lui-même, comme si tu l'avais validé.
void TestTrade(string side, double sl, double tp)
  {
   if(PositionSelect(_Symbol))
      return;                                            // une seule position par actif
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(TestNoMonday && dt.day_of_week == 1)
      return;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;
   double price = (side == "buy") ? tk.ask : tk.bid;
   if((side == "buy" && sl >= price) || (side == "sell" && sl <= price))
      return;
   string why;
   double lots = LotsForRisk(_Symbol, price, sl, AccountInfoDouble(ACCOUNT_BALANCE) * TestRiskPct / 100.0, why);
   if(lots <= 0)
      return;
   if(side == "buy")
      trade.Buy(lots, _Symbol, 0, sl, tp, "Backtest Gold Swing");
   else
      trade.Sell(lots, _Symbol, 0, sl, tp, "Backtest Gold Swing");
  }
//+------------------------------------------------------------------+
