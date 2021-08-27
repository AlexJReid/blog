+++ 
draft = false
date = 2021-08-27T10:03:12Z
title = "Numeric pagination with DynamoDB"
slug = "dynamodb-numeric-pagination" 
tags = ['dynamodb', 'pagination', 'numbered-pagination', 'seo']
categories = []
externalLink = ""
series = []
+++

Back when we all used SQL databases, it was common to paginate through large result sets by appending `LIMIT offset, rows per page` to a `SELECT` query. Depending on the schema, data volume and database engine, this was [inefficient to varying degrees](https://tusharsharma.dev/posts/api-pagination-the-right-way). On smaller result sets and with the right indexes, it was... posssibly OK.

Databases like DynamoDB prevent this inefficiency by handling pagination differently. You can page through a pre-sorted table by selecting a partition and optionally a range within the sort key. After DynamoDB has returned a page of results and there are more to follow, it provides you with `LastEvaluatedKey` which you can pass to the next iteration of the query as `ExclusiveStartKey` in order to get the next page.

Random access to page n is not possible unless you know the keys that coincide with a page break. You've got to fetch the pages in order. Users cannot jump to page 292 or only show the last page. This is entirely acceptable in many cases as modern user interfaces often provide _infinite scrolling_ or _show next 20_. 

As the `ExclusiveStartKey` is embedded into a URL, this means that this _next link_ is not stable. If the table changes, the link to retrieve page `2` changes. If the results are scanned in reverse (for instance, most recent first) the next link will change every time a new record is added. This generates a lot of URLs, which, although I am not an expert, can [hinder SEO efforts](https://www.portent.com/blog/seo/pagination-tunnels-experiment-click-depth.htm) on public sites where effective indexing is important.

Some may also say that `?page=2` looks nicer than an encoded exclusive start key (which itself may consist of several key-value pairs, possibly as a base64-encoded structure), but this might just be vanity.

What if, for whatever reason, we wanted to bring back those old-school, things-were-better-back-in-the-old-days page numbers?

# Pattern: map exclusive start keys to a numeric index
An exclusive start key is just a map containing the keys needed to _resume_ the query and grab the next n items. Rather than conveying it as part of the URL, instead store the components needed to generate an exclusive start key from a numeric index. A `page` or `skip` query parameter would be included in the URL. A look up for _item 20_ will yield the keys needed to construct an exclusive start key to _skip_ results by arbitrary intervals.

The drawback of this approach is the added complexity around building, maintaining, storing and serving this numeric index of rows. To avoid a confusing user experience, it is vital that the DynamoDB table and numeric index are consistent.

The next section details some theoretical (read: half-baked and unproven) approaches. Note that there may be WTFs, misunderstandings or things I have not considered, consider them to be ideas!

# Approaches
Our example scenario is an e-commerce site that has product pages where users can comment on a product.

The following approaches assume `comments` DynamoDB table has the string keys `PK, SK, PK2`, where `PK` is the entity ID, `SK` is a datetime of when the comment was posted, and `PK2` is a grouping key. 

The application shows comments for a product in reverse order of creation. `PK2` holds the SKU for the referenced product. A global secondary index on `PK2, SK` is used by the application to show comments in this way.

| PK     | SK               | PK2              | other attributes |
|--------|------------------|------------------| ---------------- |
| abc281 | 2021-08-25 13:00 | DAFT_PUNK_TSHIRT | ...              |
| abd212 | 2021-08-25 13:30 | DAFT_PUNK_TSHIRT | ...              |
| abc912 | 2021-08-25 13:42 | DAFT_PUNK_TSHIRT | ...              |
| ccc232 | 2021-08-25 13:55 | DAFT_PUNK_TSHIRT | ...              |

## Redis sorted sets
At the cost of an additional moving part, load the partition and sort keys into Redis sorted sets. A sorted set provides numeric index-based access to the keys, which can then be used to construct an `ExclusiveStartKey` to pass to DynamoDB. As the name of the type implies, Redis maintains the ordering (by score, aka creation date) on our behalf.

Assuming the table outlined above, we use `PK2` as the Redis key for a sorted set, `PK` as the member and `SK` (converted to unix time) as the score. 

For example `ZADD <PK2> to_unixtime(<SK>) <PK>`, would be sent to Redis through a Lambda function connected to a DynamoDB Stream off the table (it'd also need to send `ZREM/ZADD` to handle any deletions and changes.)

To get the exclusive start key for page 2, the Redis command `ZREVRANGE <PK2> <start> <end> WITHSCORES` where _start_ and _end_ is the index of the item to start from is sent. This will yield a list response of one item from Redis where `0` is `<PK>` and `1` is `<SK>`. This is all that is needed to construct an `ExclusiveStartKey`.

It is possible to get the total cardinality for grouping key with `ZCARD <PK2>` which is useful for getting the total number of pages.

Storing a large number of keys in a Redis sorted set could get expensive due to how a sorted set is implemented internally (a map and a skip list.) It is also slightly annoying to have to pay for RAM for items that won't be frequently accessed. This is a reasonable trade off as it is a very simple solution that is likely to have consistently high performance.

## Relational
The above pattern could also be achieved with a relational database. This could be a managed service like AWS RDS.

The sorted sets would live in a single table with a convering index on `PK2 ASC, SK DESC`. Instead of a `ZREVRANGE` Redis command, `SELECT PK, SK FROM pages ORDER BY SK DESC LIMIT n, 1` would be used. Despite using `LIMIT`, performance is expected to be reasonable due to the small row size. A similar Lambda function would keep this table in-sync with the DynamoDB table.

## Files on disk, EFS or even S3
The bang for buck option is good ol' files. If you don't want to run Redis or a relational database, you could define a fixed size C-style structure and append the bytes to a file, calculating the offset within the file based on the consistent size of a structure. You can then `seek` to the relevant record and read that number of bytes, or seek to the end and read backwards with a negative size.

In Python, the `struct` module is one way to achieve this - likewise in go, the `binary` module and ordinary go structs work as you would expect. The generated files are of course language agnostic. This provides interesting options for a _backfill_ of indexes as an indepedent batch process, for instance with EMR or Apache Beam.

With this pattern, the grouping key `PK2` is used to name the file. As with the prior approaches, a Lambda function that consumes a DynamoDB (or Kinesis) stream would write to these files.

Assuming a 24-character value for `PK`, and `SK` converted to an integer unix time, the code to read `index` would be something along these lines.

```python
STRUCT_DEF = "24s i"
SIZE = struct.calcsize(STRUCT_DEF) # 28 bytes (24+4)

PK2 = "DAFT_PUNK_TSHIRT"

with open(f"{PK2}.pag", "rb") as file:
    file.seek(SIZE * index) # zero indexed
    values = struct.unpack(STRUCT_DEF, input.read(SIZE))
    print(f"PK: {values[0]}, SK: {values[1]}, PK2: {PK2}")
```

This is likely to perform well with low latency on EC2 with instance storage or EBS. Non-scientific tests showed it worked far better than expected on an EFS mount in a Lambda function. If some additional latency can be tolerated, the _bargain basement_ solution is to read the **individual record** from S3.

```python
page_index = boto3.resource('s3').Object('pagination-indexes', f"{PK2}.pag")
start = SIZE * index
end = start + SIZE - 1
res = page_index.get(Range=f"bytes={start}-{end}")
values = struct.unpack(STRUCT_DEF, res["Body"].read())
print(f"PK: {values[0]}, SK: {values[1]}, PK2: {PK2}")
```

So the read path is incredibly simple and fast. The write path is more complex. The model of appending bytes to a file does not work if we want to maintain order and cannot say with 100% certainty that records won't appear out of order. Perhaps strict ordering is not necessary, but it would be confusing to have a comment from 2018 appearing alongside one from 2021. 

A simple remedy is to direct the add/remove/change _commands_ to individual files, a sort of write-ahead log. At a timed interval, a single _commit_ process could run and merge these changes into the ordered index file - discarding the temporary files. This reduces the amount of work needed to perform a sort and rewrite on the entire index, particularly if networked storage or S3 is where the indexes are stored. Deletions are fast in Redis as the member value is also indexed, which adds to the (RAM) storage footprint of a sorted set. This file based approach does not bother to do that, members marked for deletion are simply skipped when the file is rewritten. This makes the files smaller to transmit and rewrite.

The clear cost to this approach is that changes won't immediately appear.

If a degree of latency is acceptable, this is not a bad trade off. A complimentary hack would be to not consult the pagination index at all when querying the first n pages, and simply limit in your client. For example, instead of setting the DynamoDB query to `20`, set it to `200` and take a slice of the returned items to deliver up to page 10. This will increase read costs but caters for newest always being visible.

There will probably be other edge cases. It's important not to try and write your own database but you probably would not want consumers to interact directly with files. As this is the lowest level approach, some abstraction would be a good idea. An API, Lambda function that mounts an EFS or even a service that speaks [RESP](https://redis.io/topics/protocol) and apes the `Z*` commands should be considered.

Despite the odd looks you may get for suggesting this approach, I quite this it for its low cost, portability and (probably) high performance - if your workload can withstand the drawbacks.

### DynamoDB
Instead of adding another data store it is possible to stamp a _page marker_ numeric attribute onto every nth item in a table with an ascending page number.

A sparsely populated GSI would use this attribute as its sort key (plus other keys) so that only page _start_ items are included. 

** Page marker index**

| PK     | SK               | PK2 (GSI PK)     | page (GSI SK)    |
|--------|------------------|------------------| ---------------- |
| abc912 | 2021-08-25 13:42 | DAFT_PUNK_TSHIRT | 2                |
| ccc232 | 2021-08-25 14:55 | DAFT_PUNK_TSHIRT | 3                |


The partition header item contains the current page number (ascending) and running count of items remaining for the current page. 

**Table**
| PK     | SK               | current_page     | remaining        | card |
|--------|------------------|------------------| ---------------- | ---- |
| STATS  | DAFT_PUNK_TSHIRT | 3                | 2                | 7    |


If a new record flows onto the next page (i.e. is record 20), a page marker attribute is added to it and values within the `STATS` item for that product are incremented/reset within a transaction. 

To paginate in reverse sort order (for instance, latest items first), get the `PK: STATS, SK: DAFT_PUNK_TSHIRT` item to find the current page. Assuming there are 10 pages and page 3 is requested: `(10+1)-3 = 8`, leading us to key `PK2: DAFT_PUNK_TSHIRT, page: 8` on the page marker index. This item is retrieved to form an exclusive start key to be used in a query.

Handling changes other than appends economically is the challenge here. If an item needs to be removed in the middle of the results, subsequent page markers need to be updated. Depending on table size, this could result in a large number of operations and therefore increase read/write costs.

You may wonder why the oldest comments live on page 1 and the newest live on the highest page number. This is because our access pattern states that we must show the most recent comments on the first page, so would be continually updating page markers if a comment was being added to what the index considers to be page 1. In other words, changes are more likely in newer items.

This approach may only be appropriate for slow moving data, deletions are very rare or cannot happen, or when the table is materialized from scratch from another source.

# Conclusion
When something seemingly simple appears convoluted with your current technology stack, you've got to consider whether it is a good return on investment and wise to even try to make it work. The approaches discussed in the post may be a case of YAGNI. Infinite scrolling is simpler for the user and appears more _native_ these days. [Guys, we're doing pagination wrong](https://hackernoon.com/guys-were-doing-pagination-wrong-f6c18a91b232) is a great post that delves into the details further.

However, we don't live in a one-size-fits all world and sometimes creative solutions are needed. Different use cases have different constraints and levels of tolerance to eventual consistency and _correctness_. I'd be interested to hear thoughts on these untested approaches and if you've solved this problem in similar or entirely different way.
