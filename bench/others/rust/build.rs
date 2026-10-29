// Builds the static libdateparsa, ReleaseFast as a release archive's is, and
// links it.
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("../../..");
    let prefix = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("dateparsa");
    let status = Command::new("zig")
        .args(["build", "lib", "-Doptimize=ReleaseFast", "--prefix"])
        .arg(&prefix)
        .current_dir(&root)
        .status()
        .expect("zig is not on PATH");
    assert!(status.success(), "zig build lib failed");
    println!("cargo:rustc-link-search=native={}", prefix.join("lib").display());
    println!("cargo:rustc-link-lib=static=dateparsa");
    for path in ["src", "build.zig", "build.zig.zon"] {
        println!("cargo:rerun-if-changed={}", root.join(path).display());
    }
}
