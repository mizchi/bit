///| Real .git snapshot benchmarks

///|

///| Run with:

///| - moon bench -p mizchi/git/x/bitfs --target native -f "bench_real"

///|

///| These benchmarks test the scenario:

///| 1. Create a snapshot from a real .git directory

///| 2. Load it into memory (Fs)

///| 3. Work in memory with COW

///| 4. Generate diff to push back

///|
/// Get the git directory path for benchmarks
/// Uses the current project's .git directory
fn get_bench_git_dir() -> String {
  // Use absolute path to avoid issues with working directory
  "/Users/mz/ghq/github.com/mizchi/git/.git"
}

///|
/// Get HEAD commit ID from the real repository
fn get_head_commit(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> @git.ObjectId raise @git.GitError {
  let head_path = git_dir + "/HEAD"
  let head_content = fs.read_file(head_path)
  let head_str = @utf8.decode_lossy(head_content[:]).trim().to_string()
  if head_str.has_prefix("ref: ") {
    let ref_name = String::unsafe_substring(
      head_str,
      start=5,
      end=head_str.length(),
    )
    let ref_path = git_dir + "/" + ref_name
    let ref_content = fs.read_file(ref_path)
    let ref_str = @utf8.decode_lossy(ref_content[:]).trim().to_string()
    @git.ObjectId::from_hex(ref_str)
  } else {
    @git.ObjectId::from_hex(head_str)
  }
}

///|
/// Check if the bench git directory exists
fn bench_git_dir_exists() -> Bool {
  let osfs = @osfs.OsFs::new()
  let git_dir = get_bench_git_dir()
  try {
    let _ = osfs.read_file(git_dir + "/HEAD")
    true
  } catch {
    _ => false
  }
}

///|
/// Simple test to verify real git reading works
test "real_git: can read HEAD" {
  if not(bench_git_dir_exists()) {
    println("Skipping: bench git dir not found")
    return
  }
  let osfs = @osfs.OsFs::new()
  let git_dir = get_bench_git_dir()
  let commit_id = get_head_commit(osfs, git_dir)
  assert_true(commit_id.to_hex().length() == 40)
}

///|
/// Simple test to verify Fs from real git works
test "real_git: can create Fs from HEAD" {
  if not(bench_git_dir_exists()) {
    println("Skipping: bench git dir not found")
    return
  }
  let osfs = @osfs.OsFs::new()
  let git_dir = get_bench_git_dir()
  let commit_id = get_head_commit(osfs, git_dir)
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  assert_false(bitfs.is_dirty())
}

///|
/// Test reading files from real git
test "real_git: can read files" {
  if not(bench_git_dir_exists()) {
    println("Skipping: bench git dir not found")
    return
  }
  let osfs = @osfs.OsFs::new()
  let git_dir = get_bench_git_dir()
  let commit_id = get_head_commit(osfs, git_dir)
  let bitfs = Fs::from_commit(osfs, git_dir, commit_id)
  let entries = bitfs.readdir(osfs, "")
  assert_true(entries.length() > 0)
}

///|
/// Pre-load data for benchmarks
let bench_real_osfs : @osfs.OsFs = @osfs.OsFs::new()

///|
let bench_real_git_dir : String = get_bench_git_dir()

///|
let bench_real_commit : @git.ObjectId = try! get_head_commit(
  bench_real_osfs, bench_real_git_dir,
)

///|
/// Benchmark: ObjectDb load time (the main bottleneck for snapshot)
test "bench_real: ObjectDb load" (b : @bench.T) {
  b.bench(fn() {
    b.keep(try! @lib.ObjectDb::load(bench_real_osfs, bench_real_git_dir))
  })
}

///|
/// Benchmark: Create Fs snapshot from real .git (full load)
test "bench_real: snapshot from .git" (b : @bench.T) {
  b.bench(fn() {
    b.keep(
      try! Fs::from_commit(
        bench_real_osfs, bench_real_git_dir, bench_real_commit,
      ),
    )
  })
}

///|
/// Benchmark: Read file list from root (cached bitfs)
test "bench_real: readdir root" (b : @bench.T) {
  let bitfs = try! Fs::from_commit(
    bench_real_osfs, bench_real_git_dir, bench_real_commit,
  )
  b.bench(fn() { b.keep(try! bitfs.readdir(bench_real_osfs, "")) })
}

///|
/// Benchmark: Read README.md (cold then cached)
test "bench_real: read README.md" (b : @bench.T) {
  let bitfs = try! Fs::from_commit(
    bench_real_osfs, bench_real_git_dir, bench_real_commit,
  )
  b.bench(fn() { b.keep(try! bitfs.read_file(bench_real_osfs, "README.md")) })
}

///|
/// Benchmark: COW write operations on real snapshot
test "bench_real: write 100 files in memory" (b : @bench.T) {
  let content = Bytes::make(100, b'x')
  b.bench(fn() {
    let bitfs = try! Fs::from_commit(
      bench_real_osfs, bench_real_git_dir, bench_real_commit,
    )
    for i in 0..<100 {
      bitfs.write_file("test/file\{i}.txt", content)
    }
    b.keep(bitfs)
  })
}

///|
/// Benchmark: ObjectDb load_lazy (shallow snapshot)
test "bench_real: ObjectDb load_lazy" (b : @bench.T) {
  b.bench(fn() {
    b.keep(try! @lib.ObjectDb::load_lazy(bench_real_osfs, bench_real_git_dir))
  })
}

///|
/// Benchmark: from_commit (shallow snapshot)
test "bench_real: snapshot_lazy from .git" (b : @bench.T) {
  b.bench(fn() {
    b.keep(
      try! Fs::from_commit(
        bench_real_osfs, bench_real_git_dir, bench_real_commit,
      ),
    )
  })
}

///|
/// Benchmark: read files after lazy snapshot
test "bench_real: read README.md (lazy)" (b : @bench.T) {
  let bitfs = try! Fs::from_commit(
    bench_real_osfs, bench_real_git_dir, bench_real_commit,
  )
  b.bench(fn() { b.keep(try! bitfs.read_file(bench_real_osfs, "README.md")) })
}

///|
/// Benchmark: full workflow with lazy loading
test "bench_real: full workflow (lazy)" (b : @bench.T) {
  let content = Bytes::make(100, b'x')
  b.bench(fn() {
    // 1. Create lazy snapshot from HEAD
    let bitfs = try! Fs::from_commit(
      bench_real_osfs, bench_real_git_dir, bench_real_commit,
    )
    // 2. Read some files
    let _ = try! bitfs.readdir(bench_real_osfs, "")
    let _ = try! bitfs.read_file(bench_real_osfs, "README.md")
    // 3. Write changes (COW)
    for i in 0..<10 {
      bitfs.write_file("test/file\{i}.txt", content)
    }
    b.keep(bitfs.is_dirty())
  })
}
