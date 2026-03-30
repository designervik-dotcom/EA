//+------------------------------------------------------------------+
//|                              MultiTimeframeStrategy.mq4          |
//|                                                                  |
//|  Strategy Logic                                                  |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. H1 Bias: detect a structural break on the 1-hour chart.     |
//|     • Bullish bias  – H1 candle closes ABOVE a prior swing high  |
//|     • Bearish bias  – H1 candle closes BELOW a prior swing low   |
//|                                                                  |
//|  2. M5 Entry:                                                    |
//|     a. H1 leg: after the BOS, the leg continues while H1 candles |
//|        form in the bias direction. The wick reference updates     |
//|        to the last candle in the leg on each new bar.            |
//|        Retrace starts ONLY when an opposite H1 candle body       |
//|        closes past that last leg candle's wick.                  |
//|     b. Once the H1 retrace begins, watch the 5-min for structure |
//|        that matches the H1 bias – first M5 BOS in that direction. |
//|     c. After the M5 BOS, wait for a 5M pullback.                |
//|     d. Initial entry: M5 candle body closes above (bull) /       |
//|        below (bear) the previous candle's body.                  |
//|     e. Stop loss: below (bull) / above (bear) the entry candle.  |
//|                                                                  |
//|  3. Scale-ins (within the same H1 leg):                         |
//|     After each M5 leg, wait for a pullback then enter again      |
//|     when a 5M candle body closes fully above (bull) / below      |
//|     (bear) the previous candle's body (full body engulf).        |
//|     Each scale-in uses the same SL and 1:3 TP rules.            |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//--- Input parameters
input int    InpH1SwingBars   = 5;         // H1 pivot: bars each side to confirm
input int    InpM5SwingBars   = 3;         // M5 pivot: bars each side to confirm
input int    InpH1Lookback    = 40;        // H1 bars to search for structure
input int    InpM5Lookback    = 60;        // M5 bars to search for structure
input double InpRiskPercent   = 1.0;       // Risk per trade (% of account balance)
input double InpRRRatio       = 3.0;       // Take profit reward:risk ratio (e.g. 3 = 1:3)
input double InpSLBufferPips  = 3.0;       // Extra pip buffer added to stop loss
input int    InpSlippage      = 3;         // Maximum slippage in points
input int    InpMagicNumber   = 20240101;
input string InpComment       = "MTF";

//--- State machine
enum EState
{
   STATE_IDLE,           // No bias – scanning H1
   STATE_BULL_RETRACE,   // H1 bullish bias set, awaiting H1 retrace confirmation
   STATE_BEAR_RETRACE,   // H1 bearish bias set, awaiting H1 retrace confirmation
   STATE_BULL,           // H1 retrace confirmed, scanning M5 for bullish BOS
   STATE_BEAR,           // H1 retrace confirmed, scanning M5 for bearish BOS
   STATE_BULL_BOS,       // M5 bullish BOS confirmed, awaiting pullback then initial entry
   STATE_BEAR_BOS,       // M5 bearish BOS confirmed, awaiting pullback then initial entry
   STATE_BULL_SCALE,     // Initial entry taken, watching for further M5 scale-in setups
   STATE_BEAR_SCALE      // Initial entry taken, watching for further M5 scale-in setups
};

//--- Global variables
EState   g_state         = STATE_IDLE;
datetime g_h1_bar_time   = 0;
datetime g_m5_bar_time   = 0;
double   g_pip           = 0;

// H1 structure levels recorded at the time of bias detection
double   g_h1_swing_high     = 0;
double   g_h1_swing_low      = 0;

// H1 leg tracking
// Tracks the wick of the LAST H1 candle in the bias direction.
// Updated on every new H1 candle that continues the leg.
// Retrace is confirmed only when an opposite candle body closes past this level.
// Bullish leg: last bullish H1 candle's lower wick (iLow)
// Bearish leg: last bearish H1 candle's upper wick (iHigh)
double   g_h1_leg_last_wick  = 0;

// M5 BOS details
double   g_bos_close          = 0;   // Close of the M5 candle that created the BOS
double   g_bos_bar_high       = 0;
double   g_bos_bar_low        = 0;
bool     g_pullback_seen      = false;
int      g_pullback_count     = 0;   // consecutive opposite-direction candles toward pullback

// Scale-in tracking
bool     g_scale_pullback_seen  = false;
int      g_scale_pullback_count = 0; // consecutive opposite-direction candles toward scale pullback

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pip = (Digits == 5 || Digits == 3) ? Point * 10.0 : Point;

   Print("MultiTimeframeStrategy | Symbol: ", Symbol(),
         " | Digits: ", Digits,
         " | Pip: ",    g_pip);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MultiTimeframeStrategy stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Process each timeframe only on the open of a new bar.
   // No trade-open gate – scale-ins must keep firing while H1 bias holds.
   if (IsNewBar(PERIOD_H1, g_h1_bar_time))
   {
      CheckH1Bias();
      CheckH1Retrace();
   }
   if (IsNewBar(PERIOD_M5, g_m5_bar_time)) ProcessM5();
}

//+------------------------------------------------------------------+
//| H1 – detect structural break and set/invalidate bias            |
//+------------------------------------------------------------------+
void CheckH1Bias()
{
   double cl1 = iClose(Symbol(), PERIOD_H1, 1);
   double sh  = FindSwingHigh(PERIOD_H1, InpH1Lookback, InpH1SwingBars);
   double sl  = FindSwingLow (PERIOD_H1, InpH1Lookback, InpH1SwingBars);

   //--- Bullish BOS: H1 candle closes above a prior swing high
   if (sh > 0 && cl1 > sh)
   {
      if (g_state == STATE_IDLE || g_state == STATE_BEAR        ||
          g_state == STATE_BEAR_RETRACE || g_state == STATE_BEAR_BOS)
      {
         g_state             = STATE_BULL_RETRACE;
         g_h1_swing_high     = sh;
         // Seed with BOS candle's lower wick – will update as leg continues
         g_h1_leg_last_wick  = iLow(Symbol(), PERIOD_H1, 1);
         g_pullback_seen     = false;
         Print("H1 Bullish BOS | Swing High: ", sh,
               " | Leg wick seed: ", g_h1_leg_last_wick);
      }
   }
   //--- Bearish BOS: H1 candle closes below a prior swing low
   else if (sl > 0 && cl1 < sl)
   {
      if (g_state == STATE_IDLE || g_state == STATE_BULL        ||
          g_state == STATE_BULL_RETRACE || g_state == STATE_BULL_BOS)
      {
         g_state             = STATE_BEAR_RETRACE;
         g_h1_swing_low      = sl;
         // Seed with BOS candle's upper wick – will update as leg continues
         g_h1_leg_last_wick  = iHigh(Symbol(), PERIOD_H1, 1);
         g_pullback_seen     = false;
         Print("H1 Bearish BOS | Swing Low: ", sl,
               " | Leg wick seed: ", g_h1_leg_last_wick);
      }
   }

   //--- Invalidate an active bullish bias if a bearish structural break occurs
   if ((g_state == STATE_BULL_RETRACE || g_state == STATE_BULL  ||
        g_state == STATE_BULL_BOS     || g_state == STATE_BULL_SCALE) &&
       sl > 0 && cl1 < sl)
   {
      Print("H1 Bullish bias invalidated. Resetting to IDLE.");
      g_state = STATE_IDLE;
   }

   //--- Invalidate an active bearish bias if a bullish structural break occurs
   if ((g_state == STATE_BEAR_RETRACE || g_state == STATE_BEAR  ||
        g_state == STATE_BEAR_BOS     || g_state == STATE_BEAR_SCALE) &&
       sh > 0 && cl1 > sh)
   {
      Print("H1 Bearish bias invalidated. Resetting to IDLE.");
      g_state = STATE_IDLE;
   }
}

//+------------------------------------------------------------------+
//| M5 – route to the correct stage handler                         |
//+------------------------------------------------------------------+
void ProcessM5()
{
   switch (g_state)
   {
      case STATE_BULL:       LookForBullishM5BOS();   break;
      case STATE_BEAR:       LookForBearishM5BOS();   break;
      case STATE_BULL_BOS:   CheckBullishEntry();     break;
      case STATE_BEAR_BOS:   CheckBearishEntry();     break;
      case STATE_BULL_SCALE: CheckBullishScaleIn();   break;
      case STATE_BEAR_SCALE: CheckBearishScaleIn();   break;
      default: break;
   }
}

//+------------------------------------------------------------------+
//| H1 leg tracker and retrace detector – called on every new H1 bar|
//|                                                                  |
//| While the leg is forming (STATE_BULL/BEAR_RETRACE):             |
//|   • Each H1 candle in the bias direction extends the leg –      |
//|     update g_h1_leg_last_wick to that candle's wick             |
//|   • The leg ends ONLY when an opposing candle body closes past  |
//|     the wick of the LAST candle in the leg:                     |
//|     Bull: bearish H1 body bottom < last bullish candle's low    |
//|     Bear: bullish H1 body top   > last bearish candle's high    |
//+------------------------------------------------------------------+
void CheckH1Retrace()
{
   if (g_state != STATE_BULL_RETRACE && g_state != STATE_BEAR_RETRACE) return;

   double op1      = iOpen (Symbol(), PERIOD_H1, 1);
   double cl1      = iClose(Symbol(), PERIOD_H1, 1);
   double body_top = MathMax(op1, cl1);
   double body_bot = MathMin(op1, cl1);

   if (g_state == STATE_BULL_RETRACE)
   {
      if (cl1 > op1)
      {
         // Bullish candle – leg is still going, update the wick reference
         g_h1_leg_last_wick = iLow(Symbol(), PERIOD_H1, 1);
         Print("H1 leg extended (bull) | New wick level: ", g_h1_leg_last_wick);
      }
      else
      {
         // Bearish candle – check if body closes below the last leg candle's wick
         if (body_bot < g_h1_leg_last_wick)
         {
            g_state = STATE_BULL;
            Print("H1 retrace started (bull) | Body closed below wick: ", g_h1_leg_last_wick);
         }
      }
   }
   else // STATE_BEAR_RETRACE
   {
      if (cl1 < op1)
      {
         // Bearish candle – leg is still going, update the wick reference
         g_h1_leg_last_wick = iHigh(Symbol(), PERIOD_H1, 1);
         Print("H1 leg extended (bear) | New wick level: ", g_h1_leg_last_wick);
      }
      else
      {
         // Bullish candle – check if body closes above the last leg candle's wick
         if (body_top > g_h1_leg_last_wick)
         {
            g_state = STATE_BEAR;
            Print("H1 retrace started (bear) | Body closed above wick: ", g_h1_leg_last_wick);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| M5 – detect first bullish Break of Structure                    |
//| A bullish BOS = M5 candle closes above a confirmed M5 swing high |
//+------------------------------------------------------------------+
void LookForBullishM5BOS()
{
   double m5_sh = FindSwingHigh(PERIOD_M5, InpM5Lookback, InpM5SwingBars);
   if (m5_sh <= 0) return;

   double cl1 = iClose(Symbol(), PERIOD_M5, 1);

   if (cl1 > m5_sh)
   {
      g_state           = STATE_BULL_BOS;
      g_bos_close       = cl1;
      g_bos_bar_high    = iHigh(Symbol(), PERIOD_M5, 1);
      g_bos_bar_low     = iLow (Symbol(), PERIOD_M5, 1);
      g_pullback_seen   = false;
      g_pullback_count  = 0;
      Print("M5 Bullish BOS | Level: ", m5_sh, " | M5 Close: ", cl1);
   }
}

//+------------------------------------------------------------------+
//| M5 – detect first bearish Break of Structure                    |
//| A bearish BOS = M5 candle closes below a confirmed M5 swing low  |
//+------------------------------------------------------------------+
void LookForBearishM5BOS()
{
   double m5_sl = FindSwingLow(PERIOD_M5, InpM5Lookback, InpM5SwingBars);
   if (m5_sl <= 0) return;

   double cl1 = iClose(Symbol(), PERIOD_M5, 1);

   if (cl1 < m5_sl)
   {
      g_state           = STATE_BEAR_BOS;
      g_bos_close       = cl1;
      g_bos_bar_high    = iHigh(Symbol(), PERIOD_M5, 1);
      g_bos_bar_low     = iLow (Symbol(), PERIOD_M5, 1);
      g_pullback_seen   = false;
      g_pullback_count  = 0;
      Print("M5 Bearish BOS | Level: ", m5_sl, " | M5 Close: ", cl1);
   }
}

//+------------------------------------------------------------------+
//| M5 Bullish entry sequence                                        |
//| 1. Wait for pullback – any M5 bar closes below the BOS close    |
//| 2. Entry – next M5 candle body closes above the previous body   |
//| 3. Stop loss – below the entry candle low (+ buffer)            |
//+------------------------------------------------------------------+
void CheckBullishEntry()
{
   double cl1 = iClose(Symbol(), PERIOD_M5, 1);
   double lo1 = iLow  (Symbol(), PERIOD_M5, 1);

   // Top of the previous candle's body (ignores the wick)
   double body_top2 = MathMax(iOpen(Symbol(), PERIOD_M5, 2), iClose(Symbol(), PERIOD_M5, 2));

   // Step 1 – detect pullback: requires 2 consecutive bearish M5 candles
   if (!g_pullback_seen)
   {
      double op1_pb = iOpen(Symbol(), PERIOD_M5, 1);
      if (cl1 < op1_pb)
         g_pullback_count++;
      else
         g_pullback_count = 0;  // bullish candle resets the count

      if (g_pullback_count >= 2)
      {
         g_pullback_seen  = true;
         g_pullback_count = 0;
         Print("Pullback confirmed (bull) | 2 consecutive bearish M5 candles");
      }
      return;
   }

   // Step 2 – entry: candle in bias direction closes above the last pullback candle's body
   if (cl1 > body_top2)
   {
      double sl   = lo1 - InpSLBufferPips * g_pip;
      double tp   = Ask + (Ask - sl) * InpRRRatio;
      double lots = CalculateLots(Ask - sl);

      if (lots <= 0)
      {
         Print("Lot size error – trade skipped.");
         return;
      }

      int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                             sl, tp, InpComment, InpMagicNumber, 0, clrGreen);
      if (ticket > 0)
      {
         g_state               = STATE_BULL_SCALE;
         g_scale_pullback_seen  = false;
         g_scale_pullback_count = 0;
         Print("LONG opened | Ask: ", Ask,
               " | SL: ", sl,
               " | TP: ", tp,
               " | RR: 1:", InpRRRatio,
               " | Lots: ", lots,
               " | Ticket: ", ticket);
      }
      else
      {
         Print("OrderSend (BUY) failed | Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| M5 Bearish entry sequence                                        |
//| 1. Wait for pullback – any M5 bar closes above the BOS close    |
//| 2. Entry – next M5 candle body closes below the previous body   |
//| 3. Stop loss – above the entry candle high (+ buffer)           |
//+------------------------------------------------------------------+
void CheckBearishEntry()
{
   double cl1 = iClose(Symbol(), PERIOD_M5, 1);
   double hi1 = iHigh (Symbol(), PERIOD_M5, 1);

   // Bottom of the previous candle's body (ignores the wick)
   double body_bot2 = MathMin(iOpen(Symbol(), PERIOD_M5, 2), iClose(Symbol(), PERIOD_M5, 2));

   // Step 1 – detect pullback: requires 2 consecutive bullish M5 candles
   if (!g_pullback_seen)
   {
      double op1_pb = iOpen(Symbol(), PERIOD_M5, 1);
      if (cl1 > op1_pb)
         g_pullback_count++;
      else
         g_pullback_count = 0;  // bearish candle resets the count

      if (g_pullback_count >= 2)
      {
         g_pullback_seen  = true;
         g_pullback_count = 0;
         Print("Pullback confirmed (bear) | 2 consecutive bullish M5 candles");
      }
      return;
   }

   // Step 2 – entry: candle in bias direction closes below the last pullback candle's body
   if (cl1 < body_bot2)
   {
      double sl   = hi1 + InpSLBufferPips * g_pip;
      double tp   = Bid - (sl - Bid) * InpRRRatio;
      double lots = CalculateLots(sl - Bid);

      if (lots <= 0)
      {
         Print("Lot size error – trade skipped.");
         return;
      }

      int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                             sl, tp, InpComment, InpMagicNumber, 0, clrRed);
      if (ticket > 0)
      {
         g_state                = STATE_BEAR_SCALE;
         g_scale_pullback_seen  = false;
         g_scale_pullback_count = 0;
         Print("SHORT opened | Bid: ", Bid,
               " | SL: ", sl,
               " | TP: ", tp,
               " | RR: 1:", InpRRRatio,
               " | Lots: ", lots,
               " | Ticket: ", ticket);
      }
      else
      {
         Print("OrderSend (SELL) failed | Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Find the most recent confirmed swing HIGH within the last        |
//| 'lookback' bars on timeframe 'tf'.                               |
//| A pivot high at bar[i] requires that the 'n' bars on each side  |
//| have strictly lower highs.                                       |
//+------------------------------------------------------------------+
double FindSwingHigh(int tf, int lookback, int n)
{
   // Start at n+1 so both sides (n bars left and right) are fully closed.
   // Bar 0 is still forming so the earliest possible pivot is bar n+1.
   for (int i = n + 1; i <= lookback - n; i++)
   {
      double h  = iHigh(Symbol(), tf, i);
      bool   ok = true;

      for (int j = 1; j <= n && ok; j++)
      {
         if (iHigh(Symbol(), tf, i - j) >= h) ok = false; // left side (more recent)
         if (iHigh(Symbol(), tf, i + j) >= h) ok = false; // right side (older)
      }

      if (ok) return h;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Find the most recent confirmed swing LOW within the last         |
//| 'lookback' bars on timeframe 'tf'.                               |
//+------------------------------------------------------------------+
double FindSwingLow(int tf, int lookback, int n)
{
   for (int i = n + 1; i <= lookback - n; i++)
   {
      double l  = iLow(Symbol(), tf, i);
      bool   ok = true;

      for (int j = 1; j <= n && ok; j++)
      {
         if (iLow(Symbol(), tf, i - j) <= l) ok = false;
         if (iLow(Symbol(), tf, i + j) <= l) ok = false;
      }

      if (ok) return l;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Returns true on the first tick of a new bar on 'tf'             |
//+------------------------------------------------------------------+
bool IsNewBar(int tf, datetime &last_time)
{
   datetime cur = iTime(Symbol(), tf, 0);
   if (cur != last_time)
   {
      last_time = cur;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size from a fixed risk percentage                  |
//| sl_distance – distance from entry to stop loss in price units   |
//+------------------------------------------------------------------+
double CalculateLots(double sl_distance)
{
   if (sl_distance <= 0) return 0;

   double balance   = AccountBalance();
   double risk_cash = balance * InpRiskPercent / 100.0;
   double tick_val  = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tick_size = MarketInfo(Symbol(), MODE_TICKSIZE);

   double lots = risk_cash / (sl_distance / tick_size * tick_val);

   double min_lot  = MarketInfo(Symbol(), MODE_MINLOT);
   double max_lot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lot_step = MarketInfo(Symbol(), MODE_LOTSTEP);

   lots = MathFloor(lots / lot_step) * lot_step;
   return MathMax(min_lot, MathMin(max_lot, lots));
}

//+------------------------------------------------------------------+
//| Scale-in: bullish – watch for M5 pullback then full body engulf  |
//|                                                                  |
//| Pullback: any bearish M5 candle (close < open)                  |
//| Entry:    current candle body entirely above previous candle     |
//|           body (body_bot1 > body_top2) — full body engulf        |
//| SL:       below the entry candle low                            |
//+------------------------------------------------------------------+
void CheckBullishScaleIn()
{
   double op1 = iOpen (Symbol(), PERIOD_M5, 1);
   double cl1 = iClose(Symbol(), PERIOD_M5, 1);
   double op2 = iOpen (Symbol(), PERIOD_M5, 2);
   double cl2 = iClose(Symbol(), PERIOD_M5, 2);
   double lo1 = iLow  (Symbol(), PERIOD_M5, 1);

   // Step 1 – detect pullback: 2 consecutive bearish M5 candles after the last entry
   if (!g_scale_pullback_seen)
   {
      if (cl1 < op1)
         g_scale_pullback_count++;
      else
         g_scale_pullback_count = 0;

      if (g_scale_pullback_count >= 2)
      {
         g_scale_pullback_seen  = true;
         g_scale_pullback_count = 0;
         Print("Scale-in pullback confirmed (bull) | 2 consecutive bearish M5 candles");
      }
      return;
   }

   // Step 2 – full body engulf: entire body of current candle above previous body
   double body_bot1 = MathMin(op1, cl1);
   double body_top2 = MathMax(op2, cl2);

   if (body_bot1 > body_top2)
   {
      double sl   = lo1 - InpSLBufferPips * g_pip;
      double tp   = Ask + (Ask - sl) * InpRRRatio;
      double lots = CalculateLots(Ask - sl);

      if (lots <= 0) { Print("Scale-in lot size error – skipped."); return; }

      int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                             sl, tp, InpComment + "_SI", InpMagicNumber, 0, clrBlue);
      if (ticket > 0)
      {
         g_scale_pullback_seen  = false;
         g_scale_pullback_count = 0;
         Print("SCALE-IN LONG | Ask: ", Ask,
               " | SL: ", sl, " | TP: ", tp,
               " | Lots: ", lots, " | Ticket: ", ticket);
      }
      else
      {
         Print("Scale-in BUY failed | Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Scale-in: bearish – watch for M5 pullback then full body engulf  |
//|                                                                  |
//| Pullback: any bullish M5 candle (close > open)                  |
//| Entry:    current candle body entirely below previous candle     |
//|           body (body_top1 < body_bot2) — full body engulf        |
//| SL:       above the entry candle high                           |
//+------------------------------------------------------------------+
void CheckBearishScaleIn()
{
   double op1 = iOpen (Symbol(), PERIOD_M5, 1);
   double cl1 = iClose(Symbol(), PERIOD_M5, 1);
   double op2 = iOpen (Symbol(), PERIOD_M5, 2);
   double cl2 = iClose(Symbol(), PERIOD_M5, 2);
   double hi1 = iHigh (Symbol(), PERIOD_M5, 1);

   // Step 1 – detect pullback: 2 consecutive bullish M5 candles after the last entry
   if (!g_scale_pullback_seen)
   {
      if (cl1 > op1)
         g_scale_pullback_count++;
      else
         g_scale_pullback_count = 0;

      if (g_scale_pullback_count >= 2)
      {
         g_scale_pullback_seen  = true;
         g_scale_pullback_count = 0;
         Print("Scale-in pullback confirmed (bear) | 2 consecutive bullish M5 candles");
      }
      return;
   }

   // Step 2 – full body engulf: entire body of current candle below previous body
   double body_top1 = MathMax(op1, cl1);
   double body_bot2 = MathMin(op2, cl2);

   if (body_top1 < body_bot2)
   {
      double sl   = hi1 + InpSLBufferPips * g_pip;
      double tp   = Bid - (sl - Bid) * InpRRRatio;
      double lots = CalculateLots(sl - Bid);

      if (lots <= 0) { Print("Scale-in lot size error – skipped."); return; }

      int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                             sl, tp, InpComment + "_SI", InpMagicNumber, 0, clrOrange);
      if (ticket > 0)
      {
         g_scale_pullback_seen  = false;
         g_scale_pullback_count = 0;
         Print("SCALE-IN SHORT | Bid: ", Bid,
               " | SL: ", sl, " | TP: ", tp,
               " | Lots: ", lots, " | Ticket: ", ticket);
      }
      else
      {
         Print("Scale-in SELL failed | Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Returns true if the EA has an open position on this symbol       |
//+------------------------------------------------------------------+
bool IsTradeOpen()
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if (OrderMagicNumber() == InpMagicNumber &&
             OrderSymbol()      == Symbol())
            return true;
      }
   }
   return false;
}
//+------------------------------------------------------------------+
