// This file is Copyright its original authors, visible in version control history.
//
// This file is licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0> or the MIT license <LICENSE-MIT or
// http://opensource.org/licenses/MIT>, at your option. You may not use this file except in
// accordance with one or both of these licenses.

//! Dart bindgen entry point.
//!
//! uniffi-dart is pinned to uniffi 0.31.1, and 0.31's explicit-UDL CLI
//! rejects UDL files that don't live inside a crate's `src/`. ldk-node's
//! UDL is at `bindings/ldk_node.udl`, so we run uniffi-dart in library
//! mode, which resolves UDL locations through a
//! `BindgenCrateConfigSupplier`. The default supplier hard-codes
//! `<crate_root>/src/<namespace>.udl`; we supply our own
//! ([`LdkNodePathSupplier`]) that points at the canonical `bindings/`
//! path instead — avoiding an otherwise-needless symlink.

use anyhow::{bail, Context, Result};
use camino::{Utf8Path, Utf8PathBuf};
use uniffi_bindgen::BindgenCrateConfigSupplier;
use uniffi_dart::gen::DartBindingGenerator;

/// Resolves `ldk_node`'s UDL + uniffi.toml from their canonical locations
/// outside `src/`. See the module-level doc for the why.
struct LdkNodePathSupplier {
	repo_root: Utf8PathBuf,
}

impl BindgenCrateConfigSupplier for LdkNodePathSupplier {
	fn get_udl(&self, crate_name: &str, _udl_name: &str) -> Result<String> {
		if crate_name != "ldk_node" {
			bail!("LdkNodePathSupplier only knows the 'ldk_node' crate, got '{crate_name}'");
		}
		let path = self.repo_root.join("bindings").join("ldk_node.udl");
		std::fs::read_to_string(&path)
			.with_context(|| format!("reading canonical UDL at {path}"))
	}

	fn get_toml_path(&self, crate_name: &str) -> Option<Utf8PathBuf> {
		(crate_name == "ldk_node").then(|| {
			self.repo_root.join("bindings").join("dart").join("rust").join("uniffi.toml")
		})
	}

	fn get_toml(&self, crate_name: &str) -> Result<Option<toml::value::Table>> {
		let Some(path) = self.get_toml_path(crate_name) else {
			return Ok(None);
		};
		let contents = std::fs::read_to_string(&path)
			.with_context(|| format!("reading uniffi.toml at {path}"))?;
		Ok(Some(toml::de::from_str(&contents)?))
	}
}

fn main() {
	let args: Vec<String> = std::env::args().collect();
	let language =
		args.iter().position(|arg| arg == "--language").and_then(|idx| args.get(idx + 1));

	match language {
		Some(lang) if lang == "dart" => generate_dart(&args).expect("dart bindgen failed"),
		_ => uniffi::uniffi_bindgen_main(),
	}
}

fn generate_dart(args: &[String]) -> Result<()> {
	let library_path = args
		.iter()
		.find(|arg| {
			!arg.starts_with("--")
				&& (arg.ends_with(".dylib") || arg.ends_with(".so") || arg.ends_with(".dll"))
		})
		.context("library path not found — pass a .dylib/.so/.dll positionally")?;
	let out_dir = args
		.iter()
		.position(|arg| arg == "--out-dir")
		.and_then(|idx| args.get(idx + 1))
		.context("--out-dir is required")?;

	// `repo_root` = three dirs up from this bin's manifest (bindings/dart/rust → repo root).
	let manifest_dir = Utf8PathBuf::from(env!("CARGO_MANIFEST_DIR"));
	let repo_root = manifest_dir
		.ancestors()
		.nth(3)
		.context("could not resolve repo root from CARGO_MANIFEST_DIR")?
		.to_owned();

	let supplier = LdkNodePathSupplier { repo_root };
	uniffi_bindgen::library_mode::generate_bindings(
		Utf8Path::new(library_path),
		None, // crate-name filter — bind everything in the cdylib
		&DartBindingGenerator,
		&supplier,
		None, // config-file override — supplier already returns the right toml
		Utf8Path::new(out_dir),
		true, // try_format_code
	)?;
	Ok(())
}
