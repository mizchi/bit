///|
test "config: set_config escapes double quotes in value" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-config-escape-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root)
  let config_path = root + "/config"
  set_config(
    fs, config_path, "remote.origin.uploadpack", "\"$TRASH_DIRECTORY/fake-upload-pack\"",
    false,
  )
  let content = decode_bytes(fs.read_file(config_path))
  assert_true(
    content.contains("uploadpack = \\\"$TRASH_DIRECTORY/fake-upload-pack\\\""),
  )
  fs.remove_file(config_path) catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "config: set_config escapes quotes when appending to existing section" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-config-escape-existing-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root)
  let config_path = root + "/config"
  let base_config =
    #|
    #|[remote "origin"]
    #|  url = https://example.com/repo.git
    #|[branch "main"]
    #|  remote = origin
  fs.write_string(config_path, base_config)
  set_config(
    fs, config_path, "remote.origin.uploadpack", "\"$TRASH_DIRECTORY/fake-upload-pack\"",
    false,
  )
  let content = decode_bytes(fs.read_file(config_path))
  assert_true(
    content.contains("uploadpack = \\\"$TRASH_DIRECTORY/fake-upload-pack\\\""),
  )
  fs.remove_file(config_path) catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
async test "config: --global writes to HOME/.gitconfig without delegation" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-config-global-" +
    get_current_timestamp().to_string()
  let home = root + "/home"
  fs.mkdir_p(home)
  let config_path = home + "/.gitconfig"
  let prev_home = @sys.get_env_var("HOME")
  let prev_global = @sys.get_env_var("GIT_CONFIG_GLOBAL")
  @sys.set_env_var("HOME", home)
  @sys.unset_env_var("GIT_CONFIG_GLOBAL")
  handle_config(["--global", "user.name", "bit-test"])
  let content = decode_bytes(fs.read_file(config_path))
  assert_true(content.contains("[user]"))
  assert_true(content.contains("name = bit-test"))
  match prev_home {
    Some(v) => @sys.set_env_var("HOME", v)
    None => @sys.unset_env_var("HOME")
  }
  match prev_global {
    Some(v) => @sys.set_env_var("GIT_CONFIG_GLOBAL", v)
    None => @sys.unset_env_var("GIT_CONFIG_GLOBAL")
  }
  fs.remove_file(config_path) catch {
    _ => ()
  }
  fs.remove_dir(home) catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "config: get_config_value parses quoted values and inline comments" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-config-parse-" + get_current_timestamp().to_string()
  fs.mkdir_p(root)
  let config_path = root + "/config"
  let content =
    #|
    #|[section]
    #|  sparseAndTailQuoted = "big 	 blue "
    #|  sparseAndBiggerTailQuoted = "big 	 blue 	 "
    #|  sparseAndBiggerTailQuotedPlus = "big 	 blue 	 " 	
    #|  headAndTailQuoted = "	big blue "
    #|  headAndTailQuotedPlus = "	big blue " 
    #|  annotated = big blue	# to be discarded
    #|  annotatedQuoted = "big blue"	# to be discarded
  fs.write_string(config_path, content)
  assert_true(
    get_config_value(fs, config_path, "section.sparseAndTailQuoted") ==
    Some("big \t blue "),
  )
  assert_true(
    get_config_value(fs, config_path, "section.sparseAndBiggerTailQuoted") ==
    Some("big \t blue \t "),
  )
  assert_true(
    get_config_value(fs, config_path, "section.sparseAndBiggerTailQuotedPlus") ==
    Some("big \t blue \t "),
  )
  assert_true(
    get_config_value(fs, config_path, "section.headAndTailQuoted") ==
    Some("\tbig blue "),
  )
  assert_true(
    get_config_value(fs, config_path, "section.headAndTailQuotedPlus") ==
    Some("\tbig blue "),
  )
  assert_true(
    get_config_value(fs, config_path, "section.annotated") == Some("big blue"),
  )
  assert_true(
    get_config_value(fs, config_path, "section.annotatedQuoted") ==
    Some("big blue"),
  )
  fs.remove_file(config_path) catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "config: set_config updates section case-insensitively" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-config-case-" + get_current_timestamp().to_string()
  fs.mkdir_p(root)
  let config_path = root + "/config"
  let content =
    #|
    #|[section]
    #|  penguin = little blue
  fs.write_string(config_path, content)
  set_config(fs, config_path, "Section.Movie", "BadPhysics", false)
  set_config(fs, config_path, "SECTION.UPPERCASE", "true", false)
  let actual = decode_bytes(fs.read_file(config_path))
  assert_true(actual.contains("[section]"))
  assert_true(actual.contains("\tMovie = BadPhysics"))
  assert_true(actual.contains("\tUPPERCASE = true"))
  assert_false(actual.contains("[Section]"))
  assert_false(actual.contains("[SECTION]"))
  fs.remove_file(config_path) catch {
    _ => ()
  }
  fs.remove_dir(root) catch {
    _ => ()
  }
}

///|
test "diff: cached revision token classifier handles HEAD forms" {
  assert_true(looks_like_cached_diff_revision("HEAD"))
  assert_true(looks_like_cached_diff_revision("@"))
  assert_true(looks_like_cached_diff_revision("HEAD^"))
  assert_true(looks_like_cached_diff_revision("HEAD~2"))
  assert_false(looks_like_cached_diff_revision("path/to/file"))
}
