///|
pub struct EnvProvider {
  get : (String) -> String?
  current_dir : () -> String?
}

///|
pub fn EnvProvider::new(
  get : (String) -> String?,
  current_dir : () -> String?,
) -> EnvProvider {
  { get, current_dir }
}

///|
pub fn EnvProvider::none() -> EnvProvider {
  { get: fn(_ : String) { None }, current_dir: () => None }
}

///|
priv struct EnvProviderBox {
  mut value : EnvProvider
}

///|
let env_provider_box : EnvProviderBox = { value: EnvProvider::none() }

///|
pub fn set_env_provider(provider : EnvProvider) -> Unit {
  env_provider_box.value = provider
}

///|
pub fn env_get(name : String) -> String? {
  (env_provider_box.value.get)(name)
}

///|
pub fn env_current_dir() -> String? {
  (env_provider_box.value.current_dir)()
}
