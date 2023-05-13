+++ 
draft = false
date = 2022-12-31T21:05:54Z
title = "End of 2022"
description = "End of year thoughts - 2022 edition"
slug = "end-of-2022" 
tags = ['yearly-review']
categories = []
externalLink = ""
series = []
+++

### Some technologies I've enjoyed using this year:

- Go: still a lovely, simple to use and learn language. I took the time to understand the fairly new (?) support for generics. When I return to a Go codebase I feel right at home. The code is incredibly easy to read and the standard library is a joy. It remains my preference for writing APIs.
- [Consul](https://www.consul.io/) and [Envoy](https://www.envoyproxy.io/): when you have a lot of services to securely link together, this is a great combination. They're both incredibly flexible and I learnt a lot (Raft, xDS, HTTP, gRPC, AWS ECS...) by going deep on using them both.
- [DuckDB](https://duckdb.org/): The best way to describe this is SQLite but better at analytics. It has great integration with Python and Pandas if that's your bag. As ridiculously sized VMs become available (not to mention ever more powerful laptops), in-process OLAP can make sense. Not all data is big data. Besides, what is big data anyway? [I think we will see a lot more of this hybrid local/cloud approach to analytics over the next year](https://motherduck.com/). DuckDB can also run in the browser thanks to WASM. Download compressed, encoded data segments and slice and dice locally in a webapp!
- [Apache Arrow](https://arrow.apache.org/): A performant, in-memory data format optimised for analytics. Like DuckDB, it has very tight integration with Python. For instance you can define an Arrow table as a Python variable and run SQL queries against it with DuckDB. Of course there is far more to Arrow than that, but I predict it'll become a load bearing part of many or most of the data systems we use. Not much a prediction actually, it probably is already.
- [Dataflow](https://cloud.google.com/dataflow): A fantastic service on GCP that makes writing [Apache Beam](https://beam.apache.org/) code in Java almost worthwhile. I jest. Apache Beam has a few quirks, but writing data processing jobs with the built-in IO transforms for reading and writing is almost trivial. You know you are leveraging a robust platform where someone else has solved the hard infrastructure problems for you. It's good enough for Spotify. This year I gained a far more in-depth understanding of how windowing, triggers and watermarks work and how late data is handled.
- [BigQuery](https://cloud.google.com/bigquery): Now an old and boring technology, it never ceases to amaze me how easy it makes processing and querying huge volumes of data. Calling it an enterprise data warehouse is underselling it, in my opinion. Materialized views (finally!), BI Engine (in-memory analytics for fast response times) and the Storage Write API (stream data into tables without the limitations of the old streaming API) are incredibly interesting additions that I learnt about this year. It can be extremely expensive if used badly, so the excellent execution plan analysis tools are essential. You need partitioning and clustering.
- [Cloud Run](https://cloud.google.com/run): Serverless as it should be. You give it a container image that listens for HTTP and it handles everything else - including load balancing, auto scaling, certificates and more. The service continues to get even more awesome with larger task sizes, gRPC and ephemeral jobs. It largely keeps out of the way. [Once I ran ClickHouse on it](/posts/clickhouse-on-cloud-run/) and it worked.
- **I believe now more than ever that a lot of really useful data systems (and SaaS products) can be implemented with the GCP dream team of PubSub, Dataflow, BigQuery/Table and Cloud Run.**

### What I hope to do more of this year

- Writing and drawing boxes is a natural way for me to gather my thoughts and express ideas. I will aim to make every word count and write more one pagers than seven pagers.
- Having resisted them for a long while, I've started to express ideas through SQL notebooks. To the right audience, they're more effective than a document. GitHub renders them nicely too.
- See more of the big picture about how technical decisions affect the bottom line. Everything is a trade-off and what's technically right (or cool or cheapest to run) isn't always the way to go.
- Strive to keep proposed solutions boring and simple, but to get there, go deep on the problem. It's useful to zig zag technically as for me at least, it broadens my horizons and makes me to identify the hard problems that I don't need to solve. Going relatively low level and asking "how would I naively solve this problem myself and why would it be foolish to do so?" is a good line of self questioning. Thinking about the problem in this way allows one to ask the right questions of a higher level technology, such as a cloud service or database. "Ah, so dictionary encoding, compression, vectorization and intelligent in-memory caching is a case of me pressing this button? Deal." We build on abstractions, but it really helps to understand what is going on underneath.

I am very excited to see what 2023 brings. I wish you all the best for a productive, challenging and most of all fun time in the coming twelve months. `:)`
