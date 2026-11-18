// `edit-rust set FILE EDITS [SELECTOR]`: the Rust arms of the edit lane, by the file's format. An `.html` file is
// lol_html's streaming rewrite (html.rs), a `.toml` file toml_edit's document (toml_arm.rs).
mod html;
mod toml_arm;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let html = args.get(2).is_some_and(|file| file.ends_with(".html"));
    let result = if html { html::run(&args) } else { toml_arm::run(&args) };
    if let Err(e) = result {
        eprintln!("edit-rust: {e}");
        std::process::exit(1);
    }
}
