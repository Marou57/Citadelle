# Citadelle · serveur central

Le cerveau de ta citadelle. Il reçoit tes alertes TradingView, applique les règles du Sniper System, te demande de valider, et parle au robot MetaTrader 5.

```
TradingView ──alerte──▶ Serveur ──règles──▶ Telegram / page web ──ta validation──▶ file d'ordres
                           ▲                                                           │
                           └──── solde, positions (toutes les 5 s) ──── Robot MT5 ◀────┘
```

**Par défaut, aucun ordre n'est passé** (`EXECUTION_MODE=off`). Même activée, l'exécution ne part que vers le numéro de compte indiqué dans `EXECUTION_LOGIN`, et seulement si le robot a `AllowTrading=true`.

## Les règles vérifiées à chaque alerte

| Règle | Réglage |
|---|---|
| Actif autorisé (XAUUSD, EURUSD, BTCUSD) | `ALLOWED_SYMBOLS` |
| Stop du bon côté de l'entrée | — |
| Ratio gain/risque minimum (2 par défaut) | `MIN_RR` |
| Pas de trade le lundi | `NO_MONDAY` |
| Fenêtres d'annonces bloquées | `NEWS_BLOCKS` |
| Perte du jour + risque du trade sous la limite, avec une marge | `MAX_DAILY_LOSS_PCT`, `DAILY_BUFFER_PCT` |
| Perte maximale du compte | `MAX_LOSS_PCT` |
| Une seule position par actif, nombre maximum de positions | `MAX_OPEN` |
| Risque fixe (1 % du solde) | `RISK_PCT` |

Vérifie les limites exactes de ton compte FTMO et ajuste `MAX_DAILY_LOSS_PCT` et `MAX_LOSS_PCT`. La taille de lot est calculée par le robot avec les vraies spécifications du symbole chez FTMO.

## Mise en route depuis l'iPad

### 1. Le bot Telegram
1. Dans Telegram, ouvre **@BotFather**, envoie `/newbot` et suis les étapes. Garde le **token**.
2. Envoie un message à ton nouveau bot.
3. Dans Safari, ouvre `https://api.telegram.org/bot<TON_TOKEN>/getUpdates` : ton identifiant est le nombre après `"chat":{"id":`. C'est `TELEGRAM_CHAT_ID`.

### 2. Les trois secrets
Génère trois mots de passe de 32 caractères (l'app Mots de passe de l'iPad sait le faire) pour `WEBHOOK_SECRET`, `BRIDGE_KEY` et `DASHBOARD_KEY`. Ne les colle jamais dans le code ni dans une conversation.

### 3. Le code sur GitHub
Dépôt **privé** `citadelle-serveur`. Ne mets jamais de fichier `.env` rempli dans le dépôt.

### 4. L'hébergement (DigitalOcean App Platform)
1. Create → App → GitHub → choisis le dépôt. Node.js est détecté tout seul.
2. Ajoute les variables de `.env.example` dans « Environment variables », en mode chiffré pour les secrets.
3. Déploie, récupère l'adresse publique, puis renseigne-la dans `PUBLIC_URL` et redéploie.
4. Vérifie `https://ton-adresse/health`.

À savoir : sur App Platform, le disque n'est pas permanent. L'historique des signaux repart à zéro à chaque redéploiement. C'est acceptable pour la phase 1 ; on passera ensuite à une base de données.

### 5. Les alertes TradingView
Les alertes par webhook demandent un abonnement TradingView payant.
- URL du webhook : `https://ton-adresse/webhook/tradingview`
- Message de l'alerte (exemple dans ton script Pine) :

```pine
if longSignal
    alert('{"secret":"' + secret + '","symbol":"' + syminfo.ticker + '","side":"buy","entry":' + str.tostring(close) + ',"sl":' + str.tostring(stopLevel) + ',"tp":' + str.tostring(targetLevel) + ',"timeframe":"' + timeframe.period + '"}', alert.freq_once_per_bar_close)
```

### 6. Le robot MetaTrader 5 (avec ton compte FTMO)
1. Loue un petit serveur Windows (VPS) et installe MetaTrader 5.
2. Connecte-toi à FTMO avec le **mot de passe en lecture seule** pour la phase 1.
3. Copie `mt5/CitadelleBridge.mq5` dans `MQL5/Experts`, puis compile-le dans MetaEditor.
4. Outils → Options → Expert Advisors : coche « Autoriser WebRequest » et ajoute l'adresse de ton serveur.
5. Glisse le robot sur un graphique, renseigne `ServerUrl` et `BridgeKey`, et laisse `AllowTrading=false`.

### 7. Le tableau de bord
`https://ton-adresse/tableau?k=TA_DASHBOARD_KEY` : ajoute-le à l'écran d'accueil de l'iPad.

## Les phases, dans l'ordre

1. **Lecture seule** : le robot envoie le compte, rien d'autre. `EXECUTION_MODE=off`.
2. **Vraies alertes, validation simulée** : tu valides sur Telegram, aucun ordre ne part.
3. **Compte d'essai FTMO** pendant au moins deux semaines : `EXECUTION_MODE=demo`, `EXECUTION_LOGIN=<numéro du compte d'essai>`, mot de passe principal de ce compte, `AllowTrading=true`.
4. **Compte réel** seulement si la phase 3 est propre : `EXECUTION_MODE=live`, `EXECUTION_LOGIN=<ton compte>`.

## Tests

```
npm install
npm test
```
