///|
test "workspace: parse manifest with dependencies and tasks" {
  let manifest_text =
    #|version = 1
    #|
    #|[[nodes]]
    #|id = "root"
    #|path = "."
    #|required = true
    #|depends_on = []
    #|task.test = "just test"
    #|
    #|[[nodes]]
    #|id = "foo"
    #|path = "foo"
    #|required = false
    #|depends_on = ["root"]
    #|task.check = "just check"
  let parsed = parse_workspace_manifest(manifest_text)
  assert_eq(parsed.version, 1)
  assert_eq(parsed.nodes.length(), 2)
  let root = parsed.nodes[0]
  let foo = parsed.nodes[1]
  assert_eq(root.id, "root")
  assert_eq(root.path, ".")
  assert_eq(root.required, true)
  assert_eq(root.depends_on.length(), 0)
  assert_eq(root.tasks.get("test").unwrap_or(""), "just test")
  assert_eq(foo.id, "foo")
  assert_eq(foo.required, false)
  assert_eq(foo.depends_on.length(), 1)
  assert_eq(foo.depends_on[0], "root")
  assert_eq(foo.tasks.get("check").unwrap_or(""), "just check")
}

///|
test "workspace: format and parse roundtrip keeps node shape" {
  let node = workspace_new_node()
  node.id = "pkg"
  node.path = "packages/pkg"
  node.required = false
  node.depends_on = ["root"]
  node.tasks["lint"] = "just lint"
  let manifest : WorkspaceManifest = { version: 1, nodes: [workspace_new_node(), node] }
  let text = format_workspace_manifest(manifest)
  let reparsed = parse_workspace_manifest(text)
  assert_eq(reparsed.nodes.length(), 2)
  assert_eq(reparsed.nodes[1].id, "pkg")
  assert_eq(reparsed.nodes[1].path, "packages/pkg")
  assert_eq(reparsed.nodes[1].required, false)
  assert_eq(reparsed.nodes[1].depends_on.length(), 1)
  assert_eq(reparsed.nodes[1].depends_on[0], "root")
  assert_eq(reparsed.nodes[1].tasks.get("lint").unwrap_or(""), "just lint")
}

///|
test "workspace: implicit translation activates inside workspace root tree" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-translate-" + get_current_timestamp().to_string()
  let nested = root + "/nested/leaf"
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(nested)
  fs.write_string(root + "/.bit/workspace.toml", "version = 1\n")
  let (cmd, rest) = workspace_translate_implicit_command(Some(nested), "status", [])
  assert_eq(cmd, "workspace")
  assert_eq(rest.length(), 1)
  assert_eq(rest[0], "status")
  fs.remove_file(root + "/.bit/workspace.toml") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested/leaf") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "workspace: implicit translation is skipped outside workspace" {
  let root = "/tmp/bit-test-workspace-skip-" + get_current_timestamp().to_string()
  let fs = @osfs.OsFs::new()
  fs.mkdir_p(root)
  let (cmd, rest) = workspace_translate_implicit_command(Some(root), "status", ["--short"])
  assert_eq(cmd, "status")
  assert_eq(rest.length(), 1)
  assert_eq(rest[0], "--short")
  fs.remove_dir(root) catch {
    _ => ()
  }
}
