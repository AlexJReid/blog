+++
draft = false
date = 2026-04-24
title = "A playground for monoblok"
description = "Try out monoblok via the NATS CLI without installing anything."
slug = "monoblok-demo"
tags = ["nats","zig","pub-sub","stream-processing","monoblok","patchbay"]
categories = ["projects"]
externalLink = ""
series = []
ShowToc = false
TocOpen = false
+++

There's now a public [monoblok](/posts/monoblok/) demo server you can use with any NATS client to try it out.

It is at `nats://monoblok.rtd.pub:4222`, docs at [demo.md](https://github.com/lexvicacom/monoblok/blob/main/docs/demo.md). Grab the [`nats` CLI](https://github.com/nats-io/natscli), save the demo server as a context once, and select it so you don't have to type the URL every time:

```
nats context save monoblok-demo --server nats://monoblok.rtd.pub:4222
nats context select monoblok-demo
```

Now `nats pub` and `nats sub` go straight to the public demo server.

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

The demo rules live in the repo at [`examples/demo.edn`](https://github.com/lexvicacom/monoblok/blob/main/examples/demo.edn). The idea is to give one compact example of every primitive family so a reader hits all of them in a single sitting: `squelch` for value-dedup, `deadband` for "ignore small wobbles", `moving-avg` for smoothing, `delta` for per-tick change, `transition` for boolean edge detection, `rising-edge` for one-shot crossings, and `hold-off` for time-based rate limiting. The [demo.md](https://github.com/lexvicacom/monoblok/blob/main/docs/demo.md) doc has the full subject map and per-rule walkthroughs.

## The LVC, independent of any rule

A small but mighty thing that separates monoblok from a vanilla broker, and it works independently of any patchbay rule: every subject has a last-value cache. Subscribe to `$LVC.demo.sensors.temp` and you get the most recent cached value immediately, then live updates.

```
# Publish a value, then walk away.
nats pub demo.sensors.temp 23.5

# Later, subscribe. A normal SUB would see nothing until the next publish.
nats sub '$LVC.demo.sensors.temp'
# -> prints "23.5" immediately
```

(Single-quote any subject starting with `$` so your shell doesn't try to expand it.)

On the demo server you can watch this across any subject someone else has ever published to: subscribe to `$LVC.demo.>` and you get a snapshot of whatever's lingering in the cache, then the live stream. Useful for dashboards, restarted consumers, curious late joiners. No JetStream, no external KV store, just the broker remembering the last thing it saw. Caveat: 

It pairs particularly well with the conditioning rules: a subscriber to `$LVC.demo.sensors.temp.stable` gets the most recent *rule-produced* value on connect, not the raw input. Nice side effect.

## Bridge is on too

The demo server now has the [outbound bridge](/posts/monoblok/#nats-bridge) wired up, so you can see the export side of the story without standing up two brokers yourself. The config at the bottom of [`examples/demo.edn`](https://github.com/lexvicacom/monoblok/blob/main/examples/demo.edn) exports just two subject filters:

```
(bridge
   :servers  ("nats://127.0.0.1:4223")
   :name     "monoblok-prod-1"
   :export   ("demo.sensors.*.spike" "demo.alerts.>"))
```

Everything else - the raw `demo.sensors.*` firehose, the smoothed and deltaed derivatives, the `$LVC` and `$STATS` trees - stays local to the demo broker. Only the rising-edge spikes and the alert mirror cross over. That's the pattern from the [massive post](/posts/monoblok-massive/): a noisy input stream gets conditioned down to a few high-signal subjects, and only those get forwarded onward.

The downstream broker is reachable at `nats://monoblok.rtd.pub:4223`, so you can subscribe there and watch the bridged subjects arrive:

```
# Terminal A: subscribe on the downstream broker (port 4223)
nats sub --server nats://monoblok.rtd.pub:4223 'demo.>'

# Terminal B: publish to the demo broker (port 4222)
nats pub demo.sensors.temp 10
nats pub demo.sensors.temp 60   # crosses 50 -> rising-edge "spike"
nats pub demo.log.app "alert: disk full"
```

Terminal A only sees `demo.sensors.temp.spike` and `demo.alerts` - the two filters in the export list. Publish anything else and it stays on `:4222`.

## Boring mechanical notes

The demo server is a single static binary on a 2-core VPS. The repo has ARM and x86 Linux builds on the [releases page](https://github.com/lexvicacom/monoblok/releases). The demo is running on a Hetzner CAX11 ARM server - less than £5/mo!

There's a read-only `$STATS.>` tree too, if you want to watch the rule-level counters update once a minute:

```
nats sub '$STATS.>'
```

Each rule publishes `emitted` and `suppressed` totals, so you can confirm a gate is actually firing (or not). Handy for debugging your own patchbay on a local server; mildly voyeuristic on a public one.

## Try it

Reading a DSL is not the same as running it. If you've got the `nats` CLI handy, have a play and let me know what you think.

Monoblok is available for download at [github.com/lexvicacom/monoblok](https://github.com/lexvicacom/monoblok), demo server doc is [demo.md](https://github.com/lexvicacom/monoblok/blob/main/docs/demo.md), and if you want the full patchbay DSL reference there's [patchbay.md](https://github.com/lexvicacom/monoblok/blob/main/docs/patchbay.md). 
