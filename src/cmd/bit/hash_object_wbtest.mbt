///|
test "hash-object: delegate only when -w and compat format is sha256" {
  assert_true(
    hash_object_should_delegate_to_real_git(true, Some("sha256"), true),
  )
  assert_false(
    hash_object_should_delegate_to_real_git(false, Some("sha256"), true),
  )
  assert_false(
    hash_object_should_delegate_to_real_git(true, Some("sha1"), true),
  )
  assert_false(hash_object_should_delegate_to_real_git(true, None, true))
}

///|
test "hash-object: delegate check normalizes compat format value" {
  assert_true(
    hash_object_should_delegate_to_real_git(true, Some(" \"SHA256\" "), true),
  )
}

///|
test "hash-object: unavailable real git path keeps pure execution" {
  assert_false(
    hash_object_should_delegate_to_real_git(true, Some("sha256"), false),
  )
}
