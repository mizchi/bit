///|
fn issues_contain(issues : Array[String], needle : String) -> Bool {
  for issue in issues {
    if issue.contains(needle) {
      return true
    }
  }
  false
}

///|
test "workspace: flow graph conversion preserves node shape" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.required = false
  dep.depends_on = ["root"]
  let manifest : WorkspaceManifest = { version: 1, nodes: [root, dep] }
  let flow_nodes = workspace_flow_nodes(manifest)
  assert_eq(flow_nodes.length(), 2)
  assert_eq(flow_nodes[0].id, "root")
  assert_eq(flow_nodes[1].id, "dep")
  assert_eq(flow_nodes[1].required, false)
  assert_eq(flow_nodes[1].depends_on.length(), 1)
  assert_eq(flow_nodes[1].depends_on[0], "root")
}

///|
test "workspace: flow ir keeps selected dependency edges" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  root.tasks["test"] = "echo root"
  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.depends_on = ["root"]
  dep.tasks["test"] = "echo dep"
  let extra = workspace_new_node()
  extra.id = "extra"
  extra.path = "extra"
  extra.depends_on = []
  extra.tasks["test"] = "echo extra"
  let manifest : WorkspaceManifest = { version: 1, nodes: [root, dep, extra] }
  let selected : Map[String, Bool] = { "root": true, "dep": true }
  let ir = workspace_flow_ir(manifest, selected, "test")
  assert_eq(ir.nodes.length(), 2)
  assert_eq(ir.tasks.length(), 2)
  let task_map : Map[String, @bitflow.FlowTask] = {}
  for task in ir.tasks {
    task_map[task.id] = task
  }
  assert_true(task_map.get("root") is Some(_))
  assert_true(task_map.get("dep") is Some(_))
  assert_true(task_map.get("extra") is None)
  match task_map.get("dep") {
    Some(task) => {
      assert_eq(task.needs.length(), 1)
      assert_eq(task.needs[0], "root")
    }
    None => fail("dep task missing")
  }
}

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
  let manifest : WorkspaceManifest = {
    version: 1,
    nodes: [workspace_new_node(), node],
  }
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
test "workspace: flow template manifest scaffolds expected node graph" {
  let manifest = workspace_manifest_for_template(Some("flow")) catch {
    err => fail("unexpected error: \{err.to_string()}")
  }
  assert_eq(manifest.nodes.length(), 4)
  assert_eq(manifest.nodes[0].id, "root")
  assert_eq(manifest.nodes[1].id, "dep")
  assert_eq(manifest.nodes[2].id, "leaf")
  assert_eq(manifest.nodes[3].id, "extra")
  assert_eq(manifest.nodes[1].depends_on[0], "root")
  assert_eq(manifest.nodes[2].depends_on[0], "dep")
  let root_task = manifest.nodes[0].tasks.get("test").unwrap_or("")
  assert_true(root_task.contains("BIT_WORKSPACE_FLOW_LOG_DIR"))
}

///|
test "workspace: manifest template rejects unknown name" {
  ignore(
    workspace_manifest_for_template(Some("nope-template")) catch {
      @git.GitError::InvalidObject(message) => {
        assert_true(message.contains("unknown workspace template"))
        return ()
      }
      err => fail("unexpected error: \{err.to_string()}")
    },
  )
  fail("expected invalid object error")
}

///|
test "workspace: expand affected follows workspace dependency graph" {
  let root = workspace_new_node()
  root.id = "root"
  root.path = "."
  root.depends_on = []
  let dep = workspace_new_node()
  dep.id = "dep"
  dep.path = "dep"
  dep.depends_on = ["root"]
  let leaf = workspace_new_node()
  leaf.id = "leaf"
  leaf.path = "leaf"
  leaf.depends_on = ["dep"]
  let extra = workspace_new_node()
  extra.id = "extra"
  extra.path = "extra"
  extra.depends_on = []
  let manifest : WorkspaceManifest = {
    version: 1,
    nodes: [root, dep, leaf, extra],
  }
  let initial : Map[String, Bool] = { "dep": true }
  let affected = expand_affected_node_ids(manifest, initial)
  assert_eq(affected.get("root") is Some(_), true)
  assert_eq(affected.get("dep") is Some(_), true)
  assert_eq(affected.get("leaf") is Some(_), true)
  assert_eq(affected.get("extra") is Some(_), false)
}

///|
test "workspace: implicit translation activates inside workspace root tree" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-translate-" +
    get_current_timestamp().to_string()
  let nested = root + "/nested/leaf"
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(nested)
  fs.write_string(root + "/.bit/workspace.toml", "version = 1\n")
  let (cmd, rest) = workspace_translate_implicit_command(
    Some(nested),
    "status",
    [],
  )
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
  let root = "/tmp/bit-test-workspace-skip-" +
    get_current_timestamp().to_string()
  let fs = @osfs.OsFs::new()
  fs.mkdir_p(root)
  let (cmd, rest) = workspace_translate_implicit_command(Some(root), "status", [
    "--short",
  ])
  assert_eq(cmd, "status")
  assert_eq(rest.length(), 1)
  assert_eq(rest[0], "--short")
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "workspace: flow cache key keeps task and node scope" {
  let key = workspace_flow_cache_key("test", "pkg")
  assert_eq(key, "test::pkg")
}

///|
test "workspace: flow fingerprint changes when dependency signature changes" {
  let node = workspace_new_node()
  node.id = "pkg"
  node.path = "pkg"
  node.depends_on = ["root"]
  let signatures : Map[String, String] = { "pkg": "pkg-1", "root": "root-1" }
  let fp1 = workspace_flow_fingerprint("test", "just test", node, signatures)
  signatures["root"] = "root-2"
  let fp2 = workspace_flow_fingerprint("test", "just test", node, signatures)
  assert_eq(fp1 == fp2, false)
}

///|
test "workspace: directory hash changes when file content changes" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-dirhash-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/nested")
  fs.write_string(root + "/nested/file.txt", "hello\n")
  let hash1 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  fs.write_string(root + "/nested/file.txt", "hello world\n")
  let hash2 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  assert_eq(hash1 == hash2, false)
  fs.remove_file(root + "/nested/file.txt") catch {
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
test "workspace: directory hash ignores .git and .bit metadata dirs" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-dirhash-ignore-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root)
  fs.write_string(root + "/tracked.txt", "payload\n")
  let hash1 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  fs.mkdir_p(root + "/.git")
  fs.mkdir_p(root + "/.bit")
  fs.write_string(root + "/.git/HEAD", "ref: refs/heads/main\n")
  fs.write_string(root + "/.bit/WORKSPACE", "metadata\n")
  let hash2 = @fingerprint.directory_fingerprint(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  assert_eq(hash1, hash2)
  fs.remove_file(root + "/tracked.txt") catch {
    _ => ()
  }
  fs.remove_file(root + "/.git/HEAD") catch {
    _ => ()
  }
  fs.remove_file(root + "/.bit/WORKSPACE") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.git") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
async test "workspace: node signature changes by fingerprint mode" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-signature-mode-" +
    get_current_timestamp().to_string()
  ignore(@process.run("rm", ["-rf", root], inherit_env=true)) catch {
    _ => ()
  }
  fs.mkdir_p(root)
  let init_code = @process.run(
    "git",
    ["init", "-b", "main"],
    inherit_env=true,
    cwd=root,
  ) catch {
    _ => -1
  }
  if init_code != 0 {
    ignore(@process.run("rm", ["-rf", root], inherit_env=true)) catch {
      _ => ()
    }
    return
  }
  fs.write_string(root + "/file.txt", "payload\n")
  let fast = workspace_node_directory_signature_with_mode(
    fs,
    root,
    @fingerprint.FingerprintMode::Fast,
  )
  let git = workspace_node_directory_signature_with_mode(
    fs,
    root,
    @fingerprint.FingerprintMode::GitCompat,
  )
  match (fast, git) {
    (Some(fast_sig), Some(git_sig)) => assert_eq(fast_sig == git_sig, false)
    _ => fail("workspace signature should exist for initialized repository")
  }
  ignore(@process.run("rm", ["-rf", root], inherit_env=true)) catch {
    _ => ()
  }
}

///|
test "workspace: path containment rejects escape outside workspace root" {
  let workspace_root = "/tmp/ws"
  let inside_path = workspace_node_abs_path(workspace_root, "dep")
  let escaped_path = workspace_node_abs_path(workspace_root, "../outside")
  assert_eq(path_is_within_workspace_root(workspace_root, inside_path), true)
  assert_eq(path_is_within_workspace_root(workspace_root, escaped_path), false)
}

///|
test "workspace: manifest issues include governance and security violations" {
  let fs = @osfs.OsFs::new()
  let node1 = workspace_new_node()
  node1.id = "dup"
  node1.path = "."
  node1.depends_on = []
  let node2 = workspace_new_node()
  node2.id = "dup"
  node2.path = "../outside"
  node2.depends_on = ["missing"]
  let manifest : WorkspaceManifest = { version: 1, nodes: [node1, node2] }
  let issues = workspace_manifest_issues(fs, "/tmp/ws", manifest, false)
  assert_true(issues_contain(issues, "duplicate node id"))
  assert_true(issues_contain(issues, "escapes workspace root"))
  assert_true(issues_contain(issues, "depends on unknown node"))
}

///|
test "workspace: implicit translation includes flow command inside workspace" {
  let fs = @osfs.OsFs::new()
  let root = "/tmp/bit-test-workspace-flow-translate-" +
    get_current_timestamp().to_string()
  let nested = root + "/nested"
  fs.mkdir_p(root + "/.bit")
  fs.mkdir_p(nested)
  fs.write_string(root + "/.bit/workspace.toml", "version = 1\n")
  let (cmd, rest) = workspace_translate_implicit_command(Some(nested), "flow", [
    "test",
  ])
  assert_eq(cmd, "workspace")
  assert_eq(rest.length(), 2)
  assert_eq(rest[0], "flow")
  assert_eq(rest[1], "test")
  fs.remove_file(root + "/.bit/workspace.toml") catch {
    _ => ()
  }
  fs.remove_dir(root + "/.bit") catch {
    _ => ()
  }
  fs.remove_dir(root + "/nested") catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}
