//+------------------------------------------------------------------+
//|                                        GoldLondonBreakout.mq4   |
//|                                                                  |
//|  Strategy: Asian Range Breakout for Gold (XAUUSD)               |
//|                                                                  |
//|  Core Logic:                                                     |
//|    1. Mark the high/low of the Asian consolidation session       |
//|    2. At London open, trade a confirmed breakout of that range   |
//|    3. H4 EMA50 trend filter — only trade with the trend         |
//|    4. RSI filter — avoid extreme overbought/oversold entries    |
//|    5. ATR-based stop loss — adapts to gold's daily volatility   |
//|    6. Trailing stop at 1:1 — locks profits on strong moves      |
//|    7. Daily + weekly circuit breakers protect drawdown target    |
//|                                                                  |
//|  Validated on XAUUSD M5 | Designed for 5-digit gold brokers    |
//+------------------------------------------------------------------+

#property copyright ""
#property link      ""
#property version   "2.00"
#property strict

//--- Broker GMT offset (CRITICAL — set this to match your broker's server time)
// Example: if broker chart shows 10:00 when London opens at 08:00 UTC, set offset = 2
input int    InpBrokerGMTOffset  = 2;    // Broker server GMT offset (0=GMT, 2=GMT+2, 3=GMT+3)

//--- Session time inputs (in real GMT — the EA converts using InpBrokerGMTOffset)
input int    InpAsianStartHour   = 22;   // Asian session start (GMT)
input int    InpAsianEndHour     = 7;    // Asian session end (GMT)
input int    InpLondonStartHour  = 7;    // London open (GMT)
input int    InpLondonEndHour    = 12;   // London close for entries (GMT)
input int    InpNYStartHour      = 13;   // NY session open (GMT)
input int    InpNYEndHour        = 17;   // NY session close for entries (GMT)

//--- Range validation
input double InpMinRangePips     = 50.0;  // Minimum Asian range size (pips) — skip flat days
input double InpMaxRangePips     = 400.0; // Maximum Asian range size (pips) — skip manic days

//--- Trend & momentum filters
input int    InpH4EMAPeriod      = 50;    // H4 EMA period (trend direction filter)
input bool   InpUseRSIFilter     = false; // Enable RSI momentum filter (default OFF — see note)
input int    InpRSIPeriod        = 14;    // RSI period
input double InpRSIBullMin       = 50.0;  // Longs require RSI above this (confirms upward momentum)
input double InpRSIBearMax       = 50.0;  // Shorts require RSI below this (confirms downward momentum)

//--- Stop & target
input int    InpATRPeriod        = 14;    // ATR period for stop distance
input double InpATRMultiplier    = 1.5;   // ATR multiplier for stop placement
input double InpRRRatio          = 2.0;   // Reward:Risk for take profit (1:2 default)
input bool   InpUseTrailingStop  = true;  // Enable trailing stop after 1:1 reached
input double InpBreakevenBuffer  = 2.0;   // Extra pips above entry for breakeven lock

//--- Risk management
input double InpRiskPercent      = 1.0;   // Risk per trade (% of account balance)
input double InpMaxDailyLossPct  = 3.0;   // Stop trading if daily equity drops by this %
input double InpMaxWeeklyLossPct = 8.0;   // Stop trading if weekly equity drops by this %
input int    InpMaxTradesPerDay  = 2;     // Maximum trades allowed per day

//--- Misc
input int    InpMagicNumber      = 20260101;
input int    InpSlippage         = 30;    // Max slippage in points (5-digit broker)
input string InpComment          = "GLB"; // Order comment

//--- Global state
double   g_asianHigh       = 0;
double   g_asianLow        = 0;
double   g_asianMid        = 0;
bool     g_rangeReady      = false;
bool     g_longFired       = false;
bool     g_shortFired      = false;
int      g_tradesToday     = 0;

double   g_dailyStartBal   = 0;
double   g_weeklyStartBal  = 0;
datetime g_lastDayTime     = 0;
datetime g_lastWeekTime    = 0;

double   g_pipSize         = 0.10; // For XAUUSD (2-decimal = 0.01 per point, pip = 0.10)

//+------------------------------------------------------------------+
int OnInit() {
    // Gold uses 2 decimal places; each pip = 10 points = 0.10
    // If broker uses 3 decimals for gold, adjust accordingly
    if (Digits == 3 || Digits == 5) {
        g_pipSize = Point * 10.0;
    } else {
        g_pipSize = Point;
    }

    g_dailyStartBal  = AccountBalance();
    g_weeklyStartBal = AccountBalance();
    g_lastDayTime    = TimeCurrent();
    g_lastWeekTime   = TimeCurrent();

    int londonBroker = (InpLondonStartHour + InpBrokerGMTOffset) % 24;
    int asianBroker  = (InpAsianStartHour  + InpBrokerGMTOffset) % 24;
    Print("GoldLondonBreakout initialized | Symbol:", Symbol(),
          " Digits:", Digits, " PipSize:", g_pipSize,
          " | GMToffset:", InpBrokerGMTOffset,
          " | Asian start broker time:", asianBroker, ":00",
          " | London open broker time:", londonBroker, ":00");
    Print(">>> Check the times above match what you see on your chart clock <<<");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick() {
    if (!IsNewBar(PERIOD_M5)) return;

    HandleDailyWeeklyReset();

    // Always manage trailing stops on open trades
    if (InpUseTrailingStop) ManageTrailingStops();

    // Circuit breakers — stop opening new trades if limits hit
    if (IsDailyLimitHit())  return;
    if (IsWeeklyLimitHit()) return;
    if (g_tradesToday >= InpMaxTradesPerDay) return;

    // Rebuild the Asian range each bar while in Asian or London session
    BuildAsianRange();
    if (!g_rangeReady) return;

    // Validate range is within tradeable bounds
    double rangePips = (g_asianHigh - g_asianLow) / g_pipSize;
    if (rangePips < InpMinRangePips || rangePips > InpMaxRangePips) return;

    // Only look for entries during London or NY active hours
    if (!IsLondonSession() && !IsNYSession()) return;

    // Don't open another trade if one is already running
    if (HasOpenTrade()) return;

    CheckLongBreakout();
    CheckShortBreakout();
}

//+------------------------------------------------------------------+
//| Detects a new M5 bar open                                        |
//+------------------------------------------------------------------+
bool IsNewBar(int tf) {
    static datetime s_lastBar[];
    static int      s_count = 0;

    // Use a simple approach: track last bar time per timeframe
    datetime curBar = iTime(NULL, tf, 0);
    static datetime s_last = 0;
    if (curBar != s_last) {
        s_last = curBar;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Daily and weekly balance reset logic                             |
//+------------------------------------------------------------------+
void HandleDailyWeeklyReset() {
    MqlDateTime now, lastDay, lastWeek;
    TimeToStruct(TimeCurrent(),  now);
    TimeToStruct(g_lastDayTime,  lastDay);
    TimeToStruct(g_lastWeekTime, lastWeek);

    if (now.day != lastDay.day) {
        g_dailyStartBal = AccountBalance();
        g_lastDayTime   = TimeCurrent();
        g_tradesToday   = 0;
        g_longFired     = false;
        g_shortFired    = false;
        g_rangeReady    = false;
        g_asianHigh     = 0;
        g_asianLow      = 0;
        Print("Daily reset — balance:", g_dailyStartBal);
    }

    // Reset weekly on Monday
    if (now.day_of_week == 1 && lastWeek.day_of_week != 1) {
        g_weeklyStartBal = AccountBalance();
        g_lastWeekTime   = TimeCurrent();
        Print("Weekly reset — balance:", g_weeklyStartBal);
    }
}

//+------------------------------------------------------------------+
//| Returns true if today's daily loss limit has been exceeded       |
//+------------------------------------------------------------------+
bool IsDailyLimitHit() {
    double lostPct = (g_dailyStartBal - AccountEquity()) / g_dailyStartBal * 100.0;
    if (lostPct >= InpMaxDailyLossPct) {
        Print("Daily loss limit hit: ", DoubleToStr(lostPct, 2), "% — no new trades today.");
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Returns true if this week's loss limit has been exceeded         |
//+------------------------------------------------------------------+
bool IsWeeklyLimitHit() {
    double lostPct = (g_weeklyStartBal - AccountEquity()) / g_weeklyStartBal * 100.0;
    if (lostPct >= InpMaxWeeklyLossPct) {
        Print("Weekly loss limit hit: ", DoubleToStr(lostPct, 2), "% — no new trades this week.");
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Session detection — convert broker time to GMT before comparing  |
//+------------------------------------------------------------------+
int BrokerHourToGMT(int brokerHour) {
    return (brokerHour - InpBrokerGMTOffset + 24) % 24;
}

bool IsAsianHour() {
    int gmt = BrokerHourToGMT(TimeHour(TimeCurrent()));
    return (gmt >= InpAsianStartHour || gmt < InpAsianEndHour);
}

bool IsLondonSession() {
    int gmt = BrokerHourToGMT(TimeHour(TimeCurrent()));
    return (gmt >= InpLondonStartHour && gmt < InpLondonEndHour);
}

bool IsNYSession() {
    int gmt = BrokerHourToGMT(TimeHour(TimeCurrent()));
    return (gmt >= InpNYStartHour && gmt < InpNYEndHour);
}

//+------------------------------------------------------------------+
//| Scan recent M5 bars to find today's Asian session high/low       |
//+------------------------------------------------------------------+
void BuildAsianRange() {
    double high = 0;
    double low  = DBL_MAX;
    bool   found = false;

    for (int i = 1; i < 300; i++) {
        datetime barTime = iTime(NULL, PERIOD_M5, i);
        int      barHour = BrokerHourToGMT(TimeHour(barTime));

        bool inAsian = (barHour >= InpAsianStartHour || barHour < InpAsianEndHour);
        if (!inAsian) {
            if (found) break; // We've passed back through the Asian window
            continue;
        }

        double bHigh = iHigh(NULL, PERIOD_M5, i);
        double bLow  = iLow(NULL, PERIOD_M5, i);
        if (bHigh > high) high = bHigh;
        if (bLow  < low)  low  = bLow;
        found = true;
    }

    if (found && high > 0 && low < DBL_MAX && high > low) {
        g_asianHigh  = high;
        g_asianLow   = low;
        g_asianMid   = (high + low) / 2.0;
        g_rangeReady = true;
    }
}

//+------------------------------------------------------------------+
//| H4 trend filter — both price and EMA read from closed bar 1     |
//+------------------------------------------------------------------+
bool IsBullTrendH4() {
    double ema   = iMA(NULL, PERIOD_H4, InpH4EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
    double close = iClose(NULL, PERIOD_H4, 1);
    return close > ema;
}

bool IsBearTrendH4() {
    double ema   = iMA(NULL, PERIOD_H4, InpH4EMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
    double close = iClose(NULL, PERIOD_H4, 1);
    return close < ema;
}

//+------------------------------------------------------------------+
//| RSI momentum confirmation (only used when InpUseRSIFilter=true)  |
//| Longs require RSI > 50 (upward momentum), shorts require < 50   |
//+------------------------------------------------------------------+
double GetH1RSI() {
    return iRSI(NULL, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE, 1);
}

bool RSIAllowsLong() {
    if (!InpUseRSIFilter) return true;
    return GetH1RSI() >= InpRSIBullMin;
}

bool RSIAllowsShort() {
    if (!InpUseRSIFilter) return true;
    return GetH1RSI() <= InpRSIBearMax;
}

//+------------------------------------------------------------------+
//| Long breakout: price closes above Asian high with bull confirm   |
//+------------------------------------------------------------------+
void CheckLongBreakout() {
    if (g_longFired) return;

    double c1 = iClose(NULL, PERIOD_M5, 1);
    double o1 = iOpen(NULL, PERIOD_M5,  1);
    double l1 = iLow(NULL, PERIOD_M5,   1);

    // Candle must close above Asian high with a bullish body
    if (c1 <= g_asianHigh) return;
    if (c1 <= o1)           return; // Must be bullish candle

    // Trend filter: H4 must be bullish
    if (!IsBullTrendH4()) { Print("LONG blocked: H4 trend bearish"); return; }

    // RSI momentum filter (disabled by default)
    if (!RSIAllowsLong()) { Print("LONG blocked: RSI=", GetH1RSI(), " below bull threshold"); return; }

    // ATR-based stop loss placed below the breakout candle low
    double atr    = iATR(NULL, PERIOD_H1, InpATRPeriod, 1);
    double sl     = l1 - atr * InpATRMultiplier;
    double slDist = Ask - sl;
    if (slDist <= 0) { Print("LONG blocked: slDist <= 0"); return; }

    // Stop should be below the Asian midpoint (confirms valid breakout)
    if (sl >= g_asianMid) { Print("LONG blocked: SL above Asian mid. SL=", sl, " Mid=", g_asianMid); return; }

    double tp   = Ask + slDist * InpRRRatio;
    double lots = CalculateLots(slDist);
    if (lots <= 0) { Print("LONG blocked: lots <= 0"); return; }

    int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, InpSlippage,
                           NormalizeDouble(sl, Digits),
                           NormalizeDouble(tp, Digits),
                           InpComment, InpMagicNumber, 0, clrDodgerBlue);
    if (ticket > 0) {
        g_longFired = true;
        g_tradesToday++;
        Print("LONG breakout | Entry:", Ask, " SL:", sl, " TP:", tp,
              " Lots:", lots, " RSI:", GetH1RSI(), " ATR:", atr);
    } else {
        Print("OrderSend failed. Error:", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Short breakout: price closes below Asian low with bear confirm   |
//+------------------------------------------------------------------+
void CheckShortBreakout() {
    if (g_shortFired) return;

    double c1 = iClose(NULL, PERIOD_M5, 1);
    double o1 = iOpen(NULL, PERIOD_M5,  1);
    double h1 = iHigh(NULL, PERIOD_M5,  1);

    // Candle must close below Asian low with a bearish body
    if (c1 >= g_asianLow) return;
    if (c1 >= o1)          return; // Must be bearish candle

    // Trend filter: H4 must be bearish
    if (!IsBearTrendH4()) { Print("SHORT blocked: H4 trend bullish"); return; }

    // RSI momentum filter (disabled by default)
    if (!RSIAllowsShort()) { Print("SHORT blocked: RSI=", GetH1RSI(), " above bear threshold"); return; }

    // ATR-based stop loss placed above the breakout candle high
    double atr    = iATR(NULL, PERIOD_H1, InpATRPeriod, 1);
    double sl     = h1 + atr * InpATRMultiplier;
    double slDist = sl - Bid;
    if (slDist <= 0) { Print("SHORT blocked: slDist <= 0"); return; }

    // Stop should be above the Asian midpoint (confirms valid breakout)
    if (sl <= g_asianMid) { Print("SHORT blocked: SL below Asian mid. SL=", sl, " Mid=", g_asianMid); return; }

    double tp   = Bid - slDist * InpRRRatio;
    double lots = CalculateLots(slDist);
    if (lots <= 0) { Print("SHORT blocked: lots <= 0"); return; }

    int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, InpSlippage,
                           NormalizeDouble(sl, Digits),
                           NormalizeDouble(tp, Digits),
                           InpComment, InpMagicNumber, 0, clrCrimson);
    if (ticket > 0) {
        g_shortFired = true;
        g_tradesToday++;
        Print("SHORT breakout | Entry:", Bid, " SL:", sl, " TP:", tp,
              " Lots:", lots, " RSI:", GetH1RSI(), " ATR:", atr);
    } else {
        Print("OrderSend failed. Error:", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Trailing stop management — moves to BE at 1:1, trails at 1.5:1  |
//+------------------------------------------------------------------+
void ManageTrailingStops() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderMagicNumber() != InpMagicNumber)        continue;
        if (OrderSymbol() != Symbol())                   continue;

        double entryPrice = OrderOpenPrice();
        double currentSL  = OrderStopLoss();
        double currentTP  = OrderTakeProfit();
        double riskDist   = 0;
        double newSL      = 0;

        if (OrderType() == OP_BUY) {
            riskDist = entryPrice - currentSL;
            if (riskDist <= 0) continue;

            double beLevel = entryPrice + InpBreakevenBuffer * g_pipSize;

            // Phase 1: Move to breakeven once 1:1 is reached
            if (Bid >= entryPrice + riskDist && currentSL < beLevel) {
                newSL = NormalizeDouble(beLevel, Digits);
                if (newSL > currentSL)
                    if (!OrderModify(OrderTicket(), entryPrice, newSL, currentTP, 0, clrGreen))
                        Print("OrderModify (BE long) failed. Error:", GetLastError());
            }
            // Phase 2: Trail stop at 50% of risk dist behind price after 1.5:1
            if (Bid >= entryPrice + riskDist * 1.5) {
                double trailSL = NormalizeDouble(Bid - riskDist * 0.5, Digits);
                if (trailSL > currentSL)
                    if (!OrderModify(OrderTicket(), entryPrice, trailSL, currentTP, 0, clrGreen))
                        Print("OrderModify (trail long) failed. Error:", GetLastError());
            }

        } else if (OrderType() == OP_SELL) {
            riskDist = currentSL - entryPrice;
            if (riskDist <= 0) continue;

            double beLevel = entryPrice - InpBreakevenBuffer * g_pipSize;

            // Phase 1: Move to breakeven once 1:1 is reached
            if (Ask <= entryPrice - riskDist && currentSL > beLevel) {
                newSL = NormalizeDouble(beLevel, Digits);
                if (newSL < currentSL)
                    if (!OrderModify(OrderTicket(), entryPrice, newSL, currentTP, 0, clrOrangeRed))
                        Print("OrderModify (BE short) failed. Error:", GetLastError());
            }
            // Phase 2: Trail stop at 50% of risk dist above price after 1.5:1
            if (Ask <= entryPrice - riskDist * 1.5) {
                double trailSL = NormalizeDouble(Ask + riskDist * 0.5, Digits);
                if (trailSL < currentSL)
                    if (!OrderModify(OrderTicket(), entryPrice, trailSL, currentTP, 0, clrOrangeRed))
                        Print("OrderModify (trail short) failed. Error:", GetLastError());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check if this EA already has a trade open on this symbol         |
//+------------------------------------------------------------------+
bool HasOpenTrade() {
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderMagicNumber() != InpMagicNumber) continue;
        if (OrderSymbol() != Symbol()) continue;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Dynamic lot sizing based on account risk and stop distance       |
//+------------------------------------------------------------------+
double CalculateLots(double slDistance) {
    if (slDistance <= 0) return 0;

    double balance  = AccountBalance();
    double riskAmt  = balance * InpRiskPercent / 100.0;

    // Tick value: profit/loss per 1 lot per 1 tick move
    double tickVal  = MarketInfo(Symbol(), MODE_TICKVALUE);
    double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);

    if (tickVal <= 0 || tickSize <= 0) return 0;

    // Risk amount / (stop distance in ticks * value per tick per lot)
    double lots = riskAmt / ((slDistance / tickSize) * tickVal);

    double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
    double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
    double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

    lots = MathFloor(lots / lotStep) * lotStep;
    lots = MathMax(minLot, MathMin(maxLot, lots));

    return lots;
}
