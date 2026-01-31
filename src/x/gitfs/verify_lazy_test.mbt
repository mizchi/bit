///| Verification test for lazy loading on real repositories

///|
test "verify: lazy loading on helix repo" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/Users/mz/ghq/github.com/helix-editor/helix/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: helix repo not found")
    return
  }

  // Get HEAD
  let head_path = git_dir + "/HEAD"
  let head_content = osfs.read_file(head_path)
  let head_str = @utf8.decode_lossy(head_content[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
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
  println("HEAD: \{commit_id}")

  // Test lazy loading (default)
  println("\n=== Lazy Loading (default) ===")
  let gitfs_lazy = GitFs::from_commit(osfs, git_dir, commit_id)
  println("is_lazy: \{gitfs_lazy.is_lazy()}")

  // Read root directory
  let root = gitfs_lazy.readdir(osfs, "")
  println("Root entries: \{root.length()}")

  // Read some files
  let readme = gitfs_lazy.read_file(osfs, "README.md")
  println("README.md: \{readme.length()} bytes")
  let cargo = gitfs_lazy.read_file(osfs, "Cargo.toml")
  println("Cargo.toml: \{cargo.length()} bytes")

  // Read nested files
  let helix_term = gitfs_lazy.readdir(osfs, "helix-term")
  println("helix-term/: \{helix_term.length()} entries")
  let src_files = gitfs_lazy.readdir(osfs, "helix-term/src")
  println("helix-term/src/: \{src_files.length()} entries")

  // Read a deeply nested file
  if src_files.contains("main.rs") {
    let main_rs = gitfs_lazy.read_file(osfs, "helix-term/src/main.rs")
    println("helix-term/src/main.rs: \{main_rs.length()} bytes")
  }

  // Test COW write
  println("\n=== COW Write Test ===")
  gitfs_lazy.write_string("TEST_FILE.txt", "Hello from lazy GitFs!")
  let test_content = gitfs_lazy.read_file(osfs, "TEST_FILE.txt")
  println("Written TEST_FILE.txt: \{test_content.length()} bytes")
  println("is_dirty: \{gitfs_lazy.is_dirty()}")

  // Verify original file unchanged in git
  let readme2 = gitfs_lazy.read_file(osfs, "README.md")
  assert_eq(readme.length(), readme2.length())
  println("README.md unchanged: OK")

  // Test eager loading for comparison
  println("\n=== Eager Loading ===")
  let config = GitFsConfig::eager()
  let gitfs_eager = GitFs::from_commit(osfs, git_dir, commit_id, config~)
  println("is_lazy: \{gitfs_eager.is_lazy()}")
  let root_eager = gitfs_eager.readdir(osfs, "")
  println("Root entries: \{root_eager.length()}")
  assert_eq(root.length(), root_eager.length())
  let readme_eager = gitfs_eager.read_file(osfs, "README.md")
  assert_eq(readme.length(), readme_eager.length())
  println("README.md matches lazy version: OK")
  println("\n=== All Checks Passed ===")
}

///|
test "verify: lazy loading on this repo" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/Users/mz/ghq/github.com/mizchi/git/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: this repo .git not found")
    return
  }

  // Get HEAD
  let head_path = git_dir + "/HEAD"
  let head_content = osfs.read_file(head_path)
  let head_str = @utf8.decode_lossy(head_content[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    if osfs.is_file(ref_path) {
      let ref_content = osfs.read_file(ref_path)
      let ref_str = @utf8.decode_lossy(ref_content[:]).trim().to_string()
      @git.ObjectId::from_hex(ref_str)
    } else {
      // Packed ref - skip for now
      println("Skipping: packed ref")
      return
    }
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  println("HEAD: \{commit_id}")
  let gitfs = GitFs::from_commit(osfs, git_dir, commit_id)
  println("is_lazy: \{gitfs.is_lazy()}")

  // Read root
  let root = gitfs.readdir(osfs, "")
  println("Root entries: \{root.length()}")
  for entry in root {
    println("  \{entry}")
  }

  // Read moon.mod.json
  if root.contains("moon.mod.json") {
    let moon_mod = gitfs.read_file(osfs, "moon.mod.json")
    println("moon.mod.json: \{moon_mod.length()} bytes")
  }

  // Read src directory
  if root.contains("src") {
    let src = gitfs.readdir(osfs, "src")
    println("src/: \{src.length()} entries")
  }
  println("\n=== This Repo Check Passed ===")
}
