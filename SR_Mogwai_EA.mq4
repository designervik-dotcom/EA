//+------------------------------------------------------------------+
//|                                              SR_Mogwai_EA.mq4    |
//|                  Support & Resistance EA - Mogwai Style          |
//|                                                                  |
//|  Strategy Overview:                                              |
//|  - Identifies key S/R levels from swing highs/lows              |
//|  - Validates levels by counting price touches                   |
//|  - Enters on price action signals (pin bars, engulfing) at S/R  |
//|  - Stop loss placed beyond the S/R zone                         |
//|  - Take profit at next opposing S/R level or fixed R:R ratio    |
//+------------------------------------------------------------------+
#property copyright "SR Mogwai EA"
#property link      ""
#property version   "1.00"
#property strict

//--- Input Parameters
extern int    SwingLookback   = 10;     // Bars left/right to confirm swing point
extern int    SRLookback      = 300;    // How many bars to scan for S/R levels
extern double ZoneBuffer      = 5.0;   // Zone half-width in PIPS (auto-scaled per instrument)
                                        //   Forex:  5 pips = ~0.0005 on EURUSD
                                        //   Gold:   5 pips = $5.00 on XAUUSD — lower to 2-3
extern double LevelMergePips  = 3.0;   // Merge levels within this many pips
extern int    MinTouches      = 2;     // Min touches to validate a level
extern int    MaxLevels       = 30;    // Max S/R levels to track

extern double RiskPercent     = 1.0;   // % of balance to risk per trade
extern double RiskReward      = 2.0;   // Minimum risk:reward ratio
extern int    ATR_Period      = 14;    // ATR period for stop placement
extern double ATR_SL_Multi    = 2.0;   // ATR multiplier beyond zone for stop loss
                                        //   Gold needs wider stops — default raised to 2.0

extern bool   UsePinBars      = true;  // Enable pin bar entries
extern bool   UseEngulfing    = true;  // Enable engulfing entries
extern double PinBodyRatio    = 0.3;   // Max body/range ratio for pin bar
extern double PinWickRatio    = 0.6;   // Min dominant wick/range ratio for pin bar

extern int    MagicNumber     = 78432; // EA magic number
extern int    Slippage        = 10;    // Max slippage in points
                                        //   Gold: 10 × $0.01 = $0.10 slippage tolerance

extern bool   DrawLevels      = true;  // Draw S/R levels on chart
extern color  ResistanceColor = clrCrimson;
extern color  SupportColor    = clrDodgerBlue;
extern color  NeutralColor    = clrGray;

//--- Level structure
struct SRLevel
{
    double price;
    int    type;       // 1=support, -1=resistance, 0=neutral
    int    touches;
    bool   active;
    string objName;
};

SRLevel srLevels[30];
int     levelCount = 0;
bool    levelsBuilt = false;
datetime lastBarTime = 0;
int     lastOrderTicket = -1;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    if(Period() > PERIOD_M15)
    {
        Alert("SR_Mogwai_EA: Designed for M5 or M15 timeframes.");
        return INIT_FAILED;
    }
    double pip = GetPipSize();
    Print("SR_Mogwai_EA initialized on ", Symbol(), " M", Period(),
          " | Digits=", Digits,
          " Point=", DoubleToStr(Point, Digits),
          " PipSize=", DoubleToStr(pip, Digits),
          " ZoneWidth=", DoubleToStr(ZoneBuffer * pip, Digits));
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(DrawLevels)
        DeleteAllLevelObjects();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Only process on new bar open
    if(Time[0] == lastBarTime) return;
    lastBarTime = Time[0];

    // Rebuild S/R levels every 50 bars or on first run
    static int barsSinceRebuild = 0;
    if(!levelsBuilt || barsSinceRebuild >= 50)
    {
        BuildSRLevels();
        levelsBuilt   = true;
        barsSinceRebuild = 0;
    }
    barsSinceRebuild++;

    // Classify each level relative to current price
    ClassifyLevels();

    // Draw levels on chart
    if(DrawLevels) DrawAllLevels();

    // Skip if we already have an open position from this EA
    if(HasOpenPosition()) return;

    // Check for entry signals at S/R levels
    CheckEntrySignals();
}

//+------------------------------------------------------------------+
//| Build Support/Resistance levels from swing points               |
//+------------------------------------------------------------------+
void BuildSRLevels()
{
    levelCount = 0;
    double rawLevels[300];
    int    rawCount = 0;
    int    available = MathMin(SRLookback, Bars - SwingLookback - 1);

    // --- Collect swing highs and lows ---
    for(int i = SwingLookback + 1; i < available; i++)
    {
        if(IsSwingHigh(i))
        {
            rawLevels[rawCount] = High[i];
            rawCount++;
        }
        if(IsSwingLow(i))
        {
            rawLevels[rawCount] = Low[i];
            rawCount++;
        }
        if(rawCount >= 299) break;
    }

    if(rawCount == 0) return;

    // --- Cluster nearby levels ---
    double pip = GetPipSize();
    double mergeThreshold = LevelMergePips * pip;

    // Simple clustering: sort then merge
    SortArray(rawLevels, rawCount);

    double  clusteredPrice[30];
    int     clusterTouches[30];
    int     clusterCount = 0;

    for(int i = 0; i < rawCount; i++)
    {
        bool merged = false;
        for(int c = 0; c < clusterCount; c++)
        {
            if(MathAbs(rawLevels[i] - clusteredPrice[c]) <= mergeThreshold)
            {
                // Weighted average
                clusteredPrice[c]  = (clusteredPrice[c] * clusterTouches[c] + rawLevels[i]) / (clusterTouches[c] + 1);
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

    // --- Add touches from historical closes ---
    double zoneWidth = ZoneBuffer * GetPipSize();
    for(int c = 0; c < clusterCount; c++)
    {
        for(int i = 1; i < available; i++)
        {
            double hi = High[i];
            double lo = Low[i];
            if(hi >= clusteredPrice[c] - zoneWidth && lo <= clusteredPrice[c] + zoneWidth)
                clusterTouches[c]++;
        }
    }

    // --- Populate srLevels (only validated levels) ---
    levelCount = 0;
    for(int c = 0; c < clusterCount && levelCount < MaxLevels; c++)
    {
        if(clusterTouches[c] < MinTouches) continue;
        srLevels[levelCount].price   = clusteredPrice[c];
        srLevels[levelCount].touches = clusterTouches[c];
        srLevels[levelCount].type    = 0; // classified each tick
        srLevels[levelCount].active  = true;
        srLevels[levelCount].objName = "SR_" + IntegerToString(levelCount);
        levelCount++;
    }
}

//+------------------------------------------------------------------+
//| Classify levels as support or resistance vs current price        |
//+------------------------------------------------------------------+
void ClassifyLevels()
{
    double mid = (Ask + Bid) / 2.0;
    for(int i = 0; i < levelCount; i++)
    {
        if(srLevels[i].price < mid)
            srLevels[i].type =  1;  // support
        else
            srLevels[i].type = -1;  // resistance
    }
}

//+------------------------------------------------------------------+
//| Check for entry signals on completed bar (bar index 1)           |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
    double atr = iATR(NULL, 0, ATR_Period, 1);
    if(atr <= 0) return;

    double zoneWidth = ZoneBuffer * GetPipSize();

    for(int i = 0; i < levelCount; i++)
    {
        if(!srLevels[i].active) continue;

        double level = srLevels[i].price;
        int    ltype = srLevels[i].type;

        // --- LONG setup: price at support ---
        if(ltype == 1)
        {
            // Check that candle 1 interacted with the zone
            if(Low[1] <= level + zoneWidth && Low[1] >= level - zoneWidth * 3)
            {
                bool signal = false;
                if(UsePinBars   && IsBullishPinBar(1))   signal = true;
                if(UseEngulfing && IsBullishEngulfing(1)) signal = true;

                if(signal)
                {
                    double sl  = level - atr * ATR_SL_Multi;
                    double risk = Ask - sl;
                    if(risk <= 0 || risk > atr * 4) continue; // sanity check

                    // Find take profit: next resistance above, else R:R
                    double tp = FindNextLevel(level, 1);
                    if(tp <= 0 || (tp - Ask) < risk * RiskReward)
                        tp = Ask + risk * RiskReward;

                    double lots = CalculateLotSize(risk);
                    if(lots <= 0) continue;

                    int ticket = OrderSend(Symbol(), OP_BUY, lots, Ask, Slippage,
                                           NormalizeDouble(sl, Digits),
                                           NormalizeDouble(tp, Digits),
                                           "SR_Mogwai_Long", MagicNumber, 0, clrGreen);
                    if(ticket > 0)
                    {
                        lastOrderTicket = ticket;
                        Print("SR_Mogwai: BUY ", lots, " @ ", Ask,
                              " SL=", sl, " TP=", tp,
                              " Level=", level);
                    }
                    else
                        Print("SR_Mogwai: BUY failed, error=", GetLastError());
                    return; // one trade per bar
                }
            }
        }

        // --- SHORT setup: price at resistance ---
        if(ltype == -1)
        {
            // Check that candle 1 interacted with the zone
            if(High[1] >= level - zoneWidth && High[1] <= level + zoneWidth * 3)
            {
                bool signal = false;
                if(UsePinBars   && IsBearishPinBar(1))   signal = true;
                if(UseEngulfing && IsBearishEngulfing(1)) signal = true;

                if(signal)
                {
                    double sl  = level + atr * ATR_SL_Multi;
                    double risk = sl - Bid;
                    if(risk <= 0 || risk > atr * 4) continue;

                    // Find take profit: next support below, else R:R
                    double tp = FindNextLevel(level, -1);
                    if(tp <= 0 || (Bid - tp) < risk * RiskReward)
                        tp = Bid - risk * RiskReward;

                    double lots = CalculateLotSize(risk);
                    if(lots <= 0) continue;

                    int ticket = OrderSend(Symbol(), OP_SELL, lots, Bid, Slippage,
                                           NormalizeDouble(sl, Digits),
                                           NormalizeDouble(tp, Digits),
                                           "SR_Mogwai_Short", MagicNumber, 0, clrRed);
                    if(ticket > 0)
                    {
                        lastOrderTicket = ticket;
                        Print("SR_Mogwai: SELL ", lots, " @ ", Bid,
                              " SL=", sl, " TP=", tp,
                              " Level=", level);
                    }
                    else
                        Print("SR_Mogwai: SELL failed, error=", GetLastError());
                    return;
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Find the nearest S/R level on the opposite side                  |
//| direction: 1=look above (for sell TP), -1=look below (buy TP)    |
//+------------------------------------------------------------------+
double FindNextLevel(double fromLevel, int direction)
{
    double best  = 0;
    double pip   = GetPipSize();
    double minDist = 10 * pip; // ignore levels within 10 pips

    for(int i = 0; i < levelCount; i++)
    {
        double p = srLevels[i].price;
        if(direction == -1) // we want first support below fromLevel (for long TP)
        {
            // Actually for long we look above for resistance
            if(p > fromLevel + minDist)
            {
                if(best <= 0 || p < best) best = p;
            }
        }
        else // direction==1 => we want first resistance above fromLevel (for short TP)
        {
            if(p < fromLevel - minDist)
            {
                if(best <= 0 || p > best) best = p;
            }
        }
    }
    return best;
}

//+------------------------------------------------------------------+
//| Swing high detection                                             |
//+------------------------------------------------------------------+
bool IsSwingHigh(int bar)
{
    double pivot = High[bar];
    for(int j = 1; j <= SwingLookback; j++)
    {
        if(High[bar - j] > pivot) return false;
        if(High[bar + j] > pivot) return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Swing low detection                                              |
//+------------------------------------------------------------------+
bool IsSwingLow(int bar)
{
    double pivot = Low[bar];
    for(int j = 1; j <= SwingLookback; j++)
    {
        if(Low[bar - j] < pivot) return false;
        if(Low[bar + j] < pivot) return false;
    }
    return true;
}

//+------------------------------------------------------------------+
//| Bullish pin bar: long lower wick, small body near top            |
//+------------------------------------------------------------------+
bool IsBullishPinBar(int bar)
{
    double range = High[bar] - Low[bar];
    if(range <= 0) return false;

    double body      = MathAbs(Close[bar] - Open[bar]);
    double lowerWick = MathMin(Open[bar], Close[bar]) - Low[bar];
    double upperWick = High[bar] - MathMax(Open[bar], Close[bar]);

    bool smallBody  = (body / range) <= PinBodyRatio;
    bool longLower  = (lowerWick / range) >= PinWickRatio;
    bool smallUpper = upperWick <= body * 1.5;

    return smallBody && longLower && smallUpper;
}

//+------------------------------------------------------------------+
//| Bearish pin bar: long upper wick, small body near bottom         |
//+------------------------------------------------------------------+
bool IsBearishPinBar(int bar)
{
    double range = High[bar] - Low[bar];
    if(range <= 0) return false;

    double body      = MathAbs(Close[bar] - Open[bar]);
    double upperWick = High[bar] - MathMax(Open[bar], Close[bar]);
    double lowerWick = MathMin(Open[bar], Close[bar]) - Low[bar];

    bool smallBody  = (body / range) <= PinBodyRatio;
    bool longUpper  = (upperWick / range) >= PinWickRatio;
    bool smallLower = lowerWick <= body * 1.5;

    return smallBody && longUpper && smallLower;
}

//+------------------------------------------------------------------+
//| Bullish engulfing: bar[1] fully engulfs bar[2] bearish candle    |
//+------------------------------------------------------------------+
bool IsBullishEngulfing(int bar)
{
    if(bar + 1 >= Bars) return false;
    // Previous candle bearish
    if(Close[bar + 1] >= Open[bar + 1]) return false;
    // Current candle bullish
    if(Close[bar] <= Open[bar]) return false;
    // Engulfing
    return (Close[bar] > Open[bar + 1] && Open[bar] < Close[bar + 1]);
}

//+------------------------------------------------------------------+
//| Bearish engulfing: bar[1] fully engulfs bar[2] bullish candle    |
//+------------------------------------------------------------------+
bool IsBearishEngulfing(int bar)
{
    if(bar + 1 >= Bars) return false;
    // Previous candle bullish
    if(Close[bar + 1] <= Open[bar + 1]) return false;
    // Current candle bearish
    if(Close[bar] >= Open[bar]) return false;
    // Engulfing
    return (Open[bar] > Close[bar + 1] && Close[bar] < Open[bar + 1]);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk % and stop distance             |
//+------------------------------------------------------------------+
double CalculateLotSize(double riskPoints)
{
    if(riskPoints <= 0) return 0;

    double accountRisk  = AccountBalance() * (RiskPercent / 100.0);
    double tickValue    = MarketInfo(Symbol(), MODE_TICKVALUE);
    double tickSize     = MarketInfo(Symbol(), MODE_TICKSIZE);
    double minLot       = MarketInfo(Symbol(), MODE_MINLOT);
    double maxLot       = MarketInfo(Symbol(), MODE_MAXLOT);
    double lotStep      = MarketInfo(Symbol(), MODE_LOTSTEP);

    if(tickValue <= 0 || tickSize <= 0) return 0;

    double valuePerPoint = tickValue / tickSize;
    double lots = accountRisk / (riskPoints * valuePerPoint);

    // Normalize to broker lot step
    lots = MathFloor(lots / lotStep) * lotStep;
    lots = MathMax(minLot, MathMin(maxLot, lots));

    return lots;
}

//+------------------------------------------------------------------+
//| Check if EA has an open position                                  |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Get pip size — handles forex, gold, silver, and indices          |
//|                                                                  |
//|  Instrument  Digits  Point    Pip multiplier  Result            |
//|  XAUUSD       2      0.01     × 100           $1.00             |
//|  XAGUSD       3      0.001    × 100           $0.10             |
//|  USDJPY 3dig  3      0.001    × 10            0.01              |
//|  EURUSD 5dig  5      0.00001  × 10            0.0001            |
//|  EURUSD 4dig  4      0.0001   × 1             0.0001            |
//+------------------------------------------------------------------+
double GetPipSize()
{
    string sym = Symbol();

    // Precious metals: XAU (gold), XAG (silver)
    if(StringFind(sym, "XAU")    >= 0 || StringFind(sym, "GOLD")   >= 0 ||
       StringFind(sym, "XAG")    >= 0 || StringFind(sym, "SILVER") >= 0)
        return Point * 100;

    // Standard 3-digit JPY or 5-digit forex
    if(Digits == 3 || Digits == 5)
        return Point * 10;

    // Standard 2-digit JPY or 4-digit forex
    return Point;
}

//+------------------------------------------------------------------+
//| Sort a double array ascending (insertion sort)                   |
//+------------------------------------------------------------------+
void SortArray(double &arr[], int count)
{
    for(int i = 1; i < count; i++)
    {
        double key = arr[i];
        int j = i - 1;
        while(j >= 0 && arr[j] > key)
        {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}

//+------------------------------------------------------------------+
//| Draw all S/R levels as horizontal lines on the chart             |
//+------------------------------------------------------------------+
void DrawAllLevels()
{
    DeleteAllLevelObjects();
    for(int i = 0; i < levelCount; i++)
    {
        color lineColor = NeutralColor;
        if(srLevels[i].type ==  1) lineColor = SupportColor;
        if(srLevels[i].type == -1) lineColor = ResistanceColor;

        string name = "SR_Mogwai_" + IntegerToString(i);
        srLevels[i].objName = name;

        ObjectCreate(name, OBJ_HLINE, 0, 0, srLevels[i].price);
        ObjectSetInteger(0, name, OBJPROP_COLOR,  lineColor);
        ObjectSetInteger(0, name, OBJPROP_STYLE,  STYLE_DASH);
        ObjectSetInteger(0, name, OBJPROP_WIDTH,  1);

        // Add touches count as label
        string lname = name + "_lbl";
        ObjectCreate(lname, OBJ_TEXT, 0, Time[10], srLevels[i].price);
        ObjectSetString(0, lname, OBJPROP_TEXT,
                        (srLevels[i].type == 1 ? "S" : "R") +
                        " [" + IntegerToString(srLevels[i].touches) + "]");
        ObjectSetInteger(0, lname, OBJPROP_COLOR,    lineColor);
        ObjectSetInteger(0, lname, OBJPROP_FONTSIZE, 8);
    }
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete all drawn S/R level objects                               |
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
