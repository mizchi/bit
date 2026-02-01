///| Path utilities for Fs

///|
pub fn join_path(root : String, path : String) -> String {
  if root.length() == 0 || root == "/" {
    if path.has_prefix("/") {
      path
    } else {
      "/" + path
    }
  } else if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}

///|
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => ""
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn basename(path : String) -> String {
  match path.rev_find("/") {
    None => path
    Some(i) => String::unsafe_substring(path, start=i + 1, end=path.length())
  }
}

///|
fn normalize_path(path : String) -> String {
  let mut p = path
  if p.has_prefix("./") {
    p = String::unsafe_substring(p, start=2, end=p.length())
  }
  while p.has_prefix("/") {
    p = String::unsafe_substring(p, start=1, end=p.length())
  }
  while p.has_suffix("/") {
    p = String::unsafe_substring(p, start=0, end=p.length() - 1)
  }
  p
}

///|
fn split_path(path : String) -> Array[String] {
  let out : Array[String] = []
  let norm = normalize_path(path)
  if norm.length() == 0 {
    return out
  }
  for part_view in norm.split("/") {
    let part = part_view.to_string()
    if part.length() > 0 {
      out.push(part)
    }
  }
  out
}

///|
fn split_first(path : String) -> (String, String?) {
  match path.find("/") {
    None => (path, None)
    Some(idx) => {
      let name = String::unsafe_substring(path, start=0, end=idx)
      let rest = String::unsafe_substring(
        path,
        start=idx + 1,
        end=path.length(),
      )
      (name, Some(rest))
    }
  }
}

///|
fn ensure_parent_dirs(working : WorkingLayer, path : String) -> Unit {
  let parts = split_path(path)
  let mut current = ""
  for i = 0; i < parts.length() - 1; i = i + 1 {
    current = if current.length() == 0 {
      parts[i]
    } else {
      current + "/" + parts[i]
    }
    working.dirs[current] = true
  }
}
