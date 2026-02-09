///| Ensure lib algorithms work with pure MoonBit I/O defaults.

///|
async test "lib pure runtime: status/add_paths_async without native init" {
  @gitio.set_env_provider(@gitio.EnvProvider::none())
  @gitio.set_worktree_probe(@gitio.WorktreeProbeProvider::none())
  let fs = @git.TestFs::new()
  ignore(try? init_repo(fs, "/repo"))
  fs.write_string("/repo/a.txt", "hello\n")
  let st_before = status(fs, "/repo")
  inspect(st_before.untracked, content="[\"a.txt\"]")
  add_paths_async(fs, fs, "/repo", ["a.txt"])
  let st_after = status(fs, "/repo")
  inspect(st_after.staged_added, content="[\"a.txt\"]")
  inspect(st_after.unstaged_modified, content="[]")
}
