//! Rust baseline for `lake exe bench`: runs the same workloads with the official driver and
//! prints one JSON object. Usage: bench-rust <address> <database> <scan-rows> <lookups> <bulk>
use std::{env, thread, time::Instant};

use typedb_driver::{
    Addresses, Credentials, DriverOptions, DriverTlsConfig, Promise, TransactionType, TypeDBDriver,
};

#[allow(dead_code)]
struct Person {
    email: String,
    name: String,
    age: i64,
}

fn decode(row: &typedb_driver::answer::ConceptRow) -> Person {
    let get = |c: &str| row.get(c).unwrap().unwrap();
    Person {
        email: get("e").try_get_string().unwrap().to_owned(),
        name: get("n").try_get_string().unwrap().to_owned(),
        age: get("a").try_get_integer().unwrap(),
    }
}

fn scan(driver: &TypeDBDriver, db: &str, limit: usize) -> usize {
    let tx = driver.transaction(db, TransactionType::Read).unwrap();
    let q = format!("match $p isa person, has email $e, has name $n, has age $a; limit {limit};");
    let rows = tx.query(q).resolve().unwrap().into_rows();
    rows.map(|r| decode(&r.unwrap())).count()
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    sorted[((sorted.len() as f64 - 1.0) * p).round() as usize]
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let (address, db) = (&args[1], &args[2]);
    let scan_rows: usize = args[3].parse().unwrap();
    let lookups: usize = args[4].parse().unwrap();
    let bulk: usize = args[5].parse().unwrap();
    let driver = TypeDBDriver::new(
        Addresses::try_from_address_str(address).unwrap(),
        Credentials::new("admin", "password"),
        DriverOptions::new(DriverTlsConfig::disabled()),
    )
    .unwrap();

    let start = Instant::now();
    let n = scan(&driver, db, scan_rows);
    let scan_rows_per_s = n as f64 / start.elapsed().as_secs_f64();

    let mut lat = Vec::with_capacity(lookups);
    for i in 0..lookups {
        let start = Instant::now();
        let tx = driver.transaction(db, TransactionType::Read).unwrap();
        let q = format!("match $p isa person, has email \"p{}\", has email $e, has name $n, has age $a;", i % scan_rows);
        let rows: Vec<Person> = tx.query(q).resolve().unwrap().into_rows().map(|r| decode(&r.unwrap())).collect();
        assert_eq!(rows.len(), 1);
        drop(tx);
        lat.push(start.elapsed().as_secs_f64() * 1e6);
    }
    lat.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let bulk_db = format!("{db}_rust_bulk");
    if driver.databases().contains(&bulk_db).unwrap() {
        driver.databases().get(&bulk_db).unwrap().delete().unwrap();
    }
    driver.databases().create(&bulk_db).unwrap();
    {
        let tx = driver.transaction(&bulk_db, TransactionType::Schema).unwrap();
        tx.query("define attribute email, value string; attribute name, value string; attribute age, value integer; entity person, owns email @key, owns name, owns age;").resolve().unwrap();
        tx.commit().resolve().unwrap();
    }
    let start = Instant::now();
    {
        let tx = driver.transaction(&bulk_db, TransactionType::Write).unwrap();
        for i in 0..bulk {
            tx.query(format!("insert $p isa person, has email \"b{i}\", has name \"n{i}\", has age {i};")).resolve().unwrap();
        }
        tx.commit().resolve().unwrap();
    }
    let bulk_ms = start.elapsed().as_secs_f64() * 1e3;
    driver.databases().get(&bulk_db).unwrap().delete().unwrap();

    let start = Instant::now();
    thread::scope(|s| {
        for _ in 0..16 {
            s.spawn(|| scan(&driver, db, scan_rows.min(10000)));
        }
    });
    let concurrent_ms = start.elapsed().as_secs_f64() * 1e3;

    println!(
        "{{\"impl\":\"rust\",\"scan_rows\":{n},\"scan_rows_per_s\":{scan_rows_per_s:.1},\"lookup_p50_us\":{:.1},\"lookup_p99_us\":{:.1},\"bulk_insert_ms\":{bulk_ms:.1},\"concurrent_reads_ms\":{concurrent_ms:.1}}}",
        percentile(&lat, 0.5),
        percentile(&lat, 0.99)
    );
}
