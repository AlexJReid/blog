+++ 
draft = false
date = 2023-05-14T10:00:00Z
title = "NATS as a web application backend"
slug = "nats-as-a-backend"
tags = ['nats', 'websocket', 'backend']
categories = []
externalLink = ""
series = []
+++

I have used [NATS](https://nats.io) on various projects over the years. It provides a high performance transport layer than can be used to connect applications and services. If you haven't already heard of it, [this video](https://www.youtube.com/watch?v=hjXIUPZ7ArM) is a fantastic primer.

NATS supports websocket connections. [nats.ws](https://github.com/nats-io/nats.ws) runs in browsers. This means we can directly use NATS as the backend for browser-based applications that need to display realtime streams of data.

## Why is this interesting?

We can leverage the NATS server and protocol, saving us from having to implement our own janky protocol. We can multiplex the consumption of multiple data streams, issue requests and receive responses over a single websocket. A well designed auth system is there to use. It gives us a robust implementation with a lot of the hard problems already solved.

## How does it work?

Security first. We do not want to expose an open NATS server and beyond that we also want to provide a boundary around what websocket clients can do. The [NATS security model](https://docs.nats.io/nats-concepts/security) is comprehensive. In short, the NATS server can read a cookie sent by the browser. This cookie contains a NATS-specific JWT that dictates what the bearer of the token can and can't do within the NATS environment it is connecting to.

This signed JWT can be programatically generated and set by a token vending service, perhaps in response to a user sign-in through an IdP. NATS provides segregation of resources through [accounts](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/accounts). In this model, websocket clients would connect to a dedicated _application account._ Data streams will be _exported_ from other accounts and _imported_ into the application account. This provides an important level of isolation.

Once connected, the client is then free to do anything that their token permits them to do within the account boundary. This could include querying values from a JetStream key-value store, subscribing to subjects, grabbing the last six hours data from a stream, and issuing requests.

If you are using React, the NATS connection lifecycle can be managed through an application-wide context. This makes it possible for a component to easily grab a NATS connection or stay informed about connection status. As front end applications are asynchronous and event driven, events coming off the websocket are reacted to by the application. This might fit well with any state management libraries you're using, such as Redux. Subscriptions can also be abstracted into reusable stateful components, for example `<AwesomeRealtimeLineChart stream="data" lookBack="PT5M" />`.

## Example use case

Perhaps you have a set of data streams that you want to visualise within your application. Showing a graph of values that occur after the page has loaded is perhaps not that useful. More context might be needed for the visualisation to be meaningful. Luckily, NATS has JetStream to provide stream persistence, allowing the application to start consuming from some point in the past. There is no need to query some separate store for history and then switch to the stream.

Maybe it is useful to visualise multiple series, for example, the previous hour and current hour so far. Or perhaps the same metric with different dimensions. This is all easy to do and no custom backend is needed. **We're just using the NATS API through a client library.**

Bringing in some even older, historic data might also be useful. NATS provides the ability for clients to make _requests_ to a subject that a service is listening on. The service sends a _response_ to a temporary inbox subject that the client is listening on. A backend service could be implemented to proxy queries to a database. Large result sets can be chunked over multiple messages to the request inbox. This is all supported by the NATS client, a zero byte payload is used to denote that there are no more chunks.

As a nice side effect, user experience is improved as the application can show a meaningful progress bar as chunks are received, rather than showing an indeterminate "please wait" spinner.

Like the streaming use case, we have not implemented anything special in the client to achieve this.

## I don't run NATS already

Running NATS on a small scale is quite simple, particularly if you are used to Kafka. Helm charts are also available if you are on Kubernetes. It can run anywhere, even on very constrained hardware.

Getting it running locally for experimentation is a case of downloading the `nats-server` binary and running it.

NATS is available as a [managed service](https://www.synadia.com/ngs).

A hybrid approach is also possible. You could opt to run your own NATS [leaf nodes](https://docs.nats.io/running-a-nats-service/configuration/leafnodes) (or extensions) that your websocket clients connect to, within your network boundary, but farm out the work of running your main NATS cluster to the managed offering, [NGS](https://www.synadia.com/ngs). It's an incredibly flexible model.

You can start small on a single tiny EC2 instance (or even Fargate), and then consider clustering and leaf nodes later on.

## So why not?

There is, of course, absolutely nothing wrong with HTTP. It has a huge ecosystem around it. If you're happy to construct an API with websocket/SSE resources as a bespoke backend for your application, this is clearly the well-trodden path.

As already established, if you are not already using NATS, you will need to set this up in order to attempt this approach.

In addition, you will need to learn about NATS security and write services slightly differently to how you might have done in the past.

You will need to learn the JavaScript NATS library. As alluded to above, it makes sense to contain this by embedding calls to the NATS and JetStream clients into reusable components. If you are a front end novice, you're on your own on figuring out how to integrate the NATS client with your front end library of choice.

> RAD tools like [Streamlit](https://streamlit.io/) and [Shiny](https://shiny.posit.co/) can work with NATS as a backend, however they implement their own websocket transport to update their own client running in the browser.
> For instance, your Streamlit application sits in the middle between the browser and NATS. You would interface with NATS on the server side with the [nats.py](https://github.com/nats-io/nats.py) library. This is a valid, but quite different approach to what has been proposed so far. By their nature, these tools do not produce applications that are designed to scale, but in exchange offer an extremely low-effort development experience in a single language (Python or R), often with beautiful looking results. Their wire format is far more verbose than a NATS connection.
> For internal apps with a handful of users, high server side resource consumption and significantly higher network usage might be a worthy trade-off. Many of the benefits of using NATS as a backend still apply.

## It works incredibly well

I would contend that although this approach might seem like an elaborate and somewhat exotic detour at first glance, we are building upon a proven foundation. I am certain that the NATS websocket implementation and clients are superior to something that I might cobble together with _some code off the Internet_. I haven't needed to invent some protocol. I can leverage what already works and, as requirements dictate, take advantage of more advanced NATS features that would be very challenging to implement well from scratch.

Long term, this approach will produce results quickly whilst remaining operationally simple. It is particularly compelling if you already have a lot of data flowing through NATS. Even if you don't, you won't need to [build your own bridge](https://github.com/nats-io/nats-kafka).
