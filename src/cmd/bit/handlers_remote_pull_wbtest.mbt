///|
test "pull: detect submodule replaced by file" {
  let from_modes : Map[String, Int] = {}
  from_modes["sub1"] = 0o160000
  let to_modes : Map[String, Int] = {}
  to_modes["sub1"] = 0o100644
  let replaced = find_submodule_replaced_with_non_submodule(
    from_modes, to_modes,
  )
  assert_eq(replaced, Some("sub1"))
}

///|
test "pull: do not flag submodule removal" {
  let from_modes : Map[String, Int] = {}
  from_modes["sub1"] = 0o160000
  let to_modes : Map[String, Int] = {}
  let replaced = find_submodule_replaced_with_non_submodule(
    from_modes, to_modes,
  )
  assert_eq(replaced, None)
}
