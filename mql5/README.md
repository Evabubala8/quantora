# Eva_XAUUSD_Recovery 5.00 (MQL5)

Implémentation du cahier des charges **version cible 5.00, révision 4.1** :
paire couverte BUY + SELL, fermeture CF10 à 10 pips (condition stratégique unique),
gestion du survivant par profil M15, filtres de séance / volatilité / coûts et garde-fous.
Exclusions respectées : aucun renfort (P6), pas d'ordres OCO (P7), aucun filtre d'annonces.

## Installation

1. Dans MetaTrader 5 : **Fichier → Ouvrir le dossier des données**.
2. Copier `Experts/Eva_XAUUSD_Recovery_V5.mq5` dans `MQL5/Experts/`.
3. Ouvrir le fichier dans MetaEditor (F4) et compiler (F7). Corriger toute erreur signalée avant usage.
4. Dans le terminal, glisser l'EA sur un graphique **XAUUSD** (n'importe quelle unité de temps)
   d'un compte **hedging**, et activer le trading algorithmique.

## Réglages à vérifier avant tout test

| Paramètre | À renseigner |
|---|---|
| `InpCommissionPerLotRT` | Commission aller-retour par lot et par jambe de votre courtier, dans la devise du compte. |
| `InpTesterServerGMTOffset` / `InpTesterServerUSDST` | Testeur uniquement : décalage horaire du serveur (souvent GMT+2 en hiver, +3 en été). |
| `InpAllowLiveTrading` | Laisser `false` tant que le protocole de validation (§11) n'est pas terminé. |
| `InpRiskPercentPerSeries` | 0,75 % par défaut ; 0,25 % pour les 100 premières séries en réel. |

Le pip est fixé à 0,10 (XAUUSD). Les constantes du cahier (10 pips, SL de secours 15 pips,
limites −2 % / −3 % / −5 %, 6 séries par jour, 3 pertes consécutives…) sont dans les `#define`
en tête du fichier et ne sont pas modifiables par un fichier `.set`.

## Testeur de stratégie

- Mode **« Chaque tick basé sur des ticks réels »**, calcul monétaire (pas en pips).
- Le journal des séries est écrit dans `MQL5/Files/EVA5_journal.csv`
  (`Tester/.../MQL5/Files` en backtest).
- Le blocage hebdomadaire (−5 %) se lève uniquement en passant `InpResetWeeklyBlock=true`
  après revue manuelle.

## Limites connues

- Le code n'a **pas été compilé ni testé** dans cet environnement : la compilation et un essai
  en démo sont obligatoires.
- Le source 4.31 d'origine n'étant pas disponible ici, la chaîne de signal (biais M15, motifs M5,
  cassure M5, confirmation M1) a été réécrite d'après sa description dans le cahier des charges ;
  ses résultats peuvent différer de ceux de la 4.31.
- Le SL de secours de 15 pips est calculé sur le prix demandé à l'ouverture, pas sur le prix exécuté.
- Aucun résultat de rentabilité n'est revendiqué : appliquer le protocole du §11 avant le réel.
