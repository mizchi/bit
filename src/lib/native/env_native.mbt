///|
pub fn init_env_provider() -> Unit {
  let provider = @gitlib.EnvProvider::new(
    fn(name : String) { @sys.get_env_var(name) },
    fn() { @env.current_dir() },
  )
  @gitlib.set_env_provider(provider)
}
