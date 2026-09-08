fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("src/snapshot.m")
            .flag("-fobjc-arc")
            .flag("-fblocks")
            .compile("native_snapshot");
        println!("cargo:rustc-link-lib=framework=WebKit");
        println!("cargo:rustc-link-lib=framework=AppKit");
        println!("cargo:rerun-if-changed=src/snapshot.m");
    }
    tauri_build::build();
}
