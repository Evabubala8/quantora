//+------------------------------------------------------------------+
//|                                   Eva_XAUUSD_Recovery_V5.mq5     |
//|  Version cible 5.00 — cahier des charges révision 4.1            |
//|  Paire couverte BUY+SELL, fermeture CF10 à 10 pips (condition    |
//|  stratégique unique), gestion du survivant par profil M15,       |
//|  filtres de séance / volatilité / coûts, garde-fous de risque.   |
//|  Exclusions : renforts (P6), ordres OCO (P7), filtre d'annonces. |
//+------------------------------------------------------------------+
#property copyright "Eva"
#property version   "5.00"
#property description "Recovery 5.00 : CF10 10 pips + gestion du survivant (rev. 4.1)"

#include <Trade/Trade.mqh>

//--- constantes fixes du cahier des charges (non modifiables par .set)
#define EVA_BUILD            "5.00"
#define PIP                  0.10     // InpPipSize XAUUSD
#define CF10_PIPS            10.0     // seuil CF10, comparaison >=
#define EMERGENCY_SL_PIPS    15.0     // SL serveur de secours par jambe
#define LOCK_OFFSET_PIPS     0.5      // marge du verrou de série V
#define MIN_LOT_MULTIPLE     4.0      // volume par jambe >= 4 x lot minimal
#define MAX_CONCURRENT       1        // séries simultanées
#define LOSS_PAUSE_MIN       10       // pause après série perdante
#define ZONE_PIPS            15.0     // zone anti-retournement
#define ZONE_MIN             60
#define MAX_CONSEC_LOSSES    3
#define MAX_SERIES_PER_DAY   6
#define DAILY_STOP_PCT       2.0
#define DAILY_FLAT_PCT       3.0
#define WEEKLY_STOP_PCT      5.0
#define SL0_ALERT_SEC        10
#define SL0_CLOSE_SEC        60
#define LEG2_TIMEOUT_SEC     3

//--- statuts de sortie (journal)
enum ECloseReason
  {
   CR_NONE=0, CR_CF10=1, CR_INCIDENT=2, CR_TIME=3, CR_SL0_FAIL=4,
   CR_DAILY_CLOSE=5, CR_WEEKLY_CLOSE=6, CR_DAILY_LIMIT=7, CR_OPPOSED_NOW=8
  };

//=========================== PARAMÈTRES =============================
input group "Identification"
input ulong  InpMagic                 = 26091805;
input bool   InpAllowLiveTrading      = false;   // autorise les entrées sur compte réel
input int    InpDeviationPoints       = 30;

input group "Volume et risque"
input double InpRiskPercentPerSeries  = 0.75;    // 0,25 à 1,00 %
input bool   InpUseFixedLot           = false;
input double InpFixedLot              = 0.10;
input double InpMaxLotPerTrade        = 0.50;
input double InpCommissionPerLotRT    = 7.0;     // commission A/R par lot et par jambe, devise du compte
input double InpSlippageMarginPips    = 3.0;     // marge de glissement dans L_max

input group "Séances (heure de Londres)"
input int    InpSessionStartMin       = 420;     // 07:00
input int    InpSessionEndMin         = 990;     // 16:30
input int    InpFridayEndMin          = 840;     // 14:00
input int    InpDailyCloseMin         = 1245;    // 20:45 lundi-jeudi
input int    InpWeeklyCloseMin        = 1230;    // 20:30 vendredi
input int    InpTesterServerGMTOffset = 2;       // testeur uniquement : décalage du serveur en hiver
input bool   InpTesterServerUSDST     = true;    // testeur : serveur suit l'heure d'été US (+1 h)

input group "Régime de volatilité"
input double InpATR1MaxCoef           = 0.75;    // ATR M1 <= coef x (10 - spread)
input double InpATR1MinPips           = 2.0;
input double InpATR5RatioMax          = 1.30;    // ATR5[1] / moyenne ATR5 50 bougies

input group "Coûts"
input double InpMaxSpreadPips         = 2.0;
input double InpMaxSeriesCostPips     = 5.5;

input group "Survivant — profil aligné (large)"
input double InpAl_SL0                = 10.0;
input double InpAl_AThr               = 18.0;
input double InpAl_BThr               = 25.0;
input double InpAl_BMinDist           = 12.0;
input double InpAl_PartThr            = 40.0;
input double InpAl_PartPct            = 30.0;
input double InpAl_TrailBuf           = 3.0;
input int    InpAl_MaxMinNoA          = 60;
input int    InpAl_MaxMinNoB          = 180;

input group "Survivant — profil neutre"
input double InpNe_SL0                = 5.0;
input double InpNe_AThr               = 15.0;
input double InpNe_BThr               = 22.0;
input double InpNe_BMinDist           = 8.0;
input double InpNe_PartThr            = 32.0;
input double InpNe_PartPct            = 50.0;
input double InpNe_TrailBuf           = 2.0;
input double InpNe_M5SwitchPips       = 50.0;
input int    InpNe_MaxMinNoA          = 30;
input int    InpNe_MaxMinNoB          = 120;

input group "Survivant — profil opposé (serré)"
input double InpOp_SL0                = 0.0;
input double InpOp_BThr               = 18.0;
input double InpOp_BMinDist           = 6.0;
input double InpOp_PartThr            = 25.0;
input double InpOp_PartPct            = 50.0;
input double InpOp_TrailBuf           = 1.5;
input int    InpOp_MaxMinNoB          = 15;
input bool   InpOpposedCloseImmediately = false; // variante de contrôle §11.2

input group "Signal M15 / M5 / M1 (repris du source 4.31)"
input int    InpFastEMA               = 9;
input int    InpSlowEMA               = 21;
input int    InpATRPeriod             = 14;
input int    InpSlopeLookback         = 3;
input double InpFastSlopeMin          = 0.05;
input double InpSlowSlopeMin          = 0.02;
input double InpEMAMinDistanceATR     = 0.05;
input int    InpSwingStrength         = 2;
input int    InpStructureLookback     = 100;
input bool   InpUseCandleSignals      = true;
input double InpCandleMinBodyPoints   = 0.0;
input double InpPinBarWickBodyRatio   = 2.5;
input int    InpLevelLookback         = 120;
input int    InpMinLevelTouches       = 2;
input double InpLevelToleranceATR     = 0.15;
input double InpZoneWidthATR          = 0.10;
input double InpBreakoutBufferATR     = 0.10;
input double InpBreakoutBodyATR       = 0.50;
input double InpBreakoutCloseRatio    = 0.70;
input double InpMaxBreakoutRangeATR   = 2.50;
input double InpMaxExtensionATR       = 2.00;
input int    InpM1TriggerLookback     = 30;
input double InpM1BodyATR             = 0.30;
input double InpM1BreakBufferATR      = 0.05;

input group "Maintenance"
input bool   InpResetWeeklyBlock      = false;   // à activer après revue manuelle (-5 %/semaine)

//=========================== ÉTAT ===================================
CTrade   trade;
string   GVP;                       // préfixe des variables globales

int hEmaF15, hEmaS15, hAtr15, hAtr5, hAtr1, hEmaF1, hEmaS1;

// série
bool     sActive=false;
long     sId=0;
ulong    sT[2];                     // tickets #1 / #2
int      sDir=0;                    // sens du signal (+1 BUY / -1 SELL)
double   sVol=0;
datetime sOpenTime=0;
double   sEntry[2];
bool     sIntent[2];
int      sReason[2];
datetime sNext[2];
int      sTries[2];
bool     sIncident=false;
bool     sCutDone=false;
datetime sCutTime=0;
double   sLossPips=0;               // perte réelle de la jambe fermée (pips, positive)
int      sProfile=0;                // +1 aligné, 0 neutre, -1 opposé
double   sLock=0;                   // verrou V
int      sStage=0;                  // 0 aucune, 1 A, 2 B
bool     sPartial=false;
datetime sStageATime=0;
bool     sSL0Done=false;
bool     sSL0Alerted=false;
datetime sLastModify=0;
datetime sLastPartialTry=0;
int      sCutWaitCount=0;

// compte / garde-fous
int      gDayKey=0, gWeekKey=0;
double   gDayStartEq=0, gWeekStartEq=0;
int      gSeriesToday=0, gConsecLosses=0, gConsecBlockDay=0;
bool     gDayHardStop=false, gWeekBlocked=false;
datetime gLastLossTime=0;
double   gLastLossPrice=0;
long     gSeriesCounter=0;

// setup de signal
int      gSetupDir=0;
datetime gBreakoutTime=0;           // clôture de la bougie M5 de cassure
datetime gLastBreakoutBar=0;
datetime gLastM1=0, gLastM5=0;

// spreads (médiane des 20 derniers ticks)
double   gSpreads[20];
int      gSpreadCount=0, gSpreadPos=0;
bool     gForeignWarned=false;
datetime gLastRefusalLog=0;
string   gLastRefusal="";

//=========================== OUTILS =================================
double Buf(int h,int shift)
  {
   double b[1];
   if(CopyBuffer(h,0,shift,1,b)!=1) return EMPTY_VALUE;
   return b[0];
  }
double Bid() { return SymbolInfoDouble(_Symbol,SYMBOL_BID); }
double Ask() { return SymbolInfoDouble(_Symbol,SYMBOL_ASK); }
double SpreadPips() { return (Ask()-Bid())/PIP; }
double NormPrice(double p)
  {
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) ts=_Point;
   return NormalizeDouble(MathRound(p/ts)*ts,_Digits);
  }
double PipValuePerLot()
  {
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(ts<=0) return 0;
   return tv*PIP/ts;
  }
double CommPipsSeries()
  {
   double pv=PipValuePerLot();
   if(pv<=0) return 0;
   return 2.0*InpCommissionPerLotRT/pv;
  }
void Log(string s) { Print("EVA5 S",sId," | ",s); }

//--- heure de Londres -------------------------------------------------
datetime NthSunday(int year,int mon,int n)          // n>=1 ; n=0 => dernier
  {
   MqlDateTime d; d.year=year; d.mon=mon; d.day=1; d.hour=0; d.min=0; d.sec=0;
   datetime t=StructToTime(d);
   MqlDateTime x; TimeToStruct(t,x);
   int first=(7-x.day_of_week)%7;                    // jours jusqu'au 1er dimanche
   if(n>0) return t+(first+7*(n-1))*86400;
   datetime s=t+first*86400, last=s;
   while(true)
     {
      datetime nx=s+7*86400; MqlDateTime y; TimeToStruct(nx,y);
      if(y.mon!=mon) break;
      s=nx; last=s;
     }
   return last;
  }
bool EUSummer(datetime gmt)
  {
   MqlDateTime d; TimeToStruct(gmt,d);
   datetime st=NthSunday(d.year,3,0)+3600, en=NthSunday(d.year,10,0)+3600;
   return gmt>=st && gmt<en;
  }
bool USSummer(datetime t)
  {
   MqlDateTime d; TimeToStruct(t,d);
   datetime st=NthSunday(d.year,3,2)+7*3600, en=NthSunday(d.year,11,1)+6*3600;
   return t>=st && t<en;
  }
datetime NowGMT()
  {
   if(MQLInfoInteger(MQL_TESTER))
     {
      datetime srv=TimeCurrent();
      int off=InpTesterServerGMTOffset+((InpTesterServerUSDST && USSummer(srv))?1:0);
      return srv-off*3600;
     }
   return TimeGMT();
  }
datetime NowLondon()
  {
   datetime g=NowGMT();
   return g+(EUSummer(g)?3600:0);
  }
int LondonMinutes(int &dow,int &dayKey)
  {
   MqlDateTime d; TimeToStruct(NowLondon(),d);
   dow=d.day_of_week;
   dayKey=d.year*10000+d.mon*100+d.day;
   return d.hour*60+d.min;
  }

//--- swings -----------------------------------------------------------
bool IsSwingHigh(ENUM_TIMEFRAMES tf,int i,int s)
  {
   double h=iHigh(_Symbol,tf,i);
   for(int k=1;k<=s;k++)
      if(iHigh(_Symbol,tf,i-k)>=h || iHigh(_Symbol,tf,i+k)>=h) return false;
   return true;
  }
bool IsSwingLow(ENUM_TIMEFRAMES tf,int i,int s)
  {
   double l=iLow(_Symbol,tf,i);
   for(int k=1;k<=s;k++)
      if(iLow(_Symbol,tf,i-k)<=l || iLow(_Symbol,tf,i+k)<=l) return false;
   return true;
  }

//=========================== PERSISTANCE ============================
void GVs(string k,double v) { GlobalVariableSet(GVP+k,v); }
double GVg(string k,double def) { return GlobalVariableCheck(GVP+k)?GlobalVariableGet(GVP+k):def; }

void SaveSeries()
  {
   GVs("act",sActive?1:0); GVs("id",(double)sId);
   GVs("t0",(double)sT[0]); GVs("t1",(double)sT[1]);
   GVs("dir",sDir); GVs("vol",sVol); GVs("ot",(double)sOpenTime);
   GVs("e0",sEntry[0]); GVs("e1",sEntry[1]);
   for(int i=0;i<2;i++)
     {
      GVs("in"+(string)i,sIntent[i]?1:0);
      GVs("rs"+(string)i,sReason[i]);
     }
   GVs("inc",sIncident?1:0); GVs("cut",sCutDone?1:0); GVs("ct",(double)sCutTime);
   GVs("lp",sLossPips); GVs("pf",sProfile); GVs("lk",sLock); GVs("st",sStage);
   GVs("pt",sPartial?1:0); GVs("sat",(double)sStageATime); GVs("sl0",sSL0Done?1:0);
  }
void LoadSeries()
  {
   sActive=GVg("act",0)>0.5; sId=(long)GVg("id",0);
   sT[0]=(ulong)GVg("t0",0); sT[1]=(ulong)GVg("t1",0);
   sDir=(int)GVg("dir",0); sVol=GVg("vol",0); sOpenTime=(datetime)GVg("ot",0);
   sEntry[0]=GVg("e0",0); sEntry[1]=GVg("e1",0);
   for(int i=0;i<2;i++)
     {
      sIntent[i]=GVg("in"+(string)i,0)>0.5; sReason[i]=(int)GVg("rs"+(string)i,0);
      sNext[i]=0; sTries[i]=0;
     }
   sIncident=GVg("inc",0)>0.5; sCutDone=GVg("cut",0)>0.5; sCutTime=(datetime)GVg("ct",0);
   sLossPips=GVg("lp",0); sProfile=(int)GVg("pf",0); sLock=GVg("lk",0); sStage=(int)GVg("st",0);
   sPartial=GVg("pt",0)>0.5; sStageATime=(datetime)GVg("sat",0); sSL0Done=GVg("sl0",0)>0.5;
  }
void SaveAccount()
  {
   GVs("dk",gDayKey); GVs("wk",gWeekKey); GVs("dse",gDayStartEq); GVs("wse",gWeekStartEq);
   GVs("std",gSeriesToday); GVs("cl",gConsecLosses); GVs("cbd",gConsecBlockDay);
   GVs("dhs",gDayHardStop?1:0); GVs("wb",gWeekBlocked?1:0);
   GVs("llt",(double)gLastLossTime); GVs("llp",gLastLossPrice); GVs("sc",(double)gSeriesCounter);
  }
void LoadAccount()
  {
   gDayKey=(int)GVg("dk",0); gWeekKey=(int)GVg("wk",0);
   gDayStartEq=GVg("dse",0); gWeekStartEq=GVg("wse",0);
   gSeriesToday=(int)GVg("std",0); gConsecLosses=(int)GVg("cl",0); gConsecBlockDay=(int)GVg("cbd",0);
   gDayHardStop=GVg("dhs",0)>0.5; gWeekBlocked=GVg("wb",0)>0.5;
   gLastLossTime=(datetime)GVg("llt",0); gLastLossPrice=GVg("llp",0); gSeriesCounter=(long)GVg("sc",0);
  }
void ResetSeries()
  {
   sActive=false; sT[0]=0; sT[1]=0; sDir=0; sVol=0; sOpenTime=0;
   for(int i=0;i<2;i++){ sEntry[i]=0; sIntent[i]=false; sReason[i]=CR_NONE; sNext[i]=0; sTries[i]=0; }
   sIncident=false; sCutDone=false; sCutTime=0; sLossPips=0; sProfile=0; sLock=0; sStage=0;
   sPartial=false; sStageATime=0; sSL0Done=false; sSL0Alerted=false; sCutWaitCount=0;
   SaveSeries();
  }

//=========================== POSITIONS ==============================
bool PosExists(ulong t) { return t>0 && PositionSelectByTicket(t); }
bool IsBuyLeg(int i)    { return (i==0)?(sDir>0):(sDir<0); }

// pertes en pips depuis l'entrée exécutée (positive = perte)
double LegLossPips(int i)
  {
   if(IsBuyLeg(i)) return MathMax(0.0,(sEntry[i]-Bid())/PIP);
   return MathMax(0.0,(Ask()-sEntry[i])/PIP);
  }
double LegProfitPips(int i)
  {
   if(IsBuyLeg(i)) return (Bid()-sEntry[i])/PIP;
   return (sEntry[i]-Ask())/PIP;
  }
// résultat réalisé d'une position fermée, en pips de prix (positif = gain)
bool ClosedLegPips(ulong ticket,bool isBuy,double entry,double &pips)
  {
   if(!HistorySelectByPosition(ticket)) return false;
   double vsum=0, psum=0;
   int n=HistoryDealsTotal();
   for(int k=0;k<n;k++)
     {
      ulong d=HistoryDealGetTicket(k);
      long en=HistoryDealGetInteger(d,DEAL_ENTRY);
      if(en!=DEAL_ENTRY_OUT && en!=DEAL_ENTRY_OUT_BY) continue;
      double v=HistoryDealGetDouble(d,DEAL_VOLUME), pr=HistoryDealGetDouble(d,DEAL_PRICE);
      vsum+=v; psum+=v*pr;
     }
   if(vsum<=0) return false;
   double px=psum/vsum;
   pips=isBuy?(px-entry)/PIP:(entry-px)/PIP;
   return true;
  }
double PositionNet(ulong ticket)
  {
   if(ticket==0 || !HistorySelectByPosition(ticket)) return 0;
   double s=0; int n=HistoryDealsTotal();
   for(int k=0;k<n;k++)
     {
      ulong d=HistoryDealGetTicket(k);
      s+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_COMMISSION)
         +HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_FEE);
     }
   return s;
  }
int ManagedPositionsCount()
  {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic) c++;
     }
   return c;
  }

//--- fermeture persistante (CF10 et sorties de sécurité) -------------
void RequestClose(int i,int reason)
  {
   if(sT[i]==0 || sIntent[i]) return;
   sIntent[i]=true; sReason[i]=reason; sNext[i]=0; sTries[i]=0;
   SaveSeries();                                    // intention sauvegardée avant envoi
   Log("intention de fermeture jambe #"+(string)(i+1)+" motif "+(string)reason);
  }
void ProcessCloses()
  {
   static const int delays[4]={1,2,4,5};
   for(int i=0;i<2;i++)
     {
      if(!sIntent[i]) continue;
      if(!PosExists(sT[i])) { sIntent[i]=false; SaveSeries(); continue; }
      if(TimeCurrent()<sNext[i]) continue;
      bool ok=trade.PositionClose(sT[i],(ulong)InpDeviationPoints);
      uint rc=trade.ResultRetcode();
      if(ok && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_DONE_PARTIAL || rc==TRADE_RETCODE_PLACED))
        {
         if(PosExists(sT[i])) { sNext[i]=TimeCurrent(); Log("fermeture partielle, reliquat à traiter #"+(string)(i+1)); }
         else Log("jambe #"+(string)(i+1)+" fermée (volume nul confirmé)");
         continue;
        }
      sTries[i]++;
      int wait;
      if(rc==TRADE_RETCODE_MARKET_CLOSED)
         wait=(int)MathMin(900.0,60.0*MathPow(2.0,(double)MathMin(4,sTries[i]-1)));
      else
         wait=delays[(int)MathMin(3,sTries[i]-1)];
      sNext[i]=TimeCurrent()+wait;
      Log("refus fermeture #"+(string)(i+1)+" code "+(string)rc+" nouvel essai dans "+(string)wait+" s");
     }
  }

//--- modification de SL, jamais éloignée -----------------------------
bool ModifySL(ulong ticket,double newSL,double minImprovePips)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   bool isBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   double cur=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long frz=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist=(MathMax(stops,frz)+1)*_Point;
   if(isBuy) newSL=MathMin(newSL,Bid()-minDist);
   else      newSL=MathMax(newSL,Ask()+minDist);
   newSL=NormPrice(newSL);
   if(cur>0)                                         // jamais éloigné, progression minimale
     {
      double need=MathMax(minImprovePips*PIP,_Point);
      if(isBuy  && newSL<cur+need-_Point*0.5) return false;
      if(!isBuy && newSL>cur-need+_Point*0.5) return false;
     }
   if(TimeCurrent()==sLastModify) return false;     // une modification par seconde
   sLastModify=TimeCurrent();
   if(trade.PositionModify(ticket,newSL,tp)) return true;
   Log("refus modification SL code "+(string)trade.ResultRetcode());
   return false;
  }
// SL actuel au moins aussi protecteur que la cible ?
bool SLAtLeast(ulong ticket,double target)
  {
   if(!PositionSelectByTicket(ticket)) return false;
   bool isBuy=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   double cur=PositionGetDouble(POSITION_SL);
   if(cur<=0) return false;
   long stops=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long frz=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist=(MathMax(stops,frz)+1)*_Point;
   double reach=isBuy?MathMin(target,Bid()-minDist):MathMax(target,Ask()+minDist);  // niveau le plus proche autorisé
   return isBuy?(cur>=NormPrice(reach)-_Point*0.5):(cur<=NormPrice(reach)+_Point*0.5);
  }

//=========================== SIGNAL (source 4.31) ===================
int Bias()
  {
   double atr=Buf(hAtr15,1);
   double f1=Buf(hEmaF15,1), fk=Buf(hEmaF15,1+InpSlopeLookback);
   double s1=Buf(hEmaS15,1), sk=Buf(hEmaS15,1+InpSlopeLookback);
   if(atr!=EMPTY_VALUE && atr>0 && f1!=EMPTY_VALUE && fk!=EMPTY_VALUE && s1!=EMPTY_VALUE && sk!=EMPTY_VALUE)
     {
      double fs=(f1-fk)/(InpSlopeLookback*atr), ss=(s1-sk)/(InpSlopeLookback*atr);
      double gap=MathAbs(f1-s1);
      if(f1>s1 && fs>InpFastSlopeMin && ss>InpSlowSlopeMin && gap>InpEMAMinDistanceATR*atr) return 1;
      if(f1<s1 && fs<-InpFastSlopeMin && ss<-InpSlowSlopeMin && gap>InpEMAMinDistanceATR*atr) return -1;
     }
   // structure : deux derniers sommets et creux confirmés
   double h[2], l[2]; int nh=0, nl=0;
   int s=InpSwingStrength;
   for(int i=s+1;i<=InpStructureLookback && (nh<2 || nl<2);i++)
     {
      if(nh<2 && IsSwingHigh(PERIOD_M15,i,s)) h[nh++]=iHigh(_Symbol,PERIOD_M15,i);
      if(nl<2 && IsSwingLow(PERIOD_M15,i,s))  l[nl++]=iLow(_Symbol,PERIOD_M15,i);
     }
   if(nh==2 && nl==2)
     {
      if(h[0]>h[1] && l[0]>l[1]) return 1;
      if(h[0]<h[1] && l[0]<l[1]) return -1;
     }
   return 0;
  }

int CandleSignalM5()
  {
   double o1=iOpen(_Symbol,PERIOD_M5,1), c1=iClose(_Symbol,PERIOD_M5,1);
   double h1=iHigh(_Symbol,PERIOD_M5,1), l1=iLow(_Symbol,PERIOD_M5,1);
   double o2=iOpen(_Symbol,PERIOD_M5,2), c2=iClose(_Symbol,PERIOD_M5,2);
   double h2=iHigh(_Symbol,PERIOD_M5,2), l2=iLow(_Symbol,PERIOD_M5,2);
   double o0=iOpen(_Symbol,PERIOD_M5,0), px=Bid();
   double body1=MathAbs(c1-o1), minBody=InpCandleMinBodyPoints*_Point;
   int up=0, dn=0;
   // momentum
   if(body1>minBody && c1>o1 && px>(o1+c1)/2.0) up++;
   if(body1>minBody && c1<o1 && px<(o1+c1)/2.0) dn++;
   // rejet / pin bar
   double upW=h1-MathMax(o1,c1), loW=MathMin(o1,c1)-l1, b=MathMax(body1,_Point);
   if(loW>=InpPinBarWickBodyRatio*b && loW>upW && px>h1) up++;
   if(upW>=InpPinBarWickBodyRatio*b && upW>loW && px<l1) dn++;
   // englobante
   if(c2<o2 && c1>o1 && o1<=c2 && c1>=o2) up++;
   if(c2>o2 && c1<o1 && o1>=c2 && c1<=o2) dn++;
   // inside bar
   if(h1<=h2 && l1>=l2) { if(px>h2) up++; if(px<l2) dn++; }
   // micro-tendance
   if(c1>o1 && c2>o2 && h1>h2 && l1>l2) up++;
   if(c1<o1 && c2<o2 && h1<h2 && l1<l2) dn++;
   if(up>0 && dn==0) return 1;
   if(dn>0 && up==0) return -1;
   if(up>0 && dn>0)                                   // arbitrage : impulsion de Bar[0]
     {
      if(px>o0) return 1;
      if(px<o0) return -1;
      double dh=h1-px, dl=px-l1;
      if(dh<dl) return 1;
      if(dl<dh) return -1;
     }
   return 0;
  }

int UnifiedEntryDirection()
  {
   if(InpUseCandleSignals) { int c=CandleSignalM5(); if(c!=0) return c; }
   return Bias();
  }

bool FindBreakout(int dir)
  {
   double atr=Buf(hAtr5,2);
   if(atr==EMPTY_VALUE || atr<=0) return false;
   int s=InpSwingStrength;
   double piv[]; int n=0;
   ArrayResize(piv,0);
   for(int i=s+2;i<=InpLevelLookback;i++)
     {
      if(dir>0 && IsSwingHigh(PERIOD_M5,i,s)) { ArrayResize(piv,n+1); piv[n++]=iHigh(_Symbol,PERIOD_M5,i); }
      if(dir<0 && IsSwingLow(PERIOD_M5,i,s))  { ArrayResize(piv,n+1); piv[n++]=iLow(_Symbol,PERIOD_M5,i); }
     }
   if(n<InpMinLevelTouches) return false;
   ArraySort(piv);
   double c1=iClose(_Symbol,PERIOD_M5,1), o1=iOpen(_Symbol,PERIOD_M5,1);
   double h1=iHigh(_Symbol,PERIOD_M5,1),  l1=iLow(_Symbol,PERIOD_M5,1);
   double c2=iClose(_Symbol,PERIOD_M5,2);
   double rng=h1-l1, body=MathAbs(c1-o1);
   if(rng<=0) return false;
   if(body<InpBreakoutBodyATR*atr || rng>InpMaxBreakoutRangeATR*atr) return false;
   if(dir>0 && (c1<=o1 || (c1-l1)/rng<InpBreakoutCloseRatio)) return false;
   if(dir<0 && (c1>=o1 || (h1-c1)/rng<InpBreakoutCloseRatio)) return false;
   double best=-1, bestDist=DBL_MAX;
   for(int j=0;j<n;j++)
     {
      int e=j; double sum=0;
      while(e<n && piv[e]-piv[j]<=InpLevelToleranceATR*atr) { sum+=piv[e]; e++; }
      int cnt=e-j;
      if(cnt<InpMinLevelTouches) continue;
      double lvl=sum/cnt, gmax=piv[e-1], gmin=piv[j];
      double upper=MathMax(lvl+InpZoneWidthATR*atr,gmax), lower=MathMin(lvl-InpZoneWidthATR*atr,gmin);
      bool ok=false;
      if(dir>0) ok=(c2<=upper && c1>upper+InpBreakoutBufferATR*atr && (h1-lvl)<=InpMaxExtensionATR*atr);
      else      ok=(c2>=lower && c1<lower-InpBreakoutBufferATR*atr && (lvl-l1)<=InpMaxExtensionATR*atr);
      if(ok && MathAbs(lvl-c2)<bestDist) { bestDist=MathAbs(lvl-c2); best=lvl; }
     }
   return best>0;
  }

bool Confirmation(int dir)
  {
   if(iTime(_Symbol,PERIOD_M1,1)<gBreakoutTime) return false;
   double atr1=Buf(hAtr1,2);
   if(atr1==EMPTY_VALUE || atr1<=0) return false;
   double o=iOpen(_Symbol,PERIOD_M1,1), c=iClose(_Symbol,PERIOD_M1,1), c2=iClose(_Symbol,PERIOD_M1,2);
   if(MathAbs(c-o)<InpM1BodyATR*atr1) return false;
   int s=InpSwingStrength; double piv=0; bool found=false;
   for(int i=s+1;i<=InpM1TriggerLookback;i++)
     {
      if(dir>0 && IsSwingHigh(PERIOD_M1,i,s)) { piv=iHigh(_Symbol,PERIOD_M1,i); found=true; break; }
      if(dir<0 && IsSwingLow(PERIOD_M1,i,s))  { piv=iLow(_Symbol,PERIOD_M1,i);  found=true; break; }
     }
   if(!found) return false;
   double ef=Buf(hEmaF1,1), es=Buf(hEmaS1,1);
   if(ef==EMPTY_VALUE || es==EMPTY_VALUE) return false;
   if(dir>0) { double thr=piv+InpM1BreakBufferATR*atr1; return ef>es && c>o && c>thr && c2<=thr; }
   double thr=piv-InpM1BreakBufferATR*atr1;
   return ef<es && c<o && c<thr && c2>=thr;
  }

//=========================== FILTRES ET GARDE-FOUS ==================
bool Refuse(string why)
  {
   if(why!=gLastRefusal || TimeCurrent()-gLastRefusalLog>300)
     { Print("EVA5 refus d'ouverture : ",why); gLastRefusal=why; gLastRefusalLog=TimeCurrent(); }
   return false;
  }
double MedianSpread()
  {
   if(gSpreadCount<20) return DBL_MAX;
   double a[20]; ArrayCopy(a,gSpreads); ArraySort(a);
   return (a[9]+a[10])/2.0;
  }
bool SessionOpen()
  {
   int dow,dk; int m=LondonMinutes(dow,dk);
   if(dow>=1 && dow<=4) return m>=InpSessionStartMin && m<InpSessionEndMin;
   if(dow==5) return m>=InpSessionStartMin && m<InpFridayEndMin;
   return false;
  }
bool CanOpenSeries(string &why)
  {
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL && !InpAllowLiveTrading) { why="compte réel non autorisé"; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) { why="trading non autorisé"; return false; }
   if(sActive || ManagedPositionsCount()>=MAX_CONCURRENT) { why="série déjà active"; return false; }
   if(!SessionOpen()) { why="hors séance"; return false; }
   if(gWeekBlocked) { why="limite hebdomadaire -5 % : revue manuelle requise"; return false; }
   if(gDayHardStop) { why="limite journalière -3 %"; return false; }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(gDayStartEq>0 && (eq-gDayStartEq)/gDayStartEq*100.0<=-DAILY_STOP_PCT) { why="limite journalière -2 %"; return false; }
   if(gConsecBlockDay==gDayKey && gDayKey!=0) { why="3 pertes consécutives"; return false; }
   if(gSeriesToday>=MAX_SERIES_PER_DAY) { why="6 séries aujourd'hui"; return false; }
   if(gLastLossTime>0 && TimeCurrent()-gLastLossTime<LOSS_PAUSE_MIN*60) { why="pause après perte"; return false; }
   if(gLastLossTime>0 && TimeCurrent()-gLastLossTime<ZONE_MIN*60 && MathAbs(Bid()-gLastLossPrice)<=ZONE_PIPS*PIP) { why="zone anti-retournement"; return false; }
   if(eq>0 && AccountInfoDouble(ACCOUNT_MARGIN)/eq*100.0>=70.0) { why="marge >= 70 %"; return false; }
   // coûts
   double sp=SpreadPips();
   if(sp>InpMaxSpreadPips || MedianSpread()>InpMaxSpreadPips) { why="spread "+DoubleToString(sp,1)+" pips"; return false; }
   double cost=2.0*sp+CommPipsSeries();
   if(cost>InpMaxSeriesCostPips) { why="coût de série "+DoubleToString(cost,1)+" pips"; return false; }
   // régime de volatilité
   double a1=Buf(hAtr1,1);
   if(a1==EMPTY_VALUE) { why="ATR M1 indisponible"; return false; }
   double a1p=a1/PIP;
   if(a1p>InpATR1MaxCoef*(CF10_PIPS-sp)) { why="ATR M1 trop élevé "+DoubleToString(a1p,1); return false; }
   if(a1p<InpATR1MinPips) { why="ATR M1 trop faible "+DoubleToString(a1p,1); return false; }
   double a5[]; ArraySetAsSeries(a5,true);
   if(CopyBuffer(hAtr5,0,1,50,a5)!=50) { why="ATR M5 indisponible"; return false; }
   double avg=0; for(int i=0;i<50;i++) avg+=a5[i]; avg/=50.0;
   if(avg<=0 || a5[0]/avg>InpATR5RatioMax) { why="ATR M5 en pic"; return false; }
   return true;
  }

double ComputeVolume(string &why)
  {
   double pv=PipValuePerLot();
   if(pv<=0) { why="valeur du pip inconnue"; return 0; }
   double maxSL0=MathMax(InpAl_SL0,MathMax(InpNe_SL0,InpOp_SL0));
   double lmax=CF10_PIPS+maxSL0+2.0*SpreadPips()+CommPipsSeries()+InpSlippageMarginPips;
   double riskMoney=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercentPerSeries/100.0;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),InpMaxLotPerTrade);
   double v;
   if(InpUseFixedLot)
     {
      v=InpFixedLot;
      if(v*lmax*pv>riskMoney) { why="lot fixe au-delà du risque par série"; return 0; }
     }
   else v=riskMoney/(lmax*pv);
   v=MathFloor(v/step)*step;
   v=MathMin(v,vmax);
   v=NormalizeDouble(v,2);
   if(v<MIN_LOT_MULTIPLE*vmin-1e-8) { why="volume inférieur à 4 x lot minimal"; return 0; }
   return v;
  }

ulong PositionFromDeal(ulong deal)
  {
   if(deal==0) return 0;
   if(!HistoryDealSelect(deal)) return 0;
   return (ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
  }
ulong FindPositionByComment(string cmt)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)==InpMagic && PositionGetString(POSITION_COMMENT)==cmt) return t;
     }
   return 0;
  }
bool OpenLeg(int dir,double vol,string cmt,ulong &ticket,double &entry)
  {
   bool ok;
   if(dir>0) ok=trade.Buy(vol,_Symbol,0,NormPrice(Ask()-EMERGENCY_SL_PIPS*PIP),0,cmt);
   else      ok=trade.Sell(vol,_Symbol,0,NormPrice(Bid()+EMERGENCY_SL_PIPS*PIP),0,cmt);
   uint rc=trade.ResultRetcode();
   if(!ok || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_DONE_PARTIAL && rc!=TRADE_RETCODE_PLACED))
     { Print("EVA5 échec ouverture ",cmt," code ",rc); return false; }
   ticket=PositionFromDeal(trade.ResultDeal());
   int tries=0;                                      // au plus ~3 s (LEG2_TIMEOUT_SEC)
   while(ticket==0 || !PositionSelectByTicket(ticket))
     {
      ticket=FindPositionByComment(cmt);
      if(ticket!=0 && PositionSelectByTicket(ticket)) break;
      if(++tries>LEG2_TIMEOUT_SEC*10) { Print("EVA5 position introuvable ",cmt); return false; }
      Sleep(100);
     }
   entry=PositionGetDouble(POSITION_PRICE_OPEN);
   return true;
  }

void PlaceSeries(int dir)
  {
   string why;
   double vol=ComputeVolume(why);
   if(vol<=0) { Refuse(why); return; }
   gSeriesCounter++;
   ResetSeries();
   sId=gSeriesCounter; sDir=dir; sVol=vol; sOpenTime=TimeCurrent(); sActive=true;
   string c1="EVA5 S"+(string)sId+" #1", c2="EVA5 S"+(string)sId+" #2";
   ulong t; double e;
   if(!OpenLeg(dir,vol,c1,t,e)) { ResetSeries(); SaveAccount(); return; }
   sT[0]=t; sEntry[0]=e; SaveSeries();
   if(!OpenLeg(-dir,vol,c2,t,e))
     {
      sIncident=true; SaveSeries();
      Log("INCIDENT_PAIRE : jambe #2 non exécutée, fermeture immédiate de #1");
      RequestClose(0,CR_INCIDENT);
      ProcessCloses();
      gSeriesToday++; SaveAccount();
      return;
     }
   sT[1]=t; sEntry[1]=e;
   gSeriesToday++;
   SaveSeries(); SaveAccount();
   Log(StringFormat("série ouverte %s vol %.2f entrées #1 %.2f #2 %.2f spread %.1f",dir>0?"BUY/SELL":"SELL/BUY",vol,sEntry[0],sEntry[1],SpreadPips()));
  }

//=========================== GESTION DU SURVIVANT ===================
struct Prof
  {
   double sl0; bool hasA; double aThr; double bThr; double bMinDist;
   double partThr; double partPct; double trBuf; double trMin; double m5Switch;
   bool   m5Always; int maxNoA; int maxNoB;
  };
void GetProfile(int p,Prof &r)
  {
   if(p>0)
     { r.sl0=InpAl_SL0; r.hasA=true; r.aThr=InpAl_AThr; r.bThr=InpAl_BThr; r.bMinDist=InpAl_BMinDist;
       r.partThr=InpAl_PartThr; r.partPct=InpAl_PartPct; r.trBuf=InpAl_TrailBuf; r.trMin=InpAl_BMinDist;
       r.m5Switch=0; r.m5Always=true; r.maxNoA=InpAl_MaxMinNoA; r.maxNoB=InpAl_MaxMinNoB; }
   else if(p==0)
     { r.sl0=InpNe_SL0; r.hasA=true; r.aThr=InpNe_AThr; r.bThr=InpNe_BThr; r.bMinDist=InpNe_BMinDist;
       r.partThr=InpNe_PartThr; r.partPct=InpNe_PartPct; r.trBuf=InpNe_TrailBuf; r.trMin=InpNe_BMinDist;
       r.m5Switch=InpNe_M5SwitchPips; r.m5Always=false; r.maxNoA=InpNe_MaxMinNoA; r.maxNoB=InpNe_MaxMinNoB; }
   else
     { r.sl0=InpOp_SL0; r.hasA=false; r.aThr=0; r.bThr=InpOp_BThr; r.bMinDist=InpOp_BMinDist;
       r.partThr=InpOp_PartThr; r.partPct=InpOp_PartPct; r.trBuf=InpOp_TrailBuf; r.trMin=InpOp_BMinDist;
       r.m5Switch=1e9; r.m5Always=false; r.maxNoA=InpOp_MaxMinNoB; r.maxNoB=0; }
  }

void InitSurvivor(int surv)
  {
   int los=1-surv;
   double pips;
   if(ClosedLegPips(sT[los],IsBuyLeg(los),sEntry[los],pips)) sLossPips=MathMax(0.0,-pips);
   else
     {
      if(++sCutWaitCount<5) return;                  // historique pas encore disponible
      sLossPips=CF10_PIPS;
     }
   int b=Bias();
   int sdir=IsBuyLeg(surv)?1:-1;
   sProfile=(b==0)?0:((b==sdir)?1:-1);
   sLock=sLossPips+CommPipsSeries()+LOCK_OFFSET_PIPS;
   sCutTime=TimeCurrent(); sStage=0; sPartial=false; sSL0Done=false; sSL0Alerted=false;
   sCutDone=true; SaveSeries();
   Log(StringFormat("LOSER_CLOSED #%d perte %.1f pips ; survivant #%d profil %s ; verrou V %.1f",
       los+1,sLossPips,surv+1,sProfile>0?"aligné":(sProfile<0?"opposé":"neutre"),sLock));
   if(sProfile<0 && InpOpposedCloseImmediately) RequestClose(surv,CR_OPPOSED_NOW);
  }

double LastSwingFor(bool isBuy,ENUM_TIMEFRAMES tf)
  {
   int s=InpSwingStrength;
   for(int i=s+1;i<=200;i++)
     {
      if(isBuy && IsSwingLow(tf,i,s))   return iLow(_Symbol,tf,i);
      if(!isBuy && IsSwingHigh(tf,i,s)) return iHigh(_Symbol,tf,i);
     }
   return 0;
  }

void ManageSurvivor(int surv)
  {
   if(sIntent[surv]) return;
   ulong t=sT[surv];
   if(!PositionSelectByTicket(t)) return;
   bool isBuy=IsBuyLeg(surv);
   double E=sEntry[surv], sgn=isBuy?1.0:-1.0;
   double Ps=LegProfitPips(surv);
   Prof pr; GetProfile(sProfile,pr);
   datetime now=TimeCurrent();

   // SL0
   double sl0=E-sgn*pr.sl0*PIP;
   if(!sSL0Done)
     {
      if(SLAtLeast(t,sl0)) { sSL0Done=true; SaveSeries(); Log("SL0 installé"); }
      else
        {
         ModifySL(t,sl0,0.0);
         if(SLAtLeast(t,sl0)) { sSL0Done=true; SaveSeries(); Log("SL0 installé"); }
         else if(now-sCutTime>=SL0_CLOSE_SEC) { Log("SL0 non accepté après 60 s : fermeture"); RequestClose(surv,CR_SL0_FAIL); return; }
         else if(now-sCutTime>=SL0_ALERT_SEC && !sSL0Alerted) { sSL0Alerted=true; Alert("EVA5 S",sId," : SL0 non accepté, SL de secours actif"); }
        }
     }
   // étape A
   if(pr.hasA && sStage<1 && Ps>=pr.aThr)
     {
      ModifySL(t,E,0.0);
      if(SLAtLeast(t,E)) { sStage=1; sStageATime=now; SaveSeries(); Log("étape A : SL à l'entrée"); }
     }
   // étape B
   double bThr=MathMax(pr.bThr,sLock+pr.bMinDist);
   if(sStage<2 && Ps>=bThr)
     {
      double lockSL=E+sgn*sLock*PIP;
      ModifySL(t,lockSL,0.0);
      if(SLAtLeast(t,lockSL)) { sStage=2; if(sStageATime==0) sStageATime=now; SaveSeries(); Log("étape B : série protégée"); }
     }
   // sortie partielle
   if(!sPartial && Ps>=pr.partThr && now!=sLastPartialTry)
     {
      sLastPartialTry=now;
      double v=PositionGetDouble(POSITION_VOLUME);
      double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP), vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      double pv=MathFloor(v*pr.partPct/100.0/step)*step;
      if(pv<vmin) pv=vmin;
      pv=NormalizeDouble(pv,2);
      if(v-pv<vmin-1e-8) { sPartial=true; SaveSeries(); Log("sortie partielle impossible (volume), ignorée"); }
      else if(trade.PositionClosePartial(t,pv,(ulong)InpDeviationPoints))
        { sPartial=true; SaveSeries(); Log(StringFormat("sortie partielle %.2f lot à %.1f pips",pv,Ps)); }
     }
   // suivi structurel après B
   if(sStage>=2 && PositionSelectByTicket(t))
     {
      ENUM_TIMEFRAMES tf=(pr.m5Always || Ps>=pr.m5Switch)?PERIOD_M5:PERIOD_M1;
      double sw=LastSwingFor(isBuy,tf);
      if(sw>0)
        {
         double cand=isBuy?MathMin(sw-pr.trBuf*PIP,Bid()-pr.trMin*PIP)
                          :MathMax(sw+pr.trBuf*PIP,Ask()+pr.trMin*PIP);
         ModifySL(t,cand,1.0);
        }
     }
   // durées maximales
   if(sStage==0 && now-sCutTime>=pr.maxNoA*60)
     { Log("durée maximale sans étape A/B atteinte"); RequestClose(surv,CR_TIME); return; }
   if(sStage==1 && pr.maxNoB>0 && now-sStageATime>=pr.maxNoB*60)
     { Log("durée maximale sans étape B atteinte"); RequestClose(surv,CR_TIME); return; }
  }

//=========================== CYCLE PRINCIPAL ========================
void WriteJournal(double net,string outcome)
  {
   int h=FileOpen("EVA5_journal.csv",FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"serie","ouverture","sens","volume","entree1","entree2","incident","coupe","perte_coupe_pips",
                "profil","etape","partielle","motif1","motif2","net","issue");
   FileSeek(h,0,SEEK_END);
   FileWrite(h,sId,TimeToString(sOpenTime,TIME_DATE|TIME_SECONDS),sDir,DoubleToString(sVol,2),
             DoubleToString(sEntry[0],_Digits),DoubleToString(sEntry[1],_Digits),sIncident?1:0,
             sCutTime>0?TimeToString(sCutTime,TIME_DATE|TIME_SECONDS):"",DoubleToString(sLossPips,1),
             sProfile,sStage,sPartial?1:0,sReason[0],sReason[1],DoubleToString(net,2),outcome);
   FileClose(h);
  }

void FinalizeSeries()
  {
   double net=PositionNet(sT[0])+PositionNet(sT[1]);
   string outcome=(net<0)?"perte":"gain";
   if(net<0)
     {
      gConsecLosses++; gLastLossTime=TimeCurrent(); gLastLossPrice=sEntry[0];
      if(gConsecLosses>=MAX_CONSEC_LOSSES) { gConsecBlockDay=gDayKey; Log("3 pertes consécutives : arrêt jusqu'à la séance suivante"); }
     }
   else gConsecLosses=0;
   Log(StringFormat("série terminée net %.2f %s",net,AccountInfoString(ACCOUNT_CURRENCY)));
   WriteJournal(net,outcome);
   ResetSeries();
   SaveAccount();
  }

void RequestCloseAll(int reason)
  {
   if(sActive)
      for(int i=0;i<2;i++) if(PosExists(sT[i])) RequestClose(i,reason);
   // positions gérées hors série (ex. héritées) : fermeture directe
   for(int k=PositionsTotal()-1;k>=0;k--)
     {
      ulong t=PositionGetTicket(k);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(sActive && (t==sT[0] || t==sT[1])) continue;
      trade.PositionClose(t,(ulong)InpDeviationPoints);
     }
  }

void AccountGuards()
  {
   int dow,dk; int m=LondonMinutes(dow,dk);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(dk!=gDayKey)
     {
      gDayKey=dk; gDayStartEq=eq; gSeriesToday=0; gDayHardStop=false; gConsecLosses=0;
      if(dow==1 || gWeekKey==0 || gWeekStartEq<=0) { gWeekKey=dk; gWeekStartEq=eq; }
      SaveAccount();
     }
   if(InpResetWeeklyBlock && gWeekBlocked) { gWeekBlocked=false; gWeekStartEq=eq; SaveAccount(); Print("EVA5 blocage hebdomadaire levé après revue"); }
   if(gDayStartEq>0 && !gDayHardStop && (eq-gDayStartEq)/gDayStartEq*100.0<=-DAILY_FLAT_PCT)
     {
      gDayHardStop=true; SaveAccount();
      Print("EVA5 limite journalière -3 % : fermeture de toutes les positions gérées");
      RequestCloseAll(CR_DAILY_LIMIT);
     }
   if(gWeekStartEq>0 && !gWeekBlocked && (eq-gWeekStartEq)/gWeekStartEq*100.0<=-WEEKLY_STOP_PCT)
     {
      gWeekBlocked=true; SaveAccount();
      Alert("EVA5 limite hebdomadaire -5 % : ouvertures bloquées, revue manuelle obligatoire");
     }
   // clôtures quotidienne et hebdomadaire
   bool dailyClose=(dow>=1 && dow<=4 && m>=InpDailyCloseMin) || (dow==5 && m>=InpWeeklyCloseMin) || dow==0 || dow==6;
   if(dailyClose && ManagedPositionsCount()>0)
      RequestCloseAll(dow==5?CR_WEEKLY_CLOSE:CR_DAILY_CLOSE);
  }

void Manage()
  {
   // 1. réconciliation : positions gérées hors série
   if(!sActive && ManagedPositionsCount()>0 && !gForeignWarned)
     { gForeignWarned=true; Print("EVA5 position gérée hors série détectée : SL conservé, aucun renfort"); }

   if(sActive)
     {
      // 2. fermetures engagées
      ProcessCloses();
      bool open0=PosExists(sT[0]), open1=PosExists(sT[1]);
      int nOpen=(open0?1:0)+(open1?1:0);
      if(nOpen==0) { FinalizeSeries(); }
      else
        {
         // 3. CF10 : condition stratégique unique, jambe par jambe
         for(int i=0;i<2;i++)
            if(PosExists(sT[i]) && !sIntent[i] && LegLossPips(i)>=CF10_PIPS)
              {
               Log(StringFormat("CF10 jambe #%d perte %.1f pips",i+1,LegLossPips(i)));
               RequestClose(i,CR_CF10);
              }
         ProcessCloses();
         open0=PosExists(sT[0]); open1=PosExists(sT[1]);
         nOpen=(open0?1:0)+(open1?1:0);
         // 4. survivant
         if(nOpen==1 && !sIncident)
           {
            int surv=open0?0:1;
            if(!sCutDone) InitSurvivor(surv);
            if(sCutDone) ManageSurvivor(surv);
            ProcessCloses();
           }
         if(!PosExists(sT[0]) && !PosExists(sT[1])) FinalizeSeries();
        }
     }
   // 5. garde-fous de compte et clôtures
   AccountGuards();
   if(sActive) ProcessCloses();
  }

void Signals()
  {
   datetime m5=iTime(_Symbol,PERIOD_M5,0), m1=iTime(_Symbol,PERIOD_M1,0);
   if(m5!=gLastM5)
     {
      gLastM5=m5;
      datetime brkBar=iTime(_Symbol,PERIOD_M5,1);
      if(!SessionOpen()) gSetupDir=0;
      else if(brkBar!=gLastBreakoutBar)
        {
         int dir=UnifiedEntryDirection();
         if(dir!=0 && FindBreakout(dir))
           {
            gSetupDir=dir; gBreakoutTime=m5; gLastBreakoutBar=brkBar;
            Print("EVA5 cassure M5 ",dir>0?"haussière":"baissière"," armée, attente confirmation M1");
           }
        }
     }
   if(m1!=gLastM1)
     {
      gLastM1=m1;
      if(gSetupDir!=0 && Confirmation(gSetupDir))
        {
         int dir=gSetupDir;
         gSetupDir=0;                                  // une seule tentative par confirmation
         string why;
         if(CanOpenSeries(why)) PlaceSeries(dir);
         else Refuse(why);
        }
     }
  }

void Cycle()
  {
   double sp=SpreadPips();
   gSpreads[gSpreadPos]=sp; gSpreadPos=(gSpreadPos+1)%20; if(gSpreadCount<20) gSpreadCount++;
   Manage();
   Signals();
  }

//=========================== ÉVÉNEMENTS =============================
int OnInit()
  {
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     { Print("EVA5 : un compte hedging est obligatoire"); return INIT_FAILED; }
   if(StringFind(_Symbol,"XAU")<0)
     { Print("EVA5 : symbole XAUUSD requis"); return INIT_FAILED; }
   if(InpRiskPercentPerSeries<=0 || InpRiskPercentPerSeries>1.0)
     { Print("EVA5 : risque par série entre 0 et 1 %"); return INIT_PARAMETERS_INCORRECT; }
   GVP="EVA5_"+(string)InpMagic+"_"+_Symbol+"_";
   if(MQLInfoInteger(MQL_TESTER)) GlobalVariablesDeleteAll(GVP);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hEmaF15=iMA(_Symbol,PERIOD_M15,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   hEmaS15=iMA(_Symbol,PERIOD_M15,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hEmaF1 =iMA(_Symbol,PERIOD_M1,InpFastEMA,0,MODE_EMA,PRICE_CLOSE);
   hEmaS1 =iMA(_Symbol,PERIOD_M1,InpSlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hAtr15 =iATR(_Symbol,PERIOD_M15,InpATRPeriod);
   hAtr5  =iATR(_Symbol,PERIOD_M5,InpATRPeriod);
   hAtr1  =iATR(_Symbol,PERIOD_M1,InpATRPeriod);
   if(hEmaF15==INVALID_HANDLE || hEmaS15==INVALID_HANDLE || hEmaF1==INVALID_HANDLE || hEmaS1==INVALID_HANDLE
      || hAtr15==INVALID_HANDLE || hAtr5==INVALID_HANDLE || hAtr1==INVALID_HANDLE)
     { Print("EVA5 : création des indicateurs impossible"); return INIT_FAILED; }

   LoadAccount();
   LoadSeries();
   if(sActive) Print("EVA5 reprise de la série S",sId," après redémarrage");
   EventSetTimer(1);
   Print("Eva_XAUUSD_Recovery ",EVA_BUILD," — CF10 10 pips + gestion du survivant (rév. 4.1). ",
         "Exclusions : renforts (P6), OCO (P7), filtre d'annonces. Commission/série ",
         DoubleToString(CommPipsSeries(),2)," pips.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   IndicatorRelease(hEmaF15); IndicatorRelease(hEmaS15); IndicatorRelease(hEmaF1); IndicatorRelease(hEmaS1);
   IndicatorRelease(hAtr15);  IndicatorRelease(hAtr5);   IndicatorRelease(hAtr1);
   SaveSeries(); SaveAccount();                        // aucune liquidation au retrait
  }

void OnTick()  { Cycle(); }
void OnTimer() { Manage(); }
//+------------------------------------------------------------------+
