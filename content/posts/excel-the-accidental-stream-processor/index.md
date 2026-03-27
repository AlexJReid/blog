+++
draft = false
date = 2026-03-27
title = "Excel as an accidental stream processor"
description = "Excel probably shouldn't work as a stream processor. And yet: live FX feeds, cross-rates, rolling analytics, and alerts, all in a workbook."
slug = "excel-the-accidental-stream-processor"
tags = ["excel","nats","xll","stream-processing","zigxll","xllify"]
categories = ["projects"]
externalLink = ""
series = []
+++


Watching a feed, deriving a few values, and firing an alert when something looks off shouldn't require a Kafka cluster, a JVM, and three days of ceremony. For a lot of problems, it doesn't. NATS is a natural hub for streaming values: lightweight, subject-routed, no schema enforcement. The missing piece is somewhere to do the computation. It turns out Excel is a left-field but fairly compelling answer. It puts stream processing in the hands of analysts who already know how to use it, without asking them to learn a new framework or become developers overnight.

[zigxll-connectors-nats](https://github.com/AlexJReid/zigxll-connectors-nats) is a native XLL add-in that gives Excel cells `=NATS.SUB("subject")` and `=NATS.PUB("subject", cell-ref)`. Wire a few of those up with ordinary formulas and you have a functioning stream processing topology: a spreadsheet that anyone can open, understand, and modify.

This post walks through a foreign exchange monitor that consumes simulated market data from NATS, derives cross-rates and rolling statistics in Excel, and publishes alerts back to NATS. A downstream subscriber picks them up and has absolutely no idea it's talking to a spreadsheet. This is obviously not a replacement for a proper stream processing pipeline, and we'll cover the drawbacks at the end.

---

## Why this is less stupid than it sounds

Stream processing frameworks are powerful, but they're aimed at developers and suffer from kitchen-sink-itis, or docs that assume you have a Kubernetes cluster in your back pocket. For an analyst who wants to monitor a feed, derive a few values, and fire an alert when something looks off, that's a lot of ceremony for what amounts to "watch some numbers and do some arithmetic."

Excel, meanwhile, **is already a reactive computation engine**. Change a cell, everything downstream recalculates. `AVERAGE` over a spilling range of recent prices? That's a rolling mean. `STDEV`? Rolling volatility. `IF`? A filter. These aren't approximations of stream processing primitives. They _are_ stream processing primitives, wearing a shirt and tie. Nobody noticed because they were too busy complaining about Excel.

The catch (and we'll come back to it) is that Excel was obviously not designed for this. It has no fault tolerance, no horizontal scaling, and no delivery guarantees. But for an operational dashboard or a prototype before you commit to a real pipeline, it works.

## The scenario

To prove this isn't a party trick, we'll simulate a realistic-ish FX monitoring setup:

- A Python script publishes tick data for three currency pairs to NATS: bid, ask, and mid on `fx.raw.{PAIR}.{bid|ask|mid}`
- Excel subscribes to all three, derives the EURGBP cross-rate, computes a 60-tick rolling mean and standard deviation on EURUSD, and classifies the current price regime as trending or ranging
- When a breakout is detected, Excel publishes to `fx.derived.alerts` via `NATS.PUB`
- The NATS CLI subscribed to `fx.derived.>` shows whatever arrives, standing in for any downstream consumer

The Python scripts are deliberately boring drivers. The interesting logic lives in the workbook.

{{< youtube MSW4McvuYB8 >}}


## The publisher

Save this as `driver.py`. It needs `nats-py` (`pip install nats-py`).

The subject hierarchy carries all the context. Payloads are naked numbers: no JSON, no parsing, nothing to go wrong. Each tick publishes bid, ask, and mid for all three pairs.

```python
import asyncio
import random
import nats

BASE_PRICES = {
    "EURUSD": 1.0820,
    "GBPUSD": 1.2740,
    "USDJPY": 149.50,
}

SPREADS = {
    "EURUSD": 0.0002,
    "GBPUSD": 0.0002,
    "USDJPY": 0.03,
}

async def main():
    nc = await nats.connect("nats://localhost:4222")
    prices = dict(BASE_PRICES)

    while True:
        for pair, mid in prices.items():
            mid = mid * (1 + random.gauss(0, 0.0001))
            prices[pair] = mid
            spread = SPREADS[pair]

            bid = round(mid - spread / 2, 5)
            ask = round(mid + spread / 2, 5)

            await nc.publish(f"fx.raw.{pair}.bid", str(bid).encode())
            await nc.publish(f"fx.raw.{pair}.ask", str(ask).encode())
            await nc.publish(f"fx.raw.{pair}.mid", str(round(mid, 5)).encode())

        await asyncio.sleep(0.2)  # five ticks per second

asyncio.run(main())
```

To see what Excel publishes, subscribe with the NATS CLI:

```bash
nats sub "fx.derived.>"
```

Start your NATS server (`nats-server`), run `driver.py`, and prices will be flowing.

---

## The workbook

Four sheets, each with a clearly defined role. [Download the workbook](fx_monitor.xlsx) to follow along.

### Sheet 1: Raw feed

This sheet does nothing but subscribe. One row per currency pair.

| | A | B | C | D |
|---|---|---|---|---|
| 1 | Pair | Bid | Ask | Mid |
| 2 | EURUSD | `=NATS.SUB("fx.raw.EURUSD.bid")` | `=NATS.SUB("fx.raw.EURUSD.ask")` | `=(B2+C2)/2` |
| 3 | GBPUSD | `=NATS.SUB("fx.raw.GBPUSD.bid")` | `=NATS.SUB("fx.raw.GBPUSD.ask")` | `=(B3+C3)/2` |
| 4 | USDJPY | `=NATS.SUB("fx.raw.USDJPY.bid")` | `=NATS.SUB("fx.raw.USDJPY.ask")` | `=(B4+C4)/2` |

Each subject carries a single naked number. `fx.raw.EURUSD.bid` publishes `1.08190`, nothing else. The subject name is the schema. Excel gets back a native number with no parsing step, ready for formulas.

The mid-price in column D is arithmetic over two live cells. It recalculates every time either of them does.

### Sheet 2: Derived rates

Cross-rates from the raw mids. No separate market data feed required.

| | A | B |
|---|---|---|
| 1 | Pair | Mid |
| 2 | EURGBP | `=Raw!D2/Raw!D3` |
| 3 | JPYUSD | `=1/Raw!D4` |

EURGBP doesn't have its own feed. It falls out of dividing EURUSD by GBPUSD. This shows that derived values are formulas over live cells, and they update the instant their inputs do.

### Sheet 3: Rolling window analytics

This is where `NATS.SUBWIN` comes in. Rather than showing the latest value, it accumulates the last N ticks in a ring buffer and spills them as a column.

The publisher emits a mid subject for each pair alongside bid and ask, so the sheet subscribes to that directly:

```
A1: =NATS.SUBWIN("fx.raw.EURUSD.mid", 60)
B1: =NATS.SUBWIN.VALS(A1)
```

`A1` holds a handle that changes on every new message. `B1` spills 60 values downward, oldest first, resizing as the buffer fills.

With that spill range available, the analytics are standard functions doing non-standard things:

```
D1: =AVERAGE(NATS.SUBWIN.VALS(A1))   rolling mean
D2: =STDEV(NATS.SUBWIN.VALS(A1))     rolling volatility
D3: =MAX(NATS.SUBWIN.VALS(A1))-MIN(NATS.SUBWIN.VALS(A1))   range
D4: =(D1-INDEX(NATS.SUBWIN.VALS(A1),60))/D2                z-score of drift
```

The z-score in D4 measures how far the current mean has moved from the oldest value in the window, normalised by volatility. A large positive value suggests an upward trend. A large negative value suggests the reverse. Values close to zero suggest the pair is ranging.

Select the `B1#` spill range as the data source for a sparkline and you get a live price chart with no VBA and no charting library. If you squint, it almost looks professional.

One thing worth pointing out: this is all live. While the workbook is consuming ticks and publishing alerts, you can watch it happen. The cells flicker as new values arrive, the sparkline redraws in real time, and the regime classification in the Alerts sheet updates as the window rolls forward. You can open the workbook, subscribe to `fx.derived.>` in a terminal, and watch messages arrive in both places simultaneously. This makes it genuinely useful for debugging a pipeline too; you can see exactly what a formula produces against live data and trace the output downstream, all without leaving the spreadsheet.

### Sheet 4: Alerts and publish

This sheet classifies the regime and publishes back to NATS.

```
B2: =IF(Analytics!D4>2,"BREAKOUT_UP",IF(Analytics!D4<-2,"BREAKOUT_DOWN","RANGING"))
B3: =NATS.PUB("fx.derived.EURGBP", Derived!B2)
B4: =NATS.PUB("fx.derived.alerts", B2)
```

`NATS.PUB` publishes whenever its input cell changes. Because B2 depends on the rolling z-score which depends on live ticks, this fires continuously as the window updates. When the regime flips, the alert subject gets a new value within a tick or two.

The subscriber you ran earlier will print these as they arrive. From its perspective, the thing producing `fx.derived.alerts` is an opaque NATS publisher. It could be a Go microservice, a Python script, a C++ engine. It's a spreadsheet. The spreadsheet doesn't care and neither does the subscriber.

### Aside: custom functions for complex logic (optional)

The nested `IF` in B2 is fine for a three-way classification, and for most scenarios you don't need anything more. But formulas like this get unwieldy fast. If you wanted something more involved, say a weighted signal that combines the z-score with a rate-of-change measure and a volatility band width, you'd end up with a cell formula nobody could read. [zigxll](https://github.com/AlexJReid/zigxll) lets you write custom worksheet functions in Zig or Lua, so you could wrap that logic into something like:

```
=FX_SIGNAL(Analytics!D4, Analytics!D2, Analytics!D3, 2.0)
```

With [zigxll](https://github.com/AlexJReid/zigxll) (or [xllify](https://xllify.com)), you can write custom functions in Lua that become regular worksheet functions. The Lua implementation:

```lua
--- Classifies FX regime from z-score, volatility, and range
-- @name FX_SIGNAL
-- @param zscore number The z-score of drift
-- @param volatility number Rolling standard deviation
-- @param range number Rolling high-low range
-- @param threshold number Z-score threshold for breakout detection
-- @category Financial
function FX_SIGNAL(zscore, volatility, range, threshold)
    local band_ratio = range / (volatility * 2)
    if zscore > threshold and band_ratio > 1.5 then
        return "STRONG_BREAKOUT_UP"
    elseif zscore > threshold then
        return "BREAKOUT_UP"
    elseif zscore < -threshold and band_ratio > 1.5 then
        return "STRONG_BREAKOUT_DOWN"
    elseif zscore < -threshold then
        return "BREAKOUT_DOWN"
    else
        return "RANGING"
    end
end
```

The cell becomes:

```
B2: =FX_SIGNAL(Analytics!D4, Analytics!D2, Analytics!D3, 2.0)

```

The logic lives in a testable script rather than a nested cell formula, and the cell stays readable. The `IF` approach works for this example, but for anything more sophisticated, custom functions keep the sheet from turning into line noise.


## Full throttle

Excel's RTD mechanism has a throttle interval that defaults to 2000ms. For any kind of real-time use you'll want to lower it. In the VBA immediate window (`Alt+F11`, then `Ctrl+G`):

```vb
Application.RTD.ThrottleInterval = 100
```

Set it to `0` for the fastest possible updates. This persists across sessions.

## What this is good for

Analysts who already live in Excel can now wire themselves directly into event-driven infrastructure without anyone writing a bespoke integration for them. If your organisation runs NATS, and you have people who want to monitor feeds, derive indicators, and raise alerts, this gets them there with formulas they already know. The learning curve is "here are three new functions."

It's also a useful prototyping environment. You can sketch out a transformation pipeline, validate that the logic is correct against live data, and then port it to a proper stream processor later with confidence. The formula logic translates fairly directly to code, and you can hand the workbook to a domain expert and say "is this right?" without teaching them a programming language.

## What this is absolutely not good for

This is clearly not a replacement for Kafka Streams or Flink, and if you try to use it as one you will have a bad time.

Excel has no persistent state across restarts. If the workbook closes, the window buffer is gone. There are no delivery guarantees; if Excel is slow to recalculate, ticks pile up in the NATS subscription and eventually get dropped or delayed. The calculation engine is single-process, running on _someone's PC_. Error handling amounts to `#VALUE!` in a cell.

But for an operational monitor or a prototype, none of that matters much. And there's something deeply satisfying about watching a spreadsheet consume a live message stream, crunch numbers, and publish results back out. It shouldn't work this well. But it does.

The add-in is [on GitHub](https://github.com/AlexJReid/zigxll-connectors-nats). [Pre-built, signed XLLs](https://github.com/AlexJReid/zigxll-connectors-nats/releases) are available if you'd rather not build from source. The [example workbook](fx_monitor.xlsx) used in this post is also available to download.

If you've any questions, [give me a shout](mailto:alex@xllify.com) or find me on [X](https://x.com/xllify) or [LinkedIn](https://linkedin.com/in/alexjreid).
