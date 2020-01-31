+++ 
draft = false
date = 2020-01-31T21:46:24Z
title = "Exploring Cloud Dataflow"
description = "This week, I have been busy exploring Cloud Dataflow - Google Cloud's managed data processing platform."
slug = "" 
tags = ["gcp","data","cloud dataflow"]
categories = []
externalLink = ""
series = []
+++

This week, I have been busy exploring [Cloud Dataflow](https://cloud.google.com/dataflow), as a small number of projects use it at work. There's a natural divide between the strong data offerings available on GCP, versus the rest of our estate which is over on AWS. BigQuery is clearly a gateway drug here - once committed to it, as we are, it becomes all too convenient to actually start processing data on GCP too.

Cloud Dataflow lets you process data at scale, without thinking about much other than the _what_. The infrastructure is handled for you. You package and submit your project and that's it. 

The original SDK for Cloud Dataflow evolved into Apache Beam, making it agnostic of Google and GCP. If you wanted to, you could run your Apache Beam pipelines on other clouds via an alternate runner, such as Apache Flink or Spark.

You define a data pipeline as a graph of transforms, starting with a source such as a database query or collection of files. The source data is collected and operated on, in parallel. Finally, you send your transformed data to a sink, such as a database table, collection of files or search index. You can do this in Java, Python or Go. Java seems to have the best support. If you know Scala, Spotify have released a library called [Scio](https://spotify.github.io/scio/index.html) as a higher level wrapper to Apache Beam.

When you build your pipeline code, the graph is evaluated, validated and optimised. One such optimisation is the _fusing_ of several nodes into one. Your code can be clear, explicit and reusable and you don't pay a cost for it at runtime. The libraries you have used are uploaded to a Cloud Storage bucket, along with the graph (serialized as a JSON document). You can then kick off your pipeline through the CLI or Console UI. In reality, a reliable scheduler should be used - Airflow has some operators for this very task.

The fundamental unit of work is a `PTransform<InputT, OutputT>`. It represents a step in your pipeline. A `PCollection` is a distributed data set that a transform operates on, element at a time. A `PTransform` returns a new `PCollection` - they're immutable, so are never modified. A `PTransform` is the input and output of each step in a pipeline. As previously stated, a pipeline starts with a _source_ which is essentially a `PTransform` that talks to some external source. At the end of the process, an output `PTransform` or _sink_, writes the data out to some storage or service.

There are many built-in transforms including connectors for many technologies. GCP and AWS are well supported out of the box. As an exercise this week I wrote a sink connector that interfaces with Salesforce's bulk API. It was not difficult, particularly as there were many established examples out there already. 

Pipelines can take a set of options, which are runtime parameters such as an initial query or a bucket to read files from. It is possible to build a pipeline as a template. This fits in nicely with CI/CD approaches - your favourite build system such as Travis, Jenkins or Cloud Build runs the Cloud Dataflow tooling to upload the artifacts to Cloud Storage. It can be run by supplying parameters, or `Options`. A nice form automatically appears in the Cloud Dataflow UI if this is your chosen way to start jobs. Airflow can also execute a pipeline from a template.

When the pipeline is running you get a great visual representation of the graph showing throughput, along with any logs emitted.

![Cloud Dataflow pipeline, from blog.papercut.com](https://blog.papercut.com/wp-content/uploads/2017/11/google-cloud-dataflow-rescue-2-768x744.png)

(The above image is from https://blog.papercut.com/google-cloud-dataflow-data-migration/)

Common operations include aggregating metrics, joining data from multiple sources and easily parallelising transformations. 

Apache Beam works in both batch mode where a `PCollection` is bounded by the files or result set, or in _unbounded_ streaming mode where new data is always arriving from a streaming source such as Kafka or Cloud PubSub. Beam offers powerful windowing functionality - for instance, to count the number of impressions a page has in a 10 minute window, split by geographic region. The count can be emitted at the close of window, or before. This is a deep topic, well beyond the scope of this document.

From my brief exposure, there are two compelling things about this library (Beam) and platform (Cloud Dataflow) that strike me.

The library allows you to compose your transforms as reusable building blocks. If you want to swap out the source or destination (or indeed any part of your pipeline), simply ensure the input and output types align. In other words, if your BigQuery sink expects a `Person` object, ensure that your Redshift sink also expects a `Person` object and if not, write an intermediate _adapter_ PTransform to map it.

The platform analyses your pipeline code and provisions infrastructure to run it effectively - this is across a number of Compute Engine VMs. As the job runs, the runner autoscales as needed. In some of the example talks I've watched this week, the presenter had 1000 machines running for 7 hours. This could get expensive, but it proves that the service is designed to deal with data processing problems of all sizes. In addition to orchestrating VMs, it can optionally offload the expensive _shuffle_ operation to a managed service, taking load of VMs.

To take advantage of all of those autoscaled VMs, you might think that you need to do some pretty complex distributed programming and coordination. Nope. Just ensure that the functions and objects you construct are serializable (so that they can be sent across a network between workers) and wrap in a `ParDo.of()`. The platform handles the distribution and coordination of work. It's pretty clever. At first the framework feels restrictive to work in, and some of the Java syntax a little weird, but by preventing you from doing things that will break (or making it difficult), the average developer stands a good chance of writing a data pipeline that scales nicely. That's the promise at least.

Some data engineers or scientists may prefer to use the Python SDK, for consistency with other work they may do. The fundamentals don't change, but it is still important to architect a solution that plays to the strengths of the platform. For instance, there is may not be much point in simply wrapping an existing Python program that uses Pandas to count, or uses the multiprocessing library, when there are more _native_ approaches on offer.

I often find it useful to write these things down to solidify my understanding and find gaps. It's a very interesting tech, which looks to be very well proven. I'm looking forward to learning more about it and actually getting some of my own pipelines into production.

Of course, this high level post is based on a few days worth of understanding, so take it with a pinch of salt and feel free to correct me!

[Discuss on Twitter](https://twitter.com/search?q=mybranch.dev%2Fposts%2Fcloud-dataflow)