///| Native time implementation using C FFI

///|
extern "C" fn c_time(ptr : Int) -> Int64 = "time"

///|
pub fn get_current_timestamp() -> Int64 {
  c_time(0)
}
