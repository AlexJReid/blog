+++
draft = false
date = 2020-11-14T15:37:10Z
title = "A paginated and filterable comments data model for Cloud Bigtable"
description = "An approach for building a paginated and filterable comments data model for Cloud Bigtable."
slug = "cloud-bigtable-paginated-comments"
tags = ["data","gcp","bigtable","dynamodb"]
categories = []
externalLink = ""
series = []
+++

In the [previous post](/posts/dynamodb-efficient-filtering/), an implementation of paginated and filtered product comments data model for DynamoDB was shown.

This post explores how we might solve the same problem using [Cloud Bigtable](https://cloud.google.com/bigtable). This is a simple comparison and is not meant to pitch DynamoDB against Cloud Bigtable as both are incredible pieces of engineering. Between them, I wager they power a good proportion of the sites and services we use on a daily basis.

There are several differences between DynamoDB and Bigtable, but most of note are:

- no sort keys, the only index is a single, lexicographically-ordered row key
- no automatically created secondary indexes
- no triggers to fan out the creation of duplicate records
- pay per node rather than capacity units

This will influence our design.

## Recap

In the previous post, a paginated and filtered set of comments required the following query patterns.

- **QP1**: show comments in reverse order, i.e. most recent first, regardless of filter
- **QP2**: show comments in the user's local language, but let them see comments in all languages
- **QP3**: show comments with any combination of ratings, from 1-5, where 1 is terrible and 5 is excellent
- **QP4**: show 20 comments per page, with no performance degradation when fetching pages of older comments
- **QP5**: show a comment directly through its identifier
- **QP6**: show the most recent positive English comment for product 42
- **QP7**: delete comment by id

## Row key design

As Bigtable has no secondary indexes, the creation time needs to be embedded into the row key so that we can show newest comments first. As we need to filter on `language` and a set of selected `rating`s, these also need to be included.

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

## Query patterns

We can now implement the queries needed for our comments application. The only type of query we can do in Cloud Bigtable is reading a single row, or range of rows. When reading multiple rows, a start and end key must be provided. The character `~` is used due to it being _greater than_ other characters within the row key.

#### Show comments for a product in reverse order, i.e. most recent first, regardless of filter

Read rows from `PRODUCT#42` to `PRODUCT#42/~`. This is the base query used by all other examples. A `RowKeyFilter` is applied to further restrict the returned results, based on their key.

#### Show comments in the user's local language, but let them see comments in all languages

Filter rows with `.*/.*/en/.*/` for English. Do not apply any filter is all languages and all start ratings are required.

#### Show comments with any combination of ratings

Filter rows with `.*/.*/en/(1|2|5)` to show English comments of a `1`, `2` or `5` star rating.

#### Show 20 comments per page, with ability to paginate

For the first page, read 21 rows from `PRODUCT#42` to `PRODUCT#42/~`. Store the `reverse_sort_key` value from row `20`. Only return `rows[0:19]` rows to the client.

To fetch the next page, repeat the process by reading from `PRODUCT#42/<reverse_sort_key>`.

If it is anticipated that more than one comment per second will be received for a product, the timestamp resolution could be increased to include milliseconds. Alternatively, a random three or four digit number could be appended. This is not to ensure row key uniqueness as the comment ID is the final key element. This is to workaround a scenario where comments with identical timestamps might be shown twice if they fall over a page boundary.

``` python
LONG_TIME_FUTURE = 4102444800 # 1st Jan 2100 ...
created_ts = 1605387738 # 14th Nov 2020 ...
reversed_timestamp_key = str(LONG_TIME_FUTURE - created_ts) + str(random.randint(111,999))
```

#### Show a comment directly through its identifier

This is where our scanning/filtering model gives us a little more work to do. Comments for products are easy to access, but finding a comment identifier (or comments written by a given user) is very inefficient.

A simple solution is to write the row again, with a row key beginning with the comment identifier, such as `COMMENT#1`. A column within that row should hold the `PRODUCT#42/...` row key.

#### Delete comment 1

Look up the _product_ row key by first looking up the _comment_ row key, as detailed above. Delete both.

## Example code

#### Compose start and end key

``` go
// Compose key and row filter, based on parameters
baseKey := fmt.Sprintf("PRODUCT#%s", productID)
// Scan to end for this PRODUCT#id
endKey := fmt.Sprintf("%s/~", baseKey)

// No startTime passed, so start from the beginning
if startTime == "" {
	startKey = baseKey
} else {
	startKey = fmt.Sprintf("%s/%s", baseKey, startTime)
}
```

#### Compose key filter

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

#### Read rows

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

The pattern here is simple. We exploit the fact that Cloud Bigtable orders rows by key. Comments for the same product are stored near each other. This makes ordered scanning for pages of comments simple to achieve.

Pagination is simply a case of passing the `startTime` to start reading from. This is very efficient - performance will not degrade when paginating through earlier rows as scanning begins at the explicitly set start key.

We don't need to store the comment multiple times for different filtering patterns. This means the code is far simpler: there is no need to synchronize changes.

The biggest drawback is our use of regular expressions for filtering. Our proposed read pattern is simply to scan _all_ comments **for a given product**, up to a page size limit of `20`. If a product has uniform distribution of ratings, this isn't a problem. 
However, filtering for comments with a `1` rating when there are `20000` rows between the first `1`-rated comment and the next, this will result in noticeable latency. Potentially the query will scan to the end of the comments for that product. This isn't a full table scan, but a _hot_ product with a lot of comments may make this model less viable. It is envisaged that filtering in Cloud Bigtable is not as costly as in DynamoDB as the nodes are already paid for and entire items are not read - but resources are still consumed. This should be benchmarked.

Our prior DynamoDB implementation was brute force. It materialized result sets for every possible filtering scenario at write-time. Therefore, it is likely to exhibit uniform behaviour, regardless of query. The trade off is less flexibility around ease of adding additional query patterns.

DynamoDB hits a sweet spot by being incredibly economical for very small workloads. Cloud Bigtable has a high initial price point of $0.65/hr for a single node cluster. A single Cloud Bigtable node can support a respectable number of operations, but this is only economical if you actually utilise them. A single node is the smallest billing increment. Google has other, more on-demand NoSQL products such as Firebase.

DynamoDB has an on-demand model, making it a versatile choice for workloads of all sizes - with provisioned pricing options to save money when the workload is better understood. As scale increases, the price differential will narrow.

As with data models, the best fitting technology depends on the workload and budget. DynamoDB and Cloud Bigtable force us to think at a lower level to maximise efficiency and therefore increase performance and lower costs. Both are probably overkill for sites where a handful of comments are received per project, however it is easy to imagine the patterns presented here being useful on higher volume applications.

Both solutions are unable to support jumping to arbitrary pages, instead treating the reverse-chronological stream of comments like a tape that gets started, paused, cued and stopped. 

But why are our users jumping to page `4272`? Do they want to see comments from a year ago? It is not hard to imagine how we might partition our data to efficiently implement that. This is a better user experience and less work for the database. Win, win.

In the next post, I will benchmark the two solutions.

[Discuss on Twitter](https://twitter.com/search?q=alexjreid.dev%2Fposts%2Fcloud-bigtable-paginated-comments%2F) _Corrections and comments are most welcome._
