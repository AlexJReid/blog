+++ 
draft = false
date = 2020-01-22T21:37:35Z
title = "DynamoDB modelling in a spreadsheet"
description = "Easily load data from a spreadsheet to test out your DynamoDB table design"
slug = "" 
tags = ['aws','dynamodb','data']
categories = []
externalLink = ""
series = []
+++

When working with DynamoDB, it is common practice to minimise the number of tables used, ideally down to just one.

Techniques such as sparse indexes and GSI overloading allow a lot of flexibility and efficiency.

Designing a good schema that supports your query patterns can be challenging. Often it is nice to try things out with a small amount of data. I personally find it convenient to enter data into a spreadsheet and play around with it there.

When ready to try out an approach with DynamoDB, it's a hassle to then create the items through the AWS Console or CLI. 

So, on my way to work this morning, I hacked together a script to ease the process of loading from a spreadsheet of a specific format into a DynamoDB table.

It's available at https://github.com/AlexJReid/dynamodb-dev-importer

The script:
- reads a CSV file (exported from your spreadsheet) and imports it into a DynamoDB table 
- columns 0 and 1 are used for the key: partition key `pk: S` and sort key `sk: S` - your target table needs these keys defined
- column 2, if not an empty string, is set to `data: S`
- all other columns are added as non-key attributes

Your CSV should contain columns for:
- pk
- sk
- data (optional)
- anything after those three can contain arbitrary attributes of form `attribute_name: value` i.e. `city: Edinburgh`

Example row:
```
PERSON-1,sales-Q1-2019,Alex,jan: 12012,feb: 1927
```

Will yield an item like this:
```
{
    pk: 'PERSON-1',
    sk: 'sales-Q1-2019',
    data: 'Alex',
    jan: 12012,
    feb 1927
}
```

For a full example, take a look at [example.csv](https://github.com/AlexJReid/dynamodb-dev-importer/blob/master/example.csv).

## Key ideas
- Table consists of partition key `pk: S` and sort key `sk: S` - their meaning varies depending on the item
- A secondary index swaps the sort and partition keys, so the partition key is `sk: S` and sort key `pk: S`
- A final secondary index uses `sk: S` and `data: S` where data is an arbitrary value you might want to search for, the meaning of `data` depends on the item it is part of
- Group items through a shared partition key, store _sub_ items with a sort key e.g. 
    - e.g. `pk:PERSON-1, sk:sales-Q1-2019, jan:12012, feb:1927`

AWS recently [released a preview build of a tool called NoSQL Workbench](https://aws.amazon.com/blogs/aws/nosql-workbench-for-amazon-dynamodb-available-in-preview/). It builds on the above ideas. I've tried it out and it seems pretty good, but I am a luddite and am faster working in a spreadsheet right now. I'd certainly recommend giving it a try.

## Useful resources
- https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes.html
- https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/workbench.html
- https://www.youtube.com/watch?v=6yqfmXiZTlM