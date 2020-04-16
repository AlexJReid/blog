+++ 
draft = false
date = 2017-01-23T10:00:00Z
title = "Running Druid on Cloud Dataproc"
description = "A very easy way of running Druid on GCP Cloud Dataproc"
slug = "exploring-druid" 
tags = ["data","druid","olap","clickhouse"]
categories = []
externalLink = ""
series = []
+++

Today I discovered a ridiculously easy way to run a [Druid](https://druid.io) cluster on GCP is to flick a switch when creating a Cloud Dataproc cluster. It's a recent version too.

![Component](doc/component.png)

Great, right? (If you don't mind using something labelled _alpha_ by Google.)

## Problems
There is literally no documentation other than the page I stumbled across: [Cloud Dataproc Druid Component](https://cloud.google.com/dataproc/docs/concepts/components/druid).

After running up a small cluster, I noticed the following issues:
- the [Druid router](https://druid.apache.org/docs/latest/design/router.html) process contains a great console which makes one-off ingests easy to achieve. Unfortunately, this is not enabled
- the `druid-google-extensions` extension is not included, meaning the cluster cannot load files from GCS

## Solution
Luckily, Cloud Dataproc provides a mechanism for customising nodes. These are nothing more than scripts that each node pulls from GCS on boot. I created two scripts to rectify the above.

- `enable-druid-router.sh` creates a config file and systemd unit for the router process; this means the master node will listen on port 8888
- `enable-google-extensions.sh` appends a different `druid.extensions.loadList` line in the common properties file, enabling GCP ingest support

## Running it
Anyone who is famiilar with Druid will know that it can take a bit of effort to configure well. It is quite funny to see this reduced to the following.

```
gcloud dataproc clusters create druid-example \
    --region europe-west1 \
    --subnet default \
    --zone europe-west1-b \
    --master-machine-type n1-standard-4 \
    --master-boot-disk-size 500 \
    --num-workers 2 \
    --worker-machine-type n1-standard-4 \
    --worker-boot-disk-size 500 \
    --num-preemptible-workers 2 \
    --image-version 1.5-debian10 \
    --optional-components DRUID,ZOOKEEPER \
    --tags druid \
    --project myproject \
    --initialization-actions 'gs://alex-dataproc/enable-druid-router.sh'
```

## Thoughts
This component is labelled alpha so could in theory vanish from Dataproc at any time. It isn't really doing anything clever, it just means that Druid is part of the standard image for all Dataproc machines.

The above initialisation actions are brittle because I'm assuming Google won't change where they install Druid.

By default, it uses storage on the cluster (HDFS) rather than GCS or S3 for deep storage. This could be changed with yet another initialisation action. See earlier previous point about making adjustments in this way.

One of the nice things about Druid is the ability to scale out the various processes as required. This approach is opinionated: the master(s) run the query, broker, coordinator and overlord processes (as well as Zookeeper), the worker nodes serve as historical, middle manager and indexing processes. That said, there still might be a lot of value in this simple setup.

It'd be interesting to see how if Google evolve this component in the future.