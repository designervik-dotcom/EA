//+------------------------------------------------------------------+
//|                        M5StructureEA.mq4                         |
//|                                                                  |
//|  Rules:                                                          |
//|  1. H1 Bias    – N consecutive H1 candles in one direction       |
//|                  define the higher-timeframe bias.               |
//|                  Only M5 setups that MATCH this bias are traded. |
//|                  When H1 bias flips, any conflicting M5 state    |
//|                  is reset immediately.                           |
//|  2. Structure  – N consecutive M5 candles in one direction       |
//|                  (must match H1 bias) confirm the M5 structure.  |
//|  3. Pullback   – 2+ consecutive opposite-direction M5 candles.  |
//|  4. Entry      – Candle closes above (bull) / below (bear) the  |
//|                  body of the LAST pullback candle.               |
//|  5. Execution  – Market order on that candle's close.           |
//|                  SL: beyond the entry candle wick (+ buffer).   |
//|                  TP: 1:3 RR (configurable).                     |
//|  6. Scale-ins  – After each entry the EA cycles back to          |
//|                  watching for the next pullback in the same      |
//|                  direction. Bias is maintained until the         |
//|                  structural leg is broken.                       |
//|  7. M5 Bias    – M5 bias changes only when a candle BODY closes  |
//|                  below the bull leg low / above the bear leg     |
//|                  high. The EA then seeds the scanner with that   |
//|                  candle and looks for the opposite setup         |
//|                  (subject to H1 bias agreement).                 |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "2.01"
#property strict

//--- Signal inversion
input bool   InpInvertSignals      = false; // Invert signals: bull setup→SELL, bear setup→BUY

//--- H1 bias filter
input bool   InpUseH1Filter        = true;  // Enable H1 direction filter
input int    InpH1StructureCandles = 2;     // Min consecutive H1 candles to set H1 bias

//--- M5 strategy
input int    InpStructureCandles   = 3;     // Min consecutive M5 candles to confirm structure
input double InpRiskPercent        = 1.0;   // Risk per trade (% of account balance)
input double InpRRRatio            = 3.0;   // Reward : Risk ratio  (e.g. 3 = 1:3)
input double InpSLBufferPips       = 2.0;   // Extra pip buffer added to stop loss
input int    InpEntryTimeout       = 20;    // Max M5 bars to wait for entry signal (0 = no limit)
input bool   InpOneTradeAtATime    = true;  // Do not open new entry while a trade is open
input int    InpSlippage           = 3;     // Maximum slippage in points
input int    InpMagicNumber        = 20250101;
input string InpComment            = "M5Struct";

//--- H1 bias
enum EH1Bias { H1_NONE, H1_BULL, H1_BEAR };

//--- M5 state machine
enum EState
{
   STATE_IDLE,           // No bias – scanning for N-candle structure
   STATE_BULL_PULLBACK,  // Bullish bias active – waiting for 2+ bearish pullback candles
   STATE_BEAR_PULLBACK,  // Bearish bias active – waiting for 2+ bullish pullback candles
   STATE_BULL_ENTRY,     // Bullish pullback confirmed – waiting for entry trigger
   STATE_BEAR_ENTRY      // Bearish pullback confirmed – waiting for entry trigger
};

//--- Global variables
EH1Bias  g_h1_bias            = H1_NONE;
datetime g_h1_bar_time        = 0;
int      g_h1_struct_count    = 0;
bool     g_h1_struct_bull     = false;

EState   g_state              = STATE_IDLE;
datetime g_m5_bar_time        = 0;
double   g_pip                = 0;

// M5 structure scanner (STATE_IDLE)
int      g_struct_count       = 0;
bool     g_struct_bull        = false;

// Pullback counter
int      g_pullback_count     = 0;

// Entry reference – body of the last pullback candle
double   g_pullback_body_top  = 0;
double   g_pullback_body_bot  = 0;

// Entry timeout counter
int      g_entry_bars_waited  = 0;

// M5 structural leg levels for bias invalidation
double   g_leg_low            = 0;
double   g_leg_high           = 0;

//+------------------------------------------------------------------+
//| Expert initialisation                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pip = (Digits == 5 || Digits == 3) ? Point * 10.0 : Point;
   Print("M5StructureEA v2 | Symbol: ", Symbol(),
         " | Digits: ", Digits,
         " | Pip: ",    g_pip,
         " | H1 filter: ", (InpUseH1Filter ? "ON" : "OFF"),
         " | Inverted: ", (InpInvertSignals ? "YES" : "NO"));
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
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   if (IsNewBar(PERIOD_H1, g_h1_bar_time)) ProcessH1();
   if (IsNewBar(PERIOD_M5, g_m5_bar_time)) ProcessM5();
}

//+------------------------------------------------------------------+
//| H1 bias tracker                                                  |
//|                                                                  |
//| Tracks consecutive H1 candles. Once InpH1StructureCandles in    |
//| one direction are seen, H1 bias is set to BULL or BEAR.         |
//| When bias flips, any conflicting M5 state is reset immediately. |
//| H1_NONE (startup) does not block M5 entries.                    |
//+------------------------------------------------------------------+
void ProcessH1()
{
   if (!InpUseH1Filter) return;

   double op1 = iOpen (Symbol(), PERIOD_H1, 1);
   double cl1 = iClose(Symbol(), PERIOD_H1, 1);
   bool   bull = (cl1 > op1);

   // Track consecutive same-direction H1 candles
   if (g_h1_struct_count == 0 || bull != g_h1_struct_bull)
   {
      g_h1_struct_bull  = bull;
      g_h1_struct_count = 1;
   }
   else
   {
      g_h1_struct_count++;
   }

   if (g_h1_struct_count < InpH1StructureCandles) return;

   EH1Bias new_bias = bull ? H1_BULL : H1_BEAR;
   if (new_bias == g_h1_bias) return;   // no change

   g_h1_bias = new_bias;
   Print("H1 bias set to ", (bull ? "BULLISH" : "BEARISH"),
         " | Consecutive H1 candles: ", g_h1_struct_count);

   // Reset M5 state if it is trading against the new H1 bias
   bool m5_long  = (g_state == STATE_BULL_PULLBACK || g_state == STATE_BULL_ENTRY);
   bool m5_short = (g_state == STATE_BEAR_PULLBACK || g_state == STATE_BEAR_ENTRY);

   if ((bull && m5_short) || (!bull && m5_long))
   {
      Print("M5 state conflicts with new H1 bias – M5 state reset");
      ResetState();
   }
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

   // Check whether the active M5 structural leg has been broken
   if (g_state != STATE_IDLE)
      CheckBiasInvalidation(bull, op1, cl1);

   switch (g_state)
   {
      case STATE_IDLE:          ScanForStructure(bull, op1, cl1);         break;
      case STATE_BULL_PULLBACK: TrackBullPullback(bull, op1, cl1);        break;
      case STATE_BEAR_PULLBACK: TrackBearPullback(bull, op1, cl1);        break;
      case STATE_BULL_ENTRY:    CheckBullEntry(bull, op1, cl1, lo1, hi1); break;
      case STATE_BEAR_ENTRY:    CheckBearEntry(bull, op1, cl1, hi1, lo1); break;
   }
}

//+------------------------------------------------------------------+
//| M5 bias invalidation – checks structural leg break               |
//|                                                                  |
//| Bull bias: candle body closes below the leg low  → broken        |
//| Bear bias: candle body closes above the leg high → broken        |
//+------------------------------------------------------------------+
void CheckBiasInvalidation(bool bull, double op, double cl)
{
   double body_top = MathMax(op, cl);
   double body_bot = MathMin(op, cl);

   bool is_bull = (g_state == STATE_BULL_PULLBACK || g_state == STATE_BULL_ENTRY);
   bool is_bear = (g_state == STATE_BEAR_PULLBACK || g_state == STATE_BEAR_ENTRY);

   if (is_bull && body_bot < g_leg_low)
   {
      Print("M5 bullish structure BROKEN | Body bot: ", body_bot,
            " < Leg low: ", g_leg_low);
      ResetState();
      g_struct_bull  = false;
      g_struct_count = 1;
   }
   else if (is_bear && body_top > g_leg_high)
   {
      Print("M5 bearish structure BROKEN | Body top: ", body_top,
            " > Leg high: ", g_leg_high);
      ResetState();
      g_struct_bull  = true;
      g_struct_count = 1;
   }
}

//+------------------------------------------------------------------+
//| M5 structure scanner – STATE_IDLE                                |
//|                                                                  |
//| Counts consecutive same-direction candles. On reaching           |
//| InpStructureCandles, checks H1 bias alignment before promoting. |
//| Bull structure → BULL_PULLBACK only if H1 is BULL or H1_NONE.   |
//| Bear structure → BEAR_PULLBACK only if H1 is BEAR or H1_NONE.   |
//+------------------------------------------------------------------+
void ScanForStructure(bool bull, double op, double cl)
{
   if (g_struct_count == 0 || bull != g_struct_bull)
   {
      g_struct_bull  = bull;
      g_struct_count = 1;
      return;
   }

   g_struct_count++;

   if (g_struct_count < InpStructureCandles) return;

   if (bull)
   {
      // Only promote if H1 agrees (or H1 bias not yet established)
      if (InpUseH1Filter && g_h1_bias == H1_BEAR)
      {
         Print("M5 bullish structure detected but H1 is BEARISH – setup skipped");
         return;
      }
      g_leg_low        = LegLow(InpStructureCandles);
      g_state          = STATE_BULL_PULLBACK;
      g_pullback_count = 0;
      Print("M5 bullish structure confirmed | Candles: ", g_struct_count,
            " | Leg low: ", g_leg_low,
            " | H1 bias: ", H1BiasLabel());
   }
   else
   {
      if (InpUseH1Filter && g_h1_bias == H1_BULL)
      {
         Print("M5 bearish structure detected but H1 is BULLISH – setup skipped");
         return;
      }
      g_leg_high       = LegHigh(InpStructureCandles);
      g_state          = STATE_BEAR_PULLBACK;
      g_pullback_count = 0;
      Print("M5 bearish structure confirmed | Candles: ", g_struct_count,
            " | Leg high: ", g_leg_high,
            " | H1 bias: ", H1BiasLabel());
   }
}

//+------------------------------------------------------------------+
//| Bullish pullback tracker – STATE_BULL_PULLBACK                  |
//+------------------------------------------------------------------+
void TrackBullPullback(bool bull, double op, double cl)
{
   if (!bull)
   {
      g_pullback_count++;
      g_pullback_body_top = MathMax(op, cl);

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
//+------------------------------------------------------------------+
void TrackBearPullback(bool bull, double op, double cl)
{
   if (bull)
   {
      g_pullback_count++;
      g_pullback_body_bot = MathMin(op, cl);

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
//| Entry trigger: bullish candle closes above g_pullback_body_top. |
//| SL = entry candle low – buffer.                                  |
//| TP = Ask + (Ask − SL) × RR.                                     |
//| After entry: cycles back to BULL_PULLBACK for scale-ins.        |
//+------------------------------------------------------------------+
void CheckBullEntry(bool bull, double op, double cl, double lo, double hi)
{
   g_entry_bars_waited++;

   if (InpEntryTimeout > 0 && g_entry_bars_waited > InpEntryTimeout)
   {
      Print("Bull entry timed out after ", g_entry_bars_waited, " bars – back to pullback watch");
      g_state             = STATE_BULL_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
      return;
   }

   if (!bull)
   {
      g_pullback_body_top = MathMax(op, cl);
      Print("Bull entry: pullback extended | New body top ref: ", g_pullback_body_top);
      return;
   }

   if (cl <= g_pullback_body_top) return;   // trigger not yet reached

   // Final H1 alignment check (safety net – should already be aligned)
   if (InpUseH1Filter && g_h1_bias == H1_BEAR)
   {
      Print("Bull entry blocked – H1 turned BEARISH");
      ResetState();
      return;
   }

   if (InpOneTradeAtATime && IsTradeOpen())
   {
      Print("Bull entry signal – skipped (trade already open)");
      g_state          = STATE_BULL_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   double sl, risk, tp, lots;
   int    ticket;

   if (!InpInvertSignals)
   {
      // Normal: bull signal → BUY
      sl   = lo - InpSLBufferPips * g_pip;
      risk = Ask - sl;
      if (risk <= 0) { Print("Invalid risk – skipped"); g_state = STATE_BULL_PULLBACK; g_pullback_count = 0; return; }
      tp   = Ask + risk * InpRRRatio;
      lots = CalculateLots(risk);
      if (lots <= 0) { Print("Lot size error – skipped"); g_state = STATE_BULL_PULLBACK; g_pullback_count = 0; return; }
      ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                         NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                         InpComment, InpMagicNumber, 0, clrGreen);
      if (ticket > 0)
         Print("LONG opened | Ask: ", Ask, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots, " | H1: ", H1BiasLabel(), " | Ticket: ", ticket);
      else
         Print("OrderSend BUY failed | Error: ", GetLastError());
   }
   else
   {
      // Inverted: bull signal → SELL
      sl   = hi + InpSLBufferPips * g_pip;
      risk = sl - Bid;
      if (risk <= 0) { Print("Invalid risk – skipped"); g_state = STATE_BULL_PULLBACK; g_pullback_count = 0; return; }
      tp   = Bid - risk * InpRRRatio;
      lots = CalculateLots(risk);
      if (lots <= 0) { Print("Lot size error – skipped"); g_state = STATE_BULL_PULLBACK; g_pullback_count = 0; return; }
      ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                         NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                         InpComment + "_INV", InpMagicNumber, 0, clrOrange);
      if (ticket > 0)
         Print("SHORT (inv) opened | Bid: ", Bid, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots, " | H1: ", H1BiasLabel(), " | Ticket: ", ticket);
      else
         Print("OrderSend SELL (inv) failed | Error: ", GetLastError());
   }

   if (ticket > 0)
   {
      g_state             = STATE_BULL_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
   }
}

//+------------------------------------------------------------------+
//| Bearish entry check – STATE_BEAR_ENTRY                          |
//|                                                                  |
//| Entry trigger: bearish candle closes below g_pullback_body_bot. |
//| SL = entry candle high + buffer.                                 |
//| TP = Bid − (SL − Bid) × RR.                                     |
//+------------------------------------------------------------------+
void CheckBearEntry(bool bull, double op, double cl, double hi, double lo)
{
   g_entry_bars_waited++;

   if (InpEntryTimeout > 0 && g_entry_bars_waited > InpEntryTimeout)
   {
      Print("Bear entry timed out after ", g_entry_bars_waited, " bars – back to pullback watch");
      g_state             = STATE_BEAR_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
      return;
   }

   if (bull)
   {
      g_pullback_body_bot = MathMin(op, cl);
      Print("Bear entry: pullback extended | New body bot ref: ", g_pullback_body_bot);
      return;
   }

   if (cl >= g_pullback_body_bot) return;

   if (InpUseH1Filter && g_h1_bias == H1_BULL)
   {
      Print("Bear entry blocked – H1 turned BULLISH");
      ResetState();
      return;
   }

   if (InpOneTradeAtATime && IsTradeOpen())
   {
      Print("Bear entry signal – skipped (trade already open)");
      g_state          = STATE_BEAR_PULLBACK;
      g_pullback_count = 0;
      return;
   }

   double sl, risk, tp, lots;
   int    ticket;

   if (!InpInvertSignals)
   {
      // Normal: bear signal → SELL
      sl   = hi + InpSLBufferPips * g_pip;
      risk = sl - Bid;
      if (risk <= 0) { Print("Invalid risk – skipped"); g_state = STATE_BEAR_PULLBACK; g_pullback_count = 0; return; }
      tp   = Bid - risk * InpRRRatio;
      lots = CalculateLots(risk);
      if (lots <= 0) { Print("Lot size error – skipped"); g_state = STATE_BEAR_PULLBACK; g_pullback_count = 0; return; }
      ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                         NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                         InpComment, InpMagicNumber, 0, clrRed);
      if (ticket > 0)
         Print("SHORT opened | Bid: ", Bid, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots, " | H1: ", H1BiasLabel(), " | Ticket: ", ticket);
      else
         Print("OrderSend SELL failed | Error: ", GetLastError());
   }
   else
   {
      // Inverted: bear signal → BUY
      sl   = lo - InpSLBufferPips * g_pip;
      risk = Ask - sl;
      if (risk <= 0) { Print("Invalid risk – skipped"); g_state = STATE_BEAR_PULLBACK; g_pullback_count = 0; return; }
      tp   = Ask + risk * InpRRRatio;
      lots = CalculateLots(risk);
      if (lots <= 0) { Print("Lot size error – skipped"); g_state = STATE_BEAR_PULLBACK; g_pullback_count = 0; return; }
      ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                         NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                         InpComment + "_INV", InpMagicNumber, 0, clrBlue);
      if (ticket > 0)
         Print("LONG (inv) opened | Ask: ", Ask, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots, " | H1: ", H1BiasLabel(), " | Ticket: ", ticket);
      else
         Print("OrderSend BUY (inv) failed | Error: ", GetLastError());
   }

   if (ticket > 0)
   {
      g_state             = STATE_BEAR_PULLBACK;
      g_pullback_count    = 0;
      g_entry_bars_waited = 0;
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+

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

bool IsNewBar(int tf, datetime &last_time)
{
   datetime cur = iTime(Symbol(), tf, 0);
   if (cur != last_time) { last_time = cur; return true; }
   return false;
}

bool IsTradeOpen()
{
   for (int i = 0; i < OrdersTotal(); i++)
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES) &&
          OrderMagicNumber() == InpMagicNumber        &&
          OrderSymbol()      == Symbol())
         return true;
   return false;
}

double LegLow(int n)
{
   double v = iLow(Symbol(), PERIOD_M5, 1);
   for (int i = 2; i <= n; i++)
      v = MathMin(v, iLow(Symbol(), PERIOD_M5, i));
   return v;
}

double LegHigh(int n)
{
   double v = iHigh(Symbol(), PERIOD_M5, 1);
   for (int i = 2; i <= n; i++)
      v = MathMax(v, iHigh(Symbol(), PERIOD_M5, i));
   return v;
}

string H1BiasLabel()
{
   if (g_h1_bias == H1_BULL) return "BULL";
   if (g_h1_bias == H1_BEAR) return "BEAR";
   return "NONE";
}

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
