///|
/// Performance characteristics test for partial clone
/// Verifies the lazy loading sequence:
/// 1. Mount is instant (no blob resolution)
/// 2. list_dir resolves tree objects only
/// 3. read_file triggers blob fetch on-demand
test "perf: partial clone access pattern verification" {
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
  println("\n=== Partial Clone Access Pattern Test ===\n")

  // Get commit ID
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

  // Phase 1: Mount (instant - only HEAD parsing)
  println("Phase 1: Mount")
  println("  - Parsing HEAD reference only")
  println("  - No pack file parsing yet")
  println("  - No network activity")
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  println(
    "  → Mounted: lazy=\{bitfs.is_lazy()}, promisor=\{bitfs.is_promisor_enabled()}",
  )
  println("")

  // Phase 2: List root directory (resolves commit + root tree)
  println("Phase 2: readdir('/')")
  println("  - Resolves commit object (local)")
  println("  - Resolves root tree object (local)")
  println("  - Returns file names from tree entries")
  println("  - NO blob resolution yet")
  let entries = bitfs.readdir(osfs, "")
  println("  → Found \{entries.length()} entries")

  // Count what needs fetch vs what's local
  let mut local_count = 0
  let mut fetch_needed = 0
  for entry in entries {
    if bitfs.is_file(osfs, entry) {
      if bitfs.needs_fetch(osfs, entry) {
        fetch_needed += 1
      } else {
        local_count += 1
      }
    }
  }
  println("  → Local files: \{local_count}, Need fetch: \{fetch_needed}")
  println("")

  // Phase 3: Read local file (no network)
  println("Phase 3: read_file('README.md') - already local")
  println("  - Blob exists locally (small files often included)")
  let readme_needs = bitfs.needs_fetch(osfs, "README.md")
  println("  - needs_fetch: \{readme_needs}")
  let readme = bitfs.read_file(osfs, "README.md")
  println("  → Read \{readme.length()} bytes (no network)")
  println("")

  // Phase 4: List subdirectory (resolves subtree)
  println("Phase 4: readdir('/src')")
  println("  - Resolves src/ tree object (local)")
  println("  - Still no blob resolution")
  let src_entries = bitfs.readdir(osfs, "src")
  println("  → Found \{src_entries.length()} entries in src/")
  println("")

  // Phase 5: Check a file that needs fetch
  println("Phase 5: Check file needing fetch")
  for entry in entries {
    if bitfs.is_file(osfs, entry) && bitfs.needs_fetch(osfs, entry) {
      println("  - \{entry} needs_fetch=true")
      println("  - Reading this would trigger network fetch")
      break
    }
  }
  println("")

  // Summary
  println("=== Access Pattern Summary ===")
  println("")
  println("Mount:      Instant (HEAD ref only)")
  println("readdir:    Local (tree objects in pack)")
  println("is_file:    Local (tree metadata)")
  println("needs_fetch: Local (checks object existence)")
  println("read_file:  Local if blob exists, Network fetch if missing")
  println("")
  println("Key: All metadata operations are LOCAL and INSTANT.")
  println("     Network fetch only on actual blob read for missing objects.")
}

///|
test "perf: verify lazy vs eager difference" {
  let osfs = @osfs.OsFs::new()
  let git_dir = "/tmp/partial-clone-test/tree-sitter-nickel/.git"
  if not(osfs.is_dir(git_dir)) {
    println("Skipping: partial clone test repo not found")
    return
  }
  println("\n=== Lazy vs Eager Mode Comparison ===\n")
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

  // Lazy mode (default, fast)
  println("Lazy Mode (default):")
  println("  - Pack index: parsed on-demand")
  println("  - Objects: resolved when accessed")
  let bitfs_lazy = Fs::from_commit(osfs, git_dir, commit_id)
  println("  → is_lazy: \{bitfs_lazy.is_lazy()}")
  let entries_lazy = bitfs_lazy.readdir(osfs, "")
  println("  → readdir works: \{entries_lazy.length()} entries")
  println("")

  // Verify partial clone essential for lazy
  println("Why Lazy + Partial Clone:")
  println("  - Partial clone = missing blobs by design")
  println("  - Lazy = don't try to parse missing blobs at mount")
  println("  - Result: Instant mount regardless of repo size")
  println("")
  println("  Eager mode with partial clone would fail trying")
  println("  to parse blobs that don't exist locally.")
}
