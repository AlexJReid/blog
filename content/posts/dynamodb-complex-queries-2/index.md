+++ 
draft = false
date = 2020-11-20T00:42:00Z
title = "Efficient NoSQL filtering and pagination with DynamoDB - part 2"
description = "An exploration of using data duplication to implement an efficient paginated and filterable product comments system on DynamoDB."
slug = "dynamodb-efficient-filtering-more-gsis"
tags = ['nosqlcommments','dynamodb']
categories = []
externalLink = ""
series = []
+++

In the [previous post](/posts/dynamodb-efficient-filtering/), a paginated and filtered data model representing product comments was demonstrated. It was not a perfect solution as large number of redundant items were _manually_ created by our code. The number of permutations would increase dramatically if the queries got even slightly more complicated.

Although this isn't a bad trade off if write volume and is low queries are unlikely to get more complex, we should iterate to see if we can do better. 

> When working with DynamoDB it is better to directly address known access patterns instead of trying to build something overly generic and reusable. 

Previously, we had to write code and use DynamoDB Streams to write duplicate entries. DynamoDB has built-in functionality that can achieve more or less the same thing: global secondary indexes.

In addition there was a desire to keep the client program simple and get an answer from a single request to DynamoDB. If we relax that possibly misguided notion and allow ourselves to issue multiple queries in parallel, gathering and processing the small amount of returned data within our client, perhaps we can end up with an more efficient model.

Let's apply both of these approaches and see what happens.

## Access patterns

Here is a recap of the access patterns.

- AP1: Show all comments for a product, most recent first
- AP2: Filter by a single language
- AP3: Filter by any combination of ratings from 1-5
- AP4: Show an individual comment
- AP5: Delete a comment
- AP6: Paginate through comments

## Table design

> Due to space constraints, not all non-indexed item attributes such as the comment title, text and username are not shown on the below diagrams. `language` and `rating` are shown to demonstrate non-key attributes being projected into GSIs.

### Table

The below table contains three comments for product `42`. To create a comment, a single item is written to the table with the keys shown.

![Table view](comments2.png)

That's a lot more than key attributes than last time! This is because items need to contain a key for each of the indexes they're going to appear in. We reuse `GSISK` across all of the other indexes as it stores the creation date of the comment.

Only a subset of attributes from the table are projected to save space and reduce query costs. This is shown in the following diagrams.

We form the partition key with the pattern `PRODUCT#<identifier>/<projected filter 1>/<projected filter 2>` and use the sort key to ensure correct ordering. As seen above, we need to use slightly different partition keys to support a range of queries. Discussion around the keys used in each GSI is detailed in the following sections.

### GSI: byLangAndRating

![GSI: byLangAndRating](GSI_comments2_byLangAndRating.png)

The partition key contains both the product identifier and comment language. The date, as a sortable string, is used as the sort key.

This index is suitable for getting all comments for a single rating and single language. Only a subset of attributes from the table are projected to save space and reduce query costs.

### GSI: byLang

![GSI: byLang](GSI_comments2_byLang.png)

The partition key contains just the comment language. The creation date (stored in `GSISK`) is used as the sort key.

This index is suitable for getting all comments for a given language, regardless of rating. This is the default state when a user visits each product page, so will see the most traffic.

### GSI: byRating

![GSI: byRating](GSI_comments2_byRating.png)

The partition key contains just the comment rating. The creation date (stored in `GSISK`) is used as the sort key.

This index is suitable for getting all comments for a given rating, regardless of language.

### GSI: all

![GSI: all](GSI_comments2_all.png)

The partition key contains just the product identifier. The creation date (stored in `GSISK`) is used as the sort key.
As its name would imply, this index is suitable for getting all comments of any language and any rating.

## Queries

Let's try it out. All queries should have `ScanIndexForward` set to `false` in order to retrieve the most recent comments first, and a `Limit` of `20`.

### AP1: Show all comments for a product, most recent first

- Query on `all`
    - SK = `PRODUCT#42`

### AP2: filter by a single language

- Query on `byLang`
    - GSIPK2 = `PRODUCT#42/en`

### AP3: Filter by any combination of ratings from 1-5

#### a. Single language

- Rating `2, 3 or 5` in language `en`
    - In parallel:
        - Query on `byLangAndRating`
            - GSIPK = `PRODUCT#42/en/2`
            - Limit = `20`
        - Query on `byLangAndRating`
            - GSIPK = `PRODUCT#42/en/3`
            - Limit = `20`
        - Query on `byLangAndRating`
            - GSIPK = `PRODUCT#42/en/5`
            - Limit = `20`
    - Gather results into single collection, sort on `GSISK` and return top N

#### b. Any language

- Rating 2
    - Query on `byRating`
        - GSIPK2 = `PRODUCT#42/2`

### AP4: Show a comment directly through its identifier

- `GetItem` on table
    - PK = `COMMENT#100001`
    - SK = `COMMENT#100001`

### AP5: Delete

- `DeleteItem` on table
    - PK = `COMMENT#100001`
    - SK = `COMMENT#100001`

### AP6: Paginate through comments

Run any of the above queries with `Limit` set to `20`. Use pagination tokens returned by DynamoDB to paginate through results. Performance will remain the same, regardless of what page is being requested.

## Query planning

Some decision logic is required to choose which access pattern should be used to resolve a query based on the incoming parameters.

For instance, given the parameters:

- `language=en`
- `rating=1 rating=2 rating=3 rating=4 rating=5`

`AP2` should be used as all ratings are specified, making the filtering a needless cost. 

`AP3a` would be used if only If `rating=2 rating=4` are required.

If no filtering is specified, `AP1` should be used.

... and so on.


This logic, along with any parallel query coordination (discussed in the next section), should be written once and distributed to users of this table either as a library or REST/gRPC API. This abstraction will allow them to work with a high level interface. As long as the contract is upheld, we can make further changes to our model without needing consumers to have to change their code.

## Parallel queries

`AP3`, when multiple ratings are required, issues queries in parallel. Modern languages make it easy to issue non-blocking calls to services, through promises or goroutines. The following code snippet demonstrates how this pattern might look.

```go

```

## Building the table

There is nothing to do here. DynamoDB will handle the replication **and** keeping the duplicated items in sync. Deleting a comment is now just a case of deleting the item from the table. This is a huge win.

## Problems

You might have noticed that we're fetching more data than we need in `AP3`. Page size is `20` comments, yet we are loading `20 * number_of_rating_values`, so for `[1, 2, 3, 4]` we would load `80` comments, throwing away `60` of them. We _overscan_ so that we can be sure we have enough records from each rating to fill up the page. 

You might think that it would be more efficient to perform a query to get `60` keys and then do a `BatchGetItem` on the top `20`. This will cost more as a `BatchGetItem` would cost one read capacity unit, allowing us to read up to `4KB`. A comment will be nowhere near that big, so this approach would be cost inefficient. As we will see in the next post, other NoSQL databases can accommodate the _multi-get_ pattern better than DynamoDB.

As discussed in [query planning](#query-planning) if ratings `[1, 2, 3, 4, 5]` were required, query planner would route this query to a more optimal index which can be read from as a single operation.

## Summary

We've successfully built a filtering solution without needing to use DynamoDB filters. We are still duplicating data but are doing so on a far smaller scale. Importantly the duplication is now fully automated and we have fewer moving parts - no need for Lambda executions and DynamoDB streams. 

The client code is now more complex. There are implementation details that users of our table should not care about, on both read and write paths. As previously stated, it is essential to encode this logic into a library or API so that consumers can work at a higher level. This kind of abstraction is recommended even if the table will never be directly accessed by other teams.

As previously stated, we cannot use this solution to meet every new access pattern as we might do with a relational database, but the model is flexible enough to possibly answer more questions efficiently, such as:

> Show the most recent positive and most recent negative comment for a product

> When was a product last commented on?

> ... and so on, let me know if you spot any!

The [NoSQL Workbench](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/workbench.html) model is [available for download](product-comments-nosql-wb-v2.json).

In a next post we look at how these patterns can be applied to another NoSQL database, Cloud Bigtable.

[Discuss on Twitter](https://twitter.com/search?q=alexjreid.dev%2Fposts%2Fdynamodb-efficient-filtering-more-gsis)
