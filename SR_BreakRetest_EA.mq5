//+------------------------------------------------------------------+
//|                                        SR_BreakRetest_EA.mq5     |
//|                                                                  |
//|  15m Support/Resistance Break-and-Retest EA (default: XAUUSD)    |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. Key levels: the most recently confirmed M15 swing high        |
//|     (resistance) and swing low (support) are tracked on an       |
//|     ongoing basis.                                                |
//|  2. Break: an M15 candle CLOSES beyond one of those levels.       |
//|  3. Retest: price trades back to within a small tolerance of the |
//|     broken level (checked on M5).                                 |
//|  4. Rejection / entry candle (M5): once the retest has been       |
//|     tapped, watch each new M5 candle against the one before it – |
//|     it qualifies if it EITHER closes inside the previous          |
//|     candle's high/low range, OR fully engulfs the previous        |
//|     candle's body – and closes in the direction of the original   |
//|     break (bullish candle after a resistance break, bearish after |
//|     a support break). That candle is the entry trigger.           |
//|  5. Stop loss: beyond the entry candle's low (long) / high        |
//|     (short), plus a small buffer. Take profit: InpRRRatio x risk  |
//|     (default 1:3).                                                |
//|  6. If price fully closes (M15) back through the broken level in |
//|     the wrong direction before a trade is taken, the setup is    |
//|     invalidated and the EA goes back to scanning for new levels. |
//|  Only one break/retest cycle is worked at a time – no new setup   |
//|     is started while a position from this EA is still open.      |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- M15 key levels
input int    InpM15PivotBars        = 5;    // M15 pivot bars each side to confirm a swing point
input int    InpM15Lookback         = 40;   // M15 bars searched for structure

//--- Retest / rejection timing
input double InpRetestTolerancePoints = 50; // Tolerance for price "returning to" the broken level (points)
input int    InpMaxRetestWaitBars     = 96; // Give up waiting for the retest after N M5 bars (~8h)
input int    InpMaxRejectionWaitBars  = 24; // Give up waiting for the rejection candle after N M5 bars (~2h)

//--- Stop loss / risk
input double InpSLBufferPoints      = 20;    // Extra buffer beyond the entry candle's high/low (points)
input bool   InpUseATRBuffer        = true;  // Add an ATR-based buffer to the stop loss
input double InpATRBufferMult       = 0.10;  // ATR multiple added to the SL buffer
input int    InpATRPeriod           = 14;    // ATR period (computed on M5)
input double InpRRRatio             = 3.0;   // Take profit reward:risk ratio (1:3 default)
input double InpRiskPercent         = 1.0;   // Risk per trade (% of account balance)

//--- Direction
input bool   InpTradeLongs          = true;  // Trade resistance-break retests (long)
input bool   InpTradeShorts         = true;  // Trade support-break retests (short)

//--- Execution
input int    InpSlippage            = 5;
input int    InpMagicNumber         = 20260808;
input string InpComment             = "SR_Retest";

CTrade trade;
int    g_atr_handle = INVALID_HANDLE;

enum EState { STATE_SCAN, STATE_AWAIT_RETEST, STATE_AWAIT_REJECTION };
EState g_state = STATE_SCAN;

datetime g_last_m15_bar = 0;
datetime g_last_m5_bar  = 0;

double g_resistance = 0;
double g_support    = 0;

bool     g_bias_long     = false;
double   g_broken_level  = 0;
int      g_retest_wait_ct    = 0;
int      g_rejection_wait_ct = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   g_atr_handle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   Print("SR_BreakRetest_EA initialized | Symbol: ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Print("SR_BreakRetest_EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewBar(PERIOD_M15, g_last_m15_bar))
   {
      UpdateKeyLevels();
      if(!HasOpenPosition())
      {
         if(g_state == STATE_SCAN) CheckBreak();
         else                       CheckM15Invalidation();
      }
   }

   if(IsNewBar(PERIOD_M5, g_last_m5_bar) && !HasOpenPosition())
   {
      if(g_state == STATE_AWAIT_RETEST)     CheckRetest();
      else if(g_state == STATE_AWAIT_REJECTION) CheckRejection();
   }
}

//+------------------------------------------------------------------+
//| Refresh the most recent confirmed M15 swing high/low             |
//+------------------------------------------------------------------+
void UpdateKeyLevels()
{
   double sh = FindSwingHigh(PERIOD_M15, InpM15Lookback, InpM15PivotBars);
   double sl = FindSwingLow (PERIOD_M15, InpM15Lookback, InpM15PivotBars);
   if(sh > 0) g_resistance = sh;
   if(sl > 0) g_support    = sl;
}

//+------------------------------------------------------------------+
//| M15 – detect a close-confirmed break of a key level               |
//+------------------------------------------------------------------+
void CheckBreak()
{
   double cl1 = iClose(_Symbol, PERIOD_M15, 1);

   if(InpTradeLongs && g_resistance > 0 && cl1 > g_resistance)
   {
      StartBreak(true, g_resistance);
   }
   else if(InpTradeShorts && g_support > 0 && cl1 < g_support)
   {
      StartBreak(false, g_support);
   }
}

void StartBreak(bool bias_long, double level)
{
   g_bias_long      = bias_long;
   g_broken_level   = level;
   g_state          = STATE_AWAIT_RETEST;
   g_retest_wait_ct = 0;

   Print("M15 ", bias_long ? "resistance" : "support", " break confirmed at ", level,
         " | Awaiting retest.");
}

//+------------------------------------------------------------------+
//| While awaiting retest/rejection: a full M15 close back through   |
//| the broken level in the wrong direction invalidates the setup    |
//+------------------------------------------------------------------+
void CheckM15Invalidation()
{
   double cl1 = iClose(_Symbol, PERIOD_M15, 1);

   if((g_bias_long  && cl1 < g_broken_level) ||
      (!g_bias_long && cl1 > g_broken_level))
   {
      Print("Setup invalidated – M15 closed back through ", g_broken_level, ". Back to scanning.");
      g_state = STATE_SCAN;
   }
}

//+------------------------------------------------------------------+
//| M5 – wait for price to trade back to the broken level            |
//+------------------------------------------------------------------+
void CheckRetest()
{
   g_retest_wait_ct++;
   if(InpMaxRetestWaitBars > 0 && g_retest_wait_ct >= InpMaxRetestWaitBars)
   {
      Print("No retest within ", InpMaxRetestWaitBars, " M5 bars – abandoning this break.");
      g_state = STATE_SCAN;
      return;
   }

   double tol = InpRetestTolerancePoints * _Point;

   if(g_bias_long)
   {
      double lo1 = iLow(_Symbol, PERIOD_M5, 1);
      if(lo1 <= g_broken_level + tol)
      {
         g_state = STATE_AWAIT_REJECTION;
         g_rejection_wait_ct = 0;
         Print("Retest tapped (long) at ", lo1, " | Watching for a rejection candle.");
      }
   }
   else
   {
      double hi1 = iHigh(_Symbol, PERIOD_M5, 1);
      if(hi1 >= g_broken_level - tol)
      {
         g_state = STATE_AWAIT_REJECTION;
         g_rejection_wait_ct = 0;
         Print("Retest tapped (short) at ", hi1, " | Watching for a rejection candle.");
      }
   }
}

//+------------------------------------------------------------------+
//| M5 – the entry candle must close inside the previous candle's    |
//| range, or fully engulf its body, in the direction of the break   |
//+------------------------------------------------------------------+
void CheckRejection()
{
   g_rejection_wait_ct++;
   if(InpMaxRejectionWaitBars > 0 && g_rejection_wait_ct >= InpMaxRejectionWaitBars)
   {
      Print("No rejection candle within ", InpMaxRejectionWaitBars, " M5 bars – abandoning this retest.");
      g_state = STATE_SCAN;
      return;
   }

   double o1 = iOpen (_Symbol, PERIOD_M5, 1), c1 = iClose(_Symbol, PERIOD_M5, 1);
   double h1 = iHigh (_Symbol, PERIOD_M5, 1), l1 = iLow  (_Symbol, PERIOD_M5, 1);
   double o2 = iOpen (_Symbol, PERIOD_M5, 2), c2 = iClose(_Symbol, PERIOD_M5, 2);
   double h2 = iHigh (_Symbol, PERIOD_M5, 2), l2 = iLow  (_Symbol, PERIOD_M5, 2);

   double body_top1 = MathMax(o1, c1), body_bot1 = MathMin(o1, c1);
   double body_top2 = MathMax(o2, c2), body_bot2 = MathMin(o2, c2);

   bool close_inside = (c1 <= h2 && c1 >= l2);
   bool engulf        = (body_bot1 <= body_bot2 && body_top1 >= body_top2);

   if(g_bias_long && c1 > o1 && (close_inside || engulf))
   {
      OpenTrade(true, l1);
   }
   else if(!g_bias_long && c1 < o1 && (close_inside || engulf))
   {
      OpenTrade(false, h1);
   }
}

//+------------------------------------------------------------------+
//| Open the trade: SL beyond the entry candle's extreme, TP at      |
//| InpRRRatio x the risk distance                                    |
//+------------------------------------------------------------------+
void OpenTrade(bool is_long, double entry_candle_extreme)
{
   double buffer = InpSLBufferPoints * _Point;
   if(InpUseATRBuffer) buffer += GetATR() * InpATRBufferMult;

   bool ok = false;

   if(is_long)
   {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl    = entry_candle_extreme - buffer;
      double risk  = entry - sl;
      if(risk <= 0) { Print("Long skipped – non-positive risk distance."); g_state = STATE_SCAN; return; }

      double tp   = entry + risk * InpRRRatio;
      double lots = CalculateLots(risk);
      if(lots <= 0) { Print("Long skipped – lot size calculation failed."); g_state = STATE_SCAN; return; }

      ok = trade.Buy(lots, _Symbol, entry, sl, tp, InpComment);
      if(ok)
         Print("LONG opened | Entry: ", entry, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots);
      else
         Print("Buy failed | Retcode: ", trade.ResultRetcode());
   }
   else
   {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl    = entry_candle_extreme + buffer;
      double risk  = sl - entry;
      if(risk <= 0) { Print("Short skipped – non-positive risk distance."); g_state = STATE_SCAN; return; }

      double tp   = entry - risk * InpRRRatio;
      double lots = CalculateLots(risk);
      if(lots <= 0) { Print("Short skipped – lot size calculation failed."); g_state = STATE_SCAN; return; }

      ok = trade.Sell(lots, _Symbol, entry, sl, tp, InpComment);
      if(ok)
         Print("SHORT opened | Entry: ", entry, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots);
      else
         Print("Sell failed | Retcode: ", trade.ResultRetcode());
   }

   // Whether the order succeeded or failed, this cycle is done – go back to
   // scanning. HasOpenPosition() keeps a new cycle from starting while a
   // successful trade is still live.
   g_state = STATE_SCAN;
}

//+------------------------------------------------------------------+
//| Confirmed swing HIGH/LOW finder                                   |
//+------------------------------------------------------------------+
double FindSwingHigh(ENUM_TIMEFRAMES tf, int lookback, int n)
{
   for(int i = n + 1; i <= lookback - n; i++)
   {
      double h = iHigh(_Symbol, tf, i);
      bool   ok = true;
      for(int j = 1; j <= n && ok; j++)
      {
         if(iHigh(_Symbol, tf, i - j) >= h) ok = false;
         if(iHigh(_Symbol, tf, i + j) >= h) ok = false;
      }
      if(ok) return h;
   }
   return 0;
}

double FindSwingLow(ENUM_TIMEFRAMES tf, int lookback, int n)
{
   for(int i = n + 1; i <= lookback - n; i++)
   {
      double l = iLow(_Symbol, tf, i);
      bool   ok = true;
      for(int j = 1; j <= n && ok; j++)
      {
         if(iLow(_Symbol, tf, i - j) <= l) ok = false;
         if(iLow(_Symbol, tf, i + j) <= l) ok = false;
      }
      if(ok) return l;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Latest closed-bar ATR value (M5)                                  |
//+------------------------------------------------------------------+
double GetATR()
{
   double buf[];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Calculate lot size from a fixed risk percentage                  |
//| sl_distance – distance from entry to stop loss in price units   |
//|                                                                    |
//| Rejects the trade (returns 0) rather than clamping the lot size  |
//| to the broker's min/max volume – clamping would silently break   |
//| the risk-% guarantee since the stop distance stays the same      |
//| while the position size gets forced up or down.                  |
//+------------------------------------------------------------------+
double CalculateLots(double sl_distance)
{
   if(sl_distance <= 0) return 0;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_cash  = balance * InpRiskPercent / 100.0;
   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_val <= 0 || tick_size <= 0) return 0;

   double raw_lots = risk_cash / (sl_distance / tick_size * tick_val);

   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(raw_lots > max_lot)
   {
      Print("Trade rejected – stop distance ", sl_distance, " too tight for ", InpRiskPercent,
            "% risk at balance ", balance, " (would need ", raw_lots, " lots, broker max is ", max_lot, ").");
      return 0;
   }

   double lots = MathFloor(raw_lots / lot_step) * lot_step;

   if(lots < min_lot)
   {
      double actual_risk = min_lot * (sl_distance / tick_size * tick_val);
      if(actual_risk > risk_cash * 1.5)
      {
         Print("Trade rejected – broker minimum lot (", min_lot, ") would risk $", actual_risk,
               ", well above the intended $", risk_cash, ".");
         return 0;
      }
      lots = min_lot;
   }

   return lots;
}

//+------------------------------------------------------------------+
//| Returns true if the EA has an open position on this symbol       |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Returns true on the first tick of a new bar on 'tf'               |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf, datetime &last_time)
{
   datetime cur = iTime(_Symbol, tf, 0);
   if(cur != last_time)
   {
      last_time = cur;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+
