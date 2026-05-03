+++
draft = false
date = 2026-05-03
title = "tinyblok: monoblok's patchbay on an ESP32-C6: a £5 microcontroller"
description = "Running the patchbay DSL on a microcontroller. Wi-Fi, a NATS PUB, and a temperature reading."
slug = "tinyblok"
tags = ["esp32","zig","nats","monoblok","patchbay","embedded","iot"]
categories = ["projects"]
externalLink = ""
series = []
ShowToc = false
TocOpen = false
+++

[tinyblok](https://github.com/lexvicacom/tinyblok) is the obvious next question after [monoblok](/posts/monoblok/): can the patchbay run on a microcontroller and ship sensor data straight into a remote NATS cluster? The [Peter's Porsche Rentals worked example](/posts/monoblok/#a-worked-example-catching-over-revs-at-peters-porsche-rentals) put a Raspberry Pi behind the glovebox; an ESP32 is an order of magnitude cheaper and smaller. Coupled with a 4G mi-fi or the car's onboard Wi-Fi, it's a self-contained edge node that can sit on a OBD2 dongle's worth of power and still cherry-pick what crosses the mobile data connection.

![ESP32-C6 dev board, with curious assistant](board.jpg)

Right now it's an ESP32-C6 that brings up Wi-Fi, opens a TCP socket to a NATS broker, sends `CONNECT`, and publishes the on-die temperature sensor reading once a second. C owns everything that touches ESP-IDF (Wi-Fi, NVS, lwIP, the NATS client); Zig owns the sample-and-publish loop.

The patchbay introduces a new top-level form, `pump`, alongside the familiar `(on ...)` rules. A `pump` declares a source: the subject values appear on, the Zig `extern fn` that returns the next value, the value's type, and how often to poll it.

<small>

```clojure
(pump "tinyblok.heap"   :from tinyblok_free_heap    :type u32      :hz 10)
(pump "tinyblok.rssi"   :from tinyblok_wifi_rssi    :type i32      :hz 10)
(pump "tinyblok.uptime" :from tinyblok_uptime_us    :type uptime-s :hz 10)
(pump "tinyblok.temp"   :from tinyblok_read_temp_c  :type f32      :hz 1)
```

</small>

So `tinyblok_wifi_rssi` is called ten times a second and the result is published as an `i32` on `tinyblok.rssi`. From there it's the same DSL as monoblok: deadband, moving averages, rising-edge alerts.

<small>

```clojure
(on "tinyblok.heap"
  (-> payload-float
      (deadband 1024)
      (publish! (subject-append "stable"))))

(on "tinyblok.heap"
  (-> payload-float
      (moving-avg 10)
      (round 0)
      (publish! (subject-append "avg1s"))))

(on "tinyblok.heap"
  (when (< payload-float 20480)
    (-> payload (rising-edge) (publish! "tinyblok.alert.heap.low"))))

(on "tinyblok.rssi"
  (when (not (= payload-float 0))
    (-> payload-float
        (deadband 2)
        (publish! (subject-append "stable")))))

(on "tinyblok.rssi"
  (when (not (= payload-float 0))
    (-> payload-float (moving-avg :ms 5000)
        (round 0)
        (publish! (subject-append "avg5s")))))

(on "tinyblok.rssi"
  (when (and (not (= payload-float 0)) (< payload-float -75))
    (-> payload (rising-edge) (publish! "tinyblok.alert.rssi.weak"))))

(on "tinyblok.uptime"
  (-> payload-float
      (throttle :ms 60000)
      (round 0)
      (publish! (subject-append "1m"))))

(on "tinyblok.temp"
  (-> payload-float
      (moving-avg 30)
      (round 1)
      (publish! (subject-append "avg30s"))))

(on "tinyblok.temp"
  (when (> payload-float 30)
    (-> payload (rising-edge) (publish! "tinyblok.alert.temp.hot"))))
```

</small>

Below: device boot log on the left, conditioned stream on the right. TCP connect to the NATS broker at `[1840]`, first publish a tick later. From the right pane you can see only the conditioned outputs reach a subscriber: deadbanded `tinyblok.heap.stable`, `tinyblok.rssi.avg5s`, `tinyblok.heap.avg1s`. The 10 Hz raw firehose stays on-device.

![Device log on the left, monoblok subscriber on the right](monitor.png)

## Challenges so far

**More C than planned.** ESP-IDF macros don't translate: `ESP_ERROR_CHECK`, `WIFI_INIT_CONFIG_DEFAULT`, `IPSTR`/`IP2STR`, FreeRTOS event-group bits. `@cImport` chokes on most of them, and the rest you'd want to wrap by hand anyway. Faster to keep the IDF surface in C and reserve Zig for the hot path.

**The patchbay can't be ported, only re-implemented.** Monoblok walks a parsed s-expr tree at runtime with a per-message arena. On a chip with a few hundred KB of RAM that's a non-starter. So `tools/gen.py` compiles `patchbay.edn` to straight-line Zig with statically-allocated state slots ahead of build. Same DSL, two implementations; possibly something to share later, but the forms are simple enough that two backends isn't yet painful.

**The C NATS client is hand-rolled.** The obvious off-the-shelf options didn't fit. Synadia's [nats.c](https://github.com/nats-io/nats.c) is a good library on a desktop, but it pulls in pthreads, a thread pool, and TLS through linking OpenSSL, none of which is a good match in a microcontroller context where the NATS client is one of several tasks sharing 320 KB of RAM. Same story for [nats.zig](https://github.com/nats-io/nats.zig) which assumes `std.Io.Threaded` and `std.crypto.tls`, neither of which exist here either. So, a small bespoke client it is: this is the beauty of the NATS protocol: the wire format is so simple you can implement the publish-only subset in a small amount of C and have it talk to a real broker. TLS and auth is a problem for another day, but doable.

**The temperature sensor quantises to 1 °C.** Polling faster than 1 Hz just gives you duplicates. A good early reminder that on-device, the sensor is usually the bottleneck, not the code.

`tools/gen.py` runs as a CMake step before the Zig static lib is built, turning `patchbay.edn` into `main/rules.zig` automatically on every `make build`. The Zig-flavoured alternative would be a `comptime` EDN parser or Zig-based executable; instead a small Python script is boring and produces a `.zig` file you can read. Python was the right move. What's next? Doing something more interesting than forwarding temperature and Wi-Fi RSSI.

The genuinely satisfying bit: drop in a `patchbay.edn`, run `make build flash`, and it's running. From then on every time the board sees power it's on Wi-Fi, talking to the broker, and publishing conditioned data in a couple of seconds.

Experimental quality code is at [github.com/lexvicacom/tinyblok](https://github.com/lexvicacom/tinyblok); expect more than a few rough edges.

If you've thoughts, [give me a shout](mailto:alex@lexvica.com) or find me on [X](https://x.com/AlexJReid) or [LinkedIn](https://www.linkedin.com/in/alexjreid/).
