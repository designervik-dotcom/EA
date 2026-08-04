//+------------------------------------------------------------------+
//|                                             ORB_Strategy.mq5     |
//|                                                                  |
//|  Opening Range Breakout (ORB) Expert Advisor                    |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. Opening range: the high/low formed between InpRangeStartHour |
//|     /Minute and (start + InpRangeMinutes) is recorded once, on   |
//|     the entry timeframe.                                         |
//|  2. Range-size filter: the range is only tradeable if its size   |
//|     falls between InpMinRangeATRMult and InpMaxRangeATRMult      |
//|     multiples of ATR – too narrow = noise, too wide = already    |
//|     extended (poor R:R left on the table).                       |
//|  3. Breakout: a closed candle on the entry timeframe beyond the   |
//|     range high/low triggers a signal (close-based, not a wick    |
//|     touch, to cut down on false breakouts).                      |
//|  4. Confluence filters applied to every breakout signal:          |
//|       • VWAP filter  – close must be on the correct side of the  |
//|         session VWAP (anchored at the range start), i.e. only    |
//|         trade breakouts that agree with the intraday trend.      |
//|       • Volume filter – the breakout bar's tick volume must      |
//|         exceed its recent average by InpVolumeMultiplier,        |
//|         a proxy for real participation vs. a low-volume fakeout. |
//|  5. Stop loss sits beyond the opposite side of the range (plus a |
//|     fixed points buffer and an optional ATR buffer). Take profit |
//|     is a fixed multiple of that risk (InpRRRatio), so every      |
//|     trade carries a known, healthy reward:risk ratio.            |
//|  6. Trading stops for the day after InpMaxTradesPerDay entries,  |
//|     after the breakout window elapses, or at the flat time       |
//|     (which also force-closes any open EA position).              |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Opening range / session
input int    InpRangeStartHour     = 9;      // Range start hour (server time)
input int    InpRangeStartMinute   = 30;     // Range start minute
input int    InpRangeMinutes       = 15;     // Opening range duration (minutes)
input int    InpBreakoutWindowMin  = 120;    // Stop taking new breakouts N minutes after range closes
input int    InpFlatHour           = 15;     // Flatten / stop trading hour (server time)
input int    InpFlatMinute         = 45;     // Flatten / stop trading minute
input bool   InpCloseAtFlatTime    = true;   // Close open EA positions at flat time

//--- Entry timeframe
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M5; // Timeframe used to confirm breakout close

//--- Risk management
input double InpRiskPercent        = 1.0;    // Risk per trade (% of account balance)
input double InpRRRatio            = 2.0;    // Take profit reward:risk ratio (e.g. 2 = 1:2)
input double InpSLBufferPoints     = 20;     // Extra buffer beyond range added to stop loss (points)
input bool   InpUseATRBuffer       = true;   // Add an ATR-based buffer to the stop loss
input double InpATRBufferMult      = 0.25;   // ATR multiple added to the SL buffer
input int    InpATRPeriod          = 14;     // ATR period

//--- Confluence filters
input bool   InpUseVWAPFilter      = true;   // Require breakout to be on the correct side of session VWAP
input bool   InpUseVolumeFilter    = true;   // Require breakout bar volume above its recent average
input double InpVolumeMultiplier   = 1.5;    // Breakout bar volume must exceed avg volume * this
input int    InpVolumeAvgPeriod    = 20;     // Bars used to compute the average volume baseline
input bool   InpUseRangeSizeFilter = true;   // Reject opening ranges that are too small or too large
input double InpMinRangeATRMult    = 0.20;   // Minimum range size, as a multiple of ATR
input double InpMaxRangeATRMult    = 3.00;   // Maximum range size, as a multiple of ATR

//--- Trade management
input bool   InpTradeLongs         = true;   // Allow long breakouts
input bool   InpTradeShorts        = true;   // Allow short breakouts
input int    InpMaxTradesPerDay    = 2;      // Maximum number of entries per day
input int    InpSlippage           = 5;      // Maximum slippage (points)
input int    InpMagicNumber        = 20260804;
input string InpComment            = "ORB";

//--- Trade object
CTrade trade;

//--- ATR indicator handle
int g_atr_handle = INVALID_HANDLE;

//--- Daily state
datetime g_day_start     = 0;     // Midnight of the currently tracked trading day
datetime g_last_bar_time = 0;     // Last seen entry-timeframe bar open time

bool     g_range_ready = false;   // Opening range has been built for today
bool     g_range_valid = false;   // Opening range passed the size filter
double   g_range_high  = 0;
double   g_range_low   = 0;

int      g_trades_today = 0;
bool     g_flat_done    = false;  // Flatten already executed today

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   g_atr_handle = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR indicator handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   Print("ORB_Strategy initialized | Symbol: ", _Symbol,
         " | Entry TF: ", EnumToString(InpEntryTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Print("ORB_Strategy stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime today = GetDayStart();
   if(today != g_day_start) ResetDailyState(today);

   datetime range_start       = GetTodayTime(InpRangeStartHour, InpRangeStartMinute);
   datetime range_end         = range_start + InpRangeMinutes * 60;
   datetime breakout_deadline = range_end + InpBreakoutWindowMin * 60;
   datetime flat_time         = GetTodayTime(InpFlatHour, InpFlatMinute);
   datetime now                = TimeCurrent();

   //--- Flatten check runs every tick, independent of new-bar timing
   if(InpCloseAtFlatTime && !g_flat_done && now >= flat_time)
   {
      CloseAllPositions();
      g_flat_done = true;
      Print("Flat time reached – EA positions closed, no more entries today.");
   }

   if(!IsNewBar(InpEntryTF, g_last_bar_time)) return;

   //--- Build the opening range once its window has closed
   if(!g_range_ready && now >= range_end)
      BuildOpeningRange(range_start, range_end);

   //--- Look for a breakout while the range is valid and still tradeable
   if(g_range_ready && g_range_valid && !g_flat_done &&
      now < breakout_deadline && g_trades_today < InpMaxTradesPerDay)
   {
      CheckBreakout(range_start);
   }
}

//+------------------------------------------------------------------+
//| Reset all per-day state at the start of a new trading day        |
//+------------------------------------------------------------------+
void ResetDailyState(datetime today)
{
   g_day_start     = today;
   g_range_ready   = false;
   g_range_valid   = false;
   g_range_high    = 0;
   g_range_low     = 0;
   g_trades_today  = 0;
   g_flat_done     = false;
   Print("New trading day: ", TimeToString(today, TIME_DATE), " – state reset.");
}

//+------------------------------------------------------------------+
//| Scan the entry timeframe for bars inside [range_start, range_end)|
//| to build the opening range, then validate its size against ATR   |
//+------------------------------------------------------------------+
void BuildOpeningRange(datetime range_start, datetime range_end)
{
   double hi = -DBL_MAX, lo = DBL_MAX;
   bool   found = false;

   for(int i = 1; i < 2000; i++)
   {
      datetime t = iTime(_Symbol, InpEntryTF, i);
      if(t == 0 || t < range_start) break;
      if(t < range_end)
      {
         hi = MathMax(hi, iHigh(_Symbol, InpEntryTF, i));
         lo = MathMin(lo, iLow (_Symbol, InpEntryTF, i));
         found = true;
      }
   }

   if(!found)
   {
      Print("Opening range build failed – no bars found in the range window.");
      return;
   }

   g_range_high  = hi;
   g_range_low   = lo;
   g_range_ready = true;
   g_range_valid = true;

   if(InpUseRangeSizeFilter)
   {
      double atr = GetATR(1);
      double range_size = g_range_high - g_range_low;
      if(atr <= 0 ||
         range_size < atr * InpMinRangeATRMult ||
         range_size > atr * InpMaxRangeATRMult)
      {
         g_range_valid = false;
         Print("Opening range rejected by size filter | Range: ", range_size,
               " | ATR: ", atr);
      }
   }

   Print("Opening range built | High: ", g_range_high, " | Low: ", g_range_low,
         " | Valid: ", g_range_valid);
}

//+------------------------------------------------------------------+
//| Evaluate the last closed entry-timeframe candle for a breakout   |
//+------------------------------------------------------------------+
void CheckBreakout(datetime range_start)
{
   double close1 = iClose(_Symbol, InpEntryTF, 1);

   if(InpTradeLongs && close1 > g_range_high)
   {
      if(!PassesConfluence(range_start, true)) return;
      OpenPosition(true);
   }
   else if(InpTradeShorts && close1 < g_range_low)
   {
      if(!PassesConfluence(range_start, false)) return;
      OpenPosition(false);
   }
}

//+------------------------------------------------------------------+
//| VWAP + volume confluence checks for a breakout in direction      |
//| 'is_long'                                                        |
//+------------------------------------------------------------------+
bool PassesConfluence(datetime range_start, bool is_long)
{
   double close1 = iClose(_Symbol, InpEntryTF, 1);

   if(InpUseVWAPFilter)
   {
      double vwap = ComputeSessionVWAP(range_start);
      if(vwap <= 0) return false; // not enough data to trust the read
      if(is_long  && close1 <= vwap) { Print("Breakout rejected – close below VWAP (", vwap, ")"); return false; }
      if(!is_long && close1 >= vwap) { Print("Breakout rejected – close above VWAP (", vwap, ")"); return false; }
   }

   if(InpUseVolumeFilter)
   {
      double avg_vol = AverageVolume(InpVolumeAvgPeriod);
      double vol1    = (double)iVolume(_Symbol, InpEntryTF, 1);
      if(avg_vol <= 0 || vol1 < avg_vol * InpVolumeMultiplier)
      {
         Print("Breakout rejected – volume ", vol1, " below threshold (avg ", avg_vol,
               " x ", InpVolumeMultiplier, ")");
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Open a breakout trade with a range-based stop and fixed R:R TP   |
//+------------------------------------------------------------------+
void OpenPosition(bool is_long)
{
   double point  = _Point;
   double buffer = InpSLBufferPoints * point;
   if(InpUseATRBuffer) buffer += GetATR(1) * InpATRBufferMult;

   bool ok = false;

   if(is_long)
   {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl    = g_range_low - buffer;
      double risk  = entry - sl;
      if(risk <= 0) { Print("Long skipped – non-positive risk distance."); return; }
      double tp    = entry + risk * InpRRRatio;
      double lots  = CalculateLots(risk);
      if(lots <= 0) { Print("Long skipped – lot size calculation failed."); return; }

      ok = trade.Buy(lots, _Symbol, entry, sl, tp, InpComment);
      if(ok)
         Print("LONG opened | Entry: ", entry, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots);
      else
         Print("Buy failed | Error: ", GetLastError());
   }
   else
   {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl    = g_range_high + buffer;
      double risk  = sl - entry;
      if(risk <= 0) { Print("Short skipped – non-positive risk distance."); return; }
      double tp    = entry - risk * InpRRRatio;
      double lots  = CalculateLots(risk);
      if(lots <= 0) { Print("Short skipped – lot size calculation failed."); return; }

      ok = trade.Sell(lots, _Symbol, entry, sl, tp, InpComment);
      if(ok)
         Print("SHORT opened | Entry: ", entry, " | SL: ", sl, " | TP: ", tp,
               " | RR: 1:", InpRRRatio, " | Lots: ", lots);
      else
         Print("Sell failed | Error: ", GetLastError());
   }

   if(ok) g_trades_today++;
}

//+------------------------------------------------------------------+
//| Session VWAP anchored at 'session_start', computed from closed   |
//| entry-timeframe bars using typical price weighted by tick volume |
//+------------------------------------------------------------------+
double ComputeSessionVWAP(datetime session_start)
{
   double sum_pv = 0, sum_v = 0;

   for(int i = 1; i < 2000; i++)
   {
      datetime t = iTime(_Symbol, InpEntryTF, i);
      if(t == 0 || t < session_start) break;

      double typical = (iHigh(_Symbol, InpEntryTF, i) +
                         iLow (_Symbol, InpEntryTF, i) +
                         iClose(_Symbol, InpEntryTF, i)) / 3.0;
      double vol = (double)iVolume(_Symbol, InpEntryTF, i);

      sum_pv += typical * vol;
      sum_v  += vol;
   }

   if(sum_v <= 0) return 0;
   return sum_pv / sum_v;
}

//+------------------------------------------------------------------+
//| Average tick volume of the 'period' bars preceding the breakout  |
//| bar (shifts 2..period+1, so the breakout bar itself is excluded) |
//+------------------------------------------------------------------+
double AverageVolume(int period)
{
   double sum = 0;
   for(int i = 2; i < 2 + period; i++)
      sum += (double)iVolume(_Symbol, InpEntryTF, i);
   return sum / period;
}

//+------------------------------------------------------------------+
//| Latest ATR value from the indicator handle                       |
//+------------------------------------------------------------------+
double GetATR(int shift)
{
   double buf[];
   if(CopyBuffer(g_atr_handle, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| Calculate lot size from a fixed risk percentage                  |
//| sl_distance – distance from entry to stop loss in price units   |
//+------------------------------------------------------------------+
double CalculateLots(double sl_distance)
{
   if(sl_distance <= 0) return 0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_cash = balance * InpRiskPercent / 100.0;
   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_val <= 0 || tick_size <= 0) return 0;

   double lots = risk_cash / (sl_distance / tick_size * tick_val);

   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lot_step) * lot_step;
   return MathMax(min_lot, MathMin(max_lot, lots));
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
//| Returns true on the first tick of a new bar on 'tf'              |
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
//| Today's date at midnight, server time                            |
//+------------------------------------------------------------------+
datetime GetDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Today's date at the given hour:minute, server time                |
//+------------------------------------------------------------------+
datetime GetTodayTime(int hour, int minute)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = hour; dt.min = minute; dt.sec = 0;
   return StructToTime(dt);
}
//+------------------------------------------------------------------+
