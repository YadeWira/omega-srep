//! Omega SREP core library.
//!
//! Modules are ported from the C++ implementation one at a time and
//! verified against it by `osrep-conformance`, which runs the same
//! inputs through both and diffs the bytes. See `dedup` for the first
//! ported module.

pub mod aes;
pub mod container;
pub mod decompress;
pub mod dedup;
pub mod encoder;
pub mod future_lz;
pub mod hashes;
pub mod hashes_keyed;
pub mod inmem;
pub mod lz;
pub mod rolling;
pub mod util;
pub mod vmac;
