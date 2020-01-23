+++ 
draft = false
date = 2020-01-22T21:37:35Z
title = "DynamoDB modelling in a spreadsheet with ddbimp"
description = "Easily load data from a spreadsheet to test out your DynamoDB table design with ddbimp"
slug = "" 
tags = ['aws','dynamodb','data','ddbimp']
categories = []
externalLink = ""
series = []
+++

When working with DynamoDB, it is common practice to minimise the number of tables used, ideally down to just one.

Techniques such as sparse indexes and GSI overloading allow a lot of flexibility and efficiency.

Designing a good schema that supports your query patterns can be challenging. Often it is nice to try things out with a small amount of data. I personally find it convenient to enter data into a spreadsheet and play around with it there.

When ready to try out an approach with DynamoDB, it's a hassle to then create the items through the AWS Console or CLI. 

I therefore created a utility eases the process of populating a DynamoDB table from a CSV that follows a specific format.

## Install and run
You can install and run it with

```
$ pip install ddbimp
$ ddbimp --table people --region eu-west-1 --skip 1 example.csv
```

You can find the code on [Github](https://github.com/AlexJReid/dynamodb-dev-importer) too.

### Expected format


| pk       | sk            | data |            |           |
| -------- | ------------- | ---- | ---------- | --------- | 
| PERSON-1 | sales-Q1-2019 | Alex | jan: 12012 | feb: 1927 |

Your spreadsheet (and exported CSV) should contain columns for:
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

For a full example CSV, take a look at [example.csv](https://github.com/AlexJReid/dynamodb-dev-importer/blob/master/example.csv).

## Key ideas
- Table consists of partition key `pk: S` and sort key `sk: S` - their meaning varies depending on the item
- A secondary index swaps the sort and partition keys, so the partition key is `sk: S` and sort key `pk: S`
- A final secondary index uses `sk: S` and `data: S` where data is an arbitrary value you might want to search for, the meaning of `data` depends on the item it is part of
- Group items through a shared partition key, store _sub_ items with a sort key e.g. 
    - e.g. `pk:PERSON-1, sk:sales-Q1-2019, jan:12012, feb:1927`

AWS recently [released a preview build of a tool called NoSQL Workbench](https://aws.amazon.com/blogs/aws/nosql-workbench-for-amazon-dynamodb-available-in-preview/). It builds on the above ideas. I've tried it out and it seems pretty good, but I am a luddite and am faster working in a spreadsheet right now. I'd certainly recommend giving it a try.

## Useful resources
- [AWS Docs: Indexes best practices](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-indexes.html)
- [AWS Docs: NoSQL Workbench](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/workbench.html)
- [Video: Advanced Design Patterns at re:Invent 2019](https://www.youtube.com/watch?v=6yqfmXiZTlM)