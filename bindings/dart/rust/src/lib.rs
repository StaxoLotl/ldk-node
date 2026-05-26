// This file is Copyright its original authors, visible in version control history.
//
// This file is licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license <LICENSE-MIT or
// http://opensource.org/licenses/MIT>, at your option. You may not use this file except in
// accordance with one or both of these licenses.

// The cdylib produced by this crate is what Dart loads at runtime via the
// native-assets hook. We rely entirely on `ldk-node`'s own build.rs +
// `uniffi::include_scaffolding!("ldk_node")` (gated on its `uniffi` feature,
// which is enabled in Cargo.toml) to provide the FFI scaffolding and
// proc-macro metadata symbols. We just re-export the public surface.
#[allow(unused_imports)]
pub use ldk_node::*;
