//+------------------------------------------------------------------+
//|                                             ORB_Strategy.mq5     |
//|                                                                  |
//|  9am Reference Candle Breakout + Retest EA (default: XAUUSD M15) |
//|  ─────────────────────────────────────────────────────────────  |
//|  1. Reference candle: the 15-minute candle opening at             |
//|     InpRefHour:InpRefMinute (server time – set to line up with    |
//|     9am UK on your broker's clock). Its open/close mark a body    |
//|     zone: top = max(open,close), bottom = min(open,close),        |
//|     centre = (open+close)/2.                                      |
//|  2. Breakout: wait for a later M15 candle whose body closes        |
//|     ENTIRELY beyond that zone (full body above the top, or        |
//|     entirely below the bottom) – this sets the day's bias.        |
//|  3. Retest entry: once the breakout is confirmed, a pending       |
//|     limit order is placed at the near edge of the reference       |
//|     candle's body (buy limit at the top / sell limit at the       |
//|     bottom) so the trade fires the instant price taps back into   |
//|     the zone – no need to wait for a candle close to react.       |
//|  4. Stop loss: the centre of the reference candle's body.         |
//|     Take profit: InpRRRatio x the risk distance (default 1:3).    |
//|  5. Safety nets: cancels the pending order if price fully closes  |
//|     back through the opposite side of the zone (setup             |
//|     invalidated), if too long elapses waiting for a breakout or   |
//|     a retest, or at the end-of-day cutoff – which can also flatten|
//|     any live position so gold's overnight gaps aren't carried.    |
//|  Only one setup (and at most one trade) is tracked per day.       |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "2.00"

#include <Trade\Trade.mqh>

//--- Reference candle (server time – align to 9am UK on your broker)
input int    InpRefHour            = 9;      // Reference candle hour (server time)
input int    InpRefMinute          = 0;      // Reference candle minute (server time)

//--- Breakout / retest waiting limits (in M15 bars, 0 = no limit)
input int    InpMaxBreakoutWaitBars = 16;     // Give up waiting for the breakout after N M15 bars
input int    InpMaxTapWaitBars      = 32;     // Cancel the pending retest order after N M15 bars
input bool   InpInvalidateOnOppositeBreak = true; // Cancel pending order if price fully closes through the opposite side of the zone

//--- Risk management
input double InpRRRatio            = 3.0;    // Take profit reward:risk ratio (1:3 default)
input double InpRiskPercent        = 1.0;    // Risk per trade (% of account balance)
input double InpMinStopDistance    = 1.50;   // Minimum SL distance allowed, in price units (e.g. 1.50 = $1.50 for XAUUSD; skip near-doji reference candles)

//--- End of day
input bool   InpCloseAtEndOfDay    = true;   // Cancel unfilled order / close open position at cutoff
input int    InpEndOfDayHour       = 21;     // End-of-day cutoff hour (server time)
input int    InpEndOfDayMinute     = 0;      // End-of-day cutoff minute (server time)

//--- Execution
input int    InpSlippage           = 5;      // Maximum slippage (points)
input int    InpMagicNumber        = 20260805;
input string InpComment            = "ORB_9am";

//--- Trade object
CTrade trade;

//--- Day state machine
enum EDayState
{
   STATE_WAIT_REF,       // Waiting for the reference candle to close
   STATE_WAIT_BREAKOUT,  // Waiting for a full-body close beyond the reference candle
   STATE_WAIT_TAP,       // Breakout confirmed, pending retest order live
   STATE_DONE            // Filled, invalidated, gave up, or flattened – nothing left to do today
};

EDayState g_state         = STATE_WAIT_REF;
datetime  g_day_start     = 0;
datetime  g_last_bar_time = 0;
datetime  g_ref_time      = 0;

double    g_ref_body_top  = 0;
double    g_ref_body_bot  = 0;
double    g_ref_center    = 0;

bool      g_bias_long        = false;
ulong     g_pending_ticket   = 0;
int       g_breakout_wait_ct = 0;
int       g_tap_wait_ct      = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);

   Print("ORB_Strategy (9am candle) initialized | Symbol: ", _Symbol,
         " | Reference time (server): ", InpRefHour, ":", InpRefMinute);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("ORB_Strategy stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main tick handler                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime today = GetDayStart();
   if(today != g_day_start) ResetDailyState(today);

   //--- End-of-day cutoff runs every tick, independent of new-bar timing
   datetime eod = GetTodayTime(InpEndOfDayHour, InpEndOfDayMinute);
   if(InpCloseAtEndOfDay && g_state != STATE_DONE && TimeCurrent() >= eod)
   {
      CancelPendingOrder();
      CloseAllPositions();
      g_state = STATE_DONE;
      Print("End-of-day cutoff reached – flattened for the day.");
   }

   if(!IsNewBar(PERIOD_M15, g_last_bar_time)) return;

   //--- Never stack a new setup on top of a still-open trade. This matters
   //    whenever a trade survives past the end-of-day cutoff (or the cutoff
   //    is disabled) so a 1:3 target has room to play out over more than
   //    one day – without this guard, the next day's setup would open a
   //    second position while the first is still live.
   if(HasOpenPosition()) return;

   switch(g_state)
   {
      case STATE_WAIT_REF:      ProcessWaitRef();      break;
      case STATE_WAIT_BREAKOUT: ProcessWaitBreakout();  break;
      case STATE_WAIT_TAP:      ProcessWaitTap();       break;
      default: break;
   }
}

//+------------------------------------------------------------------+
//| Reset all per-day state at the start of a new trading day        |
//+------------------------------------------------------------------+
void ResetDailyState(datetime today)
{
   CancelPendingOrder(); // a stray order from a prior day's setup is stale

   g_day_start        = today;
   g_ref_time          = GetTodayTime(InpRefHour, InpRefMinute);
   g_state             = STATE_WAIT_REF;
   g_ref_body_top      = 0;
   g_ref_body_bot       = 0;
   g_ref_center         = 0;
   g_breakout_wait_ct   = 0;
   g_tap_wait_ct        = 0;

   Print("New trading day: ", TimeToString(today, TIME_DATE),
         " – waiting for reference candle at ", TimeToString(g_ref_time, TIME_MINUTES));
}

//+------------------------------------------------------------------+
//| Locate and record the reference candle once its interval has     |
//| fully closed                                                      |
//+------------------------------------------------------------------+
void ProcessWaitRef()
{
   if(TimeCurrent() < g_ref_time + PeriodSeconds(PERIOD_M15)) return;

   int shift = iBarShift(_Symbol, PERIOD_M15, g_ref_time, true);
   if(shift < 0)
   {
      Print("Reference candle not found at ", TimeToString(g_ref_time), " – still waiting.");
      return;
   }

   double o = iOpen(_Symbol, PERIOD_M15, shift);
   double c = iClose(_Symbol, PERIOD_M15, shift);

   g_ref_body_top = MathMax(o, c);
   g_ref_body_bot = MathMin(o, c);
   g_ref_center   = (o + c) / 2.0;
   g_state        = STATE_WAIT_BREAKOUT;
   g_breakout_wait_ct = 0;

   Print("Reference candle marked | Open: ", o, " | Close: ", c,
         " | Body top: ", g_ref_body_top, " | Body bottom: ", g_ref_body_bot,
         " | Centre: ", g_ref_center);
}

//+------------------------------------------------------------------+
//| Wait for a subsequent M15 candle to close its full body beyond   |
//| the reference candle's body                                       |
//+------------------------------------------------------------------+
void ProcessWaitBreakout()
{
   double body_top1, body_bot1;
   GetBody(1, body_top1, body_bot1);

   bool bull_break = body_bot1 > g_ref_body_top;
   bool bear_break = body_top1 < g_ref_body_bot;

   if(bull_break || bear_break)
   {
      g_bias_long = bull_break;
      Print("Breakout confirmed | Direction: ", g_bias_long ? "LONG" : "SHORT",
            " | Candle body: ", body_bot1, " - ", body_top1);
      PlaceRetestOrder();
      return;
   }

   g_breakout_wait_ct++;
   if(InpMaxBreakoutWaitBars > 0 && g_breakout_wait_ct >= InpMaxBreakoutWaitBars)
   {
      g_state = STATE_DONE;
      Print("No breakout within ", InpMaxBreakoutWaitBars, " bars – giving up for today.");
   }
}

//+------------------------------------------------------------------+
//| While the retest order is pending: watch for invalidation, a     |
//| wait-time-out, or a fill                                          |
//+------------------------------------------------------------------+
void ProcessWaitTap()
{
   //--- Filled already? Nothing left to manage – SL/TP are attached to the position.
   if(g_pending_ticket != 0 && !OrderSelect(g_pending_ticket))
   {
      if(HasOpenPosition())
         Print("Retest order filled – trade is live.");
      else
         Print("Retest order no longer pending (expired/rejected) – no trade taken today.");
      g_state = STATE_DONE;
      return;
   }

   //--- Invalidation: price fully closed back through the opposite side of the zone
   if(InpInvalidateOnOppositeBreak)
   {
      double body_top1, body_bot1;
      GetBody(1, body_top1, body_bot1);
      bool opposite_break = g_bias_long ? (body_top1 < g_ref_body_bot) : (body_bot1 > g_ref_body_top);
      if(opposite_break)
      {
         CancelPendingOrder();
         g_state = STATE_DONE;
         Print("Setup invalidated – price closed through the opposite side of the zone. Order cancelled.");
         return;
      }
   }

   g_tap_wait_ct++;
   if(InpMaxTapWaitBars > 0 && g_tap_wait_ct >= InpMaxTapWaitBars)
   {
      CancelPendingOrder();
      g_state = STATE_DONE;
      Print("No retest within ", InpMaxTapWaitBars, " bars – order cancelled, giving up for today.");
   }
}

//+------------------------------------------------------------------+
//| Place the retest limit order with SL at the reference candle's   |
//| centre and TP at InpRRRatio x the risk distance                  |
//+------------------------------------------------------------------+
void PlaceRetestOrder()
{
   double entry = g_bias_long ? g_ref_body_top : g_ref_body_bot;
   double sl    = g_ref_center;
   double risk  = MathAbs(entry - sl);

   if(risk < InpMinStopDistance)
   {
      Print("Setup skipped – stop distance ", risk, " below minimum ", InpMinStopDistance);
      g_state = STATE_DONE;
      return;
   }

   double tp   = g_bias_long ? entry + risk * InpRRRatio : entry - risk * InpRRRatio;
   double lots = CalculateLots(risk);

   if(lots <= 0)
   {
      Print("Setup skipped – lot size calculation failed.");
      g_state = STATE_DONE;
      return;
   }

   datetime expiration = GetTodayTime(InpEndOfDayHour, InpEndOfDayMinute);
   bool ok;

   if(g_bias_long)
      ok = trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, InpComment);
   else
      ok = trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, expiration, InpComment);

   if(ok)
   {
      g_pending_ticket = trade.ResultOrder();
      g_state          = STATE_WAIT_TAP;
      g_tap_wait_ct     = 0;
      Print((g_bias_long ? "BUY LIMIT" : "SELL LIMIT"), " placed | Entry: ", entry,
            " | SL: ", sl, " | TP: ", tp, " | RR: 1:", InpRRRatio,
            " | Lots: ", lots, " | Ticket: ", g_pending_ticket);
   }
   else
   {
      Print("Retest order failed | Retcode: ", trade.ResultRetcode(),
            " | ", trade.ResultRetcodeDescription());
      g_state = STATE_DONE;
   }
}

//+------------------------------------------------------------------+
//| Body top/bottom of the M15 candle at 'shift'                     |
//+------------------------------------------------------------------+
void GetBody(int shift, double &body_top, double &body_bot)
{
   double o = iOpen (_Symbol, PERIOD_M15, shift);
   double c = iClose(_Symbol, PERIOD_M15, shift);
   body_top = MathMax(o, c);
   body_bot = MathMin(o, c);
}

//+------------------------------------------------------------------+
//| Calculate lot size from a fixed risk percentage                  |
//| sl_distance – distance from entry to stop loss in price units   |
//|                                                                    |
//| Rejects the trade (returns 0) rather than clamping the lot size  |
//| to the broker's min/max volume. Clamping would silently break    |
//| the risk-% guarantee: the stop distance stays the same while the |
//| position size gets forced up or down, so the actual dollar risk  |
//| no longer matches InpRiskPercent – on a tight stop this can size  |
//| up a full-size position that was only meant to risk 1%.          |
//+------------------------------------------------------------------+
double CalculateLots(double sl_distance)
{
   if(sl_distance <= 0) return 0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_cash = balance * InpRiskPercent / 100.0;
   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_val <= 0 || tick_size <= 0) return 0;

   double raw_lots = risk_cash / (sl_distance / tick_size * tick_val);

   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(raw_lots > max_lot)
   {
      Print("Trade rejected – stop distance ", sl_distance, " is too tight for ", InpRiskPercent,
            "% risk at balance ", balance, " (would need ", raw_lots,
            " lots, broker max is ", max_lot, "). Sizing to max_lot would over-risk this trade.");
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
//| Cancel the tracked pending order, if it still exists              |
//+------------------------------------------------------------------+
void CancelPendingOrder()
{
   if(g_pending_ticket == 0) return;
   if(OrderSelect(g_pending_ticket))
   {
      if(!trade.OrderDelete(g_pending_ticket))
         Print("Failed to delete order #", g_pending_ticket, " | Error: ", GetLastError());
   }
   g_pending_ticket = 0;
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
