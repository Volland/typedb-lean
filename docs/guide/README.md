# typedb-lean guide

1. [Getting started](01-getting-started.md): install, connect, run a first query.
2. [Transactions and errors](02-transactions.md): modes, commit and rollback, typed errors, conflict retry.
3. [Async](03-async.md): running transactions concurrently with `Std.Async`.
4. [Queries](04-queries.md): `typeql!`, escaping, raw splicing, answers.
5. [Decoding](05-decoding.md): row decoders, `deriving FromRow`, value types, streaming, fetch.
6. [The ORM](06-orm.md): entities, relations, references, subtypes, polymorphism, schema.
7. [Migrations](07-migrations.md): versioned up and down steps.
8. [Performance](08-performance.md): how the library is fast, and how to measure it.

The [social example](../../examples/social/Social.lean) uses every feature in one program.
