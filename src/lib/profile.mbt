///| Profiling helpers

///|
fn profile_enabled() -> Bool {
  match @gitio.env_get("BIT_PROFILE") {
    Some(v) => v != "" && v != "0"
    None => false
  }
}

///|
fn profile_start(enabled : Bool) -> @bench.Timestamp? {
  if enabled {
    Some(@bench.monotonic_clock_start())
  } else {
    None
  }
}

///|
fn profile_lap(
  enabled : Bool,
  label : String,
  start : @bench.Timestamp?,
) -> @bench.Timestamp? {
  if not(enabled) {
    return start
  }
  match start {
    Some(ts) => {
      let elapsed_us = @bench.monotonic_clock_end(ts)
      let elapsed_ms = elapsed_us / 1000.0
      println("\{label}: \{elapsed_ms}ms")
      Some(@bench.monotonic_clock_start())
    }
    None => Some(@bench.monotonic_clock_start())
  }
}
