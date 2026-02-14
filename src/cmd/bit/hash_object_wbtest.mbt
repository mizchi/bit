///|
test "hash-object: standalone error only when -w and compat format is sha256" {
  assert_true(hash_object_requires_standalone_error(true, Some("sha256")))
  assert_false(hash_object_requires_standalone_error(false, Some("sha256")))
  assert_false(hash_object_requires_standalone_error(true, Some("sha1")))
  assert_false(hash_object_requires_standalone_error(true, None))
}

///|
test "hash-object: standalone check normalizes compat format value" {
  assert_true(hash_object_requires_standalone_error(true, Some(" \"SHA256\" ")))
}
