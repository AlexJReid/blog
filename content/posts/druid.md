+++ 
draft = false
date = 2017-01-23T10:00:00Z
title = "Exploring Druid"
description = "A beginners look at Druid, a datastore designed to ingest high volumes of events and provide fast querying."
slug = "exploring-druid" 
tags = ["data","druid","olap","clickhouse"]
categories = []
externalLink = ""
series = []
+++

Update February 2019 — this post still gets a few views. Some of the content probably still makes sense, but Druid has moved on a lot…

> **Update February 2019** — this post still gets a few views. Some of the content probably still makes sense, but Druid has moved on a lot. [Managed services, SQL support, BI tools and so on](https://imply.io/).

> I confess that I did not get as far as using Druid in production as (typically) project requirements changed.

> If you are looking into Druid, you might **also** want to look into [Elasticsearch](https://www.elastic.co/) and/or [Clickhouse](https://clickhouse.yandex). Although a totally different proposition, Kafka Streams with interactive queries might also be a plausible approach if the aggregations you require are known up-front.

The big data technology space is vibrant but crowded. There is a plethora of technologies, often appearing to be in competition with each other. There are several excellent SQL-on-Hadoop projects, for instance. Spark SQL? Presto? Drill? Good old Hive?

Choice really is a great thing to have, but can lead to _experimentation paralysis_. Nobody wants to be seen as a technology butterfly, flitting from one niche technology to the next. Occasionally though, there is a particularly dominant problem that warrants deep exploration into dedicated technologies.

**One such problem is ingestion and interactive querying on streaming event data.**

Systems emit _events:_ **they**  **are event producers.** Web servers, applications, mobile devices, laptops and IoT sensors are all systems that produce events. **An event is a record of something that happened at a certain time.** Events are immutable — no matter what the future holds, the event **happened** and will not change. Event producers accumulate a sequence of these events in a log, which is often shipped or streamed to a centralised store for long term storage and analysis.

Analysing raw event logs needs additional tooling, as at an atomic level a single event doesn’t tell you much. You could load these events into a MySQL table and run aggregation queries. That’d be fine for a moderate number of events. However, there might be value in storing the last year’s events to draw comparisons and spot trends over time. Scaling to many billions of events could become costly — your queries will start to slow down and you might need to index the table heavily, or start materialising views to achieve acceptable performance, which could slow ingestion and increase latency. Relational databases are versatile tools, but generally have to support data integrity, locking and updates to records. Append-only event stores don’t have, or need, this complexity.

If your requirements can be met by MySQL boxes with plenty of RAM, SSDs and some of your time to tune things, there’s absolutely nothing wrong with that. Go home early and have a nice [gin](https://www.amazon.co.uk/Brecon-Special-Reserve-Gin-70/dp/B00CJBB64C) and tonic.

But perhaps you have exhausted that option. Sometimes you have to pick one to evaluate in-depth and roll with it.

Druid is a fairly mature project, [in use by some companies you have actually heard of](http://druid.io/druid-powered.html). **It is a data store designed to ingest billions of events and allow low latency querying.** It capitalises upon the elasticity and extremely low price point of S3 for deep storage and [high-memory EC2 spot instances](https://aws.amazon.com/ec2/spot/pricing/) for compute. Different aspects of the system can be scaled horizontally to fit your usage patterns.

Druid is not something you can just _yum install_ and forget about. There’s a cognitive investment. Coordinators. Brokers. Hadoop. Indexing Service. Deep Storage. Realtime nodes. Historical nodes. Firehoses. Tranquility. Memory-mapped segments. Off-heap memory. Intermediate buffer sizes. Overlords. Peons. MiddleManagers. JVM tuning options. Do we have to ingest via Kafka? RabbitMQ? Is it simpler to just load JSON micro batches from S3? Where does ZooKeeper fit? What kind of EC2 instance type is best for each type of node? How many of each type of node are needed?

There’s no answer to those questions other than “it depends”. You need to [understand the architecture](http://static.druid.io/docs/druid.pdf).

### 50,000 foot view

The [creators sum it up well:](http://druid.io/druid.html)

> Druid is an open-source analytics data store designed for business intelligence ([OLAP](http://en.wikipedia.org/wiki/Online_analytical_processing)) queries on **event data.** Druid provides low latency (real-time) data ingestion, flexible data exploration, and fast data aggregation. Existing Druid deployments have scaled to trillions of events and petabytes of data. Druid is most commonly used to power user-facing analytic applications.

Druid lets us group events by a time granularity. For instance, we might want a count of how many users logged into an application every minute, hour, day and so on over a given date/time window.

To answer this question, Druid must ingest _user logged in_ events, with additional data such as _user agent_ (web browser) and _country_. To provide the _country_ value, your ingestion pipeline might enrich the raw event before Druid receives it — in this case, perhaps with a geo lookup from the IP address, or simply by looking up the user’s country from another store.

We decide that we’re only interested in storing values at a minute granularity so we tell Druid this. Rolling up at the point of ingestion saves space and reduces query time. We can still roll up further when we query the data.

After some events have been ingested, we can now answer the _how many users logged in_ question. However, requirements have grown — now we also want to know what the most popular web browsers are within our app. This is easily achievable by extending the query to split on the _user agent_ dimension. The final requirement is to see the top _countries_ we’ve seen the most logins from. This is just another query, splitting on the _country_ dimension.

With a narrow date/time range specified, these queries would be well suited to powering _live_ dashboards shown on big TVs in offices. With a wider date range and reduced granularity, these output of these queries could be used within a monthly report.

Druid can help make this (and more) happen, at significant scale.

A less flexible batch system could be scheduled to run queries on the raw event data and store the results in an indexed view for users to access. However, we would need to know, in advance, what the aggregations look like in order to construct the batch job. We might then be left with a large number of materialised views that might be never be accessed.

**Druid provides fast _and_ flexible access to event data.** Queries don’t need to be thought of in advance. It is feasible for end users to experiment with what-if scenarios. Streaming events are immediately reflected in queries — you don’t have to wait for the next batch job to run for the last hour’s data to become visible. **These attributes make Druid well-suited to powering user facing applications, such as dashboards or interactive exploration tools.**

But how does it work?

### 10,000 foot view

Druid stores ingested events in an [optimised format](http://druid.io/docs/latest/design/segments.html). Files in this format are referred to as segments. A segment contains events for a date/time window. Segments are created by the indexing service and are written to deep storage, commonly S3 or HDFS. Nodes are dynamically assigned a range of segments for which they are responsible for serving. When assignment happens, a node downloads the segments from S3, stores the segment files locally and memory-maps them. This means that nodes can serve more data than they can fit into RAM, relying on the OS to page data in and out as needed. Naturally, this has a performance trade-off and implications for EBS-backed EC2 instances — instances with instance storage are preferable (i.e. r3.xlarge might be a better choice than a r4.xlarge if mmap is being relied upon).

For high availability and the ability to scale horizontally, there are several types of node that each play a different role.

This means you can scale where you need to, and use hardware that suits the node’s duties. You are free to run these on dedicated machines, or, if your use case permits, have a node perform many duties by simply running several JVM processes. ZooKeeper is used for coordination and management of the cluster state including leader election and task management.

To issue a query, you perform an HTTP POST containing a [query specification](http://druid.io/docs/0.9.2/querying/querying.html) JSON document to a [**broker**](http://druid.io/docs/0.9.2/design/broker.html) node. This node knows which [**historical**](http://druid.io/docs/0.9.2/design/historical.html) nodes to pass the query to. Historical nodes are the _data_ nodes discussed earlier — they have local copies of the data _segments_ they are responsible for servicing, assigned by a [**coordinator**](http://druid.io/docs/0.9.2/design/coordinator.html) node. Each historical node returns its results to the broker, which merges the results together and returns them to the caller as a single JSON response. To reduce latency, the broker implements a cache so that future queries can be answered without needing to consult historical nodes.

A gateway or load balancer would commonly be placed in front of the Druid broker, letting your application consume a gateway API to abstract Druid implementation details. This gateway could be implemented in any language, or make use of the [AWS API Gateway](https://aws.amazon.com/api-gateway/). There is also integration with exploration tools such as [Pivot](http://pivot.imply.io/), [Superset](https://github.com/airbnb/superset) and a plug-in for [Grafana](http://grafana.org/).

### So far, so good

Whenever I see a technology that looks interesting, I attempt to understand it at a high level, often with a weekend project. I then consider what the overhead of running the said technology in production would be, and consider whether there will be return on that investment. In other words, “it is worth it?”

Taking a Druid weekend project into production is no doubt a big undertaking. When embarking on a new development, it’s nearly always easier to naively start a project with a clean code base. However, this honeymoon period seldom lasts, as demands placed on the miniature solution will inevitably snowball.

**Investing time in a  proven foundation** is clearly a sensible choice — and has the potential to be a hell of a lot less expensive in the long run. The exploration continues.

_Corrections and comments are most welcome._