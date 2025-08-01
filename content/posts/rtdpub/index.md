+++ 
draft = false
date = 2025-07-03
title = "Taming real-time data in Excel with rtd.pub"
description = "A surprising amount of the world rests on spreadsheets, yet integrating real-time data with them can be challenging. This post introduces rtd.pub, a platform for easily connecting any real-time data source to Microsoft Excel."
slug = "rtdpub-hello"
tags = ["data","excel","realtime","acornsoft"]
categories = []
externalLink = ""
series = []
+++

> **[rtd.pub](https://rtd.pub) is a platform for easily connecting any real-time data source to Microsoft Excel.** You can write code in Go and Python, or simply configure pre-built open source connectors.

This is a design and approach I've been [mulling over](https://learning-notes.mistermicheels.com/mindset/hammock-driven-development/) for the past couple of months. I have now implemented it.

This, and of course spreadsheets in general, are somewhat boring. However, they're the original low code/RAD tool: in terms of bang for buck and the control they put into the hands of domain experts, nothing comes close. (No, not even some sketchy code regurgitated by a large language model - yet anyway.)

I appreciate this is all quite niche, but if it saves time and makes lives easier, why not?

### History lesson

<style>
 .image-float-left {
    float: left;
    padding-right:15px;
    max-width: 40%;
    height: auto;
 }
  .clearfix::after {
     content: "";
     display: table;
     clear: both;
 }
</style>

<div class="clearfix">
<img src="./xander-the-dragon.jpg" class="image-float-left" alt="Excel dragon">

Over the years, there have been many ways of extending Excel. The original C API (ancient, fast, hard to use - if you look closely you can see evidence that Excel was originally written in Pascal), COM, C++, VBA, C# ... all on Windows, of course.

Current versions contain a browser engine (Edge/Chromium on Windows, Safari on Mac) and expose a JavaScript SDK through it. This is technically very cool and has a lot of use cases, but unfortunately is quite slow for very fast moving data.

Needless to say, it's a bewildering array of choices in unfamiliar territory for many developers who simply want to use their language of choice, particularly for those not from a Windows background. To management, it might appear that developers are making heavy weather of _just_ displaying some numbers on a screen. Exactly how hard can it be?

In simple scenarios, not very, but to do it well, you will need to understand each approach, and which fits best for a particular use case. This is time-consuming.

As we have established, for very high velocity data, the JavaScript _bridge_ is a poor choice. The trusty old `=RTD()` function that leverages COM automation is still the best choice. But then you need to understand COM, threading and ... what language to even write your COM server in. "Hey Google, what even _is_ a COM server?"

</div>

### How does rtd.pub help?

It shields developers from the above by building in know-how, workarounds and patterns to keep code simple and domain focused. Developers can write or reuse code in any language to reliably stream values into Excel.

### How?

The solution boils down to these things:

- a gRPC protocol
- a unified pipe of data (UNIX sockets, H2) into Excel, via a _conduit_ RTD server
- plugins that implement said protocol, bringing in any data from anywhere
- a plugin _host_ that supervises plugin processes

An RTD server communicates with tiny processes called _plugins_ over UNIX sockets. The RTD server is a lightweight component that runs within Excel. By design, it delegates the interesting work to plugins. A plugin process implements a gRPC service definition and streams protobuf messages.

Plugins are started by the plugin host which supervises the process, multiplexing streams from all other plugins to efficiently pass over to Excel.

### Plugins

As plugins are so easy to write (usually in fewer than 100 lines of code, depending on language) it is easy to get results quickly. To move even more quickly, there is an SDK for Go (Python coming soon) that makes it very easy indeed. Finally, to move _even_ more quickly than that, NATS is supported out of the box. If you use [NATS](https://nats.io) already, you can hook your subjects up to Excel with a few lines of configuration. Support for additional messaging systems will be added soon.

It is also simple to integrate with external vendors. For example, I wrote a plugin to the [Polygon.io stocks websocket API](https://polygon.io/docs/websocket/stocks/overview) with their [official Go client](https://github.com/polygon-io/client-go).

{{< rawhtml >}}

<div style="padding:56.25% 0 0 0;position:relative;margin-top:1em;"><iframe src="https://player.vimeo.com/video/1095719570?h=8f8664b780&amp;badge=0&amp;autopause=0&amp;player_id=0&amp;app_id=58479" frameborder="0" allow="autoplay; fullscreen; picture-in-picture; clipboard-write; encrypted-media; web-share" style="position:absolute;top:0;left:0;width:100%;height:100%;" title="rtd.pub websocket plugin"></iframe></div><script src="https://player.vimeo.com/api/player.js"></script>{{< /rawhtml >}}

### GA soon

Pop over to [rtd.pub](https://rtd.pub) to see it in action, and [register your interest via your GitHub account](https://rtd.pub/register.html).

Give me a shout in the usual places or [email](mailto:cells@rtd.pub) if you want to arrange a demo, ask questions or are just plain curious.
