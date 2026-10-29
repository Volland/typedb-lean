# Performance

## What makes it fast

- **Batched decoding.** A decoder knows its columns and what it needs of each (value, label, IID). One native call returns those concepts for up to `batchSize` rows (default 256), with no intermediate objects per concept.
- **Prefetch 512.** The server sends up to `prefetch` answers ahead of the client. The C driver's default is small enough to make a scan wait on the network; 512 makes scans as fast as the Rust driver's.
- **Closes in the background.** Closing a transaction does not wait for the driver to finish closing it, just as the Rust driver's `drop` doesn't. Deleting a database and closing the driver wait for pending closes.
- **Loops compile to loops.** `Tx` is a `ReaderT` over `EIO`, so `for` and `repeat` in a transaction body become plain loops without allocating.
- **Dedicated threads.** Each async transaction blocks only its own thread.

## Measuring

```sh
lake exe bench          # 100,000-row scan, 1,000 lookups, 10,000-entity bulk insert, 16 concurrent reads
lake exe bench --ci     # smaller sizes, targets relaxed by 10%
lake exe bench --profile
```

The benchmark runs the same workloads with the official Rust driver (`bench/rust`, the same pinned version) against the same server, prints a comparison, and writes `bench/report.json`. It fails if the scan reaches less than 80% of the Rust driver's rows per second, or if the lookup p50 exceeds 1.1 times the Rust driver's.

## Known limits

The upstream driver (3.14.0) keeps about 600 bytes per transaction it has opened, in its Rust and C APIs alike. Long-running processes that open millions of transactions grow accordingly. The library's own allocations are released (`lake test -- native:`).
