//+------------------------------------------------------------------+
//|                                          TrendPullbackEA.mq4     |
//|                                                                  |
//| Strategy:                                                        |
//|   1. Identify trend via swing HH/HL (bull) or LH/LL (bear)      |
//|   2. Wait for 3+ consecutive candles counter to the trend        |
//|   3. Enter on the first candle that closes in trend direction    |
//|   4. SL below/above the entry candle; TP at 1:3 RR (default)    |
//+------------------------------------------------------------------+
#property strict
#property copyright "TrendPullbackEA"
#property version   "1.00"

//--- Inputs
input int    InpSwingBars   = 3;    // Pivot confirmation bars (each side)
input int    InpMinPullback = 3;    // Minimum consecutive pullback candles
input double InpRiskPct     = 1.0;  // Risk per trade (% of balance)
input double InpRRRatio     = 3.0;  // Reward to risk ratio
input double InpSLBuffer    = 2.0;  // Extra stop buffer (pips)
input int    InpSlippage    = 3;    // Max slippage (points)
input int    InpMagic       = 20250101;
input string InpComment     = "TPB";

//--- Enums
enum EState { IDLE, BULL_PULLBACK, BEAR_PULLBACK, BULL_ENTRY, BEAR_ENTRY };
enum ETrend { TREND_NONE, TREND_BULL, TREND_BEAR };

//--- State
EState   g_state       = IDLE;
int      g_pullback    = 0;
datetime g_lastBarTime = 0;

//--- Swing history — index 0 is the most recently confirmed swing
#define MAX_SWINGS 4
double   g_sh[MAX_SWINGS];   // swing high prices
double   g_sl[MAX_SWINGS];   // swing low prices
int      g_shCount    = 0;
int      g_slCount    = 0;
datetime g_shLastTime = 0;   // time of the last recorded swing high pivot bar
datetime g_slLastTime = 0;   // time of the last recorded swing low pivot bar

//+------------------------------------------------------------------+
int OnInit()
{
    ArrayInitialize(g_sh, 0.0);
    ArrayInitialize(g_sl, 0.0);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
    datetime barTime = iTime(_Symbol, _Period, 0);
    if(barTime == g_lastBarTime) return;   // only run on bar open
    g_lastBarTime = barTime;

    if(Bars < (InpSwingBars + 1) * 2 + 5) return;

    CheckSwings();
    ETrend trend = GetTrend();
    RunStateMachine(trend);
}

//--- Check whether bar[InpSwingBars+1] is a new swing high or low.
//    Using +1 offset ensures InpSwingBars confirmed bars exist on
//    the newer (right) side without touching the still-forming bar[0].
void CheckSwings()
{
    int      p  = InpSwingBars + 1;
    double   pH = iHigh(_Symbol, _Period, p);
    double   pL = iLow (_Symbol, _Period, p);
    datetime pT = iTime(_Symbol, _Period, p);
    bool     isH = true;
    bool     isL = true;

    for(int j = 1; j <= InpSwingBars; j++)
    {
        if(iHigh(_Symbol, _Period, p - j) >= pH) isH = false;
        if(iHigh(_Symbol, _Period, p + j) >= pH) isH = false;
        if(iLow (_Symbol, _Period, p - j) <= pL) isL = false;
        if(iLow (_Symbol, _Period, p + j) <= pL) isL = false;
    }

    if(isH && pT != g_shLastTime)
    {
        for(int k = MAX_SWINGS - 1; k > 0; k--) g_sh[k] = g_sh[k - 1];
        g_sh[0] = pH;
        if(g_shCount < MAX_SWINGS) g_shCount++;
        g_shLastTime = pT;
        Print("Swing High: ", DoubleToStr(pH, _Digits));
    }

    if(isL && pT != g_slLastTime)
    {
        for(int k = MAX_SWINGS - 1; k > 0; k--) g_sl[k] = g_sl[k - 1];
        g_sl[0] = pL;
        if(g_slCount < MAX_SWINGS) g_slCount++;
        g_slLastTime = pT;
        Print("Swing Low: ", DoubleToStr(pL, _Digits));
    }
}

//--- HH + HL = bull trend; LH + LL = bear trend
ETrend GetTrend()
{
    if(g_shCount < 2 || g_slCount < 2) return TREND_NONE;
    if(g_sh[0] > g_sh[1] && g_sl[0] > g_sl[1]) return TREND_BULL;
    if(g_sh[0] < g_sh[1] && g_sl[0] < g_sl[1]) return TREND_BEAR;
    return TREND_NONE;
}

//+------------------------------------------------------------------+
void RunStateMachine(ETrend trend)
{
    // bar[1] is the candle that just closed
    bool bar1Bull = iClose(_Symbol, _Period, 1) > iOpen(_Symbol, _Period, 1);
    bool bar1Bear = iClose(_Symbol, _Period, 1) < iOpen(_Symbol, _Period, 1);

    switch(g_state)
    {
        //--- Wait until a clear trend is established
        case IDLE:
            if(trend == TREND_BULL) { g_state = BULL_PULLBACK; g_pullback = 0; Print("State -> BULL_PULLBACK"); }
            else if(trend == TREND_BEAR) { g_state = BEAR_PULLBACK; g_pullback = 0; Print("State -> BEAR_PULLBACK"); }
            break;

        //--- Count consecutive bearish (counter-trend) candles in a bull trend
        case BULL_PULLBACK:
            if(trend != TREND_BULL) { ResetToIdle("trend lost"); break; }
            if(bar1Bear)
            {
                g_pullback++;
                Print("Bull pullback count: ", g_pullback);
                if(g_pullback >= InpMinPullback) { g_state = BULL_ENTRY; Print("State -> BULL_ENTRY"); }
            }
            else if(bar1Bull)
            {
                // Trend candle printed before minimum pullback — reset count
                g_pullback = 0;
                Print("Bull pullback reset by trend candle");
            }
            // Doji (open == close): neither counts nor resets
            break;

        //--- Count consecutive bullish (counter-trend) candles in a bear trend
        case BEAR_PULLBACK:
            if(trend != TREND_BEAR) { ResetToIdle("trend lost"); break; }
            if(bar1Bull)
            {
                g_pullback++;
                Print("Bear pullback count: ", g_pullback);
                if(g_pullback >= InpMinPullback) { g_state = BEAR_ENTRY; Print("State -> BEAR_ENTRY"); }
            }
            else if(bar1Bear)
            {
                g_pullback = 0;
                Print("Bear pullback reset by trend candle");
            }
            break;

        //--- Pullback complete — fire on the first bullish candle
        case BULL_ENTRY:
            if(trend != TREND_BULL) { ResetToIdle("trend lost"); break; }
            if(!IsTradeOpen() && bar1Bull) PlaceBuy();
            // Additional bearish candles: stay in BULL_ENTRY, still waiting
            break;

        //--- Pullback complete — fire on the first bearish candle
        case BEAR_ENTRY:
            if(trend != TREND_BEAR) { ResetToIdle("trend lost"); break; }
            if(!IsTradeOpen() && bar1Bear) PlaceSell();
            break;
    }
}

//+------------------------------------------------------------------+
void ResetToIdle(string reason)
{
    g_state    = IDLE;
    g_pullback = 0;
    Print("State -> IDLE (", reason, ")");
}

//+------------------------------------------------------------------+
void PlaceBuy()
{
    double pipMult = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
    double buffer  = InpSLBuffer * _Point * pipMult;
    double entry   = Ask;
    double sl      = iLow(_Symbol, _Period, 1) - buffer;
    double risk    = entry - sl;
    double tp      = entry + risk * InpRRRatio;
    double lots    = CalcLots(risk);

    if(lots <= 0 || risk <= 0) { Print("PlaceBuy: invalid risk/lots"); return; }

    int ticket = OrderSend(_Symbol, OP_BUY, lots, entry, InpSlippage,
                           sl, tp, InpComment, InpMagic, 0, clrGreen);
    if(ticket > 0)
    {
        Print("BUY #", ticket, "  Entry:", entry,
              "  SL:", sl, "  TP:", tp, "  Lots:", lots);
        ResetToIdle("buy entry taken");
    }
    else
        Print("BUY failed. Error:", GetLastError());
}

void PlaceSell()
{
    double pipMult = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
    double buffer  = InpSLBuffer * _Point * pipMult;
    double entry   = Bid;
    double sl      = iHigh(_Symbol, _Period, 1) + buffer;
    double risk    = sl - entry;
    double tp      = entry - risk * InpRRRatio;
    double lots    = CalcLots(risk);

    if(lots <= 0 || risk <= 0) { Print("PlaceSell: invalid risk/lots"); return; }

    int ticket = OrderSend(_Symbol, OP_SELL, lots, entry, InpSlippage,
                           sl, tp, InpComment, InpMagic, 0, clrRed);
    if(ticket > 0)
    {
        Print("SELL #", ticket, "  Entry:", entry,
              "  SL:", sl, "  TP:", tp, "  Lots:", lots);
        ResetToIdle("sell entry taken");
    }
    else
        Print("SELL failed. Error:", GetLastError());
}

//+------------------------------------------------------------------+
double CalcLots(double riskPrice)
{
    if(riskPrice <= 0) return MarketInfo(_Symbol, MODE_MINLOT);

    double balance    = AccountBalance();
    double riskAmt    = balance * InpRiskPct / 100.0;
    double tickSize   = MarketInfo(_Symbol, MODE_TICKSIZE);
    double tickVal    = MarketInfo(_Symbol, MODE_TICKVALUE);
    double minLot     = MarketInfo(_Symbol, MODE_MINLOT);
    double maxLot     = MarketInfo(_Symbol, MODE_MAXLOT);
    double lotStep    = MarketInfo(_Symbol, MODE_LOTSTEP);

    // Convert SL distance (price units) to account currency risk per lot
    double riskPerLot = (riskPrice / tickSize) * tickVal;
    if(riskPerLot <= 0) return minLot;

    double lots = riskAmt / riskPerLot;
    lots = MathFloor(lots / lotStep) * lotStep;
    lots = MathMax(minLot, MathMin(maxLot, lots));

    return lots;
}

//+------------------------------------------------------------------+
bool IsTradeOpen()
{
    for(int i = 0; i < OrdersTotal(); i++)
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
           OrderMagicNumber() == InpMagic && OrderSymbol() == _Symbol)
            return true;
    return false;
}
