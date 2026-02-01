///| Integration tests with real large repositories

///|
/// Test mounting a large repository (helix - 7103 commits, 77MB .git)
fn get_helix_git_dir() -> String {
  "/Users/mz/ghq/github.com/helix-editor/helix/.git"
}

///|
/// Get HEAD commit from helix repository
fn get_helix_head() -> @git.ObjectId raise @git.GitError {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  let head_path = git_dir + "/HEAD"
  let head_content = osfs.read_file(head_path)
  let head_str = @utf8.decode_lossy(head_content[:]).trim().to_string()
  if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    let ref_str = @utf8.decode_lossy(ref_content[:]).trim().to_string()
    @git.ObjectId::from_hex(ref_str)
  } else {
    @git.ObjectId::from_hex(head_str)
  }
}

///|
/// Test: Mount large repo and read files (lazy - default)
test "integration: mount helix repo (lazy)" {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()

  // Skip if helix repo not available
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = get_helix_head()

  // Create lazy snapshot - should be fast (default config uses lazy_load: true)
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  assert_true(bitfs.is_lazy()) // Verify lazy mode is enabled
  assert_false(bitfs.is_dirty())

  // Read root directory
  let root_entries = bitfs.readdir(osfs, "")
  assert_true(root_entries.length() > 0)
  assert_true(root_entries.contains("Cargo.toml"))
  assert_true(root_entries.contains("README.md"))

  // Read README
  let readme = bitfs.read_file(osfs, "README.md")
  assert_true(readme.length() > 0)

  // Read nested file
  let cargo_toml = bitfs.read_file(osfs, "Cargo.toml")
  assert_true(cargo_toml.length() > 0)
}

///|
/// Test: Mount large repo with eager loading
test "integration: mount helix repo (eager)" {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()

  // Skip if helix repo not available
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = get_helix_head()

  // Create eager snapshot - loads all pack indexes upfront
  let config = FsConfig::eager()
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id, config~)
  assert_false(bitfs.is_lazy()) // Verify eager mode
  assert_false(bitfs.is_dirty())

  // Should work the same as lazy
  let root_entries = bitfs.readdir(osfs, "")
  assert_true(root_entries.length() > 0)
  let readme = bitfs.read_file(osfs, "README.md")
  assert_true(readme.length() > 0)
}

///|
/// Test: Mount, modify, and get changes
test "integration: mount, modify, get changes" {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = get_helix_head()
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)

  // Read original content
  let original = bitfs.read_file(osfs, "README.md")
  let original_str = @utf8.decode_lossy(original[:])

  // Modify in memory
  let modified = original_str + "\n\n## Added by Fs test\n"
  bitfs.write_string("README.md", modified)

  // Create a new file
  bitfs.write_string("test_file.txt", "Hello from Fs!")

  // Delete a file (mark as deleted)
  bitfs.remove_file("CHANGELOG.md")

  // Check dirty state
  assert_true(bitfs.is_dirty())

  // Get changed files
  let working_files = bitfs.get_working_files()
  assert_true(working_files.contains("README.md"))
  assert_true(working_files.contains("test_file.txt"))

  // Get deleted files
  let deleted_files = bitfs.get_deleted_files()
  assert_true(deleted_files.contains("CHANGELOG.md"))

  // Read modified content (should come from working layer)
  let read_back = bitfs.read_file(osfs, "README.md")
  let read_str = @utf8.decode_lossy(read_back[:])
  assert_true(read_str.has_suffix("## Added by Fs test\n"))

  // Read new file
  let new_file = bitfs.read_file(osfs, "test_file.txt")
  assert_eq(@utf8.decode_lossy(new_file[:]), "Hello from Fs!")

  // Rollback changes
  bitfs.rollback()
  assert_false(bitfs.is_dirty())

  // Verify original content is back
  let after_rollback = bitfs.read_file(osfs, "README.md")
  assert_eq(after_rollback.length(), original.length())
}

///|
/// Test: Diff generation (show changes)
test "integration: generate diff" {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = get_helix_head()
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)

  // Make some changes
  bitfs.write_string(
    "new_file.rs", "fn main() {\n    println!(\"Hello!\");\n}\n",
  )
  bitfs.write_string("another.txt", "Some content")

  // Get all changes as a simple diff representation
  let changes = collect_changes(bitfs, osfs)

  // Verify changes are collected
  assert_true(changes.length() >= 2)

  // Find our new files
  let mut found_rs = false
  let mut found_txt = false
  for change in changes {
    if change.path == "new_file.rs" {
      found_rs = true
      assert_eq(change.change_type, "added")
    }
    if change.path == "another.txt" {
      found_txt = true
      assert_eq(change.change_type, "added")
    }
  }
  assert_true(found_rs)
  assert_true(found_txt)
}

///|
/// Simple change representation
struct FileChange {
  path : String
  change_type : String // "added", "modified", "deleted"
  _content : Bytes?
}

///|
/// Collect all changes from the working layer
fn collect_changes(
  bitfs : Fs,
  osfs : &@git.RepoFileSystem,
) -> Array[FileChange] {
  let changes : Array[FileChange] = []

  // Get modified/added files
  let working_files = bitfs.get_working_files()
  for path in working_files {
    let content = bitfs.read_file(osfs, path) catch { _ => Bytes::new(0) }
    // Check if file existed before
    let is_new = not(file_exists_in_base(bitfs, osfs, path))
    let change_type = if is_new { "added" } else { "modified" }
    changes.push({ path, change_type, _content: Some(content) })
  }

  // Get deleted files
  let deleted_files = bitfs.get_deleted_files()
  for path in deleted_files {
    changes.push({ path, change_type: "deleted", _content: None })
  }
  changes
}

///|
/// Check if file exists in base tree (without creating new Fs)
fn file_exists_in_base(
  bitfs : Fs,
  osfs : &@git.RepoFileSystem,
  path : String,
) -> Bool {
  bitfs.exists_in_base(osfs, path)
}

///|
/// Print changes in a readable format
fn format_changes(changes : Array[FileChange]) -> String {
  let sb = StringBuilder::new()
  sb.write_string("Changes:\n")
  for change in changes {
    let prefix = match change.change_type {
      "added" => "+ "
      "modified" => "M "
      "deleted" => "- "
      _ => "? "
    }
    sb.write_string(prefix)
    sb.write_string(change.path)
    sb.write_string("\n")
  }
  sb.to_string()
}

///|
/// Demo test: Show workflow output
test "integration: demo workflow output" {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: helix repo not found")
    return
  }
  let commit_id = get_helix_head()
  println("HEAD: \{commit_id.to_hex()}")

  // Mount
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println("Mounted helix repo (lazy)")

  // Read some files
  let entries = bitfs.readdir(osfs, "")
  println("Root entries: \{entries.length()} files/dirs")

  // Make changes
  bitfs.write_string("NEW_FILE.md", "# New File\n\nCreated by Fs\n")
  bitfs.write_string("test/example.rs", "fn main() {}\n")
  bitfs.remove_file("CHANGELOG.md")

  // Show changes
  let changes = collect_changes(bitfs, osfs)
  println(format_changes(changes))

  // Rollback
  bitfs.rollback()
  assert_false(bitfs.is_dirty())
  println("Rolled back changes")
}

///|
/// Benchmark: Large repo lazy mount
test "bench_integration: helix lazy mount" (b : @bench.T) {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = try! get_helix_head()
  b.bench(fn() { b.keep(try! Fs::from_commit(osfs, git_dir, commit_id)) })
}

///|
/// Benchmark: Large repo read operations
test "bench_integration: helix read files" (b : @bench.T) {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = try! get_helix_head()
  let bitfs = try! Fs::from_commit(osfs, git_dir, commit_id)

  // Warm up cache
  let _ = try! bitfs.read_file(osfs, "README.md")
  let _ = try! bitfs.read_file(osfs, "Cargo.toml")
  b.bench(fn() {
    b.keep(try! bitfs.read_file(osfs, "README.md"))
    b.keep(try! bitfs.read_file(osfs, "Cargo.toml"))
  })
}

///|
/// Benchmark: Large repo full workflow
test "bench_integration: helix full workflow" (b : @bench.T) {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_helix_git_dir()
  if not(osfs.is_dir(git_dir)) {
    return
  }
  let commit_id = try! get_helix_head()
  let content = Bytes::make(1000, b'x')
  b.bench(fn() {
    // Mount
    let bitfs = try! Fs::from_commit(osfs, git_dir, commit_id)

    // Read
    let _ = try! bitfs.readdir(osfs, "")
    let _ = try! bitfs.read_file(osfs, "README.md")

    // Write (COW)
    for i in 0..<10 {
      bitfs.write_file("test/file\{i}.txt", content)
    }

    // Collect changes
    b.keep(collect_changes(bitfs, osfs))
  })
}
