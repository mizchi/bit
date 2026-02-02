///| Tree mode helpers

///|
fn is_tree_mode(mode : String) -> Bool {
  mode == "040000" || mode == "40000"
}

///|
fn is_gitlink_mode_int(mode : Int) -> Bool {
  mode == 0o160000
}
