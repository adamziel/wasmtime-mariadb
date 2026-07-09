use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=MARIADBD_WASM");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is set by Cargo"));
    let out_wasm = out_dir.join("mariadbd.wasm");

    if let Some(path) = env::var_os("MARIADBD_WASM") {
        let path = PathBuf::from(path);
        println!("cargo:rerun-if-changed={}", path.display());
        let wasm = fs::read(&path).unwrap_or_else(|err| {
            panic!("failed to read MARIADBD_WASM at {}: {err}", path.display())
        });
        validate_wasm(&wasm, &path);
        fs::write(&out_wasm, wasm).unwrap_or_else(|err| {
            panic!(
                "failed to write embedded wasm to {}: {err}",
                out_wasm.display()
            )
        });
        println!(
            "cargo:rustc-env=EMBEDDED_MARIADBD_WASM_SOURCE={}",
            path.display()
        );
        return;
    }

    if env::var_os("CARGO_FEATURE_DEV_FIXTURE").is_some() {
        println!("cargo:rerun-if-changed=fixtures/dev-command.wat");
        let wat = fs::read_to_string("fixtures/dev-command.wat")
            .expect("failed to read fixtures/dev-command.wat");
        let wasm = wat::parse_str(&wat).expect("failed to compile dev fixture WAT");
        fs::write(&out_wasm, wasm).unwrap_or_else(|err| {
            panic!(
                "failed to write dev fixture wasm to {}: {err}",
                out_wasm.display()
            )
        });
        println!("cargo:rustc-env=EMBEDDED_MARIADBD_WASM_SOURCE=fixtures/dev-command.wat");
        return;
    }

    panic!(
        "MARIADBD_WASM must point to a compiled MariaDB server WebAssembly module. \
         For runner-only verification, build with --features dev-fixture."
    );
}

fn validate_wasm(wasm: &[u8], path: &PathBuf) {
    if !wasm.starts_with(b"\0asm") {
        panic!(
            "MARIADBD_WASM at {} is not a WebAssembly binary; expected magic bytes 00 61 73 6d",
            path.display()
        );
    }
}
