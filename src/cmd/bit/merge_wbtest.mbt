///|
test "merge help is handled by merge command path" {
  assert_true(command_handles_builtin_help("merge"))
}
