//+------------------------------------------------------------------+
//|                                     ICT_LiquiditySweep_EA.mq5    |
//|                                                                  |
//|  Liquidity Sweep + Reversal EA (default: XAUUSD, H4/H1/M5)       |
//|  Based on the "Powerful Gold Strategy for 2026" write-up by      |
//|  David_Perk (TradingView). The source material is a discretionary|
//|  ICT-style framework, not a strict algorithm, so several points  |
//|  below are this EA's specific interpretation of that write-up –  |
//|  see the accompanying chat summary for exactly which choices     |
//|  were made and why.                                               |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. HTF bias (H4): a structural break (close beyond a confirmed   |
//|     swing high/low) sets the directional bias – buy dips in an   |
//|     uptrend, sell rallies in a downtrend.                        |
//|  2. ITF range (H1): a rolling range is drawn from recent H1       |
//|     highs/lows. A full-body close beyond it invalidates the range |
//|     (redraw). A WICK beyond it that closes back inside is the    |
//|     liquidity sweep / manipulation we want to trade against.     |
//|  3. LTF shift (M5): after the sweep, wait for an M5 structure     |
//|     break back in the bias direction – the "sweep and shift".     |
//|  4. Order block + FVG filter: the order block is the last M5      |
//|     candle of opposing colour before the shift's impulsive move; |
//|     it must sit in the correct half of the H1 range (discount    |
//|     for longs / premium for shorts) and have a 3-candle Fair      |
//|     Value Gap overlapping it. (Inverse-FVG state tracking is not |
//|     separately modelled – a standard FVG is treated as covering  |
//|     the "FVG or IFVG" requirement.)                                |
//|  5. Two entries fire from one confirmed setup:                    |
//|       Model 1 – market entry immediately on shift confirmation,   |
//|                 target the 50% level of the H1 range.             |
//|       Model 2 – a resting limit order in the 61.8-80% retracement |
//|                 "reload zone" of the sweep-to-shift leg, target   |
//|                 the far side of the H1 range.                     |
//|     Both share the same stop: beyond the sweep wick (the write-up |
//|     never states a stop rule, so this is the standard convention |
//|     for this setup).                                              |
//|  6. Only one setup is worked at a time – no new sweep is hunted   |
//|     while either entry from the current setup is still open or    |
//|     pending. A full-body close back through the sweep wick        |
//|     cancels any still-pending Model 2 order.                      |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Higher timeframe bias (H4)
input int    InpHTFBiasPivotBars   = 5;      // H4 pivot bars each side to confirm a swing point
input int    InpHTFBiasLookback    = 40;     // H4 bars searched for structure

//--- Intermediate timeframe range / sweep (H1)
input int    InpRangeLookbackH1    = 20;     // H1 bars used to build the rolling range

//--- Lower timeframe structure shift (M5)
input int    InpShiftPivotBars     = 3;      // M5 pivot bars each side to confirm a swing point
input int    InpShiftLookback      = 30;     // M5 bars searched for the shift pivot
input int    InpMaxShiftWaitBars   = 48;     // Give up waiting for the shift after N M5 bars (~4h)
input int    InpMaxTapWaitBars     = 48;     // Cancel the Model 2 order after N M5 bars if untouched

//--- Model 2 retracement ("reload zone")
input double InpRetraceNear        = 0.618;  // Nearer edge of the reload zone (shallower pullback)
input double InpRetraceFar         = 0.80;   // Farther edge of the reload zone (deeper pullback)

//--- Stop loss / risk
input double InpSLBufferPoints     = 50;     // Extra buffer beyond the sweep wick (points)
input bool   InpUseATRBuffer       = true;   // Add an ATR-based buffer to the stop loss
input double InpATRBufferMult      = 0.15;   // ATR multiple added to the SL buffer
input int    InpATRPeriod          = 14;     // ATR period (computed on H1)
input double InpRiskPercent        = 1.0;    // Risk per trade (% of account balance) – applied per entry

//--- Direction / weekend safety
input bool   InpTradeLongs         = true;
input bool   InpTradeShorts        = true;
input bool   InpFlattenBeforeWeekend = true; // Cancel pending / close open positions before the weekend
input int    InpFridayFlattenHour  = 20;     // Friday cutoff hour (server time)

//--- Execution
input int    InpSlippage           = 5;      // Maximum slippage (points)
input int    InpMagicNumber        = 20260806;
input string InpComment            = "ICTSweep";

//--- Trade object
CTrade trade;
int    g_atr_handle = INVALID_HANDLE;

//--- Bias
enum EBias { BIAS_NONE, BIAS_BULL, BIAS_BEAR };
EBias g_h4_bias = BIAS_NONE;
datetime g_last_h4_bar = 0;

//--- Setup state machine
enum ESetupState { STATE_IDLE, STATE_AWAIT_SHIFT, STATE_SETUP_ACTIVE };
ESetupState g_state = STATE_IDLE;

datetime g_last_h1_bar = 0;
datetime g_last_m5_bar = 0;

//--- Range (H1)
double g_range_high = 0;
double g_range_low  = 0;

//--- Sweep tracking
bool     g_bias_trade_long = false;   // direction of the setup currently being worked
double   g_m5_extreme_price = 0;      // sweep wick tip, located on M5
int      g_m5_extreme_shift  = 0;     // M5 shift of the sweep wick candle
int      g_shift_wait_ct     = 0;

//--- Active setup tracking
ulong g_model2_ticket = 0;
int   g_setup_wait_ct = 0;

//--- Weekend flatten
bool g_weekend_flat_done = false;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   g_atr_handle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   Print("ICT_LiquiditySweep_EA initialized | Symbol: ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Print("ICT_LiquiditySweep_EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                 |
//+------------------------------------------------------------------+
void OnTick()
{
   HandleWeekendFlatten();

   if(IsNewBar(PERIOD_H4, g_last_h4_bar)) UpdateH4Bias();
   if(IsNewBar(PERIOD_H1, g_last_h1_bar)) ProcessH1();
   if(IsNewBar(PERIOD_M5, g_last_m5_bar)) ProcessM5();
}

//+------------------------------------------------------------------+
//| Cancel/close everything ahead of the weekend gap                 |
//+------------------------------------------------------------------+
void HandleWeekendFlatten()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week != FRIDAY) { g_weekend_flat_done = false; return; }
   if(!InpFlattenBeforeWeekend || g_weekend_flat_done || dt.hour < InpFridayFlattenHour) return;

   CancelModel2();
   CloseAllPositions();
   g_weekend_flat_done = true;

   if(g_state != STATE_IDLE)
   {
      g_state       = STATE_IDLE;
      g_range_high  = 0;
      Print("Weekend flatten – setup abandoned, will resume Monday.");
   }
}

//+------------------------------------------------------------------+
//| H4 – update the higher-timeframe directional bias                 |
//+------------------------------------------------------------------+
void UpdateH4Bias()
{
   double cl1 = iClose(_Symbol, PERIOD_H4, 1);
   double sh  = FindSwingHigh(PERIOD_H4, InpHTFBiasLookback, InpHTFBiasPivotBars);
   double sl  = FindSwingLow (PERIOD_H4, InpHTFBiasLookback, InpHTFBiasPivotBars);

   EBias prev = g_h4_bias;

   if(sh > 0 && cl1 > sh) g_h4_bias = BIAS_BULL;
   else if(sl > 0 && cl1 < sl) g_h4_bias = BIAS_BEAR;

   if(g_h4_bias != prev)
   {
      Print("H4 bias changed to ", EnumToString(g_h4_bias));
      // A bias flip invalidates an in-progress hunt for the old direction;
      // trades already live from a confirmed setup are left to their own SL/TP.
      if(g_state == STATE_IDLE || g_state == STATE_AWAIT_SHIFT)
      {
         g_state      = STATE_IDLE;
         g_range_high = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| H1 – build/validate the range and detect a liquidity sweep       |
//+------------------------------------------------------------------+
void ProcessH1()
{
   if(g_h4_bias == BIAS_NONE || g_state != STATE_IDLE) return;

   if(g_range_high == 0)
   {
      BuildRange();
      return;
   }

   double cl1 = iClose(_Symbol, PERIOD_H1, 1);
   double lo1 = iLow  (_Symbol, PERIOD_H1, 1);
   double hi1 = iHigh (_Symbol, PERIOD_H1, 1);

   if(g_h4_bias == BIAS_BULL)
   {
      if(cl1 < g_range_low)
      {
         Print("Range invalidated (bull) – full body close below range low. Redrawing.");
         g_range_high = 0;
         return;
      }
      if(!InpTradeLongs) return;
      if(lo1 < g_range_low && cl1 >= g_range_low)
      {
         StartSweep(true, iTime(_Symbol, PERIOD_H1, 1), lo1);
      }
   }
   else // BIAS_BEAR
   {
      if(cl1 > g_range_high)
      {
         Print("Range invalidated (bear) – full body close above range high. Redrawing.");
         g_range_high = 0;
         return;
      }
      if(!InpTradeShorts) return;
      if(hi1 > g_range_high && cl1 <= g_range_high)
      {
         StartSweep(false, iTime(_Symbol, PERIOD_H1, 1), hi1);
      }
   }
}

//+------------------------------------------------------------------+
//| Build the rolling H1 range from the last InpRangeLookbackH1 bars |
//+------------------------------------------------------------------+
void BuildRange()
{
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 1; i <= InpRangeLookbackH1; i++)
   {
      hi = MathMax(hi, iHigh(_Symbol, PERIOD_H1, i));
      lo = MathMin(lo, iLow (_Symbol, PERIOD_H1, i));
   }
   g_range_high = hi;
   g_range_low  = lo;
   Print("H1 range built | High: ", g_range_high, " | Low: ", g_range_low,
         " | Bias: ", EnumToString(g_h4_bias));
}

//+------------------------------------------------------------------+
//| A sweep wick was detected on H1 – locate its exact M5 candle and |
//| start watching for the LTF structure shift                        |
//+------------------------------------------------------------------+
void StartSweep(bool bias_long, datetime h1_bar_time, double h1_extreme)
{
   double extreme_price;
   int    extreme_shift;
   if(!FindM5ExtremeInH1Bar(h1_bar_time, bias_long, extreme_price, extreme_shift))
   {
      Print("Could not locate M5 detail for the sweep bar – skipping.");
      return;
   }

   g_bias_trade_long   = bias_long;
   g_m5_extreme_price  = extreme_price;
   g_m5_extreme_shift  = extreme_shift;
   g_shift_wait_ct     = 0;
   g_state             = STATE_AWAIT_SHIFT;

   Print("Sweep detected | Direction: ", bias_long ? "LONG" : "SHORT",
         " | H1 extreme: ", h1_extreme, " | M5 extreme: ", extreme_price,
         " | Awaiting shift.");
}

//+------------------------------------------------------------------+
//| Locate the M5 candle within the given H1 bar that made its wick   |
//| extreme (the lowest low for a bullish sweep, highest high for a  |
//| bearish sweep)                                                    |
//+------------------------------------------------------------------+
bool FindM5ExtremeInH1Bar(datetime h1_bar_time, bool want_low, double &extreme_price, int &extreme_shift)
{
   int start_shift = iBarShift(_Symbol, PERIOD_M5, h1_bar_time, false);
   if(start_shift < 0) return false;

   extreme_price = want_low ? DBL_MAX : -DBL_MAX;
   extreme_shift = start_shift;
   bool found = false;

   for(int s = start_shift; s >= 1; s--)
   {
      datetime t = iTime(_Symbol, PERIOD_M5, s);
      if(t < h1_bar_time) break;
      if(t >= h1_bar_time + 3600) break;

      double val = want_low ? iLow(_Symbol, PERIOD_M5, s) : iHigh(_Symbol, PERIOD_M5, s);
      if(want_low ? (val < extreme_price) : (val > extreme_price))
      {
         extreme_price = val;
         extreme_shift = s;
         found = true;
      }
   }
   return found;
}

//+------------------------------------------------------------------+
//| M5 – route to the correct stage handler                          |
//+------------------------------------------------------------------+
void ProcessM5()
{
   switch(g_state)
   {
      case STATE_AWAIT_SHIFT:   ProcessAwaitShift();  break;
      case STATE_SETUP_ACTIVE:  ProcessSetupActive(); break;
      default: break;
   }
}

//+------------------------------------------------------------------+
//| Watch for the M5 structure shift back in the bias direction       |
//+------------------------------------------------------------------+
void ProcessAwaitShift()
{
   g_shift_wait_ct++;
   if(InpMaxShiftWaitBars > 0 && g_shift_wait_ct >= InpMaxShiftWaitBars)
   {
      g_state      = STATE_IDLE;
      g_range_high = 0;
      Print("No shift within ", InpMaxShiftWaitBars, " M5 bars – abandoning this sweep.");
      return;
   }

   double c1 = iClose(_Symbol, PERIOD_M5, 1);

   if(g_bias_trade_long)
   {
      double piv = FindSwingHighAfter(g_m5_extreme_shift, InpShiftPivotBars, InpShiftLookback);
      if(piv > 0 && c1 > piv) OnShiftConfirmed(1);
   }
   else
   {
      double piv = FindSwingLowAfter(g_m5_extreme_shift, InpShiftPivotBars, InpShiftLookback);
      if(piv > 0 && c1 < piv) OnShiftConfirmed(1);
   }
}

//+------------------------------------------------------------------+
//| Shift confirmed – run the order block / FVG filter, then fire    |
//| Model 1 (market) and place Model 2 (retracement limit order)     |
//+------------------------------------------------------------------+
void OnShiftConfirmed(int shift_confirm_shift)
{
   double ob_high, ob_low;
   FindOrderBlock(g_m5_extreme_shift, shift_confirm_shift, g_bias_trade_long, ob_high, ob_low);

   double range_mid = (g_range_high + g_range_low) / 2.0;
   double ob_mid     = (ob_high + ob_low) / 2.0;
   bool   pd_ok       = g_bias_trade_long ? (ob_mid <= range_mid) : (ob_mid >= range_mid);
   bool   fvg_ok       = FindOverlappingFVG(g_m5_extreme_shift, shift_confirm_shift, ob_low, ob_high, g_bias_trade_long);

   Print("Shift confirmed | OB: ", ob_low, " - ", ob_high,
         " | Premium/Discount OK: ", pd_ok, " | FVG OK: ", fvg_ok);

   if(!pd_ok || !fvg_ok)
   {
      Print("Setup rejected by OB/FVG filter.");
      g_state      = STATE_IDLE;
      g_range_high = 0;
      return;
   }

   double leg_start = g_m5_extreme_price;
   double leg_end    = g_bias_trade_long
                         ? HighestHighSince(g_m5_extreme_shift, shift_confirm_shift)
                         : LowestLowSince (g_m5_extreme_shift, shift_confirm_shift);

   OpenModel1AndPlaceModel2(leg_start, leg_end);
}

//+------------------------------------------------------------------+
//| Order block = the last M5 candle of opposing colour to the bias  |
//| between the sweep extreme and the shift confirmation bar          |
//+------------------------------------------------------------------+
void FindOrderBlock(int extreme_shift, int shift_confirm_shift, bool bias_long, double &ob_high, double &ob_low)
{
   int ob_shift = extreme_shift; // fallback: the sweep candle itself
   for(int s = extreme_shift; s > shift_confirm_shift; s--)
   {
      double o = iOpen (_Symbol, PERIOD_M5, s);
      double c = iClose(_Symbol, PERIOD_M5, s);
      if(bias_long  && c < o) ob_shift = s; // most recent bearish candle
      if(!bias_long && c > o) ob_shift = s; // most recent bullish candle
   }
   ob_high = iHigh(_Symbol, PERIOD_M5, ob_shift);
   ob_low  = iLow (_Symbol, PERIOD_M5, ob_shift);
}

//+------------------------------------------------------------------+
//| Search for a 3-candle Fair Value Gap overlapping the OB zone      |
//+------------------------------------------------------------------+
bool FindOverlappingFVG(int from_shift, int to_shift, double ob_low, double ob_high, bool bias_long)
{
   for(int s = from_shift; s >= to_shift + 2; s--)
   {
      double gap_top = 0, gap_bot = 0;
      bool   found     = false;

      if(bias_long)
      {
         double h_old = iHigh(_Symbol, PERIOD_M5, s);
         double l_new = iLow (_Symbol, PERIOD_M5, s - 2);
         if(h_old < l_new) { gap_bot = h_old; gap_top = l_new; found = true; }
      }
      else
      {
         double l_old = iLow (_Symbol, PERIOD_M5, s);
         double h_new = iHigh(_Symbol, PERIOD_M5, s - 2);
         if(l_old > h_new) { gap_top = l_old; gap_bot = h_new; found = true; }
      }

      if(found && gap_top >= ob_low && gap_bot <= ob_high) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Highest high / lowest low across an M5 shift range                |
//+------------------------------------------------------------------+
double HighestHighSince(int from_shift, int to_shift)
{
   double hi = -DBL_MAX;
   for(int s = from_shift; s >= to_shift; s--) hi = MathMax(hi, iHigh(_Symbol, PERIOD_M5, s));
   return hi;
}

double LowestLowSince(int from_shift, int to_shift)
{
   double lo = DBL_MAX;
   for(int s = from_shift; s >= to_shift; s--) lo = MathMin(lo, iLow(_Symbol, PERIOD_M5, s));
   return lo;
}

//+------------------------------------------------------------------+
//| Fire Model 1 at market and place Model 2 as a resting limit      |
//| order in the 61.8-80% reload zone of the sweep-to-shift leg      |
//+------------------------------------------------------------------+
void OpenModel1AndPlaceModel2(double leg_start, double leg_end)
{
   double buffer = InpSLBufferPoints * _Point;
   if(InpUseATRBuffer) buffer += GetATR() * InpATRBufferMult;

   double sl = g_bias_trade_long ? (g_m5_extreme_price - buffer) : (g_m5_extreme_price + buffer);
   double range_mid = (g_range_high + g_range_low) / 2.0;

   //--- Model 1: market entry, target the 50% level of the range
   double entry1 = g_bias_trade_long ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double risk1  = MathAbs(entry1 - sl);
   bool   model1_ok = false;

   if(risk1 > 0)
   {
      double lots1 = CalculateLots(risk1);
      if(lots1 > 0)
      {
         model1_ok = g_bias_trade_long
            ? trade.Buy (lots1, _Symbol, entry1, sl, range_mid, InpComment + "_M1")
            : trade.Sell(lots1, _Symbol, entry1, sl, range_mid, InpComment + "_M1");

         if(model1_ok)
            Print("MODEL 1 opened | Entry: ", entry1, " | SL: ", sl, " | TP: ", range_mid, " | Lots: ", lots1);
         else
            Print("Model 1 order failed | Retcode: ", trade.ResultRetcode());
      }
      else Print("Model 1 skipped – lot size calculation failed.");
   }
   else Print("Model 1 skipped – non-positive risk distance.");

   //--- Model 2: resting limit order in the reload zone, target the far side of the range
   double leg_range = MathAbs(leg_end - leg_start);
   double price_near = g_bias_trade_long ? (leg_end - InpRetraceNear * leg_range) : (leg_end + InpRetraceNear * leg_range);
   double price_far   = g_bias_trade_long ? (leg_end - InpRetraceFar  * leg_range) : (leg_end + InpRetraceFar  * leg_range);
   double entry2       = (price_near + price_far) / 2.0;
   double tp2           = g_bias_trade_long ? g_range_high : g_range_low;
   double risk2         = MathAbs(entry2 - sl);

   g_model2_ticket = 0;
   g_setup_wait_ct = 0;

   if(risk2 > 0)
   {
      double lots2 = CalculateLots(risk2);
      if(lots2 > 0)
      {
         bool ok2 = g_bias_trade_long
            ? trade.BuyLimit (lots2, entry2, _Symbol, sl, tp2, ORDER_TIME_GTC, 0, InpComment + "_M2")
            : trade.SellLimit(lots2, entry2, _Symbol, sl, tp2, ORDER_TIME_GTC, 0, InpComment + "_M2");

         if(ok2)
         {
            g_model2_ticket = trade.ResultOrder();
            Print("MODEL 2 placed | Entry: ", entry2, " | SL: ", sl, " | TP: ", tp2, " | Lots: ", lots2);
         }
         else Print("Model 2 order failed | Retcode: ", trade.ResultRetcode());
      }
      else Print("Model 2 skipped – lot size calculation failed.");
   }
   else Print("Model 2 skipped – non-positive risk distance.");

   if(!model1_ok && g_model2_ticket == 0)
   {
      // Neither leg could be opened – nothing to manage, go back to hunting.
      g_state      = STATE_IDLE;
      g_range_high = 0;
      return;
   }

   g_state = STATE_SETUP_ACTIVE;
}

//+------------------------------------------------------------------+
//| While the setup is active: cancel Model 2 if price closes back    |
//| through the sweep wick, time out a stale Model 2, and detect     |
//| when the whole setup has fully resolved                           |
//+------------------------------------------------------------------+
void ProcessSetupActive()
{
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   bool invalidated = g_bias_trade_long ? (c1 < g_m5_extreme_price) : (c1 > g_m5_extreme_price);

   if(invalidated && g_model2_ticket != 0)
   {
      CancelModel2();
      Print("Setup invalidated – price closed back through the sweep wick. Model 2 cancelled.");
   }

   g_setup_wait_ct++;
   if(g_model2_ticket != 0 && InpMaxTapWaitBars > 0 && g_setup_wait_ct >= InpMaxTapWaitBars)
   {
      CancelModel2();
      Print("Model 2 untouched after ", InpMaxTapWaitBars, " M5 bars – cancelled.");
   }

   if(g_model2_ticket != 0 && !OrderSelect(g_model2_ticket))
      g_model2_ticket = 0; // filled or removed by the broker

   if(!HasOpenPosition() && g_model2_ticket == 0)
   {
      g_state      = STATE_IDLE;
      g_range_high = 0;
      Print("Setup fully resolved – back to idle, watching for the next sweep.");
   }
}

//+------------------------------------------------------------------+
//| Cancel the Model 2 pending order, if it still exists               |
//+------------------------------------------------------------------+
void CancelModel2()
{
   if(g_model2_ticket == 0) return;
   if(OrderSelect(g_model2_ticket))
   {
      if(!trade.OrderDelete(g_model2_ticket))
         Print("Failed to delete Model 2 order #", g_model2_ticket, " | Error: ", GetLastError());
   }
   g_model2_ticket = 0;
}

//+------------------------------------------------------------------+
//| Generic confirmed swing HIGH/LOW finder (used for the H4 bias)   |
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
//| Swing HIGH/LOW finder constrained to M5 bars strictly more       |
//| recent than 'after_shift' (used for the post-sweep shift search) |
//+------------------------------------------------------------------+
double FindSwingHighAfter(int after_shift, int n, int lookback)
{
   int max_i = MathMin(lookback, after_shift - n - 1);
   for(int i = n + 1; i <= max_i; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      bool   ok = true;
      for(int j = 1; j <= n && ok; j++)
      {
         if(iHigh(_Symbol, PERIOD_M5, i - j) >= h) ok = false;
         if(iHigh(_Symbol, PERIOD_M5, i + j) >= h) ok = false;
      }
      if(ok) return h;
   }
   return 0;
}

double FindSwingLowAfter(int after_shift, int n, int lookback)
{
   int max_i = MathMin(lookback, after_shift - n - 1);
   for(int i = n + 1; i <= max_i; i++)
   {
      double l = iLow(_Symbol, PERIOD_M5, i);
      bool   ok = true;
      for(int j = 1; j <= n && ok; j++)
      {
         if(iLow(_Symbol, PERIOD_M5, i - j) <= l) ok = false;
         if(iLow(_Symbol, PERIOD_M5, i + j) <= l) ok = false;
      }
      if(ok) return l;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Latest closed-bar ATR value (H1)                                  |
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
//| Close every open position on this symbol opened by this EA       |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      if(!trade.PositionClose(ticket))
         Print("Failed to close position #", ticket, " | Error: ", GetLastError());
   }
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
