+++
draft = false
date = 2020-11-28T00:00:00Z
title = "Filtering and pagination with Cloud Bigtable"
description = "Building a paginated and filterable comments data model with Cloud Bigtable."
slug = "cloud-bigtable-paginated-comments"
tags = ["data","gcp","bigtable","dynamodb"]
categories = []
externalLink = ""
series = []
+++

In the [previous series of posts](/posts/dynamodb-efficient-filtering/), we built data model capable of filtering and paginating product comments with DynamoDB.

This post explores how we could solve the same problem with [Cloud Bigtable](https://cloud.google.com/bigtable). 

You might wonder why another technology is now being discussed, but it is my belief that a lot of the _thinking_ that goes into a data model design is somewhat portable, whether it be DynamoDB, Cloud Bigtable, Cassandra, HBase... or maybe even Redis.

It is worth pointing out that unlike DynamoDB, Cloud Bigtable is a poor fit for small amounts of data due to fairly high entry-level cost and optimizations that it can only perform at scale. It is huge overkill in many scenarios. However some of the modelling techniques presented here might apply to larger volume and velocity usage scenarios. 

I am not suggesting you actually use Cloud Bigtable to build a comments section. Use DynamoDB, Firebase, MySQL or one of the many alternatives. **But** maybe if _comment sections as a service_ was your primary business offering, Cloud Bigtable could start to make more sense.

As could DynamoDB, of course. The point is that DynamoDB is versatile in that it can support workloads of varying sizes.

## Cloud Bigtable

Cloud Bigtable is a managed NoSQL offering from Google Cloud, similar to the internal Bigtable service that powers some huge Google properties, including search and GMail.

>Cloud Bigtable stores data in massively scalable tables, each of which is a sorted key/value map. The table is composed of rows, each of which typically describes a single entity, and columns, which contain individual values for each row. Each row is indexed by a single row key, and columns that are related to one another are typically grouped together into a column family. Each column is identified by a combination of the column family and a column qualifier, which is a unique name within the column family. [More..](https://cloud.google.com/bigtable/docs/overview#storage-model)

Despite this very simple interface, Bigtable is an abstraction on top of cloud storage, infrastructure and workload orchestration genius.

There are several differences for a developer coming from DynamoDB. Most of note are:

- no dedicated sort keys, the only index is a single, lexicographic-ordered row key
- no automatically maintained secondary indexes
- no reverse scans
- no triggers to fan out the creation of duplicate records
- pay per node (minimum of $0.65/hr so around $450 a month for a single node, plus storage) rather than capacity units

Spinning up a Bigtable instance is near-instantenous through a single command. However, the bulk of the work lies with optimally modelling the data, with particularly careful thought around the row keys.

Note that although we talk about nodes, instances and clusters, **compute and storage are separate in Bigtable.** All nodes read data from a shared file system, meaning that there is no need to _load_ data onto a node so that it can answer queries about a different section of our dataset. In non-scientific terms, Bigtable arranges the workload based on the access patterns that we throw at it.

## Possible solutions

There are several strategies we could take to bring the DynamoDB model over to Bigtable.

### Power sets

We could port the [original DynamoDB solution](/posts/dynamodb-efficient-filtering/) to Bigtable, in other words, we would duplicate a comment a large number times with different row keys to support all access patterns.

Although simple to implement, this approach will have worse maintenance costs compared to the DynamoDB version. There is no equivalent of DynamoDB Streams to create the duplicates in an event-driven manner, meaning this work will be pushed out to the client program, or a sweeper process running on a schedule, introducing some latency to our indexing process. We would also need to consider an access pattern for the sweeper to use so that it can only read rows from its high watermark, rather than performing a full table scan.

### Duplicate and multi get

Another approach is to [take inspiration from the final indexing strategy used with DynamoDB](/posts/dynamodb-efficient-filtering-2/). 

However, rather than projecting the entire comment across indexes, we will manually (through code) add non-covering _index_ rows into another table. This index table will store pointers back to rows in the main comment table. The query algorithm is a not rocket science but has a few steps:

- Parallel scan the index table for each requested rating, i.e. `1, 2, 4` up to the number of comments per page such as `20`
- Gather the comment row keys in the client and order by their sort key, in memory (this is only `60` rows)
- Extract the row key for the `topN` rows
- Perform a multi get operation to fetch the candidate rows by their key
- Gather the results and order again on sort key

The reason for having to order the results twice is because both parallel operations will potentially yield their results out of order. 

The pagination approach is very similar to [what we used in the final solution with DynamoDB](/posts/dynamodb-efficient-filtering-3/). **The biggest difference is that it is more acceptable to perform random lookups on a set of row keys with Bigtable, therefore we can afford to project and duplicate less data.** In other words, it is OK to use the Cloud Bigtable equivalent of `BatchGetItem`.

The parallel aspects of the client program are far simpler this time as the Bigtable API supports queries over multiple ranges in a single request. There is no need for us to think orchestrating parallel queries as Bigtable handles that.

There will also be a small amount of waste during pagination across complex queries. We are collecting `n * rows per page` where `n` is the number of ratings in our filter. In other words, we will read up to `100` index rows and up to `20` comment rows to satisfy the query. As the index rows are very small, this is likely to be acceptable.

### Regular expression row filter

Filters in Bigtable are maybe more acceptable than with DynamoDB. **The big difference with Bigtable is the fact that the lowest possibly amount of capacity is a single node. It is a _sunk cost_, reading tens of thousands of rows maybe does not matter, when a single node is capable of scanning up to 220mb/sec.** Of course, this inefficiency might catch up with us as volume and concurrent access increases. Node resources are not infinite and scanning excessively will make query performance less predictable.

So, instead of creating millions of duplicates, we could use row filers. By providing a start and end key, Bigtable will only scan the relevant products, in order. **This effectively partitions our data set so that we only scan comments for a given product.** If the key also contains the language, the query becomes more selective as only those rows will be scanned. 

When using a filter, it is essential to whittle down the possible results as much as possible using keys and a range scan. Rows are filtered out through the evaluation of a regular expression against the row key. In a sense this is similar to a DynamoDB filter: the database is reading the whole row and only sending results that pass the filter back to the client program.

We will investigate this solution first.

## Access patterns

To recap, these are the access patterns.

- **AP1**: show comments in reverse order, i.e. most recent first, regardless of filter
- **AP2**: show comments in the user's local language, but let them see comments in all languages
- **AP3**: show comments with any combination of ratings, from 1-5, where 1 is terrible and 5 is excellent
- **AP4**: show 20 comments per page, with no performance degradation when fetching pages of older comments
- **AP5**: show a comment directly through its identifier
- **AP6**: delete comment by id

## Row key design

Bigtable has no secondary indexes, so comment creation time needs to be embedded into the row key so that we can show newest comments first. As we need to filter on `language` and a set of selected `rating`s, these also need to be promoted into the key. 

Bigtable does not support reverse scans and to meet `AP1` we need to show the most recent comments first. A trick to achieve this is to subtract the actual timestamp from a timestamp 100 years (or more) into the future.

The first element of our key `PRODUCT#<product-id>` ensures that all comments for a given product are contiguous. If this was a multi-tenant application, the first segment could be prefixed with a tenant identifier (although care also needs to be taken if your customer base is made up over four big tenants and thousands of smaller ones.) The second element is a reverse timestamp, ensuring reverse time ordering of comments for that product.

The next two elements are the language and ratings attributes. Row keys have to be unique, so an identifier for the comment is appended as the last element. 

If it is anticipated that more than one comment per second will be received for a product, the timestamp resolution could be increased to include milliseconds. Alternatively, a random three or four digit number could be appended. This is not to ensure row key uniqueness as the comment ID is the final key element. This is to workaround a scenario where comments with identical timestamps might be shown twice if they fall over a page boundary.

Putting all of that together, we calculate the reverse timestamp with a random suffix.

``` python
LONG_TIME_FUTURE = 4102444800 # 1st Jan 2100 ...
created_ts = 1605387738 # 14th Nov 2020 ...
reversed_timestamp_key = str(LONG_TIME_FUTURE - created_ts) + str(random.randint(111,999))
```

Assuming comment `1` for product `42` is in `language=en` and has `rating=5`, the following row key will be used:

`PRODUCT#42/2497057062123/en/5/COMMENT#1`.

There is a drawback to promoting the timestamp to the first element of the key. We cannot directly access all comments of a given rating or country without some degree of filtering. Changing the order of the segments within the row key would allow this, but would require us to change how we query the table. This is discussed more later.

## Queries

The only type of query we can do in Cloud Bigtable is reading a single row, or range of rows. When reading a range of rows, a start and an end key should be provided to avoid performing a full table scan. The character `~` is used due to it being _greater than_ other characters within the row key.

### AP1: Show comments for a product in reverse order, i.e. most recent first, regardless of filter

Read rows from `PRODUCT#42/` to `PRODUCT#42/~`. A `RowKeyFilter` is applied to further restrict the returned results, based on their key.

This will scan all reviews for this product until the page size is reached.

> By including the sort key as the second element of the key we have enabled the _all_ reviews query with a prefix scan. If we shifted the sort key to after the `language` and `rating` elements, we break the _all_ query, but can now efficiently get comments in order for a given `language` and `rating`.

### AP2: Show comments in the user's local language, but let them see comments in all languages

Filter rows with `.*/en/.*/` for English. Do not apply any filter is all languages and all start ratings are required.

### AP3: Show comments with any combination of ratings

Filter rows with `.*/en/(1|2|5)` to show English comments of a `1`, `2` or `5` star rating.

Filter rows with `.*/.*/(1|2|5)` to show all comments of a `1`, `2` or `5` star rating.

### AP4: Show 20 comments per page, with ability to paginate

For the first page, read 21 rows from `PRODUCT#42` to `PRODUCT#42/~`. Store the `reverse_sort_key` value from row `21` to use as a reference point in the table for the next page. Only return the top 20 rows to the client.

To fetch the next page, repeat the process by reading from `PRODUCT#42/<reverse_sort_key>/`. This will mean the table is only scanned from that point in time.

### AP5: Show a comment directly through its identifier

So far we have only thought about ordered sets of products. Finding a comment by its identifier (or comments written by a given user) would be inefficient with the current model as it is the very last segment in the row key.

A simple solution is to write the row again, with a row key beginning with the comment identifier, such as `COMMENT#1`. A column within that row should hold the `PRODUCT#42/...` row key to support `AP6`.

### AP6: Delete comment 1

Look up the _product_ row key by first looking up the _comment_ row key, as detailed above. Delete both.

## Example code

### Compose start and end key

``` go
// Compose key and row filter, based on parameters
baseKey := fmt.Sprintf("PRODUCT#%s/", productID)
// Scan to end for this PRODUCT#id
endKey := fmt.Sprintf("%s/~", baseKey)

// No startTime passed, so start from the beginning
if startTime == "" {
    startKey = baseKey
} else {
    startKey = fmt.Sprintf("%s/%s/", baseKey, startTime)
}
```

### Compose key filter

``` go
if language != "" || len(ratings) > 0 {
    // Join slice of ratings to form ratings portion of the regex
    if len(ratings) > 0 {
        regexStars = fmt.Sprintf("(%s)", strings.Join(ratings, "|"))
    }

    if language != "" {
        regexLang = language
    }

    // Row key is of form: PRODUCT#product_id/reversed_ts/language/stars/COMMENT#id
    // PRODUCT#42/2497057062123/(en|fr)/(1|2|4)/ ...
    filterRegex = fmt.Sprintf(".*/.*/%s/%s/.*", regexLang, regexStars)
    filter = bigtable.RowFilter(bigtable.RowKeyFilter(filterRegex))
}
```

### Read rows

``` go
var comments []Comment
rowsPerPage := 20
err := tbl.ReadRows(ctx, bigtable.NewRange(startKey, endKey), func(row bigtable.Row) bool {
    comments = append(comments, NewCommentFromRow(row))
    count = count + 1

    // Over scan by 1 row to get next start key, then stop reading rows
    // Set this as 'startTime' on request for next page
    if count == rowsPerPage+1 {
        lastKey = comments[len(comments)-1].SortKey
        return false
    }

    // Keep on reading
    return true
}, filter) // <-- Pass filter created above
```

## Discussion

The solution presented here is simplistic. We exploit the fact that Cloud Bigtable orders rows by key. Comments for the same product are stored near each other, reverse sorted by time. This makes ordered scanning for pages of comments simple to achieve.

Pagination is a matter of passing the `startTime` to start reading from. This is very efficient so performance will not degrade when paginating through earlier rows as scanning begins at the explicitly set start key.

We don't need to store the comment multiple times for different access patterns. However, the biggest drawback is our use of filtering over a potentially large number of rows. The read pattern is simply to scan _all_ comments **for a given product**, from an optional starting date, up to a page size limit of `20`. 

If a product has uniform distribution of ratings and languages, this isn't much of a problem, nor is simply showing everything. However, filtering for comments with a `1` rating when there are `20000` rows between the first `1`-rated comment and the next, will result in noticeable latency. Potentially the query will scan to the end of the comments for that product. This isn't a full table scan, but a _hot_ product with a lot of comments may make this approach less viable.

This could be mitigated with a different row key to reduce the number of rows that need to be read and filtered. By promoting `rating` to come before the timestamp in the row key, we would have a more selective index for filtering by rating. The downside is that rows would be sorted by `rating` and then timestamp. This is ideal if we only wanted to show a single rating, but would require parallel queries to satsify a query requiring ratings `[1, 2, 5]`.

We should not be afraid of duplication, particularly if it allows us to optimise for the most frequent access patterns and make them less costly. A simple solution inspired by DynamoDB GSIs would be to project the comment rows into another table with an alternate row key. We would then use a simple query planner, as we did in the DynamoDB solution, to select the table (index) to use.

## Summary

We have taken a design originally for DynamoDB and applied it Cloud Bigtable. While Cloud Bigtable has fewer features than DynamoDB, its design and raw performance at the lowest level of capacity has allowed us to think differently.

As with data models, the best fitting technology depends on the workload, budget and prior investment in either cloud. If all your services live in AWS, Bigtable would be a harder sell due to increased data transfer costs.

DynamoDB and Cloud Bigtable both force us to think at a lower level than a relational database to maximise efficiency. As previously stated, use of Cloud Bigtable would be overkill for a comments section unless the number of comments is incredibly high.

DynamoDB hits a sweet spot by being incredibly economical (possibly even free) for small workloads. Cloud Bigtable has a high initial price point of $0.65/hr for a single node cluster. A single Cloud Bigtable node can support a respectable number of operations, but this is only economical if you actually utilise them. A single node is the smallest billing increment. 

As an answer to that, Google has other, more on-demand NoSQL products such as Firebase. DynamoDB has an on-demand model, making it a versatile choice for workloads of all sizes - with provisioned pricing options to save money when the workload is better understood. As scale increases, the price differential will likely narrow.

In the next post we will explore implementing the [index and multi-get](#duplicate-and-multi-get) approach to make the Cloud Bigtable solution more effcient.