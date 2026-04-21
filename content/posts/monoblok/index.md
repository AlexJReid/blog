+++
draft = false
date = 2026-04-21
title = "Monoblok: a tiny NATS-ish pub/sub server that conditions noisy feeds before they fan out"
description = "An experimental, partially NATS-compatible pub/sub daemon with last-value streams and an S-expression signal-routing and conditioning DSL, all in a single binary."
slug = "monoblok"
tags = ["nats","zig","pub-sub","stream-processing","monoblok","patchbay"]
categories = ["projects","greatest-hits"]
externalLink = ""
series = []
+++

I've recently _reified_ a pondering I've had for some time. It has come to life as [monoblok](https://github.com/lexvicacom/monoblok): a small partially NATS-compatible pub/sub daemon written in Zig. 

There are two features that set it apart: a last-value cache on every subject, and a _signal conditioning_ DSL called **patchbay**, which lets you filter, smooth and re-publish messages at the broker, before any subscriber sees them.

![monoblok](./monoblok.png)

It is an experimental toy at this point, but the ideas are quite nice.

## What's in the box

A single-threaded event loop sat on top of the excellent [libxev](https://github.com/mitchellh/libxev), so you get kqueue, io_uring, epoll or IOCP depending on where you run it. No threads, no locks, zero-copy fan-out. It speaks enough of the NATS wire protocol that an off-the-shelf NATS client can connect, `SUB` and `PUB`, which is rather convenient because it means you can drop it in alongside existing tooling without writing a client library first.

The two key features:

**The last-value cache (LVC).** Every subject has an implicit cache of its most recent value. Subscribe to `$LVC.foo.bar` and you immediately receive the cached value (if any), then the live stream of subsequent publishes. Wildcards work too. It's on by default and costs a couple of percent overhead.

**Patchbay.** A small S-expression DSL that runs at the broker, per message. You write rules of the shape `(on SUBJECT-FILTER BODY)` and the body gets evaluated when an incoming subject matches. The vocabulary borrows heavily from electronics: `squelch` to suppress duplicates, `deadband` to ignore small wobbles, `quantize` to snap to a grid, plus a family of O(1) windowed aggregates (`moving-avg`, `moving-max` and friends).

Here's the canonical example from the readme:

```clojure
(on "sensors.*"
  (-> payload-float
      (round 1)
      (squelch)
      (publish-to (subject-append "stable"))))
```

Round to 1 decimal place, drop it if it hasn't changed, republish to `sensors.<whatever>.stable`. That's the lot.

## A cool scenario

Let's wire something up that actually shows off both features together. Pretend we're running a small fleet of temperature sensors in an office building. Each sensor publishes a reading every few seconds on `temp.<floor>.<room>`. The raw stream is noisy: sensors jitter, the value wobbles by a tenth of a degree constantly, and most readings are functionally identical to the previous one. It turns out the facilities team has been buying their sensors from Temu.

What we want:

1. A clean "stable" stream that downstream dashboards can render without flickering.
2. A separate alert subject when the temperature in a room climbs above a threshold (in Celsius) sustained over a window, not just a single spike from someone leaning on the sensor.
3. Anyone opening a dashboard at any time should see the current reading immediately, without waiting for the next publish.

That last requirement is the one that usually causes pain. With a vanilla pub/sub broker you end up bolting on a key-value store, or a "snapshot on connect" service, or asking the publisher to also write to a database. Before you know it you have a Rube Goldberg contraption involving Redis, a K8s cluster, load balancers and a partridge in a pear tree. With monoblok it's a subscription pattern.

### The patchbay rules

```clojure
;; Round to 1dp, ignore wobbles under 0.3°C, republish for dashboards
(on "temp.*.*"
  (-> payload-float
      (round 1)
      (deadband 0.3)
      (publish-to (subject-append "stable"))))

;; Sustained heat alert: fire once when the 60-sample moving average
;; crosses above 28°C.
(on "temp.*.*"
  (-> (> (moving-avg 60 payload-float) 28.0)
      (rising-edge)
      (publish-to (subject-append "alert"))))

;; All-clear: fire once when the same moving average drops back below 28°C.
(on "temp.*.*"
  (-> (> (moving-avg 60 payload-float) 28.0)
      (falling-edge)
      (publish-to (subject-append "ok"))))
```

Three rules. The first turns a chatty sensor feed into a change-only stream. The second uses a windowed aggregate to avoid alerting on a single spike, and `rising-edge` makes sure it only fires once per crossing rather than on every sample while the average stays above threshold. The third is the mirror image: `falling-edge` emits an all-clear the moment the average drops back below. State is per rule, per subject, so floor 3 meeting room 2 has its own ring buffer that doesn't interfere with the kitchen on floor 1.

A subscriber wanting clean data subscribes to `temp.>.stable`. A subscriber that only cares about alerts subscribes to `temp.>.alert`, and a paired subscription on `temp.>.ok` closes the loop. Neither needs to know anything about how the conditioning happens.

### Where the LVC earns its keep

Now imagine the dashboard. It's a browser tab. Someone opens it at 14:32 and wants to see the current temperature for every room, immediately, then live updates as new readings come in.

Without an LVC you've got a chicken-and-egg situation. You can subscribe to `temp.>.stable` but you'll only see values as they change. If the kitchen has been quiet for ten minutes, the dashboard shows nothing for the kitchen until the next publish. So you build a snapshot endpoint, or a key-value bucket, or you nag the publisher to send a heartbeat.

With monoblok, the dashboard subscribes to `$LVC.temp.>.stable`. The broker delivers the most recent cached value for every matching subject right away, then transitions to live streaming. One subscription, no race condition, no separate snapshot service. Open the tab, see the current state, watch it update.

The same trick works for the alerts subject. A new on-call engineer joining mid-shift can subscribe to `$LVC.temp.>.alert` and immediately see whatever the last alert was, rather than waiting for the next one to fire.

It's quite nice how the conditioning rules and the LVC compose naturally. Rule-generated publishes participate in caching just like any other publish. The `temp.3.kitchen.stable` subject has its own LVC entry, populated by the patchbay rule, available to any late-joining subscriber. You didn't have to think about it; it just works.

## Another scenario: catching over-revs at Peter's Porsche (and Lada) Rentals

The office-sensors example is tidy but synthetic. Here's one that isn't. Peter runs a boutique rental outfit with a dozen 911s on the books. Customers pay a lot of money per day and occasionally decide the A69 is a good place to see what 9000rpm feels like. Peter would like to know about that, ideally while the car is still out, so he can have a conversation at handover rather than discovering a trashed engine three services later.

A £10 Bluetooth OBD2 dongle plugged into the diagnostic port exposes a firehose of PIDs: RPM, coolant temperature, throttle position, short and long-term fuel trims, O2 sensor voltages, intake manifold pressure, the lot. A small Python script on a Raspberry Pi tucked behind the glovebox polls the dongle over RFCOMM and publishes each reading to `car.<vin>.<pid>`.

Because monoblok compiles for ARM, the broker itself runs on the same Pi. A 5G hat gives it an uplink, so conditioned streams go straight to Peter's reporting system without ever shipping raw PIDs over the cellular link. Conditioning at the edge, analysis in the cloud.

What Peter wants:

1. A clean per-car telemetry stream for the fleet dashboard. RPM, coolant, speed, the usual.
2. An over-rev alert the moment a car holds the engine above 7500rpm for more than a couple of seconds. One brief blip past redline on a downshift is forgivable; ten seconds in the limiter is a phone call.
3. When he opens the dashboard in the morning, the current state of every car on hire, immediately. No "waiting for first reading" spinner.
4. It isn't just to spy. If the car has issues, he may want to provide pre-emptive assistance.

The raw feed is exactly the sort of thing patchbay was built for. RPM updates many times a second and wobbles constantly at a steady throttle. Coolant barely moves once the engine is warm. Publishing all of this unconditioned over a metered 5G connection is wasteful and makes the dashboard feel like it's drinking from a firehose.

```clojure
;; RPM: quantize to 50rpm buckets, drop duplicates, republish
(on "car.*.rpm"
  (-> payload-float
      (quantize 50)
      (squelch)
      (publish-to (subject-append "stable"))))

;; Coolant temp: 1°C deadband is plenty
(on "car.*.coolant"
  (-> payload-float
      (round 0)
      (deadband 1.0)
      (publish-to (subject-append "stable"))))

;; Over-rev alert: sustained above 7500rpm across a 20-sample window
(on "car.*.rpm"
  (when (> (moving-avg 20 payload-float) 7500.0)
    (publish (subject-append "alert") payload)))
```

The third rule is the one Peter cares about. A single sample over 7500 gets averaged with the surrounding values and ignored; twenty samples in a row up there, and an alert lands on `car.<vin>.rpm.alert`. State is per rule per subject, so each car has its own independent ring buffer.

The interesting part is what crosses the 5G link. Raw PIDs at full rate would chew through a SIM's data allowance for no good reason; most of it is redundant. Conditioning at the edge means the uplink only carries RPM when it moves into a new 50rpm bucket, coolant when it shifts by a degree, and over-rev alerts only when a customer is actually abusing the car. Everything else stays on the Pi. Peter's backend subscribes to `car.>.stable` and `car.>.alert` and gets a tidy, low-volume feed it can log, graph or react to without having to do its own conditioning.

The LVC earns its keep on the backend side. When Peter opens the fleet dashboard first thing, subscribing to `$LVC.car.>.stable` yields the last known value for every PID on every car without having to wait for the next change. If a logger process restarts, same deal. Useful if you're trying to work out the state a car was in at the moment something went wrong.

Once the over-rev alert is sitting on a pub/sub subject rather than buried in a log file, it becomes a seam for anything else you want to hang off it. A small service subscribed to `car.>.rpm.alert` can push a notification to Peter's phone the moment it fires. Another can look up the customer against the rental record and fire off a politely-worded SMS reminding them that the car is leased, not theirs, and that the limiter exists for a reason.

The dashcam trigger is the interesting one. Grabbing a still is time-sensitive: the moment you want captured is *now*, not thirty seconds later when the 5G link comes back after a tunnel or a patch of rural Wales with no signal. So that subscriber runs on the Pi itself, on the same broker, and pokes the dashcam over the local network the instant the alert lands on the subject. No uplink required. Because the alert payload carries the offending RPM reading, the subscriber can stamp it straight onto the image before saving: a JPEG with `8,420 RPM` burned into the corner is a lot harder to argue with at handover than a log line. The notification and SMS services live back at the office and pick up the same alert whenever the 5G link is healthy again, because the broker buffers anything that couldn't be delivered. Same subject, two very different latency and connectivity profiles, no extra plumbing.

None of these subscribers know or care about OBD2; they're plain subscribers to a clean, meaningful stream. You can add or remove them without touching the car, the Pi or the patchbay rules.

## Benchmarks

Because monoblok speaks enough of the NATS wire protocol, it was nice to benchmark it using the existing `nats bench` commands. 

Obvious caveat: `nats-server` is a mature Go codebase with a decade of production history behind it, and I ran these with an empty patchbay so they measure raw broker work only.

With that out of the way, on an M2 Air monoblok keeps up on single-publisher throughput (6.12M vs 6.18M msg/s for 64B payloads) and pulls ahead on fan-out as subscriber count grows (8.01M vs 6.70M msg/s at 50 subscribers). On a small 2-core Linux VM with the io_uring backend it's a similar story: behind on the single-subscriber fan-out case, ahead at 50 subscribers (4.51M vs 3.28M msg/s). Throughput will drop from these figures in proportion to how much your rules do, but it's a respectable starting point. This doesn't mean you should run this just yet, NATS is still the thing you'd want in production.

## Sitting in front of a real NATS cluster

Attaching monoblok to a real NATS cluster is on the cards. The idea is that monoblok would sit out at the edge as a front-end to NATSish, doing all the conditioning, deduplication and windowed aggregation work close to the publishers, then forwarding the cleaned-up streams into the main cluster for durability, replication and everything else NATS already does well. You get the patchbay primitives where they're useful without having to give up the production-grade broker behind them. Of course, if you're only experimenting, SUBscribing directly to monoblok subjects works fine.

## Why I find this interesting

The conventional logic is "broker moves bytes, application does logic." That's fine and largely correct, but there's a category of logic, signal conditioning, that you could argue belongs at the broker. It's stateless from the application's point of view, it's the same boring code reimplemented in every consumer, and it benefits enormously from being applied once, centrally, before fan-out.

Putting a small DSL at the broker for this kind of work is a nice middle ground. It's not trying to be Flink, Beam or Kafka Streams. It's just a few primitives, declared once, that turn raw sensor noise into something useful before it ever leaves the broker. The LVC then makes late-joining subscribers a non-event, which is the other thing every realtime app ends up reinventing.

It's just a toy but the applications are endless. Swap office temperature sensors for market data ticks where you want to deadband out the noise and only emit on meaningful moves, fleet telemetry from a few thousand vehicles where most of the GPS jitter is uninteresting, IoT estates with flaky sensors that need smoothing before anyone trusts the readings, gaming or trading dashboards where late-joining clients shouldn't have to wait for the next event to see current state. **Same primitives, different domain.**

There are a few loose ends to tidy up: a TTL on last-value cache entries so stale state doesn't linger forever or grow unbounded, proper structured logging, the leaf-node path mentioned earlier (potentially as an actual NATS leaf rather than a bespoke bridge) so it can plug into a real cluster cleanly, and a resilience story for when the process inevitably falls over.

The code lives at [github.com/lexvicacom/monoblok](https://github.com/lexvicacom/monoblok) and there are both x86 and ARM Linux builds ready to go on the [releases page](https://github.com/lexvicacom/monoblok/releases) if you want to skip the build step and give it a spin.

If you've thoughts or want to chat about this sort of thing, [give me a shout](mailto:alxsti3@gmail.com) or find me on [X](https://x.com/AlexJReid) or [LinkedIn](https://www.linkedin.com/in/alexjreid/).
