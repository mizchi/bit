///|
pub fn init_env_provider() -> Unit {
  let provider = @gitio.EnvProvider::new(
    fn(name : String) { @sys.get_env_var(name) },
    @env.current_dir,
  )
  @gitio.set_env_provider(provider)
}
