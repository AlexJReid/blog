+++ 
draft = false
date = 2021-10-27T10:03:12Z
title = "DynamoDB pagination with page numbers in URLs"
description = "For SEO reasons, we might want to use page numbers in URLs. This post discusses how this is possible with DynamoDB and a secondary store."
slug = "dynamodb-page-numbers" 
tags = ['dynamodb', 'pagination', 'redis', 'zset', 'sqlite', 'aws', 'paging', 'greatest-hits']
categories = []
author = "Alex Reid"
externalLink = ""
series = []
+++

Back when we all used SQL databases, it was common to paginate through large result sets by appending `LIMIT offset, rows per page` to a `SELECT` query. Depending on the schema, data volume and database engine, this was [inefficient to varying degrees](https://tusharsharma.dev/posts/api-pagination-the-right-way). On smaller result sets and with the right indexes, it was... posssibly OK.

Databases like DynamoDB prevent this inefficiency by handling pagination differently. You can page through a pre-sorted table by selecting a partition and optionally a range within the sort key. After DynamoDB has returned a page of results and there are more to follow, it provides you with `LastEvaluatedKey` which you can pass to the next iteration of the query as `ExclusiveStartKey` in order to get the next page.

Random access to page n is not possible unless you know the keys that coincide with a page break. You've got to fetch the pages in order. Users cannot jump to page 292 or only show the last page. This is entirely acceptable in many cases as modern user interfaces often provide _infinite scrolling_ or a _show next 20_ link. 

As the `ExclusiveStartKey` is embedded into a URL, this means that this _next link_ is not stable. If the table changes, the link to retrieve page `2` changes. If the results are scanned in reverse (for instance, most recent first) the next link will change every time a new record is added. This generates a lot of URLs, which, although I am not an expert, can [hinder SEO efforts](https://www.portent.com/blog/seo/pagination-tunnels-experiment-click-depth.htm) on public sites where effective indexing is important.

Some may also say that `?page=2` looks nicer than an encoded exclusive start key (which itself may consist of several key-value pairs, possibly as a base64-encoded structure), but this might just be vanity.

What if, for whatever reason, we wanted to bring back those old-school, things-were-better-back-in-the-old-days page numbers? 

**In this post I will detail a _duct tape_ solution that augments a DynamoDB table with Redis. It has been happily running in production for well over a year on the busiest, public facing part of a reviews site. It provides very fast pagination on a total store of half a billion entries, partitioned into sets ranging from a few hundred to several million.**

# The pattern: map exclusive start keys to a numeric index
A DynamoDB exclusive start key is just a structure containing the keys needed to _resume_ the query and grab the next n items. It is nothing more than a reference point. 

Rather than conveying it as part of the URL which is ugly and possibly leaks implementation details, we could instead store the key components needed to generate an exclusive start key from a numeric index. A `page` or `skip` query parameter would be included in the URL. A look up for _item 20_ will internally yield the keys needed to construct an exclusive start key to _skip_ results by arbitrary intervals.

The drawback of this approach is the added complexity around building, maintaining, storing and serving this numeric index of rows. To avoid a confusing user experience, it is vital that the system of record and numeric index are kept consistent. Allowing users to filter the results will invalidate any pre-calculated page numbers, so additional indexes will need to be maintained. Only low cardinality, coarse filters are likely to be feasible in order to minimize the number of page indexes that need to be built.

## Example
Our example scenario is an e-commerce site that has product pages where users can comment on a product.

The following approaches assume `comments` DynamoDB table has the string keys `PK, SK, PK2`, where `PK` is a randomly generated comment ID, `SK` is a datetime of when the comment was posted, and `PK2` is a grouping key, the SKU of a product the comment relates to. A global secondary index on `PK2, SK` is used by the application to show sets of comments, in reverse order.

| PK     | SK               | PK2 (GSI PK)     | other attributes |
|--------|------------------|------------------| ---------------- |
| abc281 | 2021-08-25 13:00 | DAFT_PUNK_TSHIRT | ...              |
| abd212 | 2021-08-25 13:30 | DAFT_PUNK_TSHIRT | ...              |
| abc912 | 2021-08-25 13:42 | DAFT_PUNK_TSHIRT | ...              |
| ccc232 | 2021-08-25 13:55 | DAFT_PUNK_TSHIRT | ...              |

### Redis sorted sets
The simplest approach is to bring out everyone's favourite swiss army knife, Redis. The partition and sort keys would be loaded into Redis sorted sets. Redis itself could be run on a managed service like AWS Elasticache.

A sorted set provides numeric index-based access to the keys (referred to as the _rank_ of a set member), which can then be used to construct an `ExclusiveStartKey` to pass to DynamoDB. As the name of the type implies, Redis maintains the ordering using a _score_ value. We will use a numeric representation of the _creation date_ as the score.

Assuming the table outlined above, we will use `PK2` as the Redis key for a sorted set, `PK` as the member and `SK` (converted to UNIX time) as the score. In other words: `ZADD <PK2> to_unixtime(<SK>) <PK>`, would be sent to Redis.

A Lambda function connected to a DynamoDB Stream off the table could issue these commands so that both stores remain in-sync. It'd also need to send `ZREM/ZADD` to handle any deletions and changes.

To get the exclusive start key for any page, the Redis command `ZREVRANGE <PK2> <start> <end> WITHSCORES` where both _start_ and _end_ is the index of the item to retrieve the keys of, would be sent to Redis. 

This will yield a list response where `0` is `<PK>` and `1` is `<SK>`. SK should be converted back to a date time string from UNIX time. This is all that is needed to construct an `ExclusiveStartKey` which can be used in a DynamoDB query.

It is possible to get the total cardinality for grouping key with `ZCARD <PK2>` which is needed to calculating the total number of pages.

Storing a large number of sorted sets with millions of members could get expensive due to how a sorted set is implemented by Redis: a map and a skip list. It is also quite annoying to have to pay for a lot of RAM for items that won't be frequently accessed.

However this may be a reasonable trade off as it is a very simple solution that is likely to have predictable, consistent high performance.

### Relational sorted sets
If you do not or cannot run Redis, sorted sets can be implemented in a relational database such as MySQL. This could use a managed service like AWS RDS in its various flavours. This approach also performed very well with `sqlite`.

The sorted sets would live in a single table with a convering index on `PK2 ASC, SK DESC`. Instead of a `ZREVRANGE` Redis command, a query like `SELECT PK, SK FROM pages WHERE PK2=? ORDER BY SK DESC LIMIT n, 1` is used. 

Despite using `LIMIT`, performance is expected to be reasonable due to the small row size. Instead of `ZCARD` a `SELECT COUNT(*) FROM pages WHERE PK2=?` query would be used, but it would be worth understanding the performance characteristics, despite an index being present.

A similar Lambda function would keep this table in-sync with the DynamoDB table.

# Conclusion
The solution works technically and solved an immediate problem without making other changes to how the site worked.

Would it be how I would do things if starting from scratch? Unlikely.

Before making the leap, consider whether the approaches discussed in this post are even necessary. Is it really the best user experience to present users with _page 1 of 392716_? Must they be able to randomly jump to page 392701? Could your user interface slim down the result set more intuitively, so that using your application is less _database-y_? For example, infinite scrolling (think Twitter) is simpler for the user and seems more _native_ these days. [Guys, we're doing pagination wrong](https://hackernoon.com/guys-were-doing-pagination-wrong-f6c18a91b232) is a great post that delves into the details further.

**Perhaps this is a solved problem in some database you don't use but maybe should do. Maybe you just need to use whatever you are already using correctly.** In this age of polyglot persistence, Kafka and so on, data has become liberated and can be streamed into multiple stores, each filling a particular niche. However, this is still operational overhead. 

We don't live in a one-size-fits-all world and sometimes creative solutions cannot be avoided, particularly when dealing with older systems. Workloads have varying levels of tolerance to eventual consistency and degrees of _acceptable correctness_.

I'd be interested to hear thoughts on these approaches and if you've solved this problem in similar or entirely different way.

[Discuss on Twitter](https://twitter.com/search?q=https%3A%2F%2Falexjreid.dev%2Fposts%2Fdynamodb-numeric-pagination%2F&src=typed_query)