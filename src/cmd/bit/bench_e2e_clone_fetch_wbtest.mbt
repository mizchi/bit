///| E2E-style benchmarks for clone/fetch workflows

///|
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native -f bench_e2e_clone_fetch_wbtest.mbt

///|
let bench_e2e_root : String = "/tmp/bit_bench_e2e_clone_fetch_v1"

///|
let bench_e2e_clone_source : String = bench_e2e_root + "/clone_source"

///|
let bench_e2e_clone_target : String = bench_e2e_root + "/clone_target"

///|
let bench_e2e_fetch_source : String = bench_e2e_root + "/fetch_source"

///|
let bench_e2e_fetch_target : String = bench_e2e_root + "/fetch_target"

///|
let bench_e2e_fetch_updates_dir : String = bench_e2e_fetch_source +
  "/bench_updates"

///|
fn e2e_cleanup_tree(fs : OsFs, path : String) -> Unit {
  if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
    return
  }
  if not(fs.is_dir(path)) {
    return
  }
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    e2e_cleanup_tree(fs, path + "/" + entry)
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn e2e_ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn e2e_reset_git_env() -> Unit {
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.unset_env_var("GIT_CONFIG_OVERRIDES")
  @sys.unset_env_var("SHIM_REAL_GIT")
  @sys.unset_env_var("GIT_SHIM_REAL_GIT")
}

///|
fn e2e_commit_all(fs : OsFs, repo_root : String, message : String) -> Unit {
  @async.run_async_main(async fn() {
    ignore(try? @gitlib.add_paths_async(fs, fs, repo_root, ["."]))
  })
  ignore(
    try? @gitlib.commit(
      fs,
      fs,
      repo_root,
      message,
      "Bench <bench@example.com>",
      get_current_timestamp(),
    ),
  )
}

///|
fn e2e_seed_repo_files(
  repo_root : String,
  dir_count : Int,
  files_per_dir : Int,
) -> Unit {
  for d in 0..<dir_count {
    let dir = repo_root + "/dir_\{d}"
    e2e_ensure_dir(dir)
    for i in 0..<files_per_dir {
      @fs.write_string_to_file(
        dir + "/file_\{i}.txt",
        "bench data d=\{d} i=\{i}\n",
      ) catch {
        _ => ()
      }
    }
  }
}

///|
fn ensure_clone_source_repo_for_e2e_bench() -> Unit {
  let fs = OsFs::new()
  e2e_cleanup_tree(fs, bench_e2e_clone_source)
  e2e_ensure_dir(bench_e2e_root)
  e2e_ensure_dir(bench_e2e_clone_source)
  ignore(try? @gitrepo.init_repo(fs, bench_e2e_clone_source))
  e2e_seed_repo_files(bench_e2e_clone_source, 30, 20)
  e2e_commit_all(fs, bench_e2e_clone_source, "bench clone seed")
}

///|
fn ensure_fetch_repos_for_e2e_bench() -> Unit {
  let fs = OsFs::new()
  e2e_cleanup_tree(fs, bench_e2e_fetch_source)
  e2e_cleanup_tree(fs, bench_e2e_fetch_target)
  e2e_ensure_dir(bench_e2e_root)
  e2e_ensure_dir(bench_e2e_fetch_source)
  ignore(try? @gitrepo.init_repo(fs, bench_e2e_fetch_source))
  e2e_seed_repo_files(bench_e2e_fetch_source, 20, 15)
  e2e_commit_all(fs, bench_e2e_fetch_source, "bench fetch seed")
  e2e_reset_git_env()
  @async.run_async_main(async fn() {
    run_main_for_args([
      "bit", "clone", bench_e2e_fetch_source, bench_e2e_fetch_target,
    ])
  })
}

///|
fn append_fetch_update_commit_for_e2e_bench(step : Int) -> Unit {
  let fs = OsFs::new()
  e2e_ensure_dir(bench_e2e_fetch_updates_dir)
  @fs.write_string_to_file(
    bench_e2e_fetch_updates_dir + "/tick.txt",
    "step=\{step} ts=\{get_current_timestamp().to_string()}\n",
  ) catch {
    _ => ()
  }
  e2e_commit_all(fs, bench_e2e_fetch_source, "bench fetch update \{step}")
}

///|
test "bench e2e clone local medium repo" (b : @bench.T) {
  ensure_clone_source_repo_for_e2e_bench()
  let fs = OsFs::new()
  b.bench(fn() {
    e2e_reset_git_env()
    e2e_cleanup_tree(fs, bench_e2e_clone_target)
    @async.run_async_main(async fn() {
      run_main_for_args([
        "bit", "clone", bench_e2e_clone_source, bench_e2e_clone_target,
      ])
    })
    b.keep(fs.is_dir(bench_e2e_clone_target + "/.git"))
  })
}

///|
test "bench e2e fetch after one new commit" (b : @bench.T) {
  ensure_fetch_repos_for_e2e_bench()
  let mut step = 0
  b.bench(fn() {
    step += 1
    append_fetch_update_commit_for_e2e_bench(step)
    e2e_reset_git_env()
    @async.run_async_main(async fn() {
      run_main_for_args(["bit", "-C", bench_e2e_fetch_target, "fetch", "origin"])
    })
    b.keep(step)
  })
}
