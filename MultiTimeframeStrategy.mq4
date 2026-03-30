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
//|     a. Wait for H1 retrace – confirmed by EITHER:               |
//|        • An H1 candle body closes past the H1 BOS candle's wick  |
//|          in the opposite direction                               |
//|        • Two consecutive H1 candles in the opposite direction    |
//|     b. Detect the first 5-min Break of Structure (BOS) in the   |
//|        same direction as the H1 bias.                            |
//|     c. After the M5 BOS, wait for price to pull back.           |
//|     d. Entry: next M5 candle that closes above (bull) / below   |
//|        (bear) the previous candle's high / low.                  |
//|     e. Stop loss: below (bull) / above (bear) the entry candle. |
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
   STATE_BULL_BOS,       // M5 bullish BOS confirmed, awaiting pullback then entry
   STATE_BEAR_BOS,       // M5 bearish BOS confirmed, awaiting pullback then entry
   STATE_IN_TRADE        // Position is open
};

//--- Global variables
EState   g_state         = STATE_IDLE;
datetime g_h1_bar_time   = 0;
datetime g_m5_bar_time   = 0;
double   g_pip           = 0;

// H1 structure levels recorded at the time of bias detection
double   g_h1_swing_high     = 0;
double   g_h1_swing_low      = 0;

// H1 retrace tracking
// Bullish: lower wick of the H1 BOS candle – an H1 body must close below this
// Bearish: upper wick of the H1 BOS candle – an H1 body must close above this
double   g_h1_retrace_level  = 0;
int      g_retrace_bar_count = 0;  // consecutive opposite-direction H1 bars

// M5 BOS details
double   g_bos_close     = 0;  // Close of the M5 candle that created the BOS
double   g_bos_bar_high  = 0;
double   g_bos_bar_low   = 0;
bool     g_pullback_seen = false;

int      g_ticket        = -1;

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
   // While in a trade just monitor for closure
   if (g_state == STATE_IN_TRADE)
   {
      if (!IsTradeOpen())
      {
         Print("Trade closed. Returning to IDLE.");
         g_state = STATE_IDLE;
         g_ticket = -1;
      }
      return;
   }

   // Process each timeframe only on the open of a new bar
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
         g_state              = STATE_BULL_RETRACE;
         g_h1_swing_high      = sh;
         // Lower wick of the BOS candle is the retrace reference level
         g_h1_retrace_level   = iLow(Symbol(), PERIOD_H1, 1);
         g_retrace_bar_count  = 0;
         g_pullback_seen      = false;
         Print("H1 Bullish BOS | Swing High: ", sh,
               " | Retrace level (wick): ", g_h1_retrace_level);
      }
   }
   //--- Bearish BOS: H1 candle closes below a prior swing low
   else if (sl > 0 && cl1 < sl)
   {
      if (g_state == STATE_IDLE || g_state == STATE_BULL        ||
          g_state == STATE_BULL_RETRACE || g_state == STATE_BULL_BOS)
      {
         g_state              = STATE_BEAR_RETRACE;
         g_h1_swing_low       = sl;
         // Upper wick of the BOS candle is the retrace reference level
         g_h1_retrace_level   = iHigh(Symbol(), PERIOD_H1, 1);
         g_retrace_bar_count  = 0;
         g_pullback_seen      = false;
         Print("H1 Bearish BOS | Swing Low: ", sl,
               " | Retrace level (wick): ", g_h1_retrace_level);
      }
   }

   //--- Invalidate an active bullish bias if a bearish structural break occurs
   if ((g_state == STATE_BULL_RETRACE || g_state == STATE_BULL ||
        g_state == STATE_BULL_BOS) && sl > 0 && cl1 < sl)
   {
      Print("H1 Bullish bias invalidated. Resetting to IDLE.");
      g_state = STATE_IDLE;
   }

   //--- Invalidate an active bearish bias if a bullish structural break occurs
   if ((g_state == STATE_BEAR_RETRACE || g_state == STATE_BEAR ||
        g_state == STATE_BEAR_BOS) && sh > 0 && cl1 > sh)
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
      case STATE_BULL:     LookForBullishM5BOS();  break;
      case STATE_BEAR:     LookForBearishM5BOS();  break;
      case STATE_BULL_BOS: CheckBullishEntry();    break;
      case STATE_BEAR_BOS: CheckBearishEntry();    break;
      default: break;
   }
}

//+------------------------------------------------------------------+
//| H1 retrace confirmation – called on every new H1 bar            |
//|                                                                  |
//| A valid H1 retrace is confirmed by EITHER:                      |
//|  1. An H1 candle body closes past the BOS candle's wick in the  |
//|     opposite direction (body bottom < lower wick for bull /     |
//|     body top > upper wick for bear)                             |
//|  2. Two consecutive H1 candles in the opposite direction        |
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
      // Condition 1: bearish H1 body closes below the BOS candle's lower wick
      if (body_bot < g_h1_retrace_level)
      {
         g_state             = STATE_BULL;
         g_retrace_bar_count = 0;
         Print("H1 retrace confirmed (bull) | H1 body closed below wick: ", g_h1_retrace_level);
         return;
      }
      // Condition 2: two consecutive bearish H1 candles
      if (cl1 < op1)
         g_retrace_bar_count++;
      else
         g_retrace_bar_count = 0;

      if (g_retrace_bar_count >= 2)
      {
         g_state             = STATE_BULL;
         g_retrace_bar_count = 0;
         Print("H1 retrace confirmed (bull) | 2 consecutive bearish H1 candles");
      }
   }
   else if (g_state == STATE_BEAR_RETRACE)
   {
      // Condition 1: bullish H1 body closes above the BOS candle's upper wick
      if (body_top > g_h1_retrace_level)
      {
         g_state             = STATE_BEAR;
         g_retrace_bar_count = 0;
         Print("H1 retrace confirmed (bear) | H1 body closed above wick: ", g_h1_retrace_level);
         return;
      }
      // Condition 2: two consecutive bullish H1 candles
      if (cl1 > op1)
         g_retrace_bar_count++;
      else
         g_retrace_bar_count = 0;

      if (g_retrace_bar_count >= 2)
      {
         g_state             = STATE_BEAR;
         g_retrace_bar_count = 0;
         Print("H1 retrace confirmed (bear) | 2 consecutive bullish H1 candles");
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
      g_state         = STATE_BULL_BOS;
      g_bos_close     = cl1;
      g_bos_bar_high  = iHigh(Symbol(), PERIOD_M5, 1);
      g_bos_bar_low   = iLow (Symbol(), PERIOD_M5, 1);
      g_pullback_seen = false;
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
      g_state         = STATE_BEAR_BOS;
      g_bos_close     = cl1;
      g_bos_bar_high  = iHigh(Symbol(), PERIOD_M5, 1);
      g_bos_bar_low   = iLow (Symbol(), PERIOD_M5, 1);
      g_pullback_seen = false;
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

   // Step 1 – detect pullback after BOS
   if (!g_pullback_seen)
   {
      if (cl1 < g_bos_close)
      {
         g_pullback_seen = true;
         Print("Pullback detected after M5 Bullish BOS | Bar close: ", cl1);
      }
      return;
   }

   // Step 2 – entry confirmation: candle body closes above the previous candle's body top
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
         g_ticket = ticket;
         g_state  = STATE_IN_TRADE;
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

   // Step 1 – detect pullback after BOS
   if (!g_pullback_seen)
   {
      if (cl1 > g_bos_close)
      {
         g_pullback_seen = true;
         Print("Pullback detected after M5 Bearish BOS | Bar close: ", cl1);
      }
      return;
   }

   // Step 2 – entry confirmation: candle body closes below the previous candle's body bottom
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
         g_ticket = ticket;
         g_state  = STATE_IN_TRADE;
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
