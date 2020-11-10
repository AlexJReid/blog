+++ 
draft = false
date = 2020-11-09T17:54:11Z
title = "Efficient filtering with DynamoDB"
description = "An exploration of using data duplication to implement an efficient product comments system on DynamoDB."
slug = "dynamodb-efficient-filtering"
tags = ['aws','dynamodb','data']
categories = []
externalLink = ""
series = []
+++

It never ceases to amaze me just how much is possible through the seemingly constrained model DynamoDB gives us. It's a fun puzzle to try to support query patterns beyond a simple key value lookup, or ordered set of items.

The NoSQL gods teach us to store data in a way that mirrors our application's functionality. This is often achieved with data duplication. DymamoDB secondary indexes allow us to automatically duplicate items with different attributes from the item as keys.

This can get us a long way. However, a common approach is to delegate more complex queries to another supplementary system, such as Elasticsearch. DynamoDB remains the source of truth, sending updates to Elasticsearch via DynamoDB Stream and a Lambda function. A DynamoDB stream conveys changes made to a DynamoDB table that are received by the Lambda function, which in turn converts the change into an Elasticsearch document and indexing request.

In many cases, this is the right approach. However, Elasticsearch, even when managed, can be a complex and expensive beast. I believe it is desirable to keep things as lean as possible and only follow that path if it is necessary, so let's explore what is possible with DynamoDB alone.

## Example scenario: a product comments system

Suppose we want to model the comments section on a product page within an e-commerce site. Each product has a set of comments, shown in reverse date order. 

Our query patterns are as follows:

- **QP1**: show comments in reverse order, i.e. most recent first, regardless of filter
- **QP2**: show comments in the user's local language, but let them see comments in all languages
- **QP3**: show comments with any combination of ratings, from 1-5, where 1 is terrible and 5 is excellent
- **QP4**: show 20 comments per page, with no performance degradation when fetching pages of older comments
- **QP5**: show a comment directly through its identifier
- **QP6**: show the most recent positive English comment for product 42
- **QP7**: delete comment by id

## What's wrong with DynamoDB filters?

DynamoDB allows us to filter query results before they are returned to our client program. It is possible to filter on any non-key attribute, which sounds liberating at first. However, if a large amount of data is filtered out, we will still consume resources, time and money in order to find the needle in the haystack. This is particularly costly if each item size runs into kilobytes.

Filters do have utility at ensuring data is within bounds (such as enforcing TTL on expired items that might not have been _collected_ yet). They work best when only a small proportion of the items are thrown away by the filter.

## Table design

A table with a global secondary index `gsi` is used. The index will be used to display comments relating to a product.

| pk             | sk (gsi pk)     | cd (gsi sk)             | language | rating | auto | comment_blob
| -------------- | --------------- | ----------------------- | -------- | ------ | ---- | ------------
| COMMENT#100001 | PRODUCT#42/~/~  | 2020-11-09 12:00:00.123 | en       | 5      |      | { ... }
| COMMENT#100001 | PRODUCT#42/en/~ | 2020-11-09 12:00:00.123 | en       | 5      | true | { ... }

Note that the second row is a duplicate of the first, but with a different `sk` to support a specific query.

- `pk` is the table partition key; it holds the a unique identifier of a comment
- `sk` is the table sort key and the GSI partition key; it holds a _query string_ relating to when the comment should be returned in a list
- `cd` is the creation date and the GSI sort key; it is used to order lists of comments
- `language` and `rating` are used to form different permutations of the query string held in `sk`
- `auto` is a `bool` denoting this item is a duplicate row, used to satisfy a specific query string - more on this later
- `comment_blob` the comment itself, containing arbitrary data: it could be a DynamoDB map, JSON encoded string, protobuf and so on...

## Key design

Let's elaborate on `sk`. It contains a `/` delimited string. The first element is the type, `PRODUCT#` and its identifier `42`. The second element is the language, such as `en` or `~` to denote _any_. The final element is the rating number, from `1` to `5`.

As per `QP3`, any combination of ratings can be specified in addition to the selected language. 

Here are some examples:

- `<product>/<language>/<ratings>`
- `PRODUCT#42/~/~` - any language
- `PRODUCT#42/en/~` - English only
- `PRODUCT#42/en/1` - English only, with a rating of 1
- `PRODUCT#42/en/1.2.5` - English only, with a rating of 1, 2 or 5
- `PRODUCT#42/~/1.2.5` - any language, with a rating of 1, 2 or 5

It might help to think of each `sk` as representing an ordered set of comments. It maps neatly onto a RESTful resource such as `/product/42/comments/en/1.2.3`.

## What duplicates do we need?

We will assume this application will be write light and read heavy, so it is acceptable to store the same comment mulitple times to provide  inexpensive querying.

As per `QP2`, a user can choose to show _all_ languages or select a single language. This can be met by double-writing the item with different `sk` values, once with `~` as the language element, and once with the actual language the user was written in, such as `en`.

`QP3` is more complicated as any combination of ratings can be requested. A user could select `1` to only see the bad, or `5` to only see the great - or any combination of those. To achieve this, a _power set_ is calculated to generate keys for the possible combinations. The number of items in a power set is `2 ** len(values_in_set)` so in this case `2 ** len({1,2,3,4,5}) = 32` so the power set size is `32`. We can remove any items from the set that do not contain the rating of the comment being posted. This brings the set size down to `16`. 

Ultimately, we write the comment to the table `32` times with a `sk` representing each combination of ratings, once for all languages and once for the actual language. A set containing multiple ratings is serialised to an ordered, `.`-delimited string such as `1.2.3.4.5`.

You could think about each of the ratings being toggle switches that are set low or high.

- `00001` = Rating 1
- `00010` = Rating 2
- `00100` = Rating 3
- `01000` = Rating 4
- `10000` = Rating 5

Combinations are represented as you'd expect.

- `10001` = Rating 1 and 5
- `11111` = All ratings

```
>>> rating_1 = 0b00001
>>> rating_5 = 0b10000
>>> bin(rating_5 | rating_1)
'0b10001'
>>> rating_5 | rating_1
17
```

As the combination of `rating_5` and `rating_1` is `17`, this could be used as a more compact representation of the selected ratings, as a future optimization. Instead of `PRODUCT#42/en/1.2.3.4.5`, `PRODUCT#42/en/31` could be stored instead.

It has the side-effect of allowing longer set values to be stored. For instance, if instead of numeric ratings we used `['Poor', 'Fair', 'Good', 'Great', 'Excellent']`, the keys would be longer and we would consume more resources.

It might seem premature, but shaving bytes off repeated keys and attribute names is considered good practice. The tradeoff is that this portion of the key is less readable by the human eye.

## Query patterns

We should now be able to satisfy all of our query patterns. All queries should have `ScanIndexForward` set to `false` to retrieve the most recent comments first. This is because the `gsi` uses `cd` as its sort key, and the creation dates sort lexicographically.

#### Show comments in reverse order, i.e. most recent first, regardless of filter

- Query on `gsi`
    - SK = `PRODUCT#42/~/~`


#### Show comments in the user's local language, but let them see comments in all languages

- Local language: 
    - Query on `gsi`
        - SK = `PRODUCT#42/en/~`
- All languages
    - Query on `gsi`
        - SK = `PRODUCT#42/~/~`

#### Show comments with any combination of ratings

- Rating 1
    - Query on `gsi`
        - SK = `PRODUCT#42/en/1`
- Rating 1 or 5
    - Query on `gsi`
        - SK = `PRODUCT#42/en/1.5`
- Rating 2, 3 or 4
    - Query on `gsi`
        - SK = `PRODUCT#42/en/2.3.4`
- Rating 5, all languages
    - Query on `gsi`
        - SK = `PRODUCT#42/~/5`

#### Show 20 comments per page

- Run any of the above queries with `Limit` set to `20`. Use pagination tokens returned by DynamoDB to paginate through results. Performance will remain the same, regardless of what page is being requetsed.

#### Show a comment directly through its identifier

- Show comment `100001`
    - Query on table
        - PK = `COMMENT#100001`
        - Limit = 1

#### Show the most recent positive English comment for product 42

- Query on `gsi`
    - SK = `PRODUCT#42/en/4.5`
    - Limit = 1

#### Delete comment 100001

- Query on `table`
    - PK = `COMMENT#100001`

Delete each value for PK/SK returned in a batch.


## Building the table

As we've seen, this approach works by duplicating items with different keys.

Triggers are a great way to automate the creation of these duplicated items. A DynamoDB stream should be setup on the table and connected to a Lambda function. 

When a comment is created, the wildcard  `sk` should be used, i.e. `PRODUCT#42/~/~`. We will call this the _primary item_.

The Lambda function will be invoked with a change payload when the primary item is added, updated or deleted. From the attributes `language` and `rating`, it will generate the duplicate items and add them to the table. If `language` and `rating` subsequently change, previous duplicate items will be removed before the new duplicate set is added. Upon a delete modification, all duplicate items will be removed.

An additional attribute, `auto` is added to the automatically created items so that the Lambda function knows to take no action in response to items that it has created in the table.

## Problems

Creation of the duplicate records is not atomic. Creation of the duplicate items could fail after making partial changes. Although the Lambda will retry, it is possible that the table will be left in an inconsistent state. An hourly Lambda function could check the table, processing recent changes. Larger repair jobs implemented with Step Functions or EMR could be written to check integrity, but these may be costly to run on a large table.

There will come a point where the number of duplicates ceases to remain feasible if the _possible values_ set size increases.

```
2 ** 5 = 32
2 ** 6 = 64
2 ** 7 = 128
2 ** 8 = 256
...
```

As the number of duplicates increases, so does the number of operations and therefore cost. Payloads could be compressed with `snappy` or `bz` to potentially reduce consumed capacity units. This has the drawback of making the data illegible in the DynamoDB console and other tools.

## Summary

It is expected that this system will perform well, support lots of traffic and be very economical to run. 

Despite the identified caveats, we've successfully built a filtering solution without needing to use the post-query filters provided by DynamoDB. Nothing is free. We have paid for this by duplicating the data and taking on the corresponding compute, write and on-going storage costs. 

We should not be afraid of duplicating data to make our service work efficiently. Coupled with DynamoDB Streams and Lambda functions, duplicates are automatically maintained, without cluttering client code. The rating values `1, 2, 3, 4, 5` are just example _tags_ - they could be a set of any values.

This is not a complete solution, with certain areas requiring further investigation. Far more flexible querying could be achieved with DynamoDB coupled with Elasticsearch (or of course a relational database), but it proves just how powerful DynamoDB can be.

[I'd be happy to hear your thoughts on Twitter.](https://twitter.com/alexjreid) _Corrections and comments are most welcome._

## Links

If you found this interesting, you'll enjoy the following even more.

- [When to use (and when not to use) DynamoDB Filter Expressions](https://www.alexdebrie.com/posts/dynamodb-filter-expressions/)
- [Best Practices for Using Secondary Indexes in DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes.html)
- [NoSQL Workbench](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/workbench.html)
- [Video: Advanced Design Patterns at re:Invent 2019](https://www.youtube.com/watch?v=6yqfmXiZTlM)
