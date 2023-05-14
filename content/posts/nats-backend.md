+++ 
draft = false
date = 2023-05-14T10:00:00Z
title = "NATS as a backend"
slug = "nats-as-a-backend"
tags = ['nats', 'websocket', 'backend']
categories = []
externalLink = ""
series = []
+++

NATS has its own wire protocol and can listen on websockets. [nats.ws](https://github.com/nats-io/nats.ws) runs in browsers. This means we can directly use NATS as the backend for web clients that need to display realtime streams of data.

I have used [NATS](https://nats.io) on various projects over the years. It provides a high performance transport layer, used to connect applications and services. As it is an extremely versatile technology, [this video](https://www.youtube.com/watch?v=hjXIUPZ7ArM) is a fantastic primer.

## Why is this interesting?

We can leverage the NATS server and protocol, saving us from having to implement an ad-hoc, informally specified protocol. We can multiplex the consumption of multiple data streams, issue requests and receive responses over a single websocket. A rich auth system is there to use. It gives us a robust implementation with a lot of the hard work done for us.

## How does it work?

Security first. We do not want to expose an open NATS server and we also want to provide a boundary around what websocket clients can do. The [NATS security model](https://docs.nats.io/nats-concepts/security) is comprehensive. In short, the NATS server can read a cookie sent by the browser. This cookie contains a NATS-specific JWT that dictates what the bearer of the token can and can't do within the NATS environment it is connecting to. This signed JWT can be programatically generated and set by a token vending service, perhaps in response to a user sign-in through an IdP. NATS provides segregation of resources through [accounts](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/accounts). Websocket clients would connect to a dedicated account for the application. Data streams will originate in other accounts and be _imported_ into the websocket account. This provides an important level of isolation.

One connected, the client is free to do anything their token permits them to do within the account boundary. This could include querying values from the key-value store, subscribing to subjects, grabbing the last six hours data from a stream, and issuing requests and responses.

If using React, you can manage the NATS connection lifecycle in an application-wide context. This way, it is possible for a component to easily grab a NATS connection or know about connection status. As front end applications are asynchronous and event driven, events coming off the websocket are reacted to by the application. This might fit well with the state management libraries you're using, such as Redux. Subscriptions can also be abstracted into reusable stateful components, for example `<AwesomeRealtimeLineChart stream="data" />`.

## Example use case

Perhaps you have a set of data streams that you want to visualise within your application. Showing a graph that of values from when the page loaded is perhaps not that useful as more context might be needed. Luckily, NATS has JetStream to provide stream persistence, allowing the application to start consuming from `-PT6H`.

Maybe it is useful to show two series: the previous hour and current hour so far. This is all easy to do and no custom backend is needed. We're just using the NATS API through a client library.

Bringing in some even older, historic data might also be useful. NATS provides the ability for clients to make _requests_ to a subject that a service is listening for. The service sends a _response_ to a temporary inbox subject that the client is listening on. A service could be implemented to proxy queries to a database and write the results to an inbox subject. Large result sets can be chunked over multiple messages to request inbox.

Like the streaming use case, we have not implemented anything special in the client.

## I don't run NATS already

It is available as a [managed service](https://www.synadia.com/ngs). Helm charts are also available. It can run anywhere, even on very constrained hardware.

You could opt to run your own NATS [leaf nodes](https://docs.nats.io/running-a-nats-service/configuration/leafnodes) (or extensions) that your websocket clients connect to, within your network boundary, but farm out the work of running the main NATS cluster to the managed offering, [NGS](https://www.synadia.com/ngs). It's an incredibly flexible model. You can start small on a single node, then consider clustering and leaf nodes later.

## So why not?

There is, of course, absolutely nothing wrong with HTTP. It has a huge ecosystem around it. If you're happy to construct an API with websocket/SSE resources as a bespoke backend for your application, this is clearly the tried and tested way forward. It is the well-trodden path.

If you are not already using NATS, you will need to set this up in order to attempt this approach. This is quite simple, particularly if you are used to Kafka.

In addition, you will need to learn about NATS security and write services slightly differently to how you might have done in the past.

## It's still cool

I would contend that although this approach might seem an elaborate and somewhat exotic detour on the first glance, we are building on a proven foundation. I am certain that the NATS websocket implementation and clients are superior to something that I might cobble together with _some code off the Internet_. I haven't needed to invent some protocol. I can leverage what already works and, as requirements dictate, take advantage of more advanced NATS features to make my life even easier.

I believe this has the potential to result in a very rapid, and easy to extend development experience, whilst remaining operationally simple. It is particularly compelling if you already have a lot of data flowing through NATS. But even if you don't, you won't need to [build your own bridge](https://github.com/nats-io/nats-kafka).
