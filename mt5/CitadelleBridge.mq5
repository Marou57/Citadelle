//+------------------------------------------------------------------+
//| CitadelleBridge.mq5                                              |
//| 1. Envoie l'état du compte au serveur de la Citadelle.           |
//| 2. Détecte les setups de la stratégie « Gold Swing MTF »         |
//|    (tendance H4 + entrée H1) sur plusieurs marchés, calcule le   |
//|    risque adaptatif et envoie les setups au serveur.             |
//| 3. Seulement si AllowTrading = true : exécute les ordres validés.|
//| Dans le testeur de stratégie : prend les trades lui-même         |
//| (risque fixe, SL/TP) pour mesurer la stratégie sur l'historique. |
//+------------------------------------------------------------------+
#property copyright "Citadelle"
#property version   "0.30"
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

input group "Marchés"
input string Symbols = "XAUUSD,US100.cash,EURUSD,GBPJPY"; // séparés par des virgules (noms exacts chez ton courtier) ; vide = symbole du graphique

input group "Risque adaptatif"
input bool   AdaptiveRisk  = true;    // false = toujours RiskBase
input double RiskBase      = 1.0;     // risque normal par trade en %
input double RiskReduced   = 0.5;     // risque réduit en %
input int    LossStreak    = 2;       // après X pertes d'affilée : risque réduit jusqu'au prochain gain
input double DrawdownPct   = 4.0;     // équité à plus de X % sous le capital de départ : risque réduit
input double NearTargetPct = 2.0;     // à moins de X % de l'objectif : risque réduit (pour finir sans tout reperdre)

input group "Challenge FTMO"
input bool   ChallengeMode = true;    // ne plus ouvrir de trade une fois l'objectif atteint (ou la limite franchie en backtest)
input double StartBalance  = 0;       // capital de départ du challenge (0 = solde au démarrage du robot)
input double TargetPct     = 10.0;    // objectif en %
input double DailyLossPct  = 5.0;     // backtest : limite de perte du jour en % du capital de départ
input double MaxLossPct    = 10.0;    // backtest : limite de perte max en %
input int    MaxOpen       = 2;       // backtest : positions simultanées max (comme MAX_OPEN sur le serveur)
input bool   TestNoMonday  = true;    // backtest : pas de trade le lundi (comme le serveur)

CTrade trade;
struct Market
  {
   string            sym;
   int               hEmaF, hEmaS, hRsi, hT21, hT50, hT200;
   datetime          lastBar;
  };
Market mk[];
int    nMk = 0;
bool   inTester = false;
double startBal = 0, dayStartBal = 0, lowestEq = 0;
int    curDay = -1, testTrades = 0;
bool   targetHit = false, failed = false;
string targetInfo = "", failInfo = "";
datetime startTime = 0;

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
   ArrayResize(mk, 0);
   nMk = 0;
   if(StrategyEnabled)
     {
      string list[];
      int n = (StringLen(Symbols) > 0) ? StringSplit(Symbols, ',', list) : 0;
      for(int i = 0; i < n; i++)
        {
         string s = list[i];
         StringTrimLeft(s);
         StringTrimRight(s);
         if(StringLen(s) > 0)
            AddMarket(s);
        }
      if(nMk == 0)
         AddMarket(_Symbol);
      if(nMk == 0)
        {
         Print("Citadelle : aucun marché utilisable pour la stratégie.");
         return(INIT_FAILED);
        }
     }
   startBal = (StartBalance > 0) ? StartBalance : AccountInfoDouble(ACCOUNT_BALANCE);
   lowestEq = AccountInfoDouble(ACCOUNT_EQUITY);
   startTime = TimeCurrent();
   if(!inTester && StartBalance <= 0)
      Print("Citadelle : StartBalance = 0, le capital de départ pris est le solde actuel (", Num(startBal, 2), "). Mets le vrai capital du challenge pour un calcul juste.");
   if(!inTester)
      EventSetTimer(MathMax(2, PollSeconds));
   string names = "";
   for(int i = 0; i < nMk; i++)
      names += (i > 0 ? ", " : "") + mk[i].sym;
   Print("Citadelle : robot démarré. Marchés : ", (StrategyEnabled ? names : "stratégie désactivée"),
         ". Risque : ", (AdaptiveRisk ? "adaptatif " + Num(RiskBase, 2) + " % / " + Num(RiskReduced, 2) + " %" : "fixe " + Num(RiskBase, 2) + " %"),
         ". Exécution des ordres : ", (AllowTrading ? "ACTIVÉE" : "désactivée"), (inTester ? " (mode backtest)" : ""));
   return(INIT_SUCCEEDED);
  }
void AddMarket(string s)
  {
   for(int i = 0; i < nMk; i++)
      if(StringCompare(mk[i].sym, s, false) == 0)
         return;
   if(!SymbolSelect(s, true))
     {
      Print("Citadelle : marché introuvable chez ton courtier : ", s, " (ignoré). Vérifie le nom exact dans l'Observation du marché.");
      return;
     }
   Market m;
   m.sym = s;
   m.lastBar = 0;
   m.hEmaF = iMA(s, EntryTF, EmaFast, 0, MODE_EMA, PRICE_CLOSE);
   m.hEmaS = iMA(s, EntryTF, EmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   m.hRsi  = iRSI(s, EntryTF, RsiLen, PRICE_CLOSE);
   m.hT21  = iMA(s, TrendTF, EmaFast, 0, MODE_EMA, PRICE_CLOSE);
   m.hT50  = iMA(s, TrendTF, EmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   m.hT200 = iMA(s, TrendTF, EmaTrend, 0, MODE_EMA, PRICE_CLOSE);
   if(m.hEmaF == INVALID_HANDLE || m.hEmaS == INVALID_HANDLE || m.hRsi == INVALID_HANDLE || m.hT21 == INVALID_HANDLE || m.hT50 == INVALID_HANDLE || m.hT200 == INVALID_HANDLE)
     {
      Print("Citadelle : indicateurs impossibles à créer sur ", s, " (ignoré).");
      return;
     }
   ArrayResize(mk, nMk + 1);
   mk[nMk] = m;
   nMk++;
  }
void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < nMk; i++)
     {
      IndicatorRelease(mk[i].hEmaF);
      IndicatorRelease(mk[i].hEmaS);
      IndicatorRelease(mk[i].hRsi);
      IndicatorRelease(mk[i].hT21);
      IndicatorRelease(mk[i].hT50);
      IndicatorRelease(mk[i].hT200);
     }
   if(inTester && startBal > 0)
     {
      double worst = (startBal - lowestEq) / startBal * 100.0;
      Print("===== Résumé challenge =====");
      Print("Capital de départ : ", Num(startBal, 2), " · trades : ", testTrades, " · pire point : ", Num(worst, 2), " % sous le départ");
      Print("Objectif +", Num(TargetPct, 1), " % : ", (targetHit ? "ATTEINT " + targetInfo : "non atteint"));
      Print("Limites de perte : ", (failed ? "FRANCHIES " + failInfo : "respectées"));
     }
  }
void OnTimer()
  {
   SendSnapshot();
   if(AllowTrading)
      PollOrders();
   CheckAll();
  }
void OnTick()
  {
   CheckAll();
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
   sym = ResolveSymbol(sym);                             // le serveur met les noms en majuscules (US100.CASH → US100.cash)
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
//| Marchés, risque adaptatif et suivi du challenge                  |
//+------------------------------------------------------------------+
string ResolveSymbol(string s)
  {
   for(int i = 0; i < nMk; i++)
      if(StringCompare(mk[i].sym, s, false) == 0)
         return(mk[i].sym);
   return(s);
  }

// Pertes d'affilée du robot (trades fermés avec son numéro magique, du plus récent au plus ancien).
int LossesInARow()
  {
   if(!HistorySelect(0, TimeCurrent()))
      return(0);
   int cnt = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_MAGIC) != Magic)
         continue;
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e != DEAL_ENTRY_OUT && e != DEAL_ENTRY_OUT_BY)
         continue;
      double p = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(p < 0)
         cnt++;
      else
         break;
     }
   return(cnt);
  }

double CurrentRiskPct(string &why)
  {
   if(!AdaptiveRisk)
     { why = "fixe"; return(RiskBase); }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   int ls = LossesInARow();
   if(ls >= LossStreak)
     { why = IntegerToString(ls) + " pertes d'affilée"; return(RiskReduced); }
   if(startBal > 0 && (startBal - eq) / startBal * 100.0 >= DrawdownPct)
     { why = "sous le capital de départ"; return(RiskReduced); }
   if(startBal > 0 && ChallengeMode && (bal - startBal) / startBal * 100.0 >= TargetPct - NearTargetPct)
     { why = "proche de l'objectif"; return(RiskReduced); }
   why = "normal";
   return(RiskBase);
  }

// Objectif et limites de perte (les limites ne sont mesurées qu'en backtest : en réel, c'est FTMO et le serveur qui surveillent).
void ChallengeWatch()
  {
   if(startBal <= 0)
      return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != curDay)
     { curDay = dt.day_of_year; dayStartBal = bal; }
   if(!targetHit && bal >= startBal * (1.0 + TargetPct / 100.0))
     {
      targetHit = true;
      int days = (int)((TimeCurrent() - startTime) / 86400);
      targetInfo = "le " + TimeToString(TimeCurrent(), TIME_DATE) + " (" + IntegerToString(days) + " jours" + (inTester ? ", " + IntegerToString(testTrades) + " trades" : "") + ")";
      Print("Citadelle : objectif +", Num(TargetPct, 1), " % atteint ", targetInfo, (ChallengeMode ? ". Plus aucun nouveau trade." : "."));
     }
   if(!inTester)
      return;
   if(eq < lowestEq)
      lowestEq = eq;
   if(!failed && eq <= dayStartBal - startBal * DailyLossPct / 100.0)
     {
      failed = true;
      failInfo = "perte du jour le " + TimeToString(TimeCurrent(), TIME_DATE);
      Print("Citadelle : ÉCHEC, limite de perte du jour franchie le ", TimeToString(TimeCurrent()));
     }
   if(!failed && eq <= startBal * (1.0 - MaxLossPct / 100.0))
     {
      failed = true;
      failInfo = "perte max le " + TimeToString(TimeCurrent(), TIME_DATE);
      Print("Citadelle : ÉCHEC, limite de perte max franchie le ", TimeToString(TimeCurrent()));
     }
  }

bool CanOpen()
  {
   return(!(ChallengeMode && (targetHit || failed)));
  }

void CheckAll()
  {
   ChallengeWatch();
   if(!StrategyEnabled)
      return;
   for(int k = 0; k < nMk; k++)
      CheckMarket(k);
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
double AtrWilder(string s, int shift)
  {
   int n = AtrLen * 20;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(s, EntryTF, shift, n + 1, r);
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

void CheckMarket(int k)
  {
   string s = mk[k].sym;
   datetime t1 = iTime(s, EntryTF, 1);
   if(t1 == 0 || t1 == mk[k].lastBar)
      return;
   mk[k].lastBar = t1;                                   // une seule analyse par bougie clôturée
   if(Bars(s, EntryTF) < EmaTrend + 50 || Bars(s, TrendTF) < EmaTrend + 5)
      return;

   // Tendance : dernière bougie H4 clôturée (aucune information du futur)
   double t21 = Buf(mk[k].hT21, 1), t50 = Buf(mk[k].hT50, 1), t200 = Buf(mk[k].hT200, 1), tc = iClose(s, TrendTF, 1);
   // Entrée : dernière bougie H1 clôturée
   double e21 = Buf(mk[k].hEmaF, 1), e50 = Buf(mk[k].hEmaS, 1), rsi = Buf(mk[k].hRsi, 1);
   if(t21 == EMPTY_VALUE || t50 == EMPTY_VALUE || t200 == EMPTY_VALUE || e21 == EMPTY_VALUE || e50 == EMPTY_VALUE || rsi == EMPTY_VALUE || tc <= 0)
      return;
   double o = iOpen(s, EntryTF, 1), h = iHigh(s, EntryTF, 1), l = iLow(s, EntryTF, 1), c = iClose(s, EntryTF, 1);
   double atr = AtrWilder(s, 1);
   if(atr <= 0)
      return;
   double volSum = 0;
   for(int i = 1; i <= 20; i++)
      volSum += (double)iVolume(s, EntryTF, i);
   double vol = (double)iVolume(s, EntryTF, 1), volMa = volSum / 20.0;

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
   if(!CanOpen())
      return;

   int dg = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
   double slDist = atr * AtrMultSL;
   string side = longSig ? "buy" : "sell";
   double sl = NormalizeDouble(longSig ? c - slDist : c + slDist, dg);
   double tp = NormalizeDouble(longSig ? c + slDist * RRRatio : c - slDist * RRRatio, dg);
   string why;
   double riskPct = CurrentRiskPct(why);

   if(inTester)
      TestTrade(s, side, sl, tp, riskPct);
   else
      SendSignal(s, side, c, sl, tp, dg, riskPct, why);
  }

void SendSignal(string s, string side, double entry, double sl, double tp, int dg, double riskPct, string why)
  {
   string j = "{\"symbol\":\"" + Esc(s) + "\",\"side\":\"" + side + "\""
              + ",\"entry\":" + Num(entry, dg) + ",\"sl\":" + Num(sl, dg) + ",\"tp\":" + Num(tp, dg)
              + ",\"riskPct\":" + Num(riskPct, 2)
              + ",\"timeframe\":\"" + EnumToString(EntryTF) + "\",\"note\":\"Robot Gold Swing MTF · risque " + Num(riskPct, 2) + " % (" + Esc(why) + ")\"}";
   string resp;
   if(Http("POST", "/bridge/signal", j, resp))
      Print("Citadelle : setup ", side, " ", s, " envoyé au serveur (entrée ", Num(entry, dg), ", stop ", Num(sl, dg), ", objectif ", Num(tp, dg), ", risque ", Num(riskPct, 2), " % : ", why, ").");
  }

// Backtest : le robot prend le trade lui-même, comme si l'exécution automatique était active.
void TestTrade(string s, string side, double sl, double tp, double riskPct)
  {
   int open = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != Magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == s)
         return;                                         // une seule position par marché
      open++;
     }
   if(open >= MaxOpen)
      return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(TestNoMonday && dt.day_of_week == 1)
      return;
   MqlTick tk;
   if(!SymbolInfoTick(s, tk))
      return;
   double price = (side == "buy") ? tk.ask : tk.bid;
   if((side == "buy" && sl >= price) || (side == "sell" && sl <= price))
      return;
   string why;
   double lots = LotsForRisk(s, price, sl, AccountInfoDouble(ACCOUNT_BALANCE) * riskPct / 100.0, why);
   if(lots <= 0)
      return;
   bool ok = (side == "buy") ? trade.Buy(lots, s, 0, sl, tp, "Backtest Gold Swing")
                             : trade.Sell(lots, s, 0, sl, tp, "Backtest Gold Swing");
   if(ok)
      testTrades++;
  }
//+------------------------------------------------------------------+
