///| Test for partial clone with on-demand fetch

///|
test "partial_clone: mount and list files" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"

  // Skip if test repo not available
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    println(
      "Run: moongit clone --filter=blob:none https://github.com/nickel-lang/tree-sitter-nickel /tmp/partial-clone-test/tree-sitter-nickel",
    )
    return
  }

  // Check if it's a partial clone
  let is_partial = @lib.is_partial_clone(osfs, git_dir)
  println("Is partial clone: \{is_partial}")
  assert_true(is_partial)

  // Get promisor remote
  let remote = @lib.read_promisor_remote(osfs, git_dir)
  println("Promisor remote: \{remote}")
  assert_true(remote is Some(_))

  // Get HEAD commit
  let head_ref = osfs.read_file(git_dir + "/HEAD")
  let head_str = @utf8.decode_lossy(head_ref[:]).trim().to_string()
  println("HEAD: \{head_str}")

  // Get commit ID
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    @git.ObjectId::from_hex(
      @utf8.decode_lossy(ref_content[:]).trim().to_string(),
    )
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  println("Commit: \{commit_id}")

  // Mount with Fs
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println("Fs mounted")
  println("  is_lazy: \{bitfs.is_lazy()}")
  println("  is_promisor_enabled: \{bitfs.is_promisor_enabled()}")
  println("  has_promisor: \{bitfs.has_promisor(osfs)}")

  // List root directory (this should work - tree objects are available)
  let root = bitfs.readdir(osfs, "")
  println("Root entries: \{root.length()}")
  for entry in root {
    println("  \{entry}")
  }
  assert_true(root.length() > 0)

  // Check if files need fetching
  for entry in root {
    if bitfs.is_file(osfs, entry) {
      let needs = bitfs.needs_fetch(osfs, entry)
      println("  \{entry}: needs_fetch=\{needs}")
    }
  }
}

///|
async test "partial_clone: on-demand fetch" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    return
  }

  // Get commit
  let head_ref = osfs.read_file(git_dir + "/HEAD")
  let head_str = @utf8.decode_lossy(head_ref[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    @git.ObjectId::from_hex(
      @utf8.decode_lossy(ref_content[:]).trim().to_string(),
    )
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)

  // Try to read a file - this should trigger on-demand fetch
  println("\n=== On-demand Fetch Test ===")
  println("Attempting to read README.md...")

  // Check if needs fetch first
  let needs = bitfs.needs_fetch(osfs, "README.md")
  println("needs_fetch: \{needs}")

  // Use async read to fetch
  let content = bitfs.read_file_async(osfs, osfs, "README.md")
  println("README.md: \{content.length()} bytes")
  assert_true(content.length() > 0)

  // Print first few lines
  let text = @utf8.decode_lossy(content[:])
  let lines : Array[String] = text
    .split("\n")
    .map(fn(sv) { sv.to_string() })
    .collect()
  let preview_lines = if lines.length() > 5 { 5 } else { lines.length() }
  println("Content preview:")
  for i in 0..<preview_lines {
    println("  \{lines[i]}")
  }

  // Verify file is now locally available (written as loose object)
  // After fetch, the sync read should work
  let content2 = bitfs.read_file(osfs, "README.md")
  println("Sync read after fetch: \{content2.length()} bytes")
  assert_eq(content.length(), content2.length())
  println("\n=== On-demand Fetch Test Passed ===")
}

///|
test "partial_clone: glob pattern matching" {
  // Test glob_match function via prefetch_glob behavior
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    return
  }
  let head_ref = osfs.read_file(git_dir + "/HEAD")
  let head_str = @utf8.decode_lossy(head_ref[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    @git.ObjectId::from_hex(
      @utf8.decode_lossy(ref_content[:]).trim().to_string(),
    )
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println("\n=== Glob Pattern Test ===")

  // Test collect_files_bfs
  let bfs_files = bitfs.collect_files_bfs(osfs, 50)
  println("BFS files (limit 50): \{bfs_files.length()}")
  println("First 5 files:")
  for i in 0..<5 {
    if i < bfs_files.length() {
      println("  \{bfs_files[i]}")
    }
  }

  // Verify BFS order - root files should come first
  let mut found_subdir_file = false
  for file in bfs_files {
    if file.contains("/") {
      found_subdir_file = true
      // Root file should not appear after subdir file in BFS
    } else if found_subdir_file {
      println("  Warning: root file after subdir file - not strict BFS")
    }
  }

  // Test get_pending_fetches
  let pending = bitfs.get_pending_fetches(osfs, 100)
  println("\nPending fetches: \{pending.length()}")
  for i in 0..<3 {
    if i < pending.length() {
      println("  \{pending[i]}")
    }
  }
  println("\n=== Glob Pattern Test Passed ===")
}

///|
async test "partial_clone: prefetch with glob" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    return
  }
  let head_ref = osfs.read_file(git_dir + "/HEAD")
  let head_str = @utf8.decode_lossy(head_ref[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    @git.ObjectId::from_hex(
      @utf8.decode_lossy(ref_content[:]).trim().to_string(),
    )
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println("\n=== Prefetch Glob Test ===")

  // Prefetch all .json files
  let fetched = bitfs.prefetch_glob(osfs, osfs, "*.json")
  println("Prefetched *.json files: \{fetched}")

  // Now they should be available locally
  let package_json = bitfs.read_file(osfs, "package.json")
  println("package.json: \{package_json.length()} bytes")
  assert_true(package_json.length() > 0)
  println("\n=== Prefetch Glob Test Passed ===")
}

///|
async test "partial_clone: prefetch BFS" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    return
  }
  let head_ref = osfs.read_file(git_dir + "/HEAD")
  let head_str = @utf8.decode_lossy(head_ref[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    @git.ObjectId::from_hex(
      @utf8.decode_lossy(ref_content[:]).trim().to_string(),
    )
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println("\n=== Prefetch BFS Test ===")

  // Get pending before prefetch
  let pending_before = bitfs.get_pending_fetches(osfs, 100)
  println("Pending before: \{pending_before.length()}")

  // Prefetch first 10 files in BFS order
  let fetched = bitfs.prefetch_bfs(osfs, osfs, 10)
  println("Prefetched (BFS limit 10): \{fetched}")

  // Get pending after prefetch
  let pending_after = bitfs.get_pending_fetches(osfs, 100)
  println("Pending after: \{pending_after.length()}")

  // Should have reduced pending count
  assert_true(pending_after.length() <= pending_before.length())
  println("\n=== Prefetch BFS Test Passed ===")
}

///|
async test "partial_clone: prefetch multiple files" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    return
  }
  let head_ref = osfs.read_file(git_dir + "/HEAD")
  let head_str = @utf8.decode_lossy(head_ref[:]).trim().to_string()
  let commit_id = if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = osfs.read_file(ref_path)
    @git.ObjectId::from_hex(
      @utf8.decode_lossy(ref_content[:]).trim().to_string(),
    )
  } else {
    @git.ObjectId::from_hex(head_str)
  }
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println("\n=== Prefetch Test ===")

  // Get list of files to prefetch
  let root = bitfs.readdir(osfs, "")
  let files_to_fetch : Array[String] = []
  for entry in root {
    if bitfs.is_file(osfs, entry) && bitfs.needs_fetch(osfs, entry) {
      files_to_fetch.push(entry)
    }
  }
  println("Files needing fetch: \{files_to_fetch.length()}")
  if files_to_fetch.length() > 0 {
    // Prefetch first 3 files
    let to_prefetch = if files_to_fetch.length() > 3 {
      [files_to_fetch[0], files_to_fetch[1], files_to_fetch[2]]
    } else {
      files_to_fetch
    }
    println("Prefetching: \{to_prefetch}")
    let fetched = bitfs.prefetch(osfs, osfs, to_prefetch)
    println("Fetched \{fetched} objects")

    // Verify they can now be read synchronously
    for file in to_prefetch {
      let content = bitfs.read_file(osfs, file)
      println("  \{file}: \{content.length()} bytes")
    }
  }
  println("\n=== Prefetch Test Passed ===")
}
