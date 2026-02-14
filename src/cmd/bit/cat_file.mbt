///|
struct CatFilePathAttrs {
  eol_crlf : Bool
  diff_driver : String?
}

///|
enum CatFileObjectFilter {
  Disabled
  BlobNone
  BlobLimit(Int64)
  ObjectType(@git.ObjectType)
}

///|
struct CatFileBatchAllObjectDiskRecord {
  id : @git.ObjectId
  disk_size : Int
}

///|
async fn handle_cat_file(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  if cat_file_has_incremental_midx_chain(fs, git_dir) {
    eprint_line(
      "fatal: cat-file with incremental multi-pack-index chain is not supported in standalone mode",
    )
    @sys.exit(1)
  }
  let mut show_type = false
  let mut show_size = false
  let mut pretty_print = false
  let mut exists_check = false
  let mut filters_mode = false
  let mut textconv_mode = false
  let mut batch_mode = false
  let mut batch_check_mode = false
  let mut batch_command_mode = false
  let mut batch_all_objects_mode = false
  let mut batch_unordered = false
  let mut batch_buffer = false
  let mut batch_no_buffer = false
  let mut follow_symlinks = false
  let mut nul_terminated = false
  let mut nul_terminated_upper = false
  let mut batch_format : String? = None
  let mut object_filter_spec : String? = None
  let mut explicit_path : String? = None
  let positionals : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-t" => show_type = true
      "-s" => show_size = true
      "-p" => pretty_print = true
      "-e" => exists_check = true
      "--filters" => filters_mode = true
      "--textconv" => textconv_mode = true
      "--batch" => batch_mode = true
      "--batch-check" => {
        batch_mode = true
        batch_check_mode = true
      }
      "--batch-command" => {
        batch_mode = true
        batch_command_mode = true
      }
      "--batch-all-objects" => batch_all_objects_mode = true
      "--unordered" => batch_unordered = true
      "--buffer" => batch_buffer = true
      "--no-buffer" => batch_no_buffer = true
      "--follow-symlinks" => follow_symlinks = true
      "-z" => nul_terminated = true
      "-Z" => nul_terminated_upper = true
      "--filter" if i + 1 < args.length() => {
        object_filter_spec = Some(args[i + 1])
        i += 2
        continue
      }
      "--filter" => cat_file_usage_fatal("--filter requires a value")
      "--no-filter" => object_filter_spec = None
      "--path" if i + 1 < args.length() => {
        explicit_path = Some(args[i + 1])
        i += 2
        continue
      }
      "--path" => cat_file_usage_fatal("--path requires a value")
      _ if arg.has_prefix("--path=") =>
        explicit_path = Some(
          String::unsafe_substring(arg, start=7, end=arg.length()),
        )
      _ if arg.has_prefix("--filter=") =>
        object_filter_spec = Some(
          String::unsafe_substring(arg, start=9, end=arg.length()),
        )
      _ if arg.has_prefix("--batch=") => {
        batch_mode = true
        batch_format = Some(
          String::unsafe_substring(arg, start=8, end=arg.length()),
        )
      }
      _ if arg.has_prefix("--batch-check=") => {
        batch_mode = true
        batch_check_mode = true
        batch_format = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
      }
      _ if arg.has_prefix("--batch-command=") => {
        batch_mode = true
        batch_command_mode = true
        batch_format = Some(
          String::unsafe_substring(arg, start=16, end=arg.length()),
        )
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("cat-file", arg)
      _ => positionals.push(arg)
    }
    i += 1
  }
  let batch_format_uses_objectsize_disk = cat_file_batch_format_uses_objectsize_disk(
    batch_format,
  )
  if batch_all_objects_mode && batch_format_uses_objectsize_disk {
    eprint_line(
      "fatal: cat-file --batch-all-objects with %(objectsize:disk) is not supported in standalone mode",
    )
    @sys.exit(1)
  }
  let object_filter = cat_file_parse_object_filter_or_exit(object_filter_spec)
  let object_filter_enabled = !cat_file_object_filter_is_disabled(object_filter)
  let transform_mode = filters_mode || textconv_mode
  let cmd_modes : Array[String] = []
  if exists_check {
    cmd_modes.push("-e")
  }
  if pretty_print {
    cmd_modes.push("-p")
  }
  if show_type {
    cmd_modes.push("-t")
  }
  if show_size {
    cmd_modes.push("-s")
  }
  if textconv_mode {
    cmd_modes.push("--textconv")
  }
  if filters_mode {
    cmd_modes.push("--filters")
  }
  if cmd_modes.length() > 1 {
    cat_file_usage_error(
      "options '\{cmd_modes[0]}' and '\{cmd_modes[1]}' cannot be used together",
    )
  }
  if batch_all_objects_mode && cmd_modes.length() > 0 {
    cat_file_usage_error(
      "options '\{cmd_modes[0]}' and '--batch-all-objects' cannot be used together",
    )
  }
  let batch_only_opt = batch_buffer ||
    batch_no_buffer ||
    follow_symlinks ||
    batch_unordered ||
    batch_all_objects_mode ||
    nul_terminated ||
    nul_terminated_upper
  if batch_only_opt && !batch_mode {
    cat_file_usage_fatal(
      "batch options requires --batch, --batch-check, or --batch-command",
    )
  }
  if cmd_modes.length() > 0 {
    let allows_batch_mode = cmd_modes.length() == 1 &&
      (cmd_modes[0] == "--textconv" || cmd_modes[0] == "--filters")
    if (batch_mode || batch_buffer || batch_no_buffer || follow_symlinks) &&
      !allows_batch_mode {
      cat_file_usage_fatal(
        "option '\{cmd_modes[0]}' is incompatible with batch options",
      )
    }
    if !batch_mode {
      if positionals.length() == 0 {
        cat_file_usage_fatal("object name required")
      }
      if positionals.length() > 1 {
        cat_file_usage_fatal("too many arguments")
      }
    }
  }
  if explicit_path is Some(_) && batch_mode {
    cat_file_usage_fatal(
      "--path is incompatible with --batch and --batch-check",
    )
  }
  if explicit_path is Some(_) && !transform_mode {
    cat_file_usage_fatal("--path=<path> needs --filters or --textconv")
  }
  if batch_buffer && batch_no_buffer {
    cat_file_usage_fatal("--buffer and --no-buffer cannot be used together")
  }
  if nul_terminated && nul_terminated_upper {
    cat_file_usage_fatal("-z and -Z cannot be used together")
  }
  if batch_mode {
    if positionals.length() > 0 {
      cat_file_usage_fatal(
        "--batch, --batch-check, and --batch-command take no arguments",
      )
    }
    let batch_input_separator = if nul_terminated || nul_terminated_upper {
      b'\x00'
    } else {
      b'\n'
    }
    let batch_output_separator = if nul_terminated_upper {
      "\u{00}"
    } else {
      "\n"
    }
    let batch_output_separator_bytes = cat_file_string_to_bytes(
      batch_output_separator,
    )
    let dbs = cat_file_load_object_dbs(fs, git_dir)
    let format_uses_deltabase = cat_file_batch_format_uses_deltabase(
      batch_format,
    )
    let format_uses_objectsize_disk = cat_file_batch_format_uses_objectsize_disk(
      batch_format,
    )
    if batch_all_objects_mode {
      let object_dirs = cat_file_collect_object_dirs(fs, git_dir)
      for object_dir in object_dirs {
        if cat_file_validate_midx_large_offsets(fs, object_dir) {
          eprint_line("fatal: multi-pack-index large offset out of bounds")
          @sys.exit(1)
        }
      }
      let disk_records = if format_uses_objectsize_disk {
        cat_file_collect_batch_all_object_disk_records(
          fs, object_dirs, batch_unordered,
        )
      } else {
        []
      }
      let objects = if format_uses_objectsize_disk {
        let ids : Array[@git.ObjectId] = []
        for record in disk_records {
          ids.push(record.id)
        }
        ids
      } else {
        cat_file_collect_batch_all_objects(fs, object_dirs, batch_unordered)
      }
      let batch_check_needs_object = cat_file_batch_check_format_needs_object(
        batch_format,
      )
      let batch_check_placeholder_obj = @git.PackObject::new(
        @git.ObjectType::Blob,
        bytes_from_array([]),
      )
      let sort_batch_check_output = batch_check_mode && !batch_unordered
      let deferred_batch_check_lines : Array[String] = []
      let mut object_index = 0
      while object_index < objects.length() {
        let id = objects[object_index]
        let object_size_disk_override = if format_uses_objectsize_disk {
          Some(disk_records[object_index].disk_size)
        } else {
          None
        }
        if batch_check_mode &&
          !batch_check_needs_object &&
          !object_filter_enabled {
          let line = cat_file_format_batch_check_line(
            batch_format,
            id,
            batch_check_placeholder_obj,
            "",
            None,
            None,
            None,
            object_size_disk_override,
            None,
          )
          if sort_batch_check_output {
            deferred_batch_check_lines.push(line + batch_output_separator)
          } else {
            @stdio.stdout.write(
              cat_file_string_to_bytes(line + batch_output_separator),
            )
          }
          object_index += 1
          continue
        }
        let (obj, has_invalid_object_type) = cat_file_find_object_in_dbs_lenient(
          dbs, fs, id,
        )
        if has_invalid_object_type {
          eprint_line("fatal: invalid object type")
          @sys.exit(128)
        }
        guard obj is Some(o) else {
          if batch_check_mode {
            let line = id.to_hex() + " missing" + batch_output_separator
            if sort_batch_check_output {
              deferred_batch_check_lines.push(line)
            } else {
              @stdio.stdout.write(cat_file_string_to_bytes(line))
            }
          }
          object_index += 1
          continue
        }
        if cat_file_object_is_excluded_by_filter(object_filter, o) {
          object_index += 1
          continue
        }
        if batch_check_mode {
          let delta_base_hex = if format_uses_deltabase {
            cat_file_resolve_delta_base_hex(
              dbs,
              fs,
              git_dir,
              id,
              id.to_hex().length(),
            )
          } else {
            None
          }
          let line = cat_file_format_batch_check_line(
            batch_format,
            id,
            o,
            "",
            None,
            None,
            None,
            object_size_disk_override,
            delta_base_hex,
          )
          if sort_batch_check_output {
            deferred_batch_check_lines.push(line + batch_output_separator)
          } else {
            @stdio.stdout.write(
              cat_file_string_to_bytes(line + batch_output_separator),
            )
          }
          object_index += 1
          continue
        }
        let effective_path = explicit_path
        if transform_mode && effective_path is None {
          eprint_line("fatal: --textconv/--filters needs a path")
          @sys.exit(1)
        }
        let mut out = o.data
        if transform_mode {
          let path = effective_path.unwrap_or("")
          out = cat_file_apply_path_transforms(
            fs,
            git_dir,
            root,
            path,
            o.data,
            filters_mode,
            textconv_mode,
          )
        }
        @stdio.stdout.write(
          cat_file_string_to_bytes(
            cat_file_format_batch_check_line(
              batch_format,
              id,
              o,
              "",
              None,
              None,
              None,
              object_size_disk_override,
              if format_uses_deltabase {
                cat_file_resolve_delta_base_hex(
                  dbs,
                  fs,
                  git_dir,
                  id,
                  id.to_hex().length(),
                )
              } else {
                None
              },
            ) +
            batch_output_separator,
          ),
        )
        @stdio.stdout.write(out)
        @stdio.stdout.write(batch_output_separator_bytes)
        object_index += 1
      }
      if sort_batch_check_output {
        deferred_batch_check_lines.sort()
        for line in deferred_batch_check_lines {
          @stdio.stdout.write(cat_file_string_to_bytes(line))
        }
      }
      return ()
    }
    let lines : Array[String] = []
    let mut input_record_bytes : Array[Byte] = []
    let mut input_eof = false
    let mut pending_chunks : Array[Bytes] = []
    let buffer_enabled = batch_buffer && !batch_no_buffer
    let suppress_flush_on_exit = match
      @sys.get_env_var("GIT_TEST_CAT_FILE_NO_FLUSH_ON_EXIT") {
      Some(value) => value == "1"
      None => false
    }
    let format_uses_rest = cat_file_batch_format_uses_rest(batch_format)
    let mut line_index = 0
    while true {
      while line_index < lines.length() {
        let raw_line = lines[line_index]
        let line = trim_string(raw_line)
        if batch_command_mode &&
          (raw_line.has_prefix(" ") || raw_line.has_prefix("\t")) {
          eprint_line("fatal: whitespace before command")
          @sys.exit(128)
        }
        if line.length() == 0 {
          if batch_command_mode {
            eprint_line("fatal: empty command in input")
            @sys.exit(128)
          }
          let missing = cat_file_string_to_bytes(
            " missing" + batch_output_separator,
          )
          if buffer_enabled {
            pending_chunks.push(missing)
          } else {
            @stdio.stdout.write(missing)
          }
          line_index += 1
          continue
        }
        let mut spec = line
        let mut rest = ""
        let mut line_path : String? = None
        let mut output_info_mode = batch_check_mode
        if batch_command_mode {
          let mut command = line
          let mut command_arg = ""
          match line.find(" ") {
            Some(idx) => {
              command = String::unsafe_substring(line, start=0, end=idx)
              command_arg = trim_string(
                String::unsafe_substring(line, start=idx + 1, end=line.length()),
              )
            }
            None => ()
          }
          if command == "flush" {
            if command_arg.length() > 0 {
              eprint_line("fatal: flush takes no arguments")
              @sys.exit(128)
            }
            if !buffer_enabled {
              eprint_line("fatal: flush is only for --buffer mode")
              @sys.exit(128)
            }
            for chunk in pending_chunks {
              @stdio.stdout.write(chunk)
            }
            pending_chunks = []
            line_index += 1
            continue
          }
          if command != "info" && command != "contents" {
            eprint_line("fatal: unknown command")
            @sys.exit(128)
          }
          if command_arg.length() == 0 {
            eprint_line("fatal: \{command} requires arguments")
            @sys.exit(128)
          }
          spec = command_arg
          output_info_mode = command == "info"
        } else if transform_mode || format_uses_rest {
          match line.find(" ") {
            Some(idx) => {
              spec = String::unsafe_substring(line, start=0, end=idx)
              rest = trim_string(
                String::unsafe_substring(line, start=idx + 1, end=line.length()),
              )
              if transform_mode && rest.length() > 0 {
                line_path = Some(rest)
              }
            }
            None => ()
          }
        }
        let effective_path = match line_path {
          Some(path) => Some(path)
          None =>
            match explicit_path {
              Some(path) => Some(path)
              None => cat_file_path_from_spec(spec)
            }
        }
        if transform_mode && effective_path is None {
          eprint_line("fatal: --textconv/--filters needs a path")
          @sys.exit(1)
        }
        let mut object_mode : String? = None
        let mut resolved_oid : @git.ObjectId? = None
        match cat_file_split_object_path_spec(spec) {
          Some((rev_part, path_part)) =>
            if dbs.length() > 0 {
              let base = cat_file_rev_parse_with_compat(fs, git_dir, rev_part)
              if base is Some(base_id) {
                if path_part.length() == 0 {
                  let base_obj = dbs[0].get(fs, base_id) catch { _ => None }
                  if base_obj is Some(obj) {
                    match obj.obj_type {
                      @git.ObjectType::Commit => {
                        resolved_oid = Some(@git.parse_commit(obj.data).tree)
                        object_mode = Some("040000")
                      }
                      @git.ObjectType::Tree => {
                        resolved_oid = Some(base_id)
                        object_mode = Some("040000")
                      }
                      _ => ()
                    }
                  }
                } else if follow_symlinks && output_info_mode {
                  let follow_result = cat_file_resolve_tree_entry_follow_symlinks(
                    dbs[0],
                    fs,
                    base_id,
                    path_part,
                  ) catch {
                    _ =>
                      CatFileFollowResolution::{
                        kind: "missing",
                        id: None,
                        mode: None,
                        symlink_target: None,
                      }
                  }
                  match follow_result.kind {
                    "resolved" => {
                      resolved_oid = follow_result.id
                      object_mode = follow_result.mode
                    }
                    "missing" => ()
                    "symlink" => {
                      let payload = follow_result.symlink_target.unwrap_or("")
                      let line = cat_file_follow_symlink_status_record(
                        "symlink", payload, batch_output_separator,
                      )
                      if buffer_enabled {
                        pending_chunks.push(line)
                      } else {
                        @stdio.stdout.write(line)
                      }
                      line_index += 1
                      continue
                    }
                    "notdir" => {
                      let line = cat_file_follow_symlink_status_record(
                        "notdir", spec, batch_output_separator,
                      )
                      if buffer_enabled {
                        pending_chunks.push(line)
                      } else {
                        @stdio.stdout.write(line)
                      }
                      line_index += 1
                      continue
                    }
                    "dangling" => {
                      let line = cat_file_follow_symlink_status_record(
                        "dangling", spec, batch_output_separator,
                      )
                      if buffer_enabled {
                        pending_chunks.push(line)
                      } else {
                        @stdio.stdout.write(line)
                      }
                      line_index += 1
                      continue
                    }
                    "loop" => {
                      let line = cat_file_follow_symlink_status_record(
                        "loop", spec, batch_output_separator,
                      )
                      if buffer_enabled {
                        pending_chunks.push(line)
                      } else {
                        @stdio.stdout.write(line)
                      }
                      line_index += 1
                      continue
                    }
                    _ => ()
                  }
                } else {
                  let entry = cat_file_find_tree_entry_from_base(
                    dbs[0],
                    fs,
                    base_id,
                    path_part,
                  ) catch {
                    _ => None
                  }
                  if entry is Some(tree_entry) {
                    resolved_oid = Some(tree_entry.id)
                    object_mode = Some(tree_entry.mode)
                  }
                }
              }
            }
          None =>
            if spec.has_prefix(":") && spec.length() > 1 {
              let index_path = String::unsafe_substring(
                spec,
                start=1,
                end=spec.length(),
              )
              let index_entry = cat_file_find_index_entry(
                fs, git_dir, index_path,
              )
              if index_entry is Some(entry) {
                resolved_oid = Some(entry.id)
                object_mode = Some(cat_file_mode_to_text(entry.mode))
              }
            }
        }
        if resolved_oid is None &&
          spec.length() == 40 &&
          cat_file_is_hex_string(spec) {
          let parsed_id = @git.ObjectId::from_hex(spec)
          resolved_oid = Some(parsed_id)
        }
        if resolved_oid is None {
          resolved_oid = cat_file_rev_parse_with_compat(fs, git_dir, spec)
        }
        guard resolved_oid is Some(id) else {
          let missing = cat_file_string_to_bytes(
            spec + " missing" + batch_output_separator,
          )
          if buffer_enabled {
            pending_chunks.push(missing)
          } else {
            @stdio.stdout.write(missing)
          }
          line_index += 1
          continue
        }
        let lookup_id = cat_file_resolve_replace_object_id(fs, git_dir, id)
        let (obj, has_invalid_object_type) = cat_file_find_object_in_dbs_lenient(
          dbs, fs, lookup_id,
        )
        if has_invalid_object_type {
          eprint_line("fatal: invalid object type")
          @sys.exit(128)
        }
        guard obj is Some(o) else {
          if output_info_mode && object_mode is Some(mode) && mode == "160000" {
            let submodule = cat_file_string_to_bytes(
              cat_file_batch_display_object_name(fs, git_dir, spec, id.to_hex()) +
              " submodule" +
              batch_output_separator,
            )
            if buffer_enabled {
              pending_chunks.push(submodule)
            } else {
              @stdio.stdout.write(submodule)
            }
            line_index += 1
            continue
          }
          let missing = cat_file_string_to_bytes(
            spec + " missing" + batch_output_separator,
          )
          if buffer_enabled {
            pending_chunks.push(missing)
          } else {
            @stdio.stdout.write(missing)
          }
          line_index += 1
          continue
        }
        if cat_file_object_is_excluded_by_filter(object_filter, o) {
          let excluded = cat_file_string_to_bytes(
            spec + " excluded" + batch_output_separator,
          )
          if buffer_enabled {
            pending_chunks.push(excluded)
          } else {
            @stdio.stdout.write(excluded)
          }
          line_index += 1
          continue
        }
        let display_object_name = cat_file_batch_display_object_name(
          fs,
          git_dir,
          spec,
          id.to_hex(),
        )
        let target_oid_len = display_object_name.length()
        let delta_base_hex = if format_uses_deltabase {
          cat_file_resolve_delta_base_hex(
            dbs, fs, git_dir, lookup_id, target_oid_len,
          )
        } else {
          None
        }
        let display_data = cat_file_convert_object_data_for_display(
          fs, git_dir, o, target_oid_len,
        )
        let object_size_disk = if format_uses_objectsize_disk {
          cat_file_resolve_object_disk_size(dbs, fs, lookup_id)
        } else {
          None
        }
        if output_info_mode {
          let info = cat_file_string_to_bytes(
            cat_file_format_batch_check_line(
              batch_format,
              id,
              o,
              rest,
              object_mode,
              Some(display_object_name),
              Some(display_data.length()),
              object_size_disk,
              delta_base_hex,
            ) +
            batch_output_separator,
          )
          if buffer_enabled {
            pending_chunks.push(info)
          } else {
            @stdio.stdout.write(info)
          }
          line_index += 1
          continue
        }
        let mut out = display_data
        if transform_mode {
          let path = effective_path.unwrap_or("")
          out = cat_file_apply_path_transforms(
            fs, git_dir, root, path, display_data, filters_mode, textconv_mode,
          )
        }
        let header = cat_file_string_to_bytes(
          cat_file_format_batch_check_line(
            batch_format,
            id,
            o,
            rest,
            object_mode,
            Some(display_object_name),
            Some(display_data.length()),
            object_size_disk,
            delta_base_hex,
          ) +
          batch_output_separator,
        )
        if buffer_enabled {
          pending_chunks.push(header)
          pending_chunks.push(out)
          pending_chunks.push(batch_output_separator_bytes)
        } else {
          @stdio.stdout.write(header)
          @stdio.stdout.write(out)
          @stdio.stdout.write(batch_output_separator_bytes)
        }
        line_index += 1
      }
      if input_eof {
        break
      }
      match @stdio.stdin.read_some(max_len=8192) {
        Some(bytes) =>
          for b in bytes {
            if b == batch_input_separator {
              lines.push(decode_bytes(bytes_from_array(input_record_bytes)))
              input_record_bytes = []
            } else {
              input_record_bytes.push(b)
            }
          }
        None => {
          if input_record_bytes.length() > 0 {
            lines.push(decode_bytes(bytes_from_array(input_record_bytes)))
            input_record_bytes = []
          }
          input_eof = true
        }
      }
    }
    if buffer_enabled && !suppress_flush_on_exit {
      for chunk in pending_chunks {
        @stdio.stdout.write(chunk)
      }
    }
    return ()
  }
  let mut expected_type : @git.ObjectType? = None
  let mut obj_spec : String? = None
  if not(show_type || show_size || pretty_print) && positionals.length() >= 2 {
    match cat_file_parse_object_type_name(positionals[0]) {
      Some(obj_type) => {
        expected_type = Some(obj_type)
        obj_spec = Some(positionals[1])
      }
      None => {
        eprint_line("fatal: invalid object type \"\{positionals[0]}\"")
        @sys.exit(128)
      }
    }
  }
  if obj_spec is None && positionals.length() > 0 {
    obj_spec = Some(positionals[positionals.length() - 1])
  }
  guard obj_spec is Some(spec) else {
    raise @git.GitError::InvalidObject("object name required")
  }
  let mut effective_path = match explicit_path {
    Some(path) => Some(path)
    None => cat_file_path_from_spec(spec)
  }
  let mut resolved_obj_id : @git.ObjectId? = None
  let mut resolved_mode : String? = None
  match cat_file_split_object_path_spec(spec) {
    Some((rev_part, path_part)) => {
      let base_id = cat_file_rev_parse_with_compat(fs, git_dir, rev_part)
      guard base_id is Some(base) else {
        eprint_line("fatal: invalid object name '\{rev_part}'.")
        @sys.exit(128)
      }
      let db_for_path = @gitlib.ObjectDb::load(fs, git_dir)
      if path_part.length() == 0 {
        let base_obj = db_for_path.get(fs, base) catch { _ => None }
        guard base_obj is Some(obj) else {
          eprint_line(
            "fatal: path '\{path_part}' does not exist in '\{rev_part}'",
          )
          @sys.exit(128)
        }
        match obj.obj_type {
          @git.ObjectType::Commit => {
            resolved_obj_id = Some(@git.parse_commit(obj.data).tree)
            resolved_mode = Some("040000")
          }
          @git.ObjectType::Tree => {
            resolved_obj_id = Some(base)
            resolved_mode = Some("040000")
          }
          _ => {
            eprint_line(
              "fatal: path '\{path_part}' does not exist in '\{rev_part}'",
            )
            @sys.exit(128)
          }
        }
      } else {
        let entry = cat_file_find_tree_entry_from_base(
          db_for_path, fs, base, path_part,
        )
        guard entry is Some(tree_entry) else {
          eprint_line(
            "fatal: path '\{path_part}' does not exist in '\{rev_part}'",
          )
          @sys.exit(128)
        }
        resolved_obj_id = Some(tree_entry.id)
        resolved_mode = Some(tree_entry.mode)
      }
      if explicit_path is None {
        effective_path = Some(path_part)
      }
    }
    None =>
      if spec.has_prefix(":") && spec.length() > 1 {
        let index_path = String::unsafe_substring(
          spec,
          start=1,
          end=spec.length(),
        )
        let index_entry = cat_file_find_index_entry(fs, git_dir, index_path)
        guard index_entry is Some(entry) else {
          eprint_line("fatal: path '\{index_path}' does not exist in index")
          @sys.exit(128)
        }
        resolved_obj_id = Some(entry.id)
        resolved_mode = Some(cat_file_mode_to_text(entry.mode))
        if explicit_path is None {
          effective_path = Some(index_path)
        }
      } else {
        resolved_obj_id = cat_file_rev_parse_with_compat(fs, git_dir, spec)
      }
  }
  if transform_mode && effective_path is None {
    match resolved_obj_id {
      Some(_) => {
        eprint_line(
          "fatal: <object>:<path> required, only <object> '\{spec}' given",
        )
        @sys.exit(128)
      }
      None => {
        eprint_line("fatal: Not a valid object name \{spec}")
        @sys.exit(128)
      }
    }
  }
  let dbs = cat_file_load_object_dbs(fs, git_dir)
  let db = dbs[0]
  if exists_check {
    match resolved_obj_id {
      Some(oid) =>
        if cat_file_object_exists_for_exists_check(dbs, fs, oid) {
          return ()
        }
      None => ()
    }
    @sys.exit(1)
  }
  guard resolved_obj_id is Some(oid) else {
    eprint_line("fatal: Not a valid object name \{spec}")
    @sys.exit(128)
  }
  let obj = cat_file_find_object_in_dbs(dbs, fs, oid) catch {
    err =>
      match err {
        @git.GitError::InvalidObject(msg) => {
          let prefix = "Unknown object type: "
          if msg.has_prefix(prefix) {
            let obj_type = String::unsafe_substring(
              msg,
              start=prefix.length(),
              end=msg.length(),
            )
            if obj_type.length() > 32 {
              eprint_line(
                "error: header for \{oid.to_hex()} too long, exceeds 32 bytes",
              )
              if pretty_print {
                eprint_line("fatal: Not a valid object name \{oid.to_hex()}")
              } else {
                eprint_line("fatal: git cat-file: could not get object info")
              }
            } else {
              eprint_line("fatal: invalid object type")
            }
            @sys.exit(128)
          }
          if cat_file_is_zlib_dictionary_error(msg) {
            eprint_line("error: inflate: needs dictionary")
            eprint_line("error: unable to unpack \{oid.to_hex()} header")
            @sys.exit(128)
          }
          raise err
        }
        _ => raise err
      }
  }
  guard obj is Some(o) else {
    if pretty_print {
      eprint_line("fatal: Not a valid object name \{spec}")
    } else {
      eprint_line("fatal: git cat-file: could not get object info")
    }
    @sys.exit(128)
  }
  let display_object_name = cat_file_batch_display_object_name(
    fs,
    git_dir,
    spec,
    oid.to_hex(),
  )
  let target_oid_len = display_object_name.length()
  let display_data = cat_file_convert_object_data_for_display(
    fs, git_dir, o, target_oid_len,
  )
  if expected_type is Some(expected) {
    let data = if o.obj_type == expected {
      display_data
    } else {
      peel_cat_file_object_to_type(db, fs, oid, expected) catch {
        _ =>
          raise @git.GitError::InvalidObject(
            "object is of type \{o.obj_type.to_string()}, not \{expected.to_string()}",
          )
      }
    }
    @stdio.stdout.write(data)
    return ()
  }
  if show_type {
    print_line(o.obj_type.to_string())
    return ()
  }
  if show_size {
    print_line(display_data.length().to_string())
    return ()
  }
  if pretty_print {
    match o.obj_type {
      @git.ObjectType::Blob => @stdio.stdout.write(display_data)
      @git.ObjectType::Tree => {
        let entries = @git.parse_tree(o.data)
        for entry in entries {
          let mode_str = if entry.mode == "40000" {
            "040000"
          } else {
            entry.mode
          }
          let type_str = if entry.mode == "40000" { "tree" } else { "blob" }
          let display_entry_id = cat_file_map_oid_hex_to_length(
            fs,
            git_dir,
            entry.id.to_hex(),
            target_oid_len,
          )
          print_line(
            "\{mode_str} \{type_str} \{display_entry_id}\t\{entry.name}",
          )
        }
      }
      @git.ObjectType::Commit => @stdio.stdout.write(display_data)
      @git.ObjectType::Tag => @stdio.stdout.write(display_data)
    }
    return ()
  }
  if transform_mode {
    if textconv_mode && cat_file_mode_is_symlink(resolved_mode) {
      @stdio.stdout.write(o.data)
      return ()
    }
    let path = effective_path.unwrap_or("")
    let out = cat_file_apply_path_transforms(
      fs,
      git_dir,
      root,
      path,
      o.data,
      filters_mode,
      textconv_mode,
    )
    @stdio.stdout.write(out)
    return ()
  }
  // Default: output raw content
  @stdio.stdout.write(display_data)
}

///|
fn cat_file_load_object_dbs(
  fs : OsFs,
  git_dir : String,
) -> Array[@gitlib.ObjectDb] {
  let out : Array[@gitlib.ObjectDb] = []
  let object_dirs = cat_file_collect_object_dirs(fs, git_dir)
  for object_dir in object_dirs {
    let alt_db = @gitlib.ObjectDb::load_from_objects_dir(fs, object_dir) catch {
      _ => continue
    }
    alt_db.set_skip_verify(true)
    out.push(alt_db)
  }
  out
}

///|
fn cat_file_find_object_in_dbs(
  dbs : Array[@gitlib.ObjectDb],
  fs : OsFs,
  id : @git.ObjectId,
) -> @git.PackObject? raise Error {
  for db in dbs {
    let obj = db.get(fs, id)
    if obj is Some(o) {
      return Some(o)
    }
  }
  None
}

///|
fn cat_file_find_object_in_dbs_lenient(
  dbs : Array[@gitlib.ObjectDb],
  fs : OsFs,
  id : @git.ObjectId,
) -> (@git.PackObject?, Bool) {
  for db in dbs {
    let obj = db.get(fs, id) catch {
      err =>
        match err {
          @git.GitError::InvalidObject(msg) =>
            if cat_file_extract_unknown_object_type(msg) is Some(_) {
              return (None, true)
            } else {
              None
            }
          _ => None
        }
    }
    if obj is Some(o) {
      return (Some(o), false)
    }
  }
  (None, false)
}

///|
fn cat_file_object_exists_for_exists_check(
  dbs : Array[@gitlib.ObjectDb],
  fs : OsFs,
  id : @git.ObjectId,
) -> Bool {
  for db in dbs {
    let obj = db.get(fs, id) catch {
      err =>
        match err {
          @git.GitError::InvalidObject(msg) =>
            if msg.has_prefix("Unknown object type: ") {
              return true
            } else {
              None
            }
          _ => None
        }
    }
    if obj is Some(_) {
      return true
    }
  }
  false
}

///|
fn cat_file_extract_unknown_object_type(msg : String) -> String? {
  let prefix = "Unknown object type: "
  if !msg.has_prefix(prefix) {
    return None
  }
  Some(String::unsafe_substring(msg, start=prefix.length(), end=msg.length()))
}

///|
fn cat_file_is_zlib_dictionary_error(msg : String) -> Bool {
  if !msg.has_prefix("Zlib error: ") {
    return false
  }
  msg.contains("Preset dictionary") || msg.contains("needs dictionary")
}

///|
fn cat_file_collect_batch_all_objects(
  fs : OsFs,
  object_dirs : Array[String],
  unordered : Bool,
) -> Array[@git.ObjectId] {
  let seen_ids : Map[String, Bool] = {}
  for scan_object_dir in object_dirs {
    let db = @gitlib.ObjectDb::load_from_objects_dir(fs, scan_object_dir) catch {
      _ => continue
    }
    for item in db.loose_paths.to_array() {
      let (hex, _) = item
      seen_ids[hex] = true
    }
    for pack in db.packs {
      for hex in pack.ids {
        seen_ids[hex] = true
      }
    }
    for lazy_pack in db.lazy_packs {
      let pack = lazy_pack.get(fs) catch { _ => continue }
      for hex in pack.ids {
        seen_ids[hex] = true
      }
    }
  }
  let ids : Array[String] = []
  for item in seen_ids.to_array() {
    let (hex, _) = item
    ids.push(hex)
  }
  if not(unordered) {
    ids.sort()
  }
  let out : Array[@git.ObjectId] = []
  for hex in ids {
    let id = @git.ObjectId::from_hex(hex) catch { _ => continue }
    out.push(id)
  }
  out
}

///|
fn cat_file_collect_batch_all_object_disk_records(
  fs : OsFs,
  object_dirs : Array[String],
  unordered : Bool,
) -> Array[CatFileBatchAllObjectDiskRecord] {
  let out : Array[CatFileBatchAllObjectDiskRecord] = []
  for scan_object_dir in object_dirs {
    let db = @gitlib.ObjectDb::load_from_objects_dir(fs, scan_object_dir) catch {
      _ => continue
    }
    for item in db.loose_paths.to_array() {
      let (hex, path) = item
      let id = @git.ObjectId::from_hex(hex) catch { _ => continue }
      let size = fs.read_file(path).length() catch { _ => continue }
      out.push(CatFileBatchAllObjectDiskRecord::{ id, disk_size: size })
    }
    for pack in db.packs {
      cat_file_append_pack_disk_records(fs, pack, out)
    }
    for lazy_pack in db.lazy_packs {
      let pack = lazy_pack.get(fs) catch { _ => continue }
      cat_file_append_pack_disk_records(fs, pack, out)
    }
  }
  if not(unordered) {
    out.sort_by((a, b) => {
      String::compare(
        a.id.to_hex() + " " + a.disk_size.to_string(),
        b.id.to_hex() + " " + b.disk_size.to_string(),
      )
    })
  }
  out
}

///|
fn cat_file_append_pack_disk_records(
  fs : OsFs,
  pack : @gitlib.PackIndex,
  out : Array[CatFileBatchAllObjectDiskRecord],
) -> Unit {
  let pack_data = fs.read_file(pack.pack_path) catch { _ => return }
  if pack_data.length() <= 20 {
    return
  }
  let pack_end = (pack_data.length() - 20).to_int64()
  for i in 0..<pack.ids.length() {
    let offset = pack.offsets[i]
    let size = cat_file_compute_pack_entry_disk_size(
      pack.offsets,
      offset,
      pack_end,
    )
    guard size is Some(entry_size) else { continue }
    let id = @git.ObjectId::from_hex(pack.ids[i]) catch { _ => continue }
    out.push(CatFileBatchAllObjectDiskRecord::{ id, disk_size: entry_size })
  }
}

///|
fn cat_file_compute_pack_entry_disk_size(
  offsets : Array[Int64],
  offset : Int64,
  pack_end : Int64,
) -> Int? {
  let mut next_offset : Int64? = None
  for candidate in offsets {
    if candidate > offset {
      match next_offset {
        Some(current) =>
          if candidate < current {
            next_offset = Some(candidate)
          }
        None => next_offset = Some(candidate)
      }
    }
  }
  let end_offset = match next_offset {
    Some(found) => found
    None => pack_end
  }
  if end_offset < offset {
    return None
  }
  let size64 = end_offset - offset
  if size64 < 0L || size64 > 2147483647L {
    return None
  }
  Some(size64.to_int())
}

///|
fn cat_file_collect_object_dirs(fs : OsFs, git_dir : String) -> Array[String] {
  let primary_objects_dir = git_dir + "/objects"
  let out : Array[String] = [primary_objects_dir]
  let seen_object_dirs : Map[String, Bool] = {}
  seen_object_dirs[normalize_path(primary_objects_dir)] = true
  let alt_object_dirs = cat_file_read_alternate_object_dirs(fs, git_dir)
  for alt_object_dir in alt_object_dirs {
    let normalized = normalize_path(alt_object_dir)
    if seen_object_dirs.contains(normalized) {
      continue
    }
    seen_object_dirs[normalized] = true
    out.push(alt_object_dir)
  }
  out
}

///|
fn cat_file_read_alternate_object_dirs(
  fs : OsFs,
  git_dir : String,
) -> Array[String] {
  let out : Array[String] = []
  let alt_path = git_dir + "/objects/info/alternates"
  if not(fs.is_file(alt_path)) {
    return out
  }
  let data = fs.read_file(alt_path) catch { _ => return out }
  let base_dir = git_dir + "/objects/info"
  let seen : Map[String, Bool] = {}
  let text = decode_bytes(data)
  for line_view in text.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let objects_dir = if line.has_prefix("/") {
      normalize_path(line)
    } else {
      normalize_path(base_dir + "/" + line)
    }
    if not(fs.is_dir(objects_dir)) {
      continue
    }
    if seen.contains(objects_dir) {
      continue
    }
    seen[objects_dir] = true
    out.push(objects_dir)
  }
  out
}

///|
fn cat_file_format_batch_check_line(
  format : String?,
  id : @git.ObjectId,
  obj : @git.PackObject,
  rest : String,
  object_mode : String?,
  object_name_override : String?,
  object_size_override : Int?,
  object_size_disk_override : Int?,
  delta_base_hex : String?,
) -> String {
  let mut out = match format {
    Some(fmt) if fmt.length() > 0 => fmt
    _ => "%(objectname) %(objecttype) %(objectsize)"
  }
  let id_hex = object_name_override.unwrap_or(id.to_hex())
  let zero_oid = cat_file_zero_oid(id_hex.length())
  let object_size = object_size_override.unwrap_or(obj.data.length())
  let object_size_disk = object_size_disk_override.unwrap_or(object_size)
  out = out.replace_all(
    old="%(objectsize:disk)",
    new=object_size_disk.to_string(),
  )
  out = out.replace_all(old="%(objectsize)", new=object_size.to_string())
  out = out.replace_all(old="%(objectname)", new=id_hex)
  out = out.replace_all(old="%(objecttype)", new=obj.obj_type.to_string())
  out = out.replace_all(
    old="%(deltabase)",
    new=delta_base_hex.unwrap_or(zero_oid),
  )
  out = out.replace_all(old="%(rest)", new=rest)
  out = out.replace_all(old="%(objectmode)", new=object_mode.unwrap_or(""))
  out
}

///|
fn cat_file_batch_format_uses_rest(format : String?) -> Bool {
  match format {
    Some(fmt) => fmt.contains("%(rest)")
    None => false
  }
}

///|
fn cat_file_batch_format_uses_deltabase(format : String?) -> Bool {
  match format {
    Some(fmt) => fmt.contains("%(deltabase)")
    None => false
  }
}

///|
fn cat_file_batch_format_uses_objectsize_disk(format : String?) -> Bool {
  match format {
    Some(fmt) => fmt.contains("%(objectsize:disk)")
    None => false
  }
}

///|
fn cat_file_parse_object_type_name(name : String) -> @git.ObjectType? {
  match name {
    "blob" => Some(@git.ObjectType::Blob)
    "commit" => Some(@git.ObjectType::Commit)
    "tag" => Some(@git.ObjectType::Tag)
    "tree" => Some(@git.ObjectType::Tree)
    _ => None
  }
}

///|
fn cat_file_batch_check_format_needs_object(format : String?) -> Bool {
  let effective = match format {
    Some(fmt) if fmt.length() > 0 => fmt
    _ => "%(objectname) %(objecttype) %(objectsize)"
  }
  effective.contains("%(objecttype)") ||
  effective.contains("%(objectsize)") ||
  effective.contains("%(objectsize:disk)") ||
  effective.contains("%(deltabase)")
}

///|
async fn cat_file_parse_object_filter_or_exit(
  spec : String?,
) -> CatFileObjectFilter raise Error {
  match spec {
    Some(value) => cat_file_parse_object_filter_spec_or_exit(value)
    None => CatFileObjectFilter::Disabled
  }
}

///|
async fn cat_file_parse_object_filter_spec_or_exit(
  spec : String,
) -> CatFileObjectFilter raise Error {
  if spec == "blob:none" {
    return CatFileObjectFilter::BlobNone
  }
  if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = parse_size_value(limit_str)
    guard limit is Some(max_size) else {
      return cat_file_filter_die_fatal("fatal: invalid filter-spec '\{spec}'")
    }
    return CatFileObjectFilter::BlobLimit(max_size)
  }
  if spec.has_prefix("object:type=") {
    let object_type_name = String::unsafe_substring(
      spec,
      start=12,
      end=spec.length(),
    )
    let object_type : @git.ObjectType? = match object_type_name {
      "blob" => Some(@git.ObjectType::Blob)
      "commit" => Some(@git.ObjectType::Commit)
      "tag" => Some(@git.ObjectType::Tag)
      "tree" => Some(@git.ObjectType::Tree)
      _ => None
    }
    guard object_type is Some(filter_type) else {
      return cat_file_filter_die_fatal("fatal: invalid filter-spec '\{spec}'")
    }
    return CatFileObjectFilter::ObjectType(filter_type)
  }
  if spec == "sparse:path" || spec.has_prefix("sparse:path=") {
    return cat_file_filter_die_fatal(
      "fatal: sparse:path filters support has been dropped",
    )
  }
  if spec.has_prefix("tree:") || spec.has_prefix("sparse:oid=") {
    let kind = cat_file_parse_object_filter_kind(spec)
    return cat_file_filter_die_usage(
      "usage: objects filter not supported: '\{kind}'",
    )
  }
  cat_file_filter_die_fatal("fatal: invalid filter-spec '\{spec}'")
}

///|
fn cat_file_parse_object_filter_kind(spec : String) -> String {
  if spec.has_prefix("tree:") {
    return "tree"
  }
  match spec.find("=") {
    Some(idx) => String::unsafe_substring(spec, start=0, end=idx)
    None => spec
  }
}

///|
async fn cat_file_filter_die_fatal(
  message : String,
) -> CatFileObjectFilter raise Error {
  eprint_line(message)
  @sys.exit(128)
  CatFileObjectFilter::Disabled
}

///|
async fn cat_file_filter_die_usage(
  message : String,
) -> CatFileObjectFilter raise Error {
  eprint_line(message)
  @sys.exit(129)
  CatFileObjectFilter::Disabled
}

///|
fn cat_file_object_filter_is_disabled(filter : CatFileObjectFilter) -> Bool {
  match filter {
    Disabled => true
    _ => false
  }
}

///|
fn cat_file_object_is_excluded_by_filter(
  filter : CatFileObjectFilter,
  obj : @git.PackObject,
) -> Bool {
  match filter {
    Disabled => false
    BlobNone => obj.obj_type == @git.ObjectType::Blob
    BlobLimit(limit) =>
      obj.obj_type == @git.ObjectType::Blob &&
      obj.data.length().to_int64() >= limit
    ObjectType(filter_type) => obj.obj_type != filter_type
  }
}

///|
fn cat_file_resolve_replace_object_id(
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
) -> @git.ObjectId {
  let mut current = id
  let seen : Map[String, Bool] = {}
  while true {
    let hex = current.to_hex()
    if seen.contains(hex) {
      break
    }
    seen[hex] = true
    let replace_ref = @gitlib.resolve_ref(fs, git_dir, "refs/replace/" + hex) catch {
      _ => None
    }
    match replace_ref {
      Some(replaced) => current = replaced
      None => break
    }
  }
  current
}

///|
fn cat_file_resolve_delta_base_hex(
  dbs : Array[@gitlib.ObjectDb],
  fs : OsFs,
  git_dir : String,
  id : @git.ObjectId,
  target_oid_len : Int,
) -> String? {
  for db in dbs {
    let base = db.find_delta_base(fs, id) catch { _ => None }
    if base is Some(base_id) {
      return Some(
        cat_file_map_oid_hex_to_length(
          fs,
          git_dir,
          base_id.to_hex(),
          target_oid_len,
        ),
      )
    }
  }
  None
}

///|
fn cat_file_resolve_object_disk_size(
  dbs : Array[@gitlib.ObjectDb],
  fs : OsFs,
  id : @git.ObjectId,
) -> Int? {
  for db in dbs {
    let disk_size = db.find_object_disk_size(fs, id) catch { _ => None }
    if disk_size is Some(size) {
      return Some(size)
    }
  }
  None
}

///|
fn cat_file_follow_symlink_status_record(
  kind : String,
  payload : String,
  separator : String,
) -> Bytes {
  cat_file_string_to_bytes(
    kind + " " + payload.length().to_string() + separator + payload + separator,
  )
}

///|
fn cat_file_zero_oid(length : Int) -> String {
  let mut out = ""
  let mut i = 0
  while i < length {
    out = out + "0"
    i += 1
  }
  out
}

///|
fn cat_file_has_incremental_midx_chain(
  fs : &@git.RepoFileSystem,
  git_dir : String,
) -> Bool {
  let chain_path = git_dir +
    "/objects/pack/multi-pack-index.d/multi-pack-index-chain"
  fs.is_file(chain_path)
}

///|
fn cat_file_validate_midx_large_offsets(
  fs : OsFs,
  objects_dir : String,
) -> Bool {
  let midx_path = objects_dir + "/pack/multi-pack-index"
  if not(fs.is_file(midx_path)) {
    return false
  }
  let data = fs.read_file(midx_path) catch { _ => return false }
  if data.length() < 20 {
    return false
  }
  if data[0] != b'M' || data[1] != b'I' || data[2] != b'D' || data[3] != b'X' {
    return false
  }
  let num_chunks = data[6].to_int()
  if num_chunks <= 0 {
    return false
  }
  let table_size = 12 + (num_chunks + 1) * 12
  if table_size > data.length() {
    return false
  }
  let oidf_start = midx_find_chunk(data, num_chunks, "OIDF")
  let ooff_start = midx_find_chunk(data, num_chunks, "OOFF")
  let ooff_end = midx_find_chunk_end(data, num_chunks, "OOFF")
  if oidf_start <= 0 || ooff_start <= 0 || ooff_end <= ooff_start {
    return false
  }
  let fanout_end = oidf_start + 256 * 4
  if fanout_end > data.length() {
    return false
  }
  let object_count = midx_read_u32(data, oidf_start + 255 * 4)
  if object_count <= 0 {
    return false
  }
  let loff_start = midx_find_chunk(data, num_chunks, "LOFF")
  let loff_end = if loff_start > 0 {
    midx_find_chunk_end(data, num_chunks, "LOFF")
  } else {
    0
  }
  let max_objects = (ooff_end - ooff_start) / 8
  let limit = if object_count < max_objects {
    object_count
  } else {
    max_objects
  }
  let mut i = 0
  while i < limit {
    let entry_offset = ooff_start + i * 8
    if entry_offset + 8 > data.length() {
      break
    }
    let raw_offset = midx_read_u32(data, entry_offset + 4)
    if raw_offset < 0 {
      let large_idx = raw_offset & 2147483647
      if loff_start <= 0 {
        return true
      }
      let loff_pos = loff_start + large_idx * 8
      if loff_pos + 8 > loff_end || loff_pos + 8 > data.length() {
        return true
      }
    }
    i += 1
  }
  false
}

///|
fn cat_file_rev_parse_with_compat(
  fs : OsFs,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise Error {
  let direct = cat_file_rev_parse_direct_or_loose(fs, git_dir, spec)
  if direct is Some(_) {
    return direct
  }
  let reflog_zero = cat_file_rev_parse_reflog_zero_with_compat(
    fs, git_dir, spec,
  )
  if reflog_zero is Some(_) {
    return reflog_zero
  }
  cat_file_rev_parse_commit_message_search_with_compat(fs, git_dir, spec)
}

///|
fn cat_file_rev_parse_direct_or_loose(
  fs : OsFs,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise Error {
  let direct = @gitrepo.rev_parse(fs, git_dir, spec)
  if direct is Some(_) {
    return direct
  }
  match cat_file_lookup_loose_object_idx(fs, git_dir, spec) {
    Some(mapped) => @gitrepo.rev_parse(fs, git_dir, mapped)
    None => None
  }
}

///|
fn cat_file_rev_parse_reflog_zero_with_compat(
  fs : OsFs,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise Error {
  let suffix = "@{0}"
  if !spec.has_suffix(suffix) || spec.length() <= suffix.length() {
    return None
  }
  let base_spec = String::unsafe_substring(
    spec,
    start=0,
    end=spec.length() - suffix.length(),
  )
  cat_file_rev_parse_direct_or_loose(fs, git_dir, base_spec)
}

///|
fn cat_file_rev_parse_commit_message_search_with_compat(
  fs : OsFs,
  git_dir : String,
  spec : String,
) -> @git.ObjectId? raise Error {
  match cat_file_split_commit_message_search_spec(spec) {
    Some((base_spec, needle)) => {
      let base = cat_file_rev_parse_direct_or_loose(fs, git_dir, base_spec)
      guard base is Some(base_id) else { return None }
      let db = @gitlib.ObjectDb::load(fs, git_dir) catch { _ => return None }
      cat_file_find_reachable_commit_by_message(db, fs, base_id, needle)
    }
    None => None
  }
}

///|
fn cat_file_split_commit_message_search_spec(
  spec : String,
) -> (String, String)? {
  let marker = "^{/"
  match spec.find(marker) {
    Some(idx) if idx > 0 &&
      spec.has_suffix("}") &&
      idx + marker.length() < spec.length() - 1 =>
      Some(
        (
          String::unsafe_substring(spec, start=0, end=idx),
          String::unsafe_substring(
            spec,
            start=idx + marker.length(),
            end=spec.length() - 1,
          ),
        ),
      )
    _ => None
  }
}

///|
fn cat_file_find_reachable_commit_by_message(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  start : @git.ObjectId,
  needle : String,
) -> @git.ObjectId? {
  let queue : Array[@git.ObjectId] = [start]
  let seen : Map[String, Bool] = {}
  while queue.length() > 0 {
    let current = queue.unsafe_pop()
    let hex = current.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    let obj = db.get(fs, current) catch { _ => continue }
    match obj {
      Some(o) if o.obj_type == @git.ObjectType::Commit => {
        if cat_file_commit_message_contains(o.data, needle) {
          return Some(current)
        }
        let info = @git.parse_commit(o.data) catch { _ => continue }
        for parent in info.parents {
          if not(seen.contains(parent.to_hex())) {
            queue.push(parent)
          }
        }
      }
      _ => ()
    }
  }
  None
}

///|
fn cat_file_commit_message_contains(data : Bytes, needle : String) -> Bool {
  if needle.length() == 0 {
    return true
  }
  let text = decode_bytes(data)
  match text.find("\n\n") {
    Some(idx) if idx + 2 <= text.length() => {
      let message = String::unsafe_substring(
        text,
        start=idx + 2,
        end=text.length(),
      )
      message.find(needle) is Some(_)
    }
    _ => false
  }
}

///|
fn cat_file_lookup_loose_object_idx(
  fs : OsFs,
  git_dir : String,
  spec : String,
) -> String? {
  let idx_path = git_dir + "/objects/loose-object-idx"
  if !fs.is_file(idx_path) {
    return None
  }
  let text = decode_bytes(fs.read_file(idx_path) catch { _ => return None })
  for line_view in text.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let cols : Array[String] = []
    for col_view in line.split(" ") {
      let col = trim_string(col_view.to_string())
      if col.length() > 0 {
        cols.push(col)
      }
    }
    if cols.length() < 2 {
      continue
    }
    let a = cols[0]
    let b = cols[1]
    if spec == a {
      return Some(b)
    }
    if spec == b {
      return Some(a)
    }
  }
  None
}

///|
fn cat_file_batch_display_object_name(
  fs : OsFs,
  git_dir : String,
  spec : String,
  resolved_hex : String,
) -> String {
  match cat_file_batch_oid_token(spec) {
    Some(token) =>
      if token.length() == resolved_hex.length() {
        resolved_hex
      } else {
        match cat_file_lookup_loose_object_idx(fs, git_dir, resolved_hex) {
          Some(mapped) if mapped.length() == token.length() => mapped
          _ => resolved_hex
        }
      }
    None => resolved_hex
  }
}

///|
fn cat_file_batch_oid_token(spec : String) -> String? {
  match cat_file_split_object_path_spec(spec) {
    Some((rev_part, _)) =>
      if rev_part.length() > 0 {
        Some(rev_part)
      } else {
        None
      }
    None => if spec.has_prefix(":") { None } else { Some(spec) }
  }
}

///|
fn cat_file_convert_object_data_for_display(
  fs : OsFs,
  git_dir : String,
  obj : @git.PackObject,
  target_oid_len : Int,
) -> Bytes {
  if target_oid_len != 64 {
    return obj.data
  }
  match obj.obj_type {
    @git.ObjectType::Blob => obj.data
    @git.ObjectType::Tree =>
      cat_file_convert_tree_data_for_display(
        fs,
        git_dir,
        obj.data,
        target_oid_len,
      )
    @git.ObjectType::Commit =>
      cat_file_rewrite_text_object_ids_for_display(
        fs,
        git_dir,
        obj.data,
        target_oid_len,
      )
    @git.ObjectType::Tag =>
      cat_file_rewrite_text_object_ids_for_display(
        fs,
        git_dir,
        obj.data,
        target_oid_len,
      )
  }
}

///|
fn cat_file_convert_tree_data_for_display(
  fs : OsFs,
  git_dir : String,
  data : Bytes,
  target_oid_len : Int,
) -> Bytes {
  let entries = @git.parse_tree(data) catch { _ => return data }
  let out : Array[Byte] = []
  for entry in entries {
    for c in entry.mode.to_array() {
      out.push(c.to_int().to_byte())
    }
    out.push(b' ')
    for c in entry.name.to_array() {
      out.push(c.to_int().to_byte())
    }
    out.push(b'\x00')
    let mapped_hex = cat_file_map_oid_hex_to_length(
      fs,
      git_dir,
      entry.id.to_hex(),
      target_oid_len,
    )
    let oid_bytes = match cat_file_hex_to_byte_array(mapped_hex) {
      Some(bytes) => bytes
      None => cat_file_hex_to_byte_array(entry.id.to_hex()).unwrap_or([])
    }
    for b in oid_bytes {
      out.push(b)
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn cat_file_rewrite_text_object_ids_for_display(
  fs : OsFs,
  git_dir : String,
  data : Bytes,
  target_oid_len : Int,
) -> Bytes {
  let out : Array[Byte] = []
  let mut line : Array[Byte] = []
  let mut in_header = true
  for b in data {
    if b == b'\n' {
      let next_line = if in_header {
        cat_file_rewrite_header_oid_line_bytes(
          fs, git_dir, line, target_oid_len,
        )
      } else {
        line
      }
      for ch in next_line {
        out.push(ch)
      }
      out.push(b'\n')
      if in_header && line.length() == 0 {
        in_header = false
      }
      line = []
    } else {
      line.push(b)
    }
  }
  if line.length() > 0 {
    let next_line = if in_header {
      cat_file_rewrite_header_oid_line_bytes(fs, git_dir, line, target_oid_len)
    } else {
      line
    }
    for ch in next_line {
      out.push(ch)
    }
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn cat_file_rewrite_header_oid_line_bytes(
  fs : OsFs,
  git_dir : String,
  line : Array[Byte],
  target_oid_len : Int,
) -> Array[Byte] {
  let line_str = decode_bytes(
    Bytes::from_array(FixedArray::makei(line.length(), fn(i) { line[i] })),
  )
  match
    cat_file_rewrite_header_oid_line(fs, git_dir, line_str, target_oid_len) {
    Some(rewritten) => {
      let out : Array[Byte] = []
      for c in rewritten.to_array() {
        out.push(c.to_int().to_byte())
      }
      out
    }
    None => line
  }
}

///|
fn cat_file_rewrite_header_oid_line(
  fs : OsFs,
  git_dir : String,
  line : String,
  target_oid_len : Int,
) -> String? {
  let prefixes = ["tree ", "parent ", "object "]
  for prefix in prefixes {
    if line.has_prefix(prefix) {
      let rest = String::unsafe_substring(
        line,
        start=prefix.length(),
        end=line.length(),
      )
      let mut oid = rest
      let mut suffix = ""
      match rest.find(" ") {
        Some(idx) => {
          oid = String::unsafe_substring(rest, start=0, end=idx)
          suffix = String::unsafe_substring(rest, start=idx, end=rest.length())
        }
        None => ()
      }
      if !cat_file_is_hex_string(oid) {
        return None
      }
      let mapped = cat_file_map_oid_hex_to_length(
        fs, git_dir, oid, target_oid_len,
      )
      if mapped != oid {
        return Some(prefix + mapped + suffix)
      }
      return None
    }
  }
  None
}

///|
fn cat_file_map_oid_hex_to_length(
  fs : OsFs,
  git_dir : String,
  oid_hex : String,
  target_oid_len : Int,
) -> String {
  if target_oid_len <= 0 || oid_hex.length() == target_oid_len {
    return oid_hex
  }
  match cat_file_lookup_loose_object_idx(fs, git_dir, oid_hex) {
    Some(mapped) if mapped.length() == target_oid_len => mapped
    _ => oid_hex
  }
}

///|
fn cat_file_hex_nibble(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    return Some(c.to_int() - '0'.to_int())
  }
  if c >= 'a' && c <= 'f' {
    return Some(c.to_int() - 'a'.to_int() + 10)
  }
  if c >= 'A' && c <= 'F' {
    return Some(c.to_int() - 'A'.to_int() + 10)
  }
  None
}

///|
fn cat_file_is_hex_string(s : String) -> Bool {
  if s.length() != 40 && s.length() != 64 {
    return false
  }
  for c in s.to_array() {
    if cat_file_hex_nibble(c) is None {
      return false
    }
  }
  true
}

///|
fn cat_file_hex_to_byte_array(hex : String) -> Array[Byte]? {
  if hex.length() % 2 != 0 {
    return None
  }
  let chars = hex.to_array()
  let out : Array[Byte] = []
  let mut i = 0
  while i < chars.length() {
    let hi = cat_file_hex_nibble(chars[i])
    let lo = cat_file_hex_nibble(chars[i + 1])
    match (hi, lo) {
      (Some(h), Some(l)) => out.push(((h << 4) | l).to_byte())
      _ => return None
    }
    i += 2
  }
  Some(out)
}

///|
fn cat_file_path_from_spec(spec : String) -> String? {
  match cat_file_find_path_separator_index(spec) {
    Some(idx) if idx + 1 < spec.length() =>
      Some(String::unsafe_substring(spec, start=idx + 1, end=spec.length()))
    _ => None
  }
}

///|
fn cat_file_split_object_path_spec(spec : String) -> (String, String)? {
  match cat_file_find_path_separator_index(spec) {
    Some(idx) if idx > 0 =>
      Some(
        (
          String::unsafe_substring(spec, start=0, end=idx),
          String::unsafe_substring(spec, start=idx + 1, end=spec.length()),
        ),
      )
    _ => None
  }
}

///|
fn cat_file_find_path_separator_index(spec : String) -> Int? {
  let chars = spec.to_array()
  let mut brace_depth = 0
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '{' {
      brace_depth += 1
    } else if c == '}' {
      if brace_depth > 0 {
        brace_depth -= 1
      }
    } else if c == ':' && brace_depth == 0 && i > 0 {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
fn cat_file_mode_to_text(mode : Int) -> String {
  if mode == 40960 {
    "120000"
  } else {
    mode.to_string()
  }
}

///|
fn cat_file_mode_is_symlink(mode : String?) -> Bool {
  match mode {
    Some("120000") => true
    Some("0120000") => true
    _ => false
  }
}

///|
fn cat_file_find_index_entry(
  fs : OsFs,
  git_dir : String,
  path : String,
) -> @gitlib.IndexEntry? {
  let entries = @gitlib.read_index_entries(fs, git_dir) catch { _ => [] }
  for entry in entries {
    if entry.path == path {
      return Some(entry)
    }
  }
  None
}

///|
fn cat_file_find_tree_entry_from_base(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  base_id : @git.ObjectId,
  path : String,
) -> @git.TreeEntry? raise Error {
  if path.length() == 0 {
    return None
  }
  let base_obj = db.get(fs, base_id)
  guard base_obj is Some(obj) else { return None }
  let tree_id = match obj.obj_type {
    @git.ObjectType::Commit => @git.parse_commit(obj.data).tree
    @git.ObjectType::Tree => base_id
    _ => return None
  }
  @gitlib.find_tree_entry(db, fs, tree_id, path)
}

///|
struct CatFileFollowResolution {
  kind : String
  id : @git.ObjectId?
  mode : String?
  symlink_target : String?
}

///|
fn cat_file_is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///|
fn cat_file_split_repo_path_parts(path : String) -> Array[String] {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() == 0 || part == "." {
      continue
    }
    parts.push(part)
  }
  parts
}

///|
fn cat_file_copy_path_parts(
  parts : Array[String],
  start : Int,
  end : Int,
) -> Array[String] {
  let out : Array[String] = []
  let mut i = start
  while i < end && i < parts.length() {
    out.push(parts[i])
    i += 1
  }
  out
}

///|
fn cat_file_find_tree_entry_by_name(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  tree_id : @git.ObjectId,
  name : String,
) -> @git.TreeEntry? raise Error {
  let tree_obj = db.get(fs, tree_id)
  guard tree_obj is Some(tree) else { return None }
  if tree.obj_type != @git.ObjectType::Tree {
    return None
  }
  let entries = @git.parse_tree(tree.data)
  for entry in entries {
    if entry.name == name {
      return Some(entry)
    }
  }
  None
}

///|
fn cat_file_read_symlink_target_from_entry(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  entry : @git.TreeEntry,
) -> String? raise Error {
  let obj = db.get(fs, entry.id)
  guard obj is Some(o) else { return None }
  match o.obj_type {
    @git.ObjectType::Blob => Some(decode_bytes(o.data))
    _ => None
  }
}

///|
fn cat_file_expand_symlink_follow_path(
  parent_parts : Array[String],
  target : String,
  rest_parts : Array[String],
) -> (Array[String], String?) {
  if target.has_prefix("/") {
    let mut outside = target
    if rest_parts.length() > 0 {
      if outside.has_suffix("/") {
        outside = outside + rest_parts.join("/")
      } else {
        outside = outside + "/" + rest_parts.join("/")
      }
    }
    return ([], Some(outside))
  }
  let expanded : Array[String] = []
  for part in parent_parts {
    expanded.push(part)
  }
  for token_view in target.split("/") {
    let token = token_view.to_string()
    if token.length() == 0 || token == "." {
      continue
    }
    expanded.push(token)
  }
  for part in rest_parts {
    if part.length() == 0 || part == "." {
      continue
    }
    expanded.push(part)
  }
  (expanded, None)
}

///|
fn cat_file_render_outside_path(
  parts : Array[String],
  start : Int,
  keep_trailing_slash : Bool,
) -> String {
  let outside : Array[String] = []
  let mut i = start
  while i < parts.length() {
    let token = parts[i]
    if token.length() == 0 || token == "." {
      i += 1
      continue
    }
    outside.push(token)
    i += 1
  }
  let mut rendered = if outside.length() == 0 {
    ".."
  } else {
    outside.join("/")
  }
  if keep_trailing_slash && !rendered.has_suffix("/") {
    rendered = rendered + "/"
  }
  rendered
}

///|
fn cat_file_resolve_tree_entry_follow_symlinks(
  db : @gitlib.ObjectDb,
  fs : OsFs,
  base_id : @git.ObjectId,
  path : String,
) -> CatFileFollowResolution raise Error {
  let missing = CatFileFollowResolution::{
    kind: "missing",
    id: None,
    mode: None,
    symlink_target: None,
  }
  let base_obj = db.get(fs, base_id)
  guard base_obj is Some(base) else { return missing }
  let root_tree_id = match base.obj_type {
    @git.ObjectType::Commit => @git.parse_commit(base.data).tree
    @git.ObjectType::Tree => base_id
    _ => return missing
  }
  let initial_parts = cat_file_split_repo_path_parts(path)
  if initial_parts.length() == 0 {
    return missing
  }
  let mut parts = initial_parts
  let mut followed_symlink = false
  let mut symlink_hops = 0
  let mut outside_trailing_slash = false
  let seen_paths : Map[String, Bool] = {}
  seen_paths[parts.join("/")] = true
  while true {
    if parts.length() == 0 {
      return CatFileFollowResolution::{
        kind: "resolved",
        id: Some(root_tree_id),
        mode: Some("040000"),
        symlink_target: None,
      }
    }
    let mut current_tree = root_tree_id
    let tree_stack : Array[@git.ObjectId] = [root_tree_id]
    let mut idx = 0
    let mut restarted = false
    while idx < parts.length() {
      let name = parts[idx]
      if name == "." {
        idx += 1
        continue
      }
      if name == ".." {
        if tree_stack.length() <= 1 {
          return CatFileFollowResolution::{
            kind: "symlink",
            id: None,
            mode: None,
            symlink_target: Some(
              cat_file_render_outside_path(parts, idx, outside_trailing_slash),
            ),
          }
        }
        ignore(tree_stack.pop())
        current_tree = tree_stack[tree_stack.length() - 1]
        idx += 1
        continue
      }
      let entry_opt = cat_file_find_tree_entry_by_name(
        db, fs, current_tree, name,
      )
      guard entry_opt is Some(entry) else {
        if followed_symlink {
          return CatFileFollowResolution::{
            kind: "dangling",
            id: None,
            mode: None,
            symlink_target: None,
          }
        }
        return missing
      }
      if cat_file_mode_is_symlink(Some(entry.mode)) {
        let target_opt = cat_file_read_symlink_target_from_entry(db, fs, entry)
        guard target_opt is Some(target) else {
          return CatFileFollowResolution::{
            kind: "dangling",
            id: None,
            mode: None,
            symlink_target: None,
          }
        }
        followed_symlink = true
        symlink_hops += 1
        if symlink_hops > 40 {
          return CatFileFollowResolution::{
            kind: "loop",
            id: None,
            mode: None,
            symlink_target: None,
          }
        }
        let parent_parts = cat_file_copy_path_parts(parts, 0, idx)
        let rest_parts = cat_file_copy_path_parts(
          parts,
          idx + 1,
          parts.length(),
        )
        outside_trailing_slash = target.has_suffix("/") &&
          rest_parts.length() == 0
        let (expanded, outside) = cat_file_expand_symlink_follow_path(
          parent_parts, target, rest_parts,
        )
        match outside {
          Some(outside_path) =>
            return CatFileFollowResolution::{
              kind: "symlink",
              id: None,
              mode: None,
              symlink_target: Some(outside_path),
            }
          None => {
            let key = if expanded.length() == 0 {
              "."
            } else {
              expanded.join("/")
            }
            if seen_paths.contains(key) {
              return CatFileFollowResolution::{
                kind: "loop",
                id: None,
                mode: None,
                symlink_target: None,
              }
            }
            seen_paths[key] = true
            parts = expanded
            restarted = true
            break
          }
        }
      }
      if idx + 1 == parts.length() {
        return CatFileFollowResolution::{
          kind: "resolved",
          id: Some(entry.id),
          mode: Some(entry.mode),
          symlink_target: None,
        }
      }
      if cat_file_is_tree_mode(entry.mode) {
        current_tree = entry.id
        tree_stack.push(current_tree)
        idx += 1
        continue
      }
      return CatFileFollowResolution::{
        kind: "notdir",
        id: None,
        mode: None,
        symlink_target: None,
      }
    }
    if restarted {
      continue
    }
    if idx >= parts.length() {
      return CatFileFollowResolution::{
        kind: "resolved",
        id: Some(current_tree),
        mode: Some("040000"),
        symlink_target: None,
      }
    }
    return missing
  }
  missing
}

///|
async fn cat_file_apply_path_transforms(
  fs : OsFs,
  git_dir : String,
  root : String,
  path : String,
  data : Bytes,
  filters_mode : Bool,
  textconv_mode : Bool,
) -> Bytes raise Error {
  let attrs = cat_file_read_path_attrs(fs, root, path)
  let mut out = if filters_mode || textconv_mode {
    if attrs.eol_crlf {
      cat_file_convert_lf_to_crlf(data)
    } else {
      data
    }
  } else {
    data
  }
  if textconv_mode {
    match attrs.diff_driver {
      Some(driver) => {
        let config_path = git_dir + "/config"
        let section = "diff \"" + driver + "\""
        match @gitlib.read_config_value(fs, config_path, section, "textconv") {
          Some(cmd) if trim_string(cmd).length() > 0 =>
            out = cat_file_run_textconv(fs, root, git_dir, cmd, out)
          _ => ()
        }
      }
      None => ()
    }
  }
  out
}

///|
async fn cat_file_run_textconv(
  fs : OsFs,
  root : String,
  git_dir : String,
  command : String,
  input : Bytes,
) -> Bytes raise Error {
  let temp_path = git_dir + "/bit-cat-file-textconv.tmp"
  fs.write_file(temp_path, input)
  let shell_cmd = cat_file_build_textconv_shell_command(command)
  let (code, stdout) = @process.collect_stdout(
    "sh",
    ["-c", shell_cmd, "cat-file-textconv", temp_path],
    inherit_env=true,
    cwd=root,
  ) catch {
    err => {
      fs.remove_file(temp_path) catch {
        _ => ()
      }
      raise @git.GitError::IoError("textconv failed: \{err}")
    }
  }
  fs.remove_file(temp_path) catch {
    _ => ()
  }
  if code != 0 {
    raise @git.GitError::IoError("textconv failed with status \{code}")
  }
  let text = stdout.text() catch {
    err => raise @git.GitError::IoError(err.to_string())
  }
  cat_file_string_to_bytes(text)
}

///|
fn cat_file_build_textconv_shell_command(command : String) -> String {
  let trimmed = trim_string(command)
  if trimmed.contains("%f") {
    return trimmed.replace_all(old="%f", new="\"$1\"")
  }
  if trimmed.has_suffix("<") {
    let body = String::unsafe_substring(
      trimmed,
      start=0,
      end=trimmed.length() - 1,
    )
    trim_string(body) + " < \"$1\""
  } else {
    trimmed + " \"$1\""
  }
}

///|
fn cat_file_read_path_attrs(
  fs : OsFs,
  root : String,
  path : String,
) -> CatFilePathAttrs {
  let normalized = if path.has_prefix("/") {
    String::unsafe_substring(path, start=1, end=path.length())
  } else if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  let mut eol_crlf = false
  let mut diff_driver : String? = None
  let attr_path = root + "/.gitattributes"
  if fs.is_file(attr_path) {
    let text = decode_bytes(
      fs.read_file(attr_path) catch {
        _ => Bytes::default()
      },
    )
    for line_view in text.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 || line.has_prefix("#") {
        continue
      }
      let tokens = line.split(" ")
      let words : Array[String] = []
      for token_view in tokens {
        let token = trim_string(token_view.to_string())
        if token.length() > 0 {
          words.push(token)
        }
      }
      if words.length() < 2 {
        continue
      }
      if !cat_file_attr_pattern_matches(normalized, words[0]) {
        continue
      }
      let mut j = 1
      while j < words.length() {
        let token = words[j]
        if token.has_prefix("eol=") {
          let value = trim_string(
            String::unsafe_substring(token, start=4, end=token.length()),
          ).to_lower()
          eol_crlf = value == "crlf"
        } else if token.has_prefix("diff=") {
          let value = trim_string(
            String::unsafe_substring(token, start=5, end=token.length()),
          )
          if value.length() > 0 {
            diff_driver = Some(value)
          }
        }
        j += 1
      }
    }
  }
  { eol_crlf, diff_driver }
}

///|
fn cat_file_attr_pattern_matches(path : String, pattern : String) -> Bool {
  if pattern == path {
    return true
  }
  if pattern.has_prefix("*.") {
    return path.has_suffix(
      String::unsafe_substring(pattern, start=1, end=pattern.length()),
    )
  }
  match pattern.find("*") {
    Some(idx) => {
      let prefix = String::unsafe_substring(pattern, start=0, end=idx)
      let suffix = String::unsafe_substring(
        pattern,
        start=idx + 1,
        end=pattern.length(),
      )
      path.has_prefix(prefix) &&
      path.has_suffix(suffix) &&
      path.length() >= prefix.length() + suffix.length()
    }
    None => false
  }
}

///|
fn cat_file_convert_lf_to_crlf(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  while i < data.length() {
    let b = data[i]
    if b == b'\n' && (i == 0 || data[i - 1] != b'\r') {
      out.push(b'\r')
      out.push(b'\n')
    } else {
      out.push(b)
    }
    i += 1
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn cat_file_string_to_bytes(s : String) -> Bytes {
  Bytes::from_array(FixedArray::makei(s.length(), fn(i) { s[i].to_byte() }))
}

///|
async fn cat_file_usage_fatal(message : String) -> Unit raise Error {
  eprint_line("fatal: \{message}")
  @sys.exit(129)
}

///|
async fn cat_file_usage_error(message : String) -> Unit raise Error {
  eprint_line("error: \{message}")
  @sys.exit(129)
}

///|
