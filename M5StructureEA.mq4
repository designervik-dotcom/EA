//+------------------------------------------------------------------+
//|                        M5StructureEA.mq4                         |
//|                                                                  |
//|  Rules:                                                          |
//|  1. Structure  – N consecutive M5 candles in one direction       |
//|                  defines the initial bias.                       |
//|  2. Pullback   – 2+ consecutive opposite-direction M5 candles.  |
//|  3. Entry      – Candle closes above (bull) / below (bear) the  |
//|                  body of the LAST pullback candle.               |
//|  4. Execution  – Market order on that candle's close.           |
//|                  SL: beyond the entry candle wick (+ buffer).   |
//|                  TP: 1:3 RR (configurable).                     |
//|  5. Scale-ins  – After each entry the EA cycles back to          |
//|                  watching for the next pullback in the same      |
//|                  direction. Bias is maintained until the         |
//|                  structural leg is broken.                       |
//|  6. Bias flip  – Bias changes only when a candle BODY closes     |
//|                  below the bull leg low (for bull bias) or       |
//|                  above the bear leg high (for bear bias).        |
//|                  The EA then seeds the scanner with that         |
//|                  candle and looks for the opposite setup.        |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//--- Input parameters
input int    InpStructureCandles = 3;        // Min consecutive M5 candles to confirm structure
input double InpRiskPercent      = 1.0;      // Risk per trade (% of account balance)
input double InpRRRatio          = 3.0;      // Reward : Risk ratio  (e.g. 3 = 1:3)
input double InpSLBufferPips     = 2.0;      // Extra pip buffer added to stop loss
input int    InpEntryTimeout     = 20;       // Max M5 bars to wait for entry signal (0 = no limit)
input bool   InpOneTradeAtATime  = true;     // Do not open new entry while a trade is open
input int    InpSlippage         = 3;        // Maximum slippage in points
input int    InpMagicNumber      = 20250101;
input string InpComment          = "M5Struct";

//--- State machine
enum EState
{
   STATE_IDLE,           // No bias – scanning for N-candle structure
   STATE_BULL_PULLBACK,  // Bullish bias active – waiting for 2+ bearish pullback candles
   STATE_BEAR_PULLBACK,  // Bearish bias active – waiting for 2+ bullish pullback candles
   STATE_BULL_ENTRY,     // Bullish pullback confirmed – waiting for entry trigger
   STATE_BEAR_ENTRY      // Bearish pullback confirmed – waiting for entry trigger
};

//--- Global variables
EState   g_state              = STATE_IDLE;
datetime g_m5_bar_time        = 0;
double   g_pip                = 0;

// Structure scanner (used in STATE_IDLE)
int      g_struct_count       = 0;     // consecutive same-direction candle count
bool     g_struct_bull        = false; // direction being tracked

// Pullback counter
int      g_pullback_count     = 0;

// Entry reference – body of the last pullback candle
double   g_pullback_body_top  = 0;    // top of last pullback candle body (for bull entries)
double   g_pullback_body_bot  = 0;    // bottom of last pullback candle body (for bear entries)

// Entry timeout counter
int      g_entry_bars_waited  = 0;

// Structural leg levels – used to detect bias invalidation
// Bull bias: g_leg_low  = lowest low since the bullish structure began
// Bear bias: g_leg_high = highest high since the bearish structure began
double   g_leg_low            = 0;
double   g_leg_high           = 0;

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pip = (Digits == 5 || Digits == 3) ? Point * 10.0 : Point;
   Print("M5StructureEA | Symbol: ", Symbol(),
         " | Digits: ", Digits,
         " | Pip: ",    g_pip);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("M5StructureEA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler – fires logic only on a new M5 bar            |
//+------------------------------------------------------------------+
void OnTick()
{
   if (!IsNewBar(PERIOD_M5, g_m5_bar_time)) return;
   ProcessM5();
}

//+------------------------------------------------------------------+
//| Main M5 bar handler                                              |
//+------------------------------------------------------------------+
void ProcessM5()
{
   double op1  = iOpen (Symbol(), PERIOD_M5, 1);
   double cl1  = iClose(Symbol(), PERIOD_M5, 1);
   double hi1  = iHigh (Symbol(), PERIOD_M5, 1);
   double lo1  = iLow  (Symbol(), PERIOD_M5, 1);
   bool   bull = (cl1 > op1);

   // Before routing, check whether the current bias has been structurally broken.
   // This runs for all non-IDLE states.
   if (g_state != STATE_IDLE)
      CheckBiasInvalidation(bull, op1, cl1);

   // Route to the appropriate handler.
   switch (g_state)
   {
      case STATE_IDLE:          ScanForStructure(bull, op1, cl1);               break;
      case STATE_BULL_PULLBACK: TrackBullPullback(bull, op1, cl1);              break;
      case STATE_BEAR_PULLBACK: TrackBearPullback(bull, op1, cl1);              break;
      case STATE_BULL_ENTRY:    CheckBullEntry(bull, op1, cl1, lo1, hi1);       break;
      case STATE_BEAR_ENTRY:    CheckBearEntry(bull, op1, cl1, hi1, lo1);       break;
   }
}

//+------------------------------------------------------------------+
//| Bias invalidation                                                |
//|                                                                  |
//| Bull bias: if a candle body closes below the structural leg low  |
//|            the bullish structure is broken.                      |
//| Bear bias: if a candle body closes above the structural leg high |
//|            the bearish structure is broken.                      |
//|                                                                  |
//| On invalidation the EA resets to STATE_IDLE and seeds the        |
//| structure scanner with the breaking candle so the opposite       |
//| setup can be detected quickly.                                   |
//+------------------------------------------------------------------+
void CheckBiasInvalidation(bool bull, double op, double cl)
{
   double body_top = MathMax(op, cl);
   double body_bot = MathMin(op, cl);

   bool is_bull_bias = (g_state == STATE_BULL_PULLBACK || g_state == STATE_BULL_ENTRY);
   bool is_bear_bias = (g_state == STATE_BEAR_PULLBACK || g_state == STATE_BEAR_ENTRY);

   if (is_bull_bias && body_bot < g_leg_low)
   {
      Print("Bullish structure BROKEN | Body bot: ", body_bot,
            " < Leg low: ", g_leg_low, " | Switching to scan bear");
      ResetState();
      // Seed the scanner: this candle is bearish, count it as candle #1
      g_struct_bull  = false;
      g_struct_count = 1;
   }
   else if (is_bear_bias && body_top > g_leg_high)
   {
      Print("Bearish structure BROKEN | Body top: ", body_top,
            " > Leg high: ", g_leg_high, " | Switching to scan bull");
      ResetState();
      // Seed the scanner: this candle is bullish, count it as candle #1
      g_struct_bull  = true;
      g_struct_count = 1;
   }
}

//+------------------------------------------------------------------+
//| Structure scanner – runs in STATE_IDLE                           |
//|                                                                  |
//| Tracks consecutive same-direction candles. Once                 |
//| InpStructureCandles are seen, the bias is confirmed and we       |
//| move to the corresponding pullback-watch state.                  |
//+------------------------------------------------------------------+
void ScanForStructure(bool bull, double op, double cl)
{
   // Direction change or first candle – start (or restart) the count
   if (g_struct_count == 0 || bull != g_struct_bull)
   {
      g_struct_bull  = bull;
      g_struct_count = 1;
      return;
   }

   g_struct_count++;

   if (g_struct_count >= InpStructureCandles)
   {
      // Capture the structural leg level from the last InpStructureCandles bars
      if (bull)
      {
         g_leg_low = LegLow(InpStructureCandles);
         g_state   = STATE_BULL_PULLBACK;
         g_pullback_count = 0;
         Print("Bullish structure confirmed | Candles: ", g_struct_count,
               " | Leg low: ", g_leg_low);
      }
      else
      {
         g_leg_high = LegHigh(InpStructureCandles);
         g_state    = STATE_BEAR_PULLBACK;
         g_pullback_count = 0;
         Print("Bearish structure confirmed | Candles: ", g_struct_count,
               " | Leg high: ", g_leg_high);
      }
   }
}

//+------------------------------------------------------------------+
//| Bullish pullback tracker – STATE_BULL_PULLBACK                  |
//|                                                                  |
//| Counts consecutive bearish candles (the retracement).           |
//| Once 2+ are seen the last candle's body top is saved and we     |
//| move to STATE_BULL_ENTRY.                                        |
//| A bullish candle resets the pullback counter (but the bias and  |
//| structural leg level remain valid – we just wait again).        |
//+------------------------------------------------------------------+
void TrackBullPullback(bool bull, double op, double cl)
{
   if (!bull)   // bearish = retracement direction
   {
      g_pullback_count++;
      g_pullback_body_top = MathMax(op, cl);   // body top of this pullback candle

      if (g_pullback_count >= 2)
      {
         g_state             = STATE_BULL_ENTRY;
         g_entry_bars_waited = 0;
         Print("Bullish pullback confirmed | ", g_pullback_count,
               " candles | Last body top: ", g_pullback_body_top);
      }
   }
   else
   {
      if (g_pullback_count > 0)
         Print("Bull pullback interrupted at count ", g_pullback_count, " – waiting again");
      g_pullback_count = 0;
   }
}

//+------------------------------------------------------------------+
//| Bearish pullback tracker – STATE_BEAR_PULLBACK                  |
//|                                                                  |
//| Counts consecutive bullish candles (the retracement).           |
//| Once 2+ are seen the last candle's body bottom is saved and we  |
//| move to STATE_BEAR_ENTRY.                                        |
//+------------------------------------------------------------------+
void TrackBearPullback(bool bull, double op, double cl)
{
   if (bull)   // bullish = retracement direction
   {
      g_pullback_count++;
      g_pullback_body_bot = MathMin(op, cl);   // body bottom of this pullback candle

      if (g_pullback_count >= 2)
      {
         g_state             = STATE_BEAR_ENTRY;
         g_entry_bars_waited = 0;
         Print("Bearish pullback confirmed | ", g_pullback_count,
               " candles | Last body bot: ", g_pullback_body_bot);
      }
   }
   else
   {
      if (g_pullback_count > 0)
         Print("Bear pullback interrupted at count ", g_pullback_count, " – waiting again");
      g_pullback_count = 0;
   }
}

//+------------------------------------------------------------------+
//| Bullish entry check – STATE_BULL_ENTRY                          |
//|                                                                  |
//| Waits for a candle to close above the last pullback candle's    |
//| body top. That close IS the entry trigger.                       |
//|   • More bearish candles extend/update the reference body.      |
//|   • Timeout resets to BULL_PULLBACK to wait for a fresh setup.  |
//|   • SL  = entry candle low – buffer                             |
//|   • TP  = Ask + (Ask − SL) × RR                                 |
//| After a successful trade the EA cycles back to BULL_PULLBACK    |
//| to look for scale-in opportunities.                              |
//+------------------------------------------------------------------+
void CheckBullEntry(bool bull, double op, double cl, double lo, double hi)
{
   g_entry_bars_waited++;

   // Optional timeout – prevent getting stuck if setup never fires
   if (InpEntryTimeout > 0 && g_entry_bars_waited > InpEntryTimeout)
   {
      Print("Bull entry timed out after ", g_entry_bars_waited, " bars – resetting to pullback watch");
      g_state             = STATE_BULL_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
      return;
   }

   if (!bull)
   {
      // Pullback is extending – update the reference to this candle's body
      g_pullback_body_top = MathMax(op, cl);
      Print("Bull entry: pullback extended | New body top ref: ", g_pullback_body_top);
      return;
   }

   // Entry trigger: bullish candle closes above the last pullback candle's body top
   if (cl <= g_pullback_body_top) return;   // not yet

   if (InpOneTradeAtATime && IsTradeOpen())
   {
      Print("Bull entry signal – skipped (trade already open)");
      // Cycle back to look for the next pullback opportunity
      g_state          = STATE_BULL_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   double sl   = lo - InpSLBufferPips * g_pip;
   double risk = Ask - sl;

   if (risk <= 0)
   {
      Print("Invalid risk (SL at or above Ask) – skipped");
      g_state          = STATE_BULL_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   double tp   = Ask + risk * InpRRRatio;
   double lots = CalculateLots(risk);

   if (lots <= 0)
   {
      Print("Lot size error – skipped");
      g_state          = STATE_BULL_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                          NormalizeDouble(sl, Digits),
                          NormalizeDouble(tp, Digits),
                          InpComment, InpMagicNumber, 0, clrGreen);
   if (ticket > 0)
   {
      Print("LONG opened | Ask: ",  Ask,
            " | SL: ",  sl,
            " | TP: ",  tp,
            " | RR: 1:", InpRRRatio,
            " | Lots: ", lots,
            " | Ticket: ", ticket);
      // Cycle back to BULL_PULLBACK – watch for next scale-in
      g_state             = STATE_BULL_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
   }
   else
   {
      Print("OrderSend BUY failed | Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Bearish entry check – STATE_BEAR_ENTRY                          |
//|                                                                  |
//| Mirror of CheckBullEntry for the short side.                    |
//| Entry trigger: candle closes below the last pullback candle's   |
//| body bottom.                                                     |
//|   • SL  = entry candle high + buffer                            |
//|   • TP  = Bid − (SL − Bid) × RR                                 |
//+------------------------------------------------------------------+
void CheckBearEntry(bool bull, double op, double cl, double hi, double lo)
{
   g_entry_bars_waited++;

   if (InpEntryTimeout > 0 && g_entry_bars_waited > InpEntryTimeout)
   {
      Print("Bear entry timed out after ", g_entry_bars_waited, " bars – resetting to pullback watch");
      g_state             = STATE_BEAR_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
      return;
   }

   if (bull)
   {
      // Pullback is extending – update the reference to this candle's body
      g_pullback_body_bot = MathMin(op, cl);
      Print("Bear entry: pullback extended | New body bot ref: ", g_pullback_body_bot);
      return;
   }

   // Entry trigger: bearish candle closes below the last pullback candle's body bottom
   if (cl >= g_pullback_body_bot) return;   // not yet

   if (InpOneTradeAtATime && IsTradeOpen())
   {
      Print("Bear entry signal – skipped (trade already open)");
      g_state          = STATE_BEAR_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   double sl   = hi + InpSLBufferPips * g_pip;
   double risk = sl - Bid;

   if (risk <= 0)
   {
      Print("Invalid risk (SL at or below Bid) – skipped");
      g_state          = STATE_BEAR_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   double tp   = Bid - risk * InpRRRatio;
   double lots = CalculateLots(risk);

   if (lots <= 0)
   {
      Print("Lot size error – skipped");
      g_state          = STATE_BEAR_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                          NormalizeDouble(sl, Digits),
                          NormalizeDouble(tp, Digits),
                          InpComment, InpMagicNumber, 0, clrRed);
   if (ticket > 0)
   {
      Print("SHORT opened | Bid: ", Bid,
            " | SL: ",  sl,
            " | TP: ",  tp,
            " | RR: 1:", InpRRRatio,
            " | Lots: ", lots,
            " | Ticket: ", ticket);
      // Cycle back to BEAR_PULLBACK – watch for next scale-in
      g_state             = STATE_BEAR_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
   }
   else
   {
      Print("OrderSend SELL failed | Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+

// Reset to a clean idle state
void ResetState()
{
   g_state             = STATE_IDLE;
   g_struct_count      = 0;
   g_pullback_count    = 0;
   g_pullback_body_top = 0;
   g_pullback_body_bot = 0;
   g_entry_bars_waited = 0;
   g_leg_low           = 0;
   g_leg_high          = 0;
}

// Returns true on the first tick of a new bar for timeframe tf
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

// Returns true if this EA has an open order on this symbol
bool IsTradeOpen()
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
          OrderMagicNumber() == InpMagicNumber        &&
          OrderSymbol()      == Symbol())
         return true;
   }
   return false;
}

// Lowest low of the last n closed bars (bar 1 … bar n)
double LegLow(int n)
{
   double v = iLow(Symbol(), PERIOD_M5, 1);
   for (int i = 2; i <= n; i++)
      v = MathMin(v, iLow(Symbol(), PERIOD_M5, i));
   return v;
}

// Highest high of the last n closed bars (bar 1 … bar n)
double LegHigh(int n)
{
   double v = iHigh(Symbol(), PERIOD_M5, 1);
   for (int i = 2; i <= n; i++)
      v = MathMax(v, iHigh(Symbol(), PERIOD_M5, i));
   return v;
}

// Position size from a fixed risk percentage
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
