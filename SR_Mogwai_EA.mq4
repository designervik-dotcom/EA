//+------------------------------------------------------------------+
//|                                              SR_Mogwai_EA.mq4    |
//|                  Support & Resistance EA - Mogwai Style          |
//|                         v2.0 - Gold Optimised                    |
//|                                                                  |
//|  Changelog v2.0:                                                 |
//|  - Fixed FindNextLevel direction logic (was inverted)            |
//|  - Added H1 EMA trend filter (only trade with trend)            |
//|  - Added London/NY session filter                                |
//|  - Added breakeven + optional trailing stop (per-tick)          |
//|  - Added level cooldown (prevents re-entry at same level)        |
//|  - Added daily trade cap and daily loss cap                      |
//|  - Tightened zone interaction (candle must come from right side) |
//|  - Reduced default RiskPercent 1.0 → 0.5                       |
//+------------------------------------------------------------------+
#property copyright "SR Mogwai EA v2.0"
#property link      ""
#property version   "2.00"
#property strict

//--- S/R Level Detection
extern int    SwingLookback    = 10;    // Bars each side to confirm swing point
extern int    SRLookback       = 300;   // Bars to scan for levels
extern double ZoneBuffer       = 3.0;  // Zone half-width in pips (Gold: $3)
extern double LevelMergePips   = 5.0;  // Merge levels within this many pips (Gold: $5)
extern int    MinTouches       = 2;    // Min touches to validate level
extern int    MaxLevels        = 30;   // Max levels to track
extern int    LevelCooldownBars= 20;   // Bars to skip after signal at a level

//--- Risk Management
extern double RiskPercent      = 0.5;  // % of balance per trade (halved from v1)
extern double RiskReward       = 2.0;  // Minimum acceptable R:R
extern int    ATR_Period       = 14;   // ATR period
extern double ATR_SL_Multi     = 2.0;  // ATR × this = stop distance beyond zone

//--- Trade Management
extern bool   UseBreakeven     = true; // Move SL to breakeven
extern double BE_ActivationATR = 0.8;  // Activate BE when profit >= ATR × this
extern double BE_LockPips      = 3.0;  // Pips to lock in at breakeven (Gold: $3)
extern bool   UseTrailingStop  = false;// Trail SL after breakeven
extern double TrailingATR      = 2.0;  // Trail distance in ATR multiples

//--- Daily Limits
extern int    MaxDailyTrades   = 4;    // Max new entries per day (0=off)
extern double MaxDailyLossPct  = 2.0;  // Stop trading after this % daily loss (0=off)

//--- Trend Filter (H1 EMA)
extern bool   UseTrendFilter   = true; // Only trade in direction of H1 trend
extern int    TrendEMA_Period  = 200;  // EMA period on higher timeframe
extern int    TrendTimeframe   = 60;   // Timeframe: 60=H1, 240=H4

//--- Session Filter
extern bool   UseSessionFilter = true; // Only trade during allowed hours
extern int    SessionStartHour = 7;    // Server time hour to start (London open)
extern int    SessionEndHour   = 21;   // Server time hour to stop  (NY close)

//--- Entry Signals
extern bool   UsePinBars       = true;
extern bool   UseEngulfing     = true;
extern double PinBodyRatio     = 0.3;  // Max body/range for pin bar
extern double PinWickRatio     = 0.6;  // Min dominant wick/range for pin bar

//--- Display & EA Identity
extern int    MagicNumber      = 78432;
extern int    Slippage         = 10;   // Gold: 10 × $0.01 = $0.10
extern bool   DrawLevels       = true;
extern color  ResistanceColor  = clrCrimson;
extern color  SupportColor     = clrDodgerBlue;
extern color  NeutralColor     = clrGray;

//--- Level structure
struct SRLevel
{
    double price;
    int    type;      //  1=support  -1=resistance  0=unclassified
    int    touches;
    bool   active;
    int    lastSignalBar; // bar index when this level last fired
};

SRLevel  srLevels[30];
int      levelCount    = 0;
bool     levelsBuilt   = false;
datetime lastBarTime   = 0;

//+------------------------------------------------------------------+
//| Initialise                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
    if(Period() > PERIOD_M15)
    {
        Alert("SR_Mogwai_EA: Designed for M5 or M15. Aborting.");
        return INIT_FAILED;
    }

    double pip = GetPipSize();
    Print("SR_Mogwai v2.0 | ", Symbol(), " M", Period(),
          " | Digits=", Digits,
          " | PipSize=", DoubleToStr(pip, Digits),
          " | ZoneWidth=±", DoubleToStr(ZoneBuffer * pip, Digits),
          " | TrendFilter=", UseTrendFilter ? "ON" : "OFF",
          " | SessionFilter=", UseSessionFilter ? "ON" : "OFF");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialise                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(DrawLevels) DeleteAllLevelObjects();
}

//+------------------------------------------------------------------+
//| Main tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
    // Manage open trades every tick (breakeven, trailing)
    ManageOpenTrades();

    // New bar gate
    if(Time[0] == lastBarTime) return;
    lastBarTime = Time[0];

    // Rebuild levels every 50 bars
    static int barsSinceRebuild = 0;
    if(!levelsBuilt || barsSinceRebuild >= 50)
    {
        BuildSRLevels();
        levelsBuilt      = true;
        barsSinceRebuild = 0;
    }
    barsSinceRebuild++;

    ClassifyLevels();
    if(DrawLevels) DrawAllLevels();

    // Don't enter if already positioned
    if(HasOpenPosition()) return;

    // Daily cap checks
    if(MaxDailyTrades > 0 && GetTodayTradeCount() >= MaxDailyTrades) return;
    if(MaxDailyLossPct > 0 && GetTodayPnL() <= -(AccountBalance() * MaxDailyLossPct / 100.0)) return;

    // Session filter
    if(!IsSessionAllowed()) return;

    CheckEntrySignals();
}

//+------------------------------------------------------------------+
//| Build S/R levels from swing highs/lows                          |
//+------------------------------------------------------------------+
void BuildSRLevels()
{
    levelCount = 0;
    double rawLevels[300];
    int    rawCount  = 0;
    int    available = MathMin(SRLookback, Bars - SwingLookback - 1);

    for(int i = SwingLookback + 1; i < available; i++)
    {
        if(IsSwingHigh(i) && rawCount < 299) { rawLevels[rawCount++] = High[i]; }
        if(IsSwingLow(i)  && rawCount < 299) { rawLevels[rawCount++] = Low[i];  }
    }
    if(rawCount == 0) return;

    double pip            = GetPipSize();
    double mergeThreshold = LevelMergePips * pip;
    SortArray(rawLevels, rawCount);

    double clusteredPrice[30];
    int    clusterTouches[30];
    int    clusterCount = 0;

    for(int i = 0; i < rawCount; i++)
    {
        bool merged = false;
        for(int c = 0; c < clusterCount; c++)
        {
            if(MathAbs(rawLevels[i] - clusteredPrice[c]) <= mergeThreshold)
            {
                clusteredPrice[c] = (clusteredPrice[c] * clusterTouches[c] + rawLevels[i])
                                     / (clusterTouches[c] + 1);
                clusterTouches[c]++;
                merged = true;
                break;
            }
        }
        if(!merged && clusterCount < MaxLevels)
        {
            clusteredPrice[clusterCount]  = rawLevels[i];
            clusterTouches[clusterCount]  = 1;
            clusterCount++;
        }
    }

    // Count additional bar interactions (bounce-style: touched and closed away)
    double zoneWidth = ZoneBuffer * pip;
    for(int c = 0; c < clusterCount; c++)
    {
        for(int i = 1; i < available; i++)
        {
            bool touchedFromAbove = (Low[i]  <= clusteredPrice[c] + zoneWidth && Close[i] > clusteredPrice[c]);
            bool touchedFromBelow = (High[i] >= clusteredPrice[c] - zoneWidth && Close[i] < clusteredPrice[c]);
            if(touchedFromAbove || touchedFromBelow) clusterTouches[c]++;
        }
    }

    levelCount = 0;
    for(int c = 0; c < clusterCount && levelCount < MaxLevels; c++)
    {
        if(clusterTouches[c] < MinTouches) continue;
        srLevels[levelCount].price         = clusteredPrice[c];
        srLevels[levelCount].touches       = clusterTouches[c];
        srLevels[levelCount].type          = 0;
        srLevels[levelCount].active        = true;
        srLevels[levelCount].lastSignalBar = 0;
        levelCount++;
    }
}

//+------------------------------------------------------------------+
//| Classify each level vs current price                             |
//+------------------------------------------------------------------+
void ClassifyLevels()
{
    double mid = (Ask + Bid) / 2.0;
    for(int i = 0; i < levelCount; i++)
        srLevels[i].type = (srLevels[i].price < mid) ? 1 : -1;
}

//+------------------------------------------------------------------+
//| Entry signal scan (runs once per new bar)                        |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
    double atr      = iATR(NULL, 0, ATR_Period, 1);
    if(atr <= 0) return;

    double pip       = GetPipSize();
    double zoneWidth = ZoneBuffer * pip;

    for(int i = 0; i < levelCount; i++)
    {
        if(!srLevels[i].active) continue;

        // Level cooldown: skip if this level fired recently
        if(srLevels[i].lastSignalBar > 0 &&
           Bars - srLevels[i].lastSignalBar < LevelCooldownBars) continue;

        double level = srLevels[i].price;
        int    ltype = srLevels[i].type;

        // ---- LONG: price bouncing up from support ----
        if(ltype == 1)
        {
            // Candle must have come from ABOVE the level and touched the zone
            // Open above level, low dipped into zone, close back above lower zone edge
            bool touched  = (Low[1]   <= level + zoneWidth);      // dipped into zone
            bool held     = (Close[1]  > level - zoneWidth);      // didn't close below zone
            bool fromAbove= (Open[1]   > level - zoneWidth * 0.5);// opened above zone centre

            if(!touched || !held || !fromAbove) continue;

            // Trend filter: only long when price is above H1 EMA
            if(!IsTrendAligned(1)) continue;

            bool signal = false;
            if(UsePinBars   && IsBullishPinBar(1))    signal = true;
            if(UseEngulfing && IsBullishEngulfing(1))  signal = true;
            if(!signal) continue;

            double sl   = level - atr * ATR_SL_Multi;
            double risk = Ask - sl;
            if(risk <= 0 || risk > atr * 5) continue;

            double tp = FindNextResistance(level, pip);
            if(tp <= 0 || (tp - Ask) < risk * RiskReward)
                tp = Ask + risk * RiskReward;

            double lots = CalculateLotSize(risk);
            if(lots <= 0) continue;

            int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, Slippage,
                                   NormalizeDouble(sl, Digits),
                                   NormalizeDouble(tp, Digits),
                                   "SR_Mogwai_L", MagicNumber, 0, clrGreen);
            if(ticket > 0)
            {
                srLevels[i].lastSignalBar = Bars;
                Print("SR_Mogwai BUY  ", lots, " @ ", Ask,
                      " SL=", sl, " TP=", tp, " Level=", level);
            }
            else
                Print("SR_Mogwai BUY FAILED err=", GetLastError());
            return; // one trade per bar
        }

        // ---- SHORT: price rejecting down from resistance ----
        if(ltype == -1)
        {
            // Candle must have come from BELOW the level and poked into zone
            bool touched   = (High[1]  >= level - zoneWidth);      // poked into zone
            bool held      = (Close[1]  < level + zoneWidth);      // didn't close above zone
            bool fromBelow = (Open[1]   < level + zoneWidth * 0.5);// opened below zone centre

            if(!touched || !held || !fromBelow) continue;

            // Trend filter: only short when price is below H1 EMA
            if(!IsTrendAligned(-1)) continue;

            bool signal = false;
            if(UsePinBars   && IsBearishPinBar(1))    signal = true;
            if(UseEngulfing && IsBearishEngulfing(1))  signal = true;
            if(!signal) continue;

            double sl   = level + atr * ATR_SL_Multi;
            double risk = sl - Bid;
            if(risk <= 0 || risk > atr * 5) continue;

            double tp = FindNextSupport(level, pip);
            if(tp <= 0 || (Bid - tp) < risk * RiskReward)
                tp = Bid - risk * RiskReward;

            double lots = CalculateLotSize(risk);
            if(lots <= 0) continue;

            int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, Slippage,
                                   NormalizeDouble(sl, Digits),
                                   NormalizeDouble(tp, Digits),
                                   "SR_Mogwai_S", MagicNumber, 0, clrRed);
            if(ticket > 0)
            {
                srLevels[i].lastSignalBar = Bars;
                Print("SR_Mogwai SELL ", lots, " @ ", Bid,
                      " SL=", sl, " TP=", tp, " Level=", level);
            }
            else
                Print("SR_Mogwai SELL FAILED err=", GetLastError());
            return;
        }
    }
}

//+------------------------------------------------------------------+
//| Breakeven and trailing stop — runs every tick                    |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
    if(!UseBreakeven && !UseTrailingStop) return;

    double atr = iATR(NULL, 0, ATR_Period, 1);
    if(atr <= 0) return;

    double pip    = GetPipSize();
    double beLock = BE_LockPips * pip;

    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if(OrderSymbol()      != Symbol())      continue;
        if(OrderMagicNumber() != MagicNumber)   continue;

        double openSL  = OrderStopLoss();
        double openTP  = OrderTakeProfit();
        double openPrc = OrderOpenPrice();

        if(OrderType() == OP_BUY)
        {
            double profit = Bid - openPrc;

            // Breakeven
            if(UseBreakeven && profit >= atr * BE_ActivationATR)
            {
                double newSL = NormalizeDouble(openPrc + beLock, Digits);
                if(newSL > openSL)
                    OrderModify(OrderTicket(), openPrc, newSL, openTP, 0, clrYellow);
            }

            // Trailing (only after BE is active)
            if(UseTrailingStop && openSL >= openPrc)
            {
                double trail = NormalizeDouble(Bid - atr * TrailingATR, Digits);
                if(trail > openSL)
                    OrderModify(OrderTicket(), openPrc, trail, openTP, 0, clrOrange);
            }
        }
        else if(OrderType() == OP_SELL)
        {
            double profit = openPrc - Ask;

            // Breakeven
            if(UseBreakeven && profit >= atr * BE_ActivationATR)
            {
                double newSL = NormalizeDouble(openPrc - beLock, Digits);
                if(openSL == 0 || newSL < openSL)
                    OrderModify(OrderTicket(), openPrc, newSL, openTP, 0, clrYellow);
            }

            // Trailing (only after BE is active)
            if(UseTrailingStop && openSL > 0 && openSL <= openPrc)
            {
                double trail = NormalizeDouble(Ask + atr * TrailingATR, Digits);
                if(trail < openSL)
                    OrderModify(OrderTicket(), openPrc, trail, openTP, 0, clrOrange);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trend alignment check against higher timeframe EMA              |
//+------------------------------------------------------------------+
bool IsTrendAligned(int direction)
{
    if(!UseTrendFilter) return true;
    double ema   = iMA(NULL, TrendTimeframe, TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE, 0);
    double price = iClose(NULL, TrendTimeframe, 0);
    if(direction ==  1) return price > ema; // only long if above H1 EMA
    if(direction == -1) return price < ema; // only short if below H1 EMA
    return false;
}

//+------------------------------------------------------------------+
//| Session gate                                                     |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
    if(!UseSessionFilter) return true;
    int h = TimeHour(TimeCurrent());
    return (h >= SessionStartHour && h < SessionEndHour);
}

//+------------------------------------------------------------------+
//| Today's closed trade count (this symbol, this magic)            |
//+------------------------------------------------------------------+
int GetTodayTradeCount()
{
    datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    int count = 0;
    for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderSymbol()      != Symbol())    continue;
        if(OrderMagicNumber() != MagicNumber) continue;
        if(OrderCloseTime()   <  dayStart)    continue;
        count++;
    }
    return count;
}

//+------------------------------------------------------------------+
//| Today's realised P&L (this symbol, this magic)                  |
//+------------------------------------------------------------------+
double GetTodayPnL()
{
    datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
    double pnl = 0;
    for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
    {
        if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
        if(OrderSymbol()      != Symbol())    continue;
        if(OrderMagicNumber() != MagicNumber) continue;
        if(OrderCloseTime()   <  dayStart)    continue;
        pnl += OrderProfit() + OrderSwap() + OrderCommission();
    }
    return pnl;
}

//+------------------------------------------------------------------+
//| Find nearest resistance level ABOVE fromLevel (for long TP)     |
//+------------------------------------------------------------------+
double FindNextResistance(double fromLevel, double pip)
{
    double best     = 0;
    double minDist  = 10.0 * pip;
    for(int i = 0; i < levelCount; i++)
    {
        double p = srLevels[i].price;
        if(p > fromLevel + minDist)
            if(best <= 0 || p < best) best = p; // closest above
    }
    return best;
}

//+------------------------------------------------------------------+
//| Find nearest support level BELOW fromLevel (for short TP)       |
//+------------------------------------------------------------------+
double FindNextSupport(double fromLevel, double pip)
{
    double best    = 0;
    double minDist = 10.0 * pip;
    for(int i = 0; i < levelCount; i++)
    {
        double p = srLevels[i].price;
        if(p < fromLevel - minDist)
            if(best <= 0 || p > best) best = p; // closest below
    }
    return best;
}

//+------------------------------------------------------------------+
//| Swing high                                                       |
//+------------------------------------------------------------------+
bool IsSwingHigh(int bar)
{
    double pivot = High[bar];
    for(int j = 1; j <= SwingLookback; j++)
        if(High[bar - j] > pivot || High[bar + j] > pivot) return false;
    return true;
}

//+------------------------------------------------------------------+
//| Swing low                                                        |
//+------------------------------------------------------------------+
bool IsSwingLow(int bar)
{
    double pivot = Low[bar];
    for(int j = 1; j <= SwingLookback; j++)
        if(Low[bar - j] < pivot || Low[bar + j] < pivot) return false;
    return true;
}

//+------------------------------------------------------------------+
//| Bullish pin bar: long lower wick, small body near high           |
//+------------------------------------------------------------------+
bool IsBullishPinBar(int bar)
{
    double range = High[bar] - Low[bar];
    if(range <= 0) return false;
    double body      = MathAbs(Close[bar] - Open[bar]);
    double lowerWick = MathMin(Open[bar], Close[bar]) - Low[bar];
    double upperWick = High[bar] - MathMax(Open[bar], Close[bar]);
    return (body / range)      <= PinBodyRatio &&
           (lowerWick / range) >= PinWickRatio &&
           upperWick           <= body * 1.5;
}

//+------------------------------------------------------------------+
//| Bearish pin bar: long upper wick, small body near low            |
//+------------------------------------------------------------------+
bool IsBearishPinBar(int bar)
{
    double range = High[bar] - Low[bar];
    if(range <= 0) return false;
    double body      = MathAbs(Close[bar] - Open[bar]);
    double upperWick = High[bar] - MathMax(Open[bar], Close[bar]);
    double lowerWick = MathMin(Open[bar], Close[bar]) - Low[bar];
    return (body / range)      <= PinBodyRatio &&
           (upperWick / range) >= PinWickRatio &&
           lowerWick           <= body * 1.5;
}

//+------------------------------------------------------------------+
//| Bullish engulfing                                                |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int bar)
{
    if(bar + 1 >= Bars) return false;
    if(Close[bar + 1] >= Open[bar + 1]) return false; // prev must be bearish
    if(Close[bar]     <= Open[bar])     return false; // current must be bullish
    return Close[bar] > Open[bar + 1] && Open[bar] < Close[bar + 1];
}

//+------------------------------------------------------------------+
//| Bearish engulfing                                                |
//+------------------------------------------------------------------+
bool IsBearishEngulfing(int bar)
{
    if(bar + 1 >= Bars) return false;
    if(Close[bar + 1] <= Open[bar + 1]) return false; // prev must be bullish
    if(Close[bar]     >= Open[bar])     return false; // current must be bearish
    return Open[bar] > Close[bar + 1] && Close[bar] < Open[bar + 1];
}

//+------------------------------------------------------------------+
//| Risk-based lot sizing                                            |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskPoints)
{
    if(riskPoints <= 0) return 0;
    double accountRisk   = AccountBalance() * (RiskPercent / 100.0);
    double tickValue     = MarketInfo(Symbol(), MODE_TICKVALUE);
    double tickSize      = MarketInfo(Symbol(), MODE_TICKSIZE);
    double minLot        = MarketInfo(Symbol(), MODE_MINLOT);
    double maxLot        = MarketInfo(Symbol(), MODE_MAXLOT);
    double lotStep       = MarketInfo(Symbol(), MODE_LOTSTEP);
    if(tickValue <= 0 || tickSize <= 0) return 0;
    double valuePerPoint = tickValue / tickSize;
    double lots          = accountRisk / (riskPoints * valuePerPoint);
    lots = MathFloor(lots / lotStep) * lotStep;
    return MathMax(minLot, MathMin(maxLot, lots));
}

//+------------------------------------------------------------------+
//| Open position check                                              |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = 0; i < OrdersTotal(); i++)
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
                return true;
    return false;
}

//+------------------------------------------------------------------+
//| Pip size — handles forex, gold, silver                           |
//|  Instrument  Digits  Point    Multiplier  Pip                   |
//|  XAUUSD       2      0.01     ×100        $1.00                 |
//|  XAGUSD       3      0.001    ×100        $0.10                 |
//|  EURUSD 5dig  5      0.00001  ×10         0.0001                |
//|  USDJPY 3dig  3      0.001    ×10         0.01                  |
//+------------------------------------------------------------------+
double GetPipSize()
{
    string sym = Symbol();
    if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD")   >= 0 ||
       StringFind(sym, "XAG") >= 0 || StringFind(sym, "SILVER") >= 0)
        return Point * 100;
    if(Digits == 3 || Digits == 5)
        return Point * 10;
    return Point;
}

//+------------------------------------------------------------------+
//| Insertion sort ascending                                         |
//+------------------------------------------------------------------+
void SortArray(double &arr[], int count)
{
    for(int i = 1; i < count; i++)
    {
        double key = arr[i];
        int j = i - 1;
        while(j >= 0 && arr[j] > key) { arr[j + 1] = arr[j]; j--; }
        arr[j + 1] = key;
    }
}

//+------------------------------------------------------------------+
//| Draw S/R lines on chart                                          |
//+------------------------------------------------------------------+
void DrawAllLevels()
{
    DeleteAllLevelObjects();
    for(int i = 0; i < levelCount; i++)
    {
        color  lc   = NeutralColor;
        if(srLevels[i].type ==  1) lc = SupportColor;
        if(srLevels[i].type == -1) lc = ResistanceColor;

        string name = "SR_Mogwai_" + IntegerToString(i);
        ObjectCreate(name, OBJ_HLINE, 0, 0, srLevels[i].price);
        ObjectSetInteger(0, name, OBJPROP_COLOR, lc);
        ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);

        string lname = name + "_lbl";
        ObjectCreate(lname, OBJ_TEXT, 0, Time[15], srLevels[i].price);
        ObjectSetString(0, lname, OBJPROP_TEXT,
            (srLevels[i].type == 1 ? "S" : "R") +
            "[" + IntegerToString(srLevels[i].touches) + "]");
        ObjectSetInteger(0, lname, OBJPROP_COLOR,    lc);
        ObjectSetInteger(0, lname, OBJPROP_FONTSIZE, 8);
    }
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Remove drawn objects                                             |
//+------------------------------------------------------------------+
void DeleteAllLevelObjects()
{
    for(int i = ObjectsTotal() - 1; i >= 0; i--)
    {
        string name = ObjectName(i);
        if(StringFind(name, "SR_Mogwai_") == 0)
            ObjectDelete(name);
    }
}
//+------------------------------------------------------------------+
