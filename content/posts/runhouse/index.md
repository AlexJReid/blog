+++ 
draft = false
date = 2020-01-23T18:14:16Z
title = "Squeezing Clickhouse into Cloud Run"
description = "First in the series of bad idea posts, I tried to squeeze Clickhouse into Cloud Run."
slug = "clickhouse-on-cloud-run" 
tags = ['bad ideas','data','clickhouse','gcp','cloud run','failures']
categories = []
externalLink = ""
series = []
+++

So here's the first in the series of my bad ideas that are nevertheless fun to think through. I am __not__ suggesting you actually do this. Really, I'm not. Serverless data technologies already exist.

{{< tweet 1220369839329628160 >}}

## The idea

I really like [Clickhouse](https://clickhouse.yandex). Compared with the expanse of complex software in the data space, it's refreshing to run a single process which just works. It's very fast and versatile.

Running it on [Cloud Run](https://cloud.google.com/run/) is a bad idea. Cloud Run is for stateless things like APIs and _embarrassingly parallel_ tasks that pull in data from elsewhere. 

But... well... what if the data being stored/queried is immutable so state is fixed?

## How could that possibly be useful?
- Maybe you have a comparatively small dataset (or your data has natural partitions of reasonable size, such as multi-tenant SaaS) that don't need to update frequently. For instance, the user is happy to look at yesterday's usage, or it is some historical dataset about oil production in 1983. These could be extracted to a snapshot.
- You want to allow arbitrary queries on that snapshot (most likely slice and dice aggregations with small result sets)
- Perhaps that small dataset is read heavy and might need to scale up, Cloud Run will in theory handle this by spinng up more _replica_ containers, each _containing_ of the same fixed dataset

## How I think it could work
- Extend the `yandex/clickhouse` image with some ready-to-roll data (I used the ontime dataset) or consider adding a startup script that will pull the data in from some storage service
- Push this image and run it on Cloud Run
- Access Clickhouse through HTTP

## Did it work?
Hilariously, it started up and answered _some_ queries. And then the wheel fell off and rolled away.

Firstly I prepared some data to stamp into the Clickhouse image. I used a single year (2019) of the ontime dataset and followed the instructions in [ontime](https://clickhouse.yandex/docs/en/getting_started/example_datasets/ontime/) example. In a local `yandex/clickhouse-server` container I opened a `bash` session and read the CSV into Clickhouse with
```
cat ontime.csv | sed 's/\.00//g' | clickhouse-client -query="INSERT INTO ontime FORMAT CSVWithNames"
```
I then stopped the clickhouse server process and copied the `data` and `metadata` out of the container's `/var/lib/clickhouse`. 

These were added to _data layer_ extending the base Clickhouse image.
```
FROM yandex/clickhouse-server

RUN mkdir -p /var/lib/clickhouse/data/default
RUN mkdir -p /var/lib/clickhouse/metadata/default
ADD default /var/lib/clickhouse/data/default/
ADD ontime.sql /var/lib/clickhouse/metadata/default/ontime.sql

EXPOSE 8123
```
I built and pushed the image using Google Cloud Build.
```
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['build', '--tag=gcr.io/${PROJECT_ID}/runhouse', '.']

images: ['gcr.io/${PROJECT_ID}/runhouse']
```
The build was submited with
```
$ gcloud builds submit . --config=cloudbuild.yaml
Creating temporary tarball archive of 227 file(s) totalling 56.1 MiB before compression.
```
This gave me an image to run in Cloud Run. As I wasn't sure of the exact settings I might need, I used the console to create the Cloud Run service.

I set the container port to `8123` and the container 256MB of RAM. I turned concurrency down to `5`. These settings could probably have done with some more thought.

![Creating Cloud Run service](runhouse-1.png)

I pressed `CREATE` and after maybe 10-15 seconds, it was running.

![Running](runhouse-2.png)

Exciting. I tried the endpoint given to me by the Cloud Run console with curl.

```
$ curl https://runhouse-xxxxxx-ew.a.run.app
Ok.
```
OK, this was hilarious, it seemed to work.

Moving over to Postman I queried one of the system tables.

![Postman](runhouse-3.png)

Then the big moment. I tried to query the `ontime` table but the request timed out. I could see a spike in latency.

![Latency](runhouse-4.png).

Logs told me that the Clickhouse had exhausted the 256MB memory. Not a problem. I deployed a new revision of the service, this time with 1GB and a query worked, responding very quickly.

![Success](runhouse-5.png)

A `SELECT COUNT()` also worked. However when attempting to run a query with `GROUP BY` or `WHERE`, the following error was returned.

```
Code: 460, e.displayText() = DB: :ErrnoException: Failed to create thread timer, errno: 0, strerror: Success (version 20.1.2.4 (official build))
```

Looking at the [Clickhouse code](https://github.com/ClickHouse/ClickHouse/search?q=Failed+to+create+thread+timer&unscoped_q=Failed+to+create+thread+timer), it appears this relates to a `timer_create(2)` syscall in the query profiler. The excellent [Cloud Run FAQ](https://github.com/ahmetb/cloud-run-faq#which-system-calls-are-supported) has a list of supported gVisor supported syscalls and `timer_create` appears to be among them. Unfortunately the Clickhouse code doesn't appear to log the actual error from `timer_create`. I didn't have time to spend on compiling Clickhouse to explore further. Boo.

> Some system calls and arguments are not currently supported, as are some parts of the /proc and /sys filesystems. As a result, not all applications will run inside gVisor, but many will run just fine ...
-- https://cloud.google.com/blog/products/gcp/open-sourcing-gvisor-a-sandboxed-container-runtime

I figured it _might_ have been memory related, but even with a 2GB memory allocation, the error remained. The next port of call would have been to try running Clickhouse in a gVisor environment outside of Cloud Run. I pulled the image into my [Cloud Shell](https://cloud.google.com/shell/) and it worked as expected, but this is a small VM so no gVisor? For now, game over.

## Why I thought the idea was interesting
- Clickhouse speaks HTTP anyway so will just work on Cloud Run
- It's very fast even with modest hardware and isn't a big install, it's a single binary. There's a ready made Docker image
- Given some tuning of the default configuration (especially around memory usage, caching and logging) it might work acceptably
- Dataset is immutable so no background processes (merging of data) to worry about

## Why Not
- Well, it doesn't work...
- Clickhouse is meant for far, far larger amounts of data than what can fit into a Cloud Run RAM disk (2GB on the most expensive type, after any overheads so more like 1.5GB?)
- __SQLite plus an API similar to Clickhouse would possibly meet the original, possibly tenuous _why_ goals__
- You would need to rebuild the image for new data (although you could pull it in from GCS/S3 on start)
- Data volume/image size might make the service take a long time to start on demand
- Clickhouse probably wasn't designed to be robbed of _all_ CPU when not serving an HTTP request (I believe this is how Cloud Run works)
- The API exposed over HTTP speaks SQL, some people get offended by that
- Probably a niche use case which could be better met in a more conventional way
- Serverless data tech already exists! (Athena, Aurora Serverless, BigQuery....)

## Conclusion
As with a lot of bad ideas, there can be a small grain of sanity. The approach of mastering a _data image_ as an EBS snapshot does work well with Clickhouse and a read-only dataset, in fact I've done it in the past with boring old EC2 and an ASG.

It was good to learn more about gVisor and remember some C++ by reading through the Clickhouse code. Not a completely wasted hour or two.

[Discuss on Twitter](https://twitter.com/search?q=mybranch.dev%2Fposts%2Fclickhouse-on-cloud-run)