+++ 
draft = false
date = 2020-11-24T13:00:00Z
title = "DynamoDB pagination when multiple queries have been combined"
description = "An exploration of using data duplication to implement an efficient paginated and filterable product comments system on DynamoDB. In this post, we tackle pagination."
slug = "dynamodb-efficient-filtering-3"
tags = ['nosql-series','dynamodb','aws','go']
categories = []
externalLink = ""
series = []
+++

This series of posts demonstrates efficient filtering and pagination with DynamoDB.

Part 1: [Duplicating data with Lambda and DynamoDB streams to support filtering](/posts/dynamodb-efficient-filtering/)

Part 2: [Using global secondary indexes and parallel queries to reduce storage footprint and write less code](/posts/dynamodb-efficient-filtering-2/)

Part 3: **How to make pagination work when the output of multiple queries have been combined**

-----

In this post we will explore how to implement pagination when the output of multiple queries have been combined to build a page of results.

## Pagination

We require a user to be able to paginate through comments that have been written for a product. If a popular product has received thousands of comments, they are only likely to want to read a few at a time.

DynamoDB supports pagination by giving us a reference point in a query response to use for the next set of results, if there are any. This is called `LastEvaluatedKey`.

When querying a GSI, as we are, this takes the form of map of: 
- GSI partition key
- GSI sort key
- table partition key
- table sort key

When querying a table, only the table partition key and sort key is returned.

The pattern is simple for many of our access patterns. If you get a `LastEvaluatedKey`, include it in the next query as `ExclusiveStartKey`.

## Parallel request pagination

In the [previous post](/posts/dynamodb-efficient-filtering-2/), access pattern `AP3` required us to display comments of multiple ratings, such as `3` or `5`. Our table design meant that we performed multiple queries and merged the results in our DynamoDB client code.

Now we have (at least) two `LastEvaluatedKey`s to choose from. How do we paginate through the combined result set? 

The grid below assumes a page size of three comments per page, and a filter of rating `3` or `5`.

![Pagination grid - actual table coming soon!](pagination.png)

`9` comments of ratings `3` or `5` are distributed, in reverse order of creation, across `3` pages. Each page request results in `2` requests to DynamoDB, one for both selected partitions in the `byRating` index. 

Rows with a grey background are discarded by the pagination process. 

Page `1` is filled up by the comments at `12:32` and `12:20` from partition `PRODUCT#42/5` the one at `12:30`. For a user to navigate to page `2`, we need to generate `LastEvaluatedKey`s for **both** of the partitions that we are reading. **We do this by generating a `LastEvaluatedKey` for the last visible item from each partition.**

```json
{"GSI3PK": "PRODUCT#42/5", "GSISK":"12:20", "PK":"COMMENT#9", "SK":"COMMENT#9"}
{"GSI3PK": "PRODUCT#42/3", "GSISK":"12:30", "PK":"COMMENT#8", "SK":"COMMENT#8"}
```

This gets wrapped into a map, keyed by the active GSI PK. 

```json
{
    "PRODUCT#42/5": {"GSI3PK": "PRODUCT#42/5", "GSISK":"12:20", "PK":"COMMENT#9", "SK":"COMMENT#9"},
    "PRODUCT#42/3": {"GSI3PK": "PRODUCT#42/3", "GSISK":"12:30", "PK":"COMMENT#8", "SK":"COMMENT#8"}
}
```

This structure is used as a combined `LastEvaluatedKey`. 

When the user clicks on the _next_ link, their request will contain this collection of two `LastEvaluatedKey`s, in addition to the other original parameters. Of course, DynamoDB won't understand it as is. 

The [query planner](/posts/dynamodb-efficient-filtering-2/#query-planning) will again determine that two parallel queries to `PRODUCT#42/5` and `PRODUCT#42/3` are needed. 

When building the queries, our client will look for a `LastEvaluatedKey` to use from the above structure. If one exists, it will extract it and include it as the `StartExclusiveKey` in the corresponding query.

## Encoding pagination context

A common way of passing the above pagination context between _pages_ is to encode it as a _cursor_ URL parameter. This is often done by compressing and base64 encoding it. You might also choose to encrypt it if you are worried about leaking details about your data model to the outside world.

## Discussion

### Discarded items

This approach discards results returned from DynamoDB that do not fit onto the page. In the below example, the item at `12:04` in partition `PRODUCT#42/3` will be discarded **twice**, before finally appearing on page `3`. Rows with a grey background are discarded by the pagination process. 

![Pagination](pagination.png)

Performing random accesses by key is an expensive approach with DynamoDB:
>... a `BatchGetItem` _charges_ a minimum of one read capacity unit (RCU) per item, allowing us to read a single item up to `4KB`. A comment will be nowhere near that big, so this approach would be wasteful. A query, on the other hand, consumes RCUs based on the actual data read, allowing us to read at least ten comments with a single RCU.

This would be a step backwards as in this example, the discarded items are unlikely to make much difference to cost, beyond a small amount of extra data transfer from DynamoDB to our client. (Client does not mean the end user, it means the program that connects to DynamoDB, such as an API running in a container.)

It might be tempting to implement a cache within the client to retain these discarded rows and display them later. This is an interesting approach, but it is likely to add complexity for little return. It starts to make our client stateful and harder to scale.

Putting DAX in between our client and DynamoDB could be a simple and effective solution to this concern, with likely performance improvements as well.

### Pagination context size

The pagination context is fairly large, weighing in at a few hundred bytes. For simplicity, we have simply exposed the structure DynamoDB expects. As there is some duplication in the JSON, it may compress well. People might also find the resulting URL ugly compared with say `?page=23`. This is debatable: if you bookmarked page `23` of the result set and visited it several days later, what are you expecting to see? There is a good chance the content is now totally different as older reviews would have been pushed down to later pages.

## Summary

In the next post we will explore some low hanging fruit: that is, some unplanned access patterns that have accidentally fallen out of our design.

## Links

- [Guys, we’re doing pagination wrong...](https://hackernoon.com/guys-were-doing-pagination-wrong-f6c18a91b232)

_Comments and corrections are welcome. I am working on making the diagrams more accessible._
