+++
draft = false
date = 2026-04-24
title = "Monoblok demo: a public playground for patchbay rules"
description = "I stood up a public monoblok server at monoblok.rtd.pub so you can poke at patchbay rules with the NATS CLI without installing anything."
slug = "monoblok-demo"
tags = ["nats","zig","pub-sub","stream-processing","monoblok","patchbay"]
categories = ["projects"]
externalLink = ""
series = []
ShowToc = false
TocOpen = false
+++

![monoblok](./monoblok.png)

A follow-up to [the monoblok post](/posts/monoblok/). There's now a public server you can talk to over the standard NATS wire protocol, because reading about a pub/sub DSL is fine but actually typing at one is much better.

Server is `nats://monoblok.rtd.pub:4222`, docs at [DEMO.md](https://github.com/lexvicacom/monoblok/blob/main/DEMO.md). Grab the [`nats` CLI](https://github.com/nats-io/natscli), save the demo server as a context once, and select it so you don't have to type the URL every time:

```
nats context save monoblok-demo --server nats://monoblok.rtd.pub:4222
nats context select monoblok-demo
```

Now `nats pub` and `nats sub` go straight to the public server.

## The 30-second tour

```
# One terminal
nats sub 'demo.>'

# Another
nats pub demo.sensors.temp 25.3
nats pub demo.sensors.temp 25.34
nats pub demo.sensors.temp 25.38
```

The first terminal prints a handful of derived subjects: `demo.sensors.temp.stable`, `.delta`, `.smoothed`, `.delta-abs`. Each one comes from a different patchbay rule applied to the input. The subscriber publishing the raw readings doesn't know any of those rules exist.

The demo rules live in the repo at [`examples/demo.edn`](https://github.com/lexvicacom/monoblok/blob/main/examples/demo.edn). The idea is to give one compact example of every primitive family so a reader hits all of them in a single sitting: `squelch` for value-dedup, `deadband` for "ignore small wobbles", `moving-avg` for smoothing, `delta` for per-tick change, `transition` for boolean edge detection, `rising-edge` for one-shot crossings, and `hold-off` for time-based rate limiting. The [DEMO.md](https://github.com/lexvicacom/monoblok/blob/main/DEMO.md) doc has the full subject map and per-rule walkthroughs.

## The LVC, independent of any rule

A small but mighty thing that separates monoblok from a vanilla broker, and it works independently of any patchbay rule: every subject has a last-value cache. Subscribe to `$LVC.demo.sensors.temp` and you get the most recent cached value immediately, then live updates.

```
# Publish a value, then walk away.
nats pub demo.sensors.temp 23.5

# Later, subscribe. A normal SUB would see nothing until the next publish.
nats sub '$LVC.demo.sensors.temp'
# -> prints "23.5" immediately
```

(Single-quote any subject starting with `$` so the shell doesn't try to expand it.)

On the demo server you can watch this across any subject someone else has ever published to: subscribe to `$LVC.demo.>` and you get a snapshot of whatever's lingering in the cache, then the live stream. Useful for dashboards, restarted consumers, curious late joiners. No JetStream, no external KV store, just the broker remembering the last thing it saw. Caveat: the LVC is in-memory today and doesn't survive a server restart; on-disk persistence is on the list.

It pairs particularly well with the conditioning rules: a subscriber to `$LVC.demo.sensors.temp.stable` gets the most recent *rule-produced* value on connect, not the raw input. That fallout-for-free composition is the bit I find most satisfying about how this all hangs together.

## Boring mechanical notes

Everything from the original post still applies: single-threaded libxev event loop, core NATS wire protocol, zero-copy fan-out, runs anywhere Zig targets. The demo server is a single static binary on a 2-core VPS, so don't stress-test it in anger. If it dies I'll notice eventually. If you want guaranteed uptime, the repo has ARM and x86 Linux builds on the [releases page](https://github.com/lexvicacom/monoblok/releases); it starts on sub-£5 hardware.

There's a read-only `$STATS.>` tree too, if you want to watch the rule-level counters update once a minute:

```
nats sub '$STATS.>'
```

Each rule publishes `emitted` and `suppressed` totals, so you can confirm a gate is actually firing (or not). Handy for debugging your own patchbay on a local server; mildly voyeuristic on a public one.

## Try it

The point of all this is lowering the barrier. Reading a DSL is not the same as running it. If you've got the `nats` CLI handy, pointing it at the public server is probably a better use of the next thirty seconds than reading further.

Repo is [github.com/lexvicacom/monoblok](https://github.com/lexvicacom/monoblok), demo doc is [DEMO.md](https://github.com/lexvicacom/monoblok/blob/main/DEMO.md), and if you want the full primitive reference there's [PATCHBAY.md](https://github.com/lexvicacom/monoblok/blob/main/PATCHBAY.md). Shout if it breaks.
