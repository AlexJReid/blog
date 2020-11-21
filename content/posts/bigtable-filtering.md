+++
draft = true
date = 2020-11-19T15:37:10Z
title = "Efficient NoSQL filtering and pagination - part 2: Cloud Bigtable"
description = "Building a paginated and filterable comments data model with Cloud Bigtable."
slug = "cloud-bigtable-paginated-comments"
tags = ["data","gcp","bigtable","dynamodb"]
categories = []
externalLink = ""
series = []
+++

In the [previous post](/posts/dynamodb-efficient-filtering/), a paginated and filtered data model representing product comments for DynamoDB was discussed. This was not a perfect solution as the number of items stored would increase dramatically if the queries got even slightly more complicated.

Although this isn't a bad trade off if the queries are unlikely to change, let's explore how we can improve.

This post explores how we could solve the same problem with [Cloud Bigtable](https://cloud.google.com/bigtable). We will see some similarities and differences. You might wonder why another NoSQL technology is now being discussed when we have only just started out with DynamoDB. It is my belief that a lot of the _thinking_ that goes into a NoSQL design is portable, whether it be DynamoDB, Cloud Bigtable, Cassandra, HBase... or maybe even Redis.

## Cloud Bigtable

On the surface Cloud Bigtable is a... _big_ sorted dictionary, consisting of rows that contain any number of cells. A cell is a column qualifier and set of timestamped values. Despite this very simple interface, Bigtable is an abstraction on top of some serious cloud infrastructure genius from Google and is of course proven to support massive workloads with huge volumes of data. It is a poor fit for small amounts of data.

There are several differences from DynamoDB. Most of note are:

- no sort keys, the only index is a single, lexicographic-ordered row key
- no automatically created secondary indexes
- no reverse scans
- no triggers to fan out the creation of duplicate records
- pay per node (minimum of $0.65/hr so around $450 a month for a single node) rather than capacity units

Although it is very simple to spin up a Bigtable instance, the complexity lies with optimally modelling the data, with particularly careful thought needed around row keys.

## Possible solutions

### Power sets

We could port the original DynamoDB solution from the previous post to Bigtable. As Bigtable has no sort key in which to store the creation date and therefore support ordering, it should get promoted to be part of the row key. Although simple to implement, this approach will have the same drawbacks as the DynamoDB version. There is no equivalent of DynamoDB Streams to create the duplicates in an event-driven manner, meaning this work will be pushed out to the client program, or a sweeper process running on a schedule, introducing some latency to our indexing process.

### Regular expression row filter

Instead of loading in millions of duplicates, we can use row filers. By providing a start and end key, Bigtable will only scan the relevant products, in order. This effectively partitions our data set so that we only scan comments for a given product. If the key also contains the language, only those rows will be scanned. When using a filter, it is essential to whittle down the possible results as much as possible using keys and a range scan.

Rows are filtered out through the evaluation of a regular expression against the row key. In a sense this is similar to a DynamoDB filter: the database is reading the whole row and only sending results that pass the filter back to the client program.

The big difference with Bigtable is the fact that nodes are a _sunk cost_, reading tens of thousands of rows maybe does not matter, if a single node as a throughput of up to 220mb/sec! Of course, this inefficiency might catch up with us as volume increases. Node resources are not infinite and scanning excessively will make query performance less predictable.

### Index and multi get

The most promising, but more complex approach is to insert _index_ rows into another table. This table will store pointers back to rows in the main comment table. The query algorithm is a not rocket science but has a few steps:

- Parallel scan the index table for each requested rating, i.e. `1, 2, 4` up to the number of comments per page such as `20`
- Gather the comment row keys in the client and order by their sort key, in memory (this is only `60` rows)
- Extract the row key for the `topN` rows
- Perform a multi get operation to fetch the candidate rows by their key
- Gather the results and order again on sort key

The parallel aspects require the client program to make concurrent requests in multiple threads, goroutines, promises and so on. The reason for having to order the results is because both parallel operations will potentially yield their results out of order. This is not a costly operation. There is also a small amount of waste as we are collecting `n * rows per page` where `n` is the number of ratings in our filter. In other words we will read up to `100` index rows and up to `20` comment rows to satisfy the query. As the index rows are very small pointers, this is likely to be acceptable.

We can also employ two strategies depending on the query. If it only has a single `language` or `rating` specified, it can be answered with a single `PrefixScan`. If multiple `rating` values are specified, the index will be consulted. Finally, taking inspiration from our original solution we need to be able to show _all_ comments. This can be achieved with a small degree of row duplication: write the comment row with wildcards for the `language` and `rating` segment of the row key.

```
PRODUCT#42/sortkey/en/5

... duplicates:
PRODUCT#42/sortkey/en/~
PRODUCT#42/sortkey/~/5
PRODUCT#42/sortkey/~/~
```

This solution will be demonstrated in the next post. **Chosen solution to explore further: regular expression row filter.**

## Query patterns

To recap, these are are query patterns.

- **QP1**: show comments in reverse order, i.e. most recent first, regardless of filter
- **QP2**: show comments in the user's local language, but let them see comments in all languages
- **QP3**: show comments with any combination of ratings, from 1-5, where 1 is terrible and 5 is excellent
- **QP4**: show 20 comments per page, with no performance degradation when fetching pages of older comments
- **QP5**: show a comment directly through its identifier
- **QP6**: show the most recent positive English comment for product 42
- **QP7**: delete comment by id

### Row key design

Bigtable has no secondary indexes so the creation time sort needs to be embedded into the row key so that we can show newest comments first. As we need to filter on `language` and a set of selected `rating`s, these also need to be promoted into the key.

Bigtable does not support reverse scans and to meet `QP1` we need to show the most recent comments first. A trick to achieve this is to subtract the actual timestamp from a timestamp 100 years (or more) into the future.

``` python
LONG_TIME_FUTURE = 4102444800 # 1st Jan 2100 ...
created_ts = 1605387738 # 14th Nov 2020 ...
reversed_timestamp_key = str(LONG_TIME_FUTURE - created_ts)
=> 2497057062
```

The first element of our key ensures that all comments for a given product are contiguous. The second element is a reverse timestamp, ensuring ordering within that set. The next two elements are the language and ratings attributes. Finally, for uniqueness, a unique identifier for the comment is appended as the last element.

Assuming comment `1` is in `language=en` has `rating=5`, the following key will be used:

`PRODUCT#42/2497057062/en/5/COMMENT#1`

## Queries

We can now implement the queries needed for our comments application. The only type of query we can do in Cloud Bigtable is reading a single row, or range of rows (and sets of each.) When reading a range of rows, a start and end key must be provided. The character `~` is used due to it being _greater than_ other characters within the row key.

### Show comments for a product in reverse order, i.e. most recent first, regardless of filter

Read rows from `PRODUCT#42/` to `PRODUCT#42/~`. A `RowKeyFilter` is applied to further restrict the returned results, based on their key.

This will scan all reviews for this product until the page size is reached. If the data is evenly distributed between the query parameter values, this is not a huge problem.

> By including the sort key as the second element of the key we have enabled the _all_ reviews query with a prefix scan. If we shifted the sort key to after the `language` and `rating` elements, we break the _all_ query, but can now efficiently get comments in order for a given `language` and `rating`.

### Show comments in the user's local language, but let them see comments in all languages

Filter rows with `.*/.*/en/.*/` for English. Do not apply any filter is all languages and all start ratings are required.

### Show comments with any combination of ratings

Filter rows with `.*/.*/en/(1|2|5)` to show English comments of a `1`, `2` or `5` star rating.

### Show 20 comments per page, with ability to paginate

For the first page, read 21 rows from `PRODUCT#42` to `PRODUCT#42/~`. Store the `reverse_sort_key` value from row `21`. Only return the top 20 rows to the client.

To fetch the next page, repeat the process by reading from `PRODUCT#42/<reverse_sort_key>/`.

If it is anticipated that more than one comment per second will be received for a product, the timestamp resolution could be increased to include milliseconds. Alternatively, a random three or four digit number could be appended. This is not to ensure row key uniqueness as the comment ID is the final key element. This is to workaround a scenario where comments with identical timestamps might be shown twice if they fall over a page boundary.

``` python
LONG_TIME_FUTURE = 4102444800 # 1st Jan 2100 ...
created_ts = 1605387738 # 14th Nov 2020 ...
reversed_timestamp_key = str(LONG_TIME_FUTURE - created_ts) + str(random.randint(111,999))
```

### Show a comment directly through its identifier

So far we have only thought about ordered sets of products. Finding a comment by its identifier (or comments written by a given user) would be inefficient with the current model.

A simple solution is to write the row again, with a row key beginning with the comment identifier, such as `COMMENT#1`. A column within that row should hold the `PRODUCT#42/...` row key.

### Delete comment 1

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
 startKey = fmt.Sprintf("%s/%s", baseKey, startTime)
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
 filterRegex = fmt.Sprintf(".*/.*/%s/%s/.*", regexLang, regexStars)
 filter = bigtable.RowFilter(bigtable.RowKeyFilter(filterRegex))
}
```

### Read rows

``` go
err := tbl.ReadRows(ctx, bigtable.NewRange(startKey, endKey), func(row bigtable.Row) bool {
 comments = append(comments, fromRow(row))
 count = count + 1

 // Over scan by 1 row to get next start key, then stop reading rows
 // Set this as 'startTime' on request for next page
 if count == rowsPerPage+1 {
  lastKey = comments[len(comments)-1].SortKey
  return false
 }

 // Keep on reading
 return true
}, filter)
```

## Discussion

The solution presented here is simple to implement. We exploit the fact that Cloud Bigtable orders rows by key. Comments for the same product are stored near each other. This makes ordered scanning for pages of comments simple to achieve.

Pagination is a matter of passing the `startTime` to start reading from. This is very efficient - performance will not degrade when paginating through earlier rows as scanning begins at the explicitly set start key.

We don't need to store the comment multiple times for different filtering patterns. This means the code is far simpler: there is no need to synchronize changes.

The biggest drawback is our use of regular expressions for filtering. Our proposed read pattern is simply to scan _all_ comments **for a given product**, up to a page size limit of `20`. If a product has uniform distribution of ratings, this isn't a problem.

However, filtering for comments with a `1` rating when there are `20000` rows between the first `1`-rated comment and the next, this will result in noticeable latency. Potentially the query will scan to the end of the comments for that product. This isn't a full table scan, but a _hot_ product with a lot of comments may make this approach less viable.

Our prior DynamoDB implementation was brute force. It materialized result sets for every possible filtering scenario at write-time. Therefore, it is likely to exhibit uniform behaviour, regardless of query. The trade off is less flexibility around ease of adding additional query patterns.

DynamoDB hits a sweet spot by being incredibly economical for very small workloads. Cloud Bigtable has a high initial price point of $0.65/hr for a single node cluster. A single Cloud Bigtable node can support a respectable number of operations, but this is only economical if you actually utilise them. A single node is the smallest billing increment. Google has other, more on-demand NoSQL products such as Firebase.

DynamoDB has an on-demand model, making it a versatile choice for workloads of all sizes - with provisioned pricing options to save money when the workload is better understood. As scale increases, the price differential will narrow.

As with data models, the best fitting technology depends on the workload and budget. DynamoDB and Cloud Bigtable force us to think at a lower level to maximise efficiency and therefore increase performance and lower costs. Both are overkill for sites where a handful of comments are received per project, however it is easy to imagine the patterns presented here being useful on higher volume applications.

Both solutions are unable to support jumping to arbitrary pages, instead treating the reverse-chronological stream of comments like a tape that gets started, paused, cued and stopped.

_Corrections and comments are most welcome_.
