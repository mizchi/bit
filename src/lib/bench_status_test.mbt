///| Benchmarks for worktree status

///|
/// Run with:
/// - moon bench -p mizchi/bit/lib --target native -f bench_status_test.mbt

///|
let bench_root : String = "/bench_status"

///|
fn setup_status_repo(
  file_count : Int,
  dirty_count : Int,
) -> @git.TestFs raise @git.GitError {
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, bench_root))
  for i in 0..<file_count {
    fs.write_string(bench_root + "/file_\{i}.txt", "content\n")
  }
  add_paths(fs, fs, bench_root, ["."])
  ignore(
    commit(
      fs, fs, bench_root, "msg\n", "Bench <bench@example.com>", 1700000000L,
    ),
  )
  for i in 0..<dirty_count {
    fs.write_string(bench_root + "/file_\{i}.txt", "changed\n")
  }
  fs
}

///|
let bench_status_clean_small : @git.TestFs = try! setup_status_repo(200, 0)

///|
let bench_status_dirty_small : @git.TestFs = try! setup_status_repo(200, 20)

///|
let bench_status_clean_large : @git.TestFs = try! setup_status_repo(1000, 0)

///|
test "bench status clean small" (b : @bench.T) {
  b.bench(fn() {
    let mut out = 0
    @async.run_async_main(async fn() {
      let st = status(bench_status_clean_small, bench_root)
      out = st.untracked.length()
    })
    b.keep(out)
  })
}

///|
test "bench status dirty small" (b : @bench.T) {
  b.bench(fn() {
    let mut out = 0
    @async.run_async_main(async fn() {
      let st = status(bench_status_dirty_small, bench_root)
      out = st.unstaged_modified.length()
    })
    b.keep(out)
  })
}

///|
test "bench status clean large" (b : @bench.T) {
  b.bench(fn() {
    let mut out = 0
    @async.run_async_main(async fn() {
      let st = status(bench_status_clean_large, bench_root)
      out = st.untracked.length()
    })
    b.keep(out)
  })
}

///|
async test "racy_git: unchanged file is not reported" {
  @sys.set_env_var("BIT_RACY_GIT", "1")
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs.write_string("/repo/a.txt", "hello\n")
  add_paths(fs, fs, "/repo", ["a.txt"])
  ignore(commit(fs, fs, "/repo", "msg\n", "Test <t@example.com>", 1700000000L))
  let st = status(fs, "/repo")
  assert_true(st.unstaged_modified.length() == 0)
  @sys.unset_env_var("BIT_RACY_GIT")
}
