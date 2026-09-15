fn main() {
    let cfg: Config = serde_json::from_reader(io::stdin().lock())?;
    println!("Hello, world!");
}
