//+------------------------------------------------------------------+
//|                    SupportResistanceBot.mq4                       |
//|                                                                   |
//|  Strategy Overview                                                |
//|  ─────────────────────────────────────────────────────────────── |
//|  1. M15 Bias (Higher High + Higher Low = Bullish;                 |
//|              Lower High  + Lower Low   = Bearish)                 |
//|     Scans the last InpM15Lookback bars for the 2 most recent     |
//|     confirmed M15 swing highs and lows and compares them to      |
//|     determine the current trend direction.                        |
//|                                                                   |
//|  2. S/R Level                                                     |
//|     • Bullish bias  → support    = most recent M15 swing low     |
//|     • Bearish bias  → resistance = most recent M15 swing high    |
//|     The level refreshes whenever a new confirmed swing forms      |
//|     that still agrees with the active bias.                       |
//|                                                                   |
//|  3. M5 Entry – classic engulfing candle at the S/R zone          |
//|     a. The candle BEFORE the trigger (bar[2]) must touch the      |
//|        S/R zone (within InpZoneATRMult × M15 ATR of the level).  |
//|     b. The latest closed M5 candle (bar[1]) must be a classic    |
//|        engulfing candle in the bias direction:                    |
//|        Bull: bar[2] bearish → bar[1] bullish body covers bar[2]  |
//|              body (open[1]≤close[2], close[1]≥open[2])           |
//|        Bear: bar[2] bullish → bar[1] bearish body covers bar[2]  |
//|              body (open[1]≥close[2], close[1]≤open[2])           |
//|                                                                   |
//|  4. Stop Loss & Take Profit                                       |
//|     SL  – below bar[1] low  (bull) / above bar[1] high (bear)   |
//|           + InpSLBufferATRMult × M5 ATR(14)                      |
//|     TP  – account-balance based: (InpTPPercent / InpRiskPercent) |
//|           × SL distance.  Default 3 % TP / 1 % risk = 1:3 RR.   |
//|                                                                   |
//|  Extra filters (all configurable, on by default where shown)     |
//|  ─────────────────────────────────────────────────────────────── |
//|  • Session filter   – skip trades outside InpSessionStart/End    |
//|  • Spread guard     – skip if spread > InpMaxSpreadATRMult×ATR   |
//|  • ATR body filter  – engulfing candle body must be ≥            |
//|                        InpMinBodyATR × ATR(14); keeps only        |
//|                        meaningful momentum candles               |
//|  • Daily trade cap  – max InpMaxDailyTrades entries per day      |
//|  • Chart line       – dashed H-line drawn at the active S/R      |
//|                        level (green = support, red = resistance)  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//=== Input parameters =================================================

// --- M15 Structure ---
input int    InpM15SwingBars    = 3;    // M15 pivot: bars on each side to confirm
input int    InpM15Lookback     = 80;   // M15 bars to scan for swing structure

// --- S/R Zone ---
// Zone width = InpZoneATRMult × M15 ATR(14).  Scales automatically to any
// instrument.  0.5 means bar[2] must trade within half an M15 ATR of the level.
input double InpZoneATRMult     = 0.5;  // S/R zone half-width (× M15 ATR-14)

// --- Entry Quality ---
input double InpMinBodyATR      = 0.3;  // Min engulfing body as fraction of M5 ATR(14); 0 = disabled

// --- Risk & Reward ---
input double InpRiskPercent     = 1.0;  // Risk per trade (% of account balance)
input double InpTPPercent       = 3.0;  // Take-profit target (% of account balance)
// SL extra buffer = InpSLBufferATRMult × M5 ATR(14).
// 0.15 ≈ 1.5 pips on EURUSD (ATR≈10p), ≈ $0.75 on XAUUSD (ATR≈$5).
input double InpSLBufferATRMult = 0.15; // SL extra buffer (× M5 ATR-14)

// --- Spread Guard ---
// Max spread = InpMaxSpreadATRMult × M5 ATR(14).
// 0.20 ≈ 2 pips on EURUSD, ≈ $1 on XAUUSD.  Blocks news-spike entries.
input double InpMaxSpreadATRMult= 0.20; // Max allowed spread (× M5 ATR-14)

// --- Session Filter ---
input bool   InpUseSession      = true; // Restrict entries to session window
input int    InpSessionStart    = 8;    // Session open  hour, server time (0-23)
input int    InpSessionEnd      = 21;   // Session close hour, server time (0-23)

// --- Daily Trade Cap ---
input int    InpMaxDailyTrades  = 3;    // Max trades per calendar day; 0 = unlimited

// --- H1 Trend Alignment ---
// Only take M15 setups that agree with the H1 market structure.
// Bull on M15 + Bull on H1 = price retesting support in a confirmed uptrend → higher hold rate.
// Bear on M15 + Bear on H1 = price retesting resistance in a confirmed downtrend → higher hold rate.
input bool   InpUseH1Filter     = true; // Require H1 structure to agree with M15 bias
input int    InpH1SwingBars     = 5;    // H1 pivot: bars on each side to confirm
input int    InpH1Lookback      = 40;   // H1 bars to scan for structure

// --- RSI Momentum Filter ---
// Checks that momentum has genuinely faded before the engulfing candle fires.
// At support in a bullish bias, RSI should be pulling back (below InpRSIBullMax).
// At resistance in a bearish bias, RSI should be elevated (above InpRSIBearMin).
// Default band 40-60 is intentionally wide; tighten to 35/65 for stricter filtering.
input bool   InpUseRSIFilter    = true; // Enable RSI momentum filter on M15
input int    InpRSIPeriod       = 14;   // RSI period
input double InpRSIBullMax      = 60;   // Bullish entry: M15 RSI must be ≤ this value
input double InpRSIBearMin      = 40;   // Bearish entry: M15 RSI must be ≥ this value

// --- Rejection Wick ---
// Requires bar[2] (the zone-touching candle) to have a rejection wick showing
// that the S/R level is actively being defended before the engulf fires.
// Bull: bar[2] lower wick ≥ InpMinWickRatio × bar[2] body
// Bear: bar[2] upper wick ≥ InpMinWickRatio × bar[2] body
// Set to 0 to disable.
input double InpMinWickRatio    = 0.5;  // Min wick-to-body ratio on the zone-touch candle

// --- Misc ---
input int    InpSlippage        = 3;    // Max slippage in points
input int    InpMagicNumber     = 20260101;
input string InpComment         = "SRBot";

//=== State machine ====================================================
enum EState
{
   STATE_IDLE,   // No clear M15 structure detected
   STATE_BULL,   // HH + HL confirmed – looking for long entry at support
   STATE_BEAR    // LH + LL confirmed – looking for short entry at resistance
};

//=== Global variables =================================================
EState   g_state          = STATE_IDLE;
double   g_sr_level       = 0;      // Active S/R price
double   g_pip            = 0;      // Pip size (0.0001 for 4-digit, 0.00001 for 5-digit)

datetime g_m15_bar_time   = 0;
datetime g_m5_bar_time    = 0;
datetime g_h1_bar_time    = 0;

// H1 trend state – updated on each new H1 bar, consumed in CheckM5Engulf
bool     g_h1_bull        = false;
bool     g_h1_bear        = false;

int      g_trades_today   = 0;
datetime g_last_day       = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   g_pip = (Digits == 5 || Digits == 3) ? Point * 10.0 : Point;

   Print("SupportResistanceBot | Symbol: ", Symbol(),
         " | Digits: ", Digits,
         " | Pip: ",    g_pip,
         " | Risk: ",   InpRiskPercent, "%",
         " | TP: ",     InpTPPercent,   "%");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteSRLine();
   Print("SupportResistanceBot stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   if (IsNewBar(PERIOD_H1,  g_h1_bar_time))  CheckH1Trend();
   if (IsNewBar(PERIOD_M15, g_m15_bar_time)) CheckM15Bias();
   if (IsNewBar(PERIOD_M5,  g_m5_bar_time))  CheckM5Engulf();
}

//+------------------------------------------------------------------+
//| H1 trend detector – runs once per H1 bar                        |
//|                                                                  |
//| Sets g_h1_bull / g_h1_bear by comparing the two most recent     |
//| confirmed H1 swing highs and lows.  Cached so CheckM5Engulf can  |
//| gate entries without re-running swing detection every M5 bar.   |
//+------------------------------------------------------------------+
void CheckH1Trend()
{
   if (!InpUseH1Filter) return;

   double h1_shs[2], h1_sls[2];
   int n_sh = FindTopNSwingHighs(PERIOD_H1, InpH1Lookback, InpH1SwingBars, h1_shs, 2);
   int n_sl = FindTopNSwingLows (PERIOD_H1, InpH1Lookback, InpH1SwingBars, h1_sls, 2);

   bool prev_bull = g_h1_bull;
   bool prev_bear = g_h1_bear;

   if (n_sh < 2 || n_sl < 2)
   {
      g_h1_bull = false;
      g_h1_bear = false;
   }
   else
   {
      g_h1_bull = (h1_shs[0] > h1_shs[1]) && (h1_sls[0] > h1_sls[1]);
      g_h1_bear = (h1_shs[0] < h1_shs[1]) && (h1_sls[0] < h1_sls[1]);
   }

   // Only print when the H1 trend label changes to keep the log clean
   if (g_h1_bull != prev_bull || g_h1_bear != prev_bear)
   {
      string label = g_h1_bull ? "BULLISH" : (g_h1_bear ? "BEARISH" : "MIXED/IDLE");
      Print("H1 Trend → ", label,
            " | SH: ", (n_sh >= 2 ? DoubleToStr(h1_shs[1], Digits) + " → " + DoubleToStr(h1_shs[0], Digits) : "n/a"),
            " | SL: ", (n_sl >= 2 ? DoubleToStr(h1_sls[1], Digits) + " → " + DoubleToStr(h1_sls[0], Digits) : "n/a"));
   }
}

//+------------------------------------------------------------------+
//| M15 bias detector                                                |
//|                                                                  |
//| Finds the 2 most recent confirmed M15 swing highs and lows.      |
//| HH + HL → Bullish; LH + LL → Bearish; mixed → IDLE.            |
//| g_sr_level is set to the most recent swing low (bull) or         |
//| swing high (bear) and updated on every new confirming swing.     |
//+------------------------------------------------------------------+
void CheckM15Bias()
{
   double shs[2], sls[2];
   int n_sh = FindTopNSwingHighs(PERIOD_M15, InpM15Lookback, InpM15SwingBars, shs, 2);
   int n_sl = FindTopNSwingLows (PERIOD_M15, InpM15Lookback, InpM15SwingBars, sls, 2);

   if (n_sh < 2 || n_sl < 2) return;   // Not enough confirmed pivots yet

   bool hh = shs[0] > shs[1];   // Most-recent swing high > previous → Higher High
   bool hl = sls[0] > sls[1];   // Most-recent swing low  > previous → Higher Low
   bool lh = shs[0] < shs[1];   // Most-recent swing high < previous → Lower High
   bool ll = sls[0] < sls[1];   // Most-recent swing low  < previous → Lower Low

   // ── Bullish structure ─────────────────────────────────────────
   if (hh && hl)
   {
      double new_support = sls[0];
      if (g_state != STATE_BULL || new_support != g_sr_level)
      {
         g_state    = STATE_BULL;
         g_sr_level = new_support;
         DrawSRLine(g_sr_level, clrLimeGreen);
         Print("M15 BULLISH | HH: ", DoubleToStr(shs[1], Digits), " → ", DoubleToStr(shs[0], Digits),
               " | HL: ",            DoubleToStr(sls[1], Digits), " → ", DoubleToStr(sls[0], Digits),
               " | Support: ",       DoubleToStr(g_sr_level, Digits));
      }
      return;
   }

   // ── Bearish structure ─────────────────────────────────────────
   if (lh && ll)
   {
      double new_resistance = shs[0];
      if (g_state != STATE_BEAR || new_resistance != g_sr_level)
      {
         g_state    = STATE_BEAR;
         g_sr_level = new_resistance;
         DrawSRLine(g_sr_level, clrRed);
         Print("M15 BEARISH | LH: ", DoubleToStr(shs[1], Digits), " → ", DoubleToStr(shs[0], Digits),
               " | LL: ",            DoubleToStr(sls[1], Digits), " → ", DoubleToStr(sls[0], Digits),
               " | Resistance: ",    DoubleToStr(g_sr_level, Digits));
      }
      return;
   }

   // ── Mixed / unclear structure ─────────────────────────────────
   if (g_state != STATE_IDLE)
   {
      g_state    = STATE_IDLE;
      g_sr_level = 0;
      DeleteSRLine();
      Print("M15 structure unclear (mixed HH/HL/LH/LL) – IDLE.");
   }
}

//+------------------------------------------------------------------+
//| M5 engulfing entry logic                                         |
//|                                                                  |
//| Called on every new M5 bar.  Checks all filters then looks for   |
//| a classic engulfing pattern at the active S/R zone.              |
//|                                                                   |
//| bar[2] = the candle that must touch the S/R zone                 |
//| bar[1] = the engulfing candle (entry trigger)                    |
//+------------------------------------------------------------------+
void CheckM5Engulf()
{
   // ── Pre-flight checks ─────────────────────────────────────────
   if (g_state == STATE_IDLE || g_sr_level <= 0) return;
   if (IsTradeOpen()) return;

   if (InpUseSession && !IsSessionActive()) return;

   // H1 trend alignment gate – skip if H1 structure disagrees with M15 bias.
   // Filter is only meaningful when H1 has a clear direction; if H1 is mixed
   // (g_h1_bull = false && g_h1_bear = false) the entry is also blocked.
   if (InpUseH1Filter)
   {
      if (g_state == STATE_BULL && !g_h1_bull) return;
      if (g_state == STATE_BEAR && !g_h1_bear) return;
   }

   // ── ATR values used throughout ────────────────────────────────
   // Calculated once here so all ATR-based thresholds stay consistent.
   double m5_atr  = iATR(Symbol(), PERIOD_M5,  14, 1);
   double m15_atr = iATR(Symbol(), PERIOD_M15, 14, 1);
   if (m5_atr <= 0 || m15_atr <= 0) return;   // Not enough history yet

   // Spread guard – ATR-based so it works on any instrument.
   // e.g. XAUUSD ATR≈$5: max spread = 0.20×$5 = $1.00
   //       EURUSD ATR≈0.0008: max spread = 0.20×0.0008 = 1.6 pips
   double spread = MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if (spread > InpMaxSpreadATRMult * m5_atr) return;

   // Daily trade cap
   if (InpMaxDailyTrades > 0)
   {
      datetime today = iTime(Symbol(), PERIOD_D1, 0);
      if (today != g_last_day) { g_trades_today = 0; g_last_day = today; }
      if (g_trades_today >= InpMaxDailyTrades) return;
   }

   // ── Candle data ───────────────────────────────────────────────
   double op1 = iOpen (Symbol(), PERIOD_M5, 1);
   double cl1 = iClose(Symbol(), PERIOD_M5, 1);
   double hi1 = iHigh (Symbol(), PERIOD_M5, 1);
   double lo1 = iLow  (Symbol(), PERIOD_M5, 1);

   double op2 = iOpen (Symbol(), PERIOD_M5, 2);
   double cl2 = iClose(Symbol(), PERIOD_M5, 2);
   double hi2 = iHigh (Symbol(), PERIOD_M5, 2);
   double lo2 = iLow  (Symbol(), PERIOD_M5, 2);

   // ── ATR body-size filter ──────────────────────────────────────
   // Reject doji-like candles – the engulfing candle must show real momentum.
   if (InpMinBodyATR > 0)
   {
      double body1 = MathAbs(cl1 - op1);
      if (body1 < InpMinBodyATR * m5_atr) return;
   }

   // S/R zone half-width: InpZoneATRMult × M15 ATR(14).
   // e.g. XAUUSD M15 ATR≈$10: zone = 0.5×$10 = $5 on either side of the level
   double zone   = InpZoneATRMult     * m15_atr;
   double sl_buf = InpSLBufferATRMult * m5_atr;

   // ══════════════════════════════════════════════════════════════
   // BULLISH SETUP – at M15 support
   // ══════════════════════════════════════════════════════════════
   if (g_state == STATE_BULL)
   {
      // bar[2] must have dipped into the support zone
      if (lo2 > g_sr_level + zone) return;

      // M15 RSI must confirm the pullback is genuine.
      // RSI above InpRSIBullMax means buyers are still dominant at this level
      // and the support may not hold (momentum hasn't faded yet).
      if (InpUseRSIFilter)
      {
         double rsi = iRSI(Symbol(), PERIOD_M15, InpRSIPeriod, PRICE_CLOSE, 1);
         if (rsi > InpRSIBullMax) return;
      }

      // Classic bullish engulfing:
      //   bar[2] is bearish, bar[1] is bullish,
      //   bar[1] body fully covers bar[2] body
      bool bear2   = cl2 < op2;
      bool bull1   = cl1 > op1;
      bool engulfs = (op1 <= cl2) && (cl1 >= op2);

      if (!bear2 || !bull1 || !engulfs) return;

      // Rejection wick: bar[2] lower wick must be ≥ InpMinWickRatio × bar[2] body.
      // A meaningful wick shows sellers tested below the support and were absorbed –
      // the level is actively defended, not just grazed.
      if (InpMinWickRatio > 0)
      {
         double body2       = op2 - cl2;    // bearish body (op2 > cl2)
         double lower_wick2 = cl2 - lo2;   // distance below close to candle low
         if (body2 > 0 && lower_wick2 < InpMinWickRatio * body2) return;
      }

      // ── Place buy order ───────────────────────────────────────
      double sl   = lo1 - sl_buf;
      double dist = Ask - sl;
      if (dist <= 0) return;

      double lots = CalculateLots(dist);
      if (lots <= 0) { Print("SRBot: lot calc error – BUY skipped"); return; }

      double rr = InpTPPercent / InpRiskPercent;
      double tp = Ask + dist * rr;

      int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                             sl, tp, InpComment, InpMagicNumber, 0, clrGreen);
      if (ticket > 0)
      {
         g_trades_today++;
         Print("SRBot LONG  | Ask: ",    DoubleToStr(Ask, Digits),
               " | SL: ",               DoubleToStr(sl,  Digits),
               " | TP: ",               DoubleToStr(tp,  Digits),
               " | RR: 1:",             DoubleToStr(rr,  1),
               " | Lots: ",             DoubleToStr(lots, 2),
               " | Support: ",          DoubleToStr(g_sr_level, Digits),
               " | Ticket: ",           ticket);
      }
      else
         Print("SRBot: OrderSend BUY failed | Error: ", GetLastError());

      return;
   }

   // ══════════════════════════════════════════════════════════════
   // BEARISH SETUP – at M15 resistance
   // ══════════════════════════════════════════════════════════════
   if (g_state == STATE_BEAR)
   {
      // bar[2] must have spiked into the resistance zone
      if (hi2 < g_sr_level - zone) return;

      // M15 RSI must confirm the bounce is genuinely exhausted.
      // RSI below InpRSIBearMin means sellers are still dominant at this level
      // and the resistance may not hold (upside momentum hasn't built yet).
      if (InpUseRSIFilter)
      {
         double rsi = iRSI(Symbol(), PERIOD_M15, InpRSIPeriod, PRICE_CLOSE, 1);
         if (rsi < InpRSIBearMin) return;
      }

      // Classic bearish engulfing:
      //   bar[2] is bullish, bar[1] is bearish,
      //   bar[1] body fully covers bar[2] body
      bool bull2   = cl2 > op2;
      bool bear1   = cl1 < op1;
      bool engulfs = (op1 >= cl2) && (cl1 <= op2);

      if (!bull2 || !bear1 || !engulfs) return;

      // Rejection wick: bar[2] upper wick must be ≥ InpMinWickRatio × bar[2] body.
      // A meaningful upper wick shows buyers tried to push through the resistance
      // and were rejected – the level is actively capping price.
      if (InpMinWickRatio > 0)
      {
         double body2       = cl2 - op2;    // bullish body (cl2 > op2)
         double upper_wick2 = hi2 - cl2;   // distance above close to candle high
         if (body2 > 0 && upper_wick2 < InpMinWickRatio * body2) return;
      }

      // ── Place sell order ──────────────────────────────────────
      double sl   = hi1 + sl_buf;
      double dist = sl - Bid;
      if (dist <= 0) return;

      double lots = CalculateLots(dist);
      if (lots <= 0) { Print("SRBot: lot calc error – SELL skipped"); return; }

      double rr = InpTPPercent / InpRiskPercent;
      double tp = Bid - dist * rr;

      int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                             sl, tp, InpComment, InpMagicNumber, 0, clrRed);
      if (ticket > 0)
      {
         g_trades_today++;
         Print("SRBot SHORT | Bid: ",    DoubleToStr(Bid, Digits),
               " | SL: ",               DoubleToStr(sl,  Digits),
               " | TP: ",               DoubleToStr(tp,  Digits),
               " | RR: 1:",             DoubleToStr(rr,  1),
               " | Lots: ",             DoubleToStr(lots, 2),
               " | Resistance: ",       DoubleToStr(g_sr_level, Digits),
               " | Ticket: ",           ticket);
      }
      else
         Print("SRBot: OrderSend SELL failed | Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Find the N most recent confirmed swing highs on timeframe tf.    |
//| swings[0] = most recent, swings[1] = second most recent, …      |
//| Returns the number of swings actually found (≤ count).          |
//+------------------------------------------------------------------+
int FindTopNSwingHighs(int tf, int lookback, int n, double &swings[], int count)
{
   int found = 0;
   for (int i = n + 1; i <= lookback - n && found < count; i++)
   {
      double h  = iHigh(Symbol(), tf, i);
      bool   ok = true;
      for (int j = 1; j <= n && ok; j++)
      {
         if (iHigh(Symbol(), tf, i - j) >= h) ok = false;   // right (newer) side
         if (iHigh(Symbol(), tf, i + j) >= h) ok = false;   // left  (older) side
      }
      if (ok) swings[found++] = h;
   }
   return found;
}

//+------------------------------------------------------------------+
//| Find the N most recent confirmed swing lows on timeframe tf.     |
//+------------------------------------------------------------------+
int FindTopNSwingLows(int tf, int lookback, int n, double &swings[], int count)
{
   int found = 0;
   for (int i = n + 1; i <= lookback - n && found < count; i++)
   {
      double l  = iLow(Symbol(), tf, i);
      bool   ok = true;
      for (int j = 1; j <= n && ok; j++)
      {
         if (iLow(Symbol(), tf, i - j) <= l) ok = false;
         if (iLow(Symbol(), tf, i + j) <= l) ok = false;
      }
      if (ok) swings[found++] = l;
   }
   return found;
}

//+------------------------------------------------------------------+
//| Returns true on the first tick of a new bar on tf               |
//+------------------------------------------------------------------+
bool IsNewBar(int tf, datetime &last_time)
{
   datetime cur = iTime(Symbol(), tf, 0);
   if (cur != last_time) { last_time = cur; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size from a fixed risk percentage                  |
//| sl_distance = distance from entry price to stop loss in price    |
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
//| Returns true if this EA has an open position on current symbol   |
//+------------------------------------------------------------------+
bool IsTradeOpen()
{
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         if (OrderMagicNumber() == InpMagicNumber && OrderSymbol() == Symbol())
            return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Returns true if current server time is within the session window |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   int hour = TimeHour(TimeCurrent());
   return (hour >= InpSessionStart && hour < InpSessionEnd);
}

//+------------------------------------------------------------------+
//| Draw / update the active S/R horizontal line on the chart        |
//+------------------------------------------------------------------+
void DrawSRLine(double price, color clr)
{
   string name = "SRBot_Level";
   ObjectDelete(name);
   if (ObjectCreate(name, OBJ_HLINE, 0, 0, price))
   {
      ObjectSet(name, OBJPROP_COLOR, clr);
      ObjectSet(name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSet(name, OBJPROP_WIDTH, 1);
   }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Remove the S/R line from the chart                               |
//+------------------------------------------------------------------+
void DeleteSRLine()
{
   ObjectDelete("SRBot_Level");
   ChartRedraw();
}
//+------------------------------------------------------------------+
