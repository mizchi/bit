///| Native HTTP client implementation using @http package

///| This file is only compiled for native target

///|
pub struct NativeHttpClient {
  // No state needed, uses @http directly
  dummy : Int
}

///|
pub fn NativeHttpClient::new() -> NativeHttpClient {
  { dummy: 0 }
}

///|
async fn apply_auth_header(
  url : String,
  headers : Map[String, String],
) -> Map[String, String] raise @git.GitError {
  if headers.contains("Authorization") {
    return headers
  }
  let auth = resolve_auth_header(url)
  match auth {
    None => headers
    Some(value) => {
      let out : Map[String, String] = {}
      for item in headers.to_array() {
        let (k, v) = item
        out[k] = v
      }
      out["Authorization"] = value
      out
    }
  }
}

///|
async fn resolve_auth_header(url : String) -> String? raise @git.GitError {
  match parse_http_url(url) {
    None => None
    Some((protocol, host, path, username, password)) =>
      match password {
        Some(pass) => {
          let user = username.unwrap_or("")
          Some(build_basic_auth(user, pass))
        }
        None => {
          let cred_path = normalize_credential_path(path)
          match git_credential_fill(protocol, host, cred_path, username) {
            None => None
            Some((user, pass)) => Some(build_basic_auth(user, pass))
          }
        }
      }
  }
}

///|
fn build_basic_auth(username : String, password : String) -> String {
  let raw = username + ":" + password
  let encoded = @base64.encode(@utf8.encode(raw), url_safe=false)
  "Basic " + encoded
}

///|
fn parse_http_url(url : String) -> (String, String, String, String?, String?)? {
  let (protocol, rest) = if url.has_prefix("https://") {
    ("https", String::unsafe_substring(url, start=8, end=url.length()))
  } else if url.has_prefix("http://") {
    ("http", String::unsafe_substring(url, start=7, end=url.length()))
  } else {
    return None
  }
  let slash = rest.find("/")
  let authority = match slash {
    Some(idx) => String::unsafe_substring(rest, start=0, end=idx)
    None => rest
  }
  let path = match slash {
    Some(idx) =>
      String::unsafe_substring(rest, start=idx + 1, end=rest.length())
    None => ""
  }
  let mut host = authority
  let mut username : String? = None
  let mut password : String? = None
  match authority.rev_find("@") {
    Some(at) => {
      let userinfo = String::unsafe_substring(authority, start=0, end=at)
      host = String::unsafe_substring(
        authority,
        start=at + 1,
        end=authority.length(),
      )
      match userinfo.find(":") {
        Some(colon) => {
          username = Some(
            String::unsafe_substring(userinfo, start=0, end=colon),
          )
          password = Some(
            String::unsafe_substring(
              userinfo,
              start=colon + 1,
              end=userinfo.length(),
            ),
          )
        }
        None => username = Some(userinfo)
      }
    }
    None => ()
  }
  Some((protocol, host, path, username, password))
}

///|
fn normalize_credential_path(path : String) -> String {
  let mut out = path
  if out.find("?") is Some(q) {
    out = String::unsafe_substring(out, start=0, end=q)
  }
  let suffix_info = "/info/refs"
  if out.has_suffix(suffix_info) {
    out = String::unsafe_substring(
      out,
      start=0,
      end=out.length() - suffix_info.length(),
    )
  }
  let suffix_recv = "/git-receive-pack"
  if out.has_suffix(suffix_recv) {
    out = String::unsafe_substring(
      out,
      start=0,
      end=out.length() - suffix_recv.length(),
    )
  }
  out
}

///|
async fn git_credential_fill(
  protocol : String,
  host : String,
  path : String,
  username : String?,
) -> (String, String)? raise @git.GitError {
  let input = build_credential_input(protocol, host, path, username)
  let (stdin, writer) = @process.write_to_process() catch {
    err => raise @git.GitError::IoError("git credential pipe failed: \{err}")
  }
  writer.write(input) catch {
    err => raise @git.GitError::IoError("git credential write failed: \{err}")
  }
  writer.close()
  let (code, stdout, stderr) = @process.collect_output(
    "git",
    ["credential", "fill"],
    inherit_env=true,
    stdin~,
    extra_env={ "GIT_TERMINAL_PROMPT": "0" },
  ) catch {
    err => raise @git.GitError::IoError("git credential fill failed: \{err}")
  }
  if code != 0 {
    ignore(stderr)
    return None
  }
  let text = stdout.text() catch {
    err if @async.is_cancellation_error(err) =>
      raise @git.GitError::IoError(err.to_string())
    _ => ""
  }
  let mut user : String? = None
  let mut pass : String? = None
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    match line.find("=") {
      Some(eq) => {
        let key = String::unsafe_substring(line, start=0, end=eq)
        let value = String::unsafe_substring(
          line,
          start=eq + 1,
          end=line.length(),
        )
        if key == "username" {
          user = Some(value)
        } else if key == "password" || key == "token" || key == "oauth_token" {
          pass = Some(value)
        }
      }
      None => ()
    }
  }
  match pass {
    Some(p) => Some((user.unwrap_or(""), p))
    None => None
  }
}

///|
fn build_credential_input(
  protocol : String,
  host : String,
  path : String,
  username : String?,
) -> String {
  let sb = StringBuilder::new()
  sb.write_string("protocol=" + protocol + "\n")
  sb.write_string("host=" + host + "\n")
  if path.length() > 0 {
    sb.write_string("path=" + path + "\n")
  }
  if username is Some(u) {
    sb.write_string("username=" + u + "\n")
  }
  sb.write_string("\n")
  sb.to_string()
}

///|
pub async fn native_http_get(
  url : String,
  headers : Map[String, String],
) -> (@git.HttpResponse, Bytes) raise @git.GitError {
  let auth_headers = apply_auth_header(url, headers)
  let (response, client) = @http.get_stream(url, headers=auth_headers) catch {
    e => raise @git.GitError::IoError("HTTP GET failed: \{e}")
  }
  let chunks : Array[Byte] = []
  while true {
    let chunk = client.read_some() catch {
      err if @async.is_cancellation_error(err) =>
        raise @git.GitError::IoError(err.to_string())
      _ => break
    }
    match chunk {
      Some(b) =>
        for byte in b {
          chunks.push(byte)
        }
      None => break
    }
  }
  client.close()
  let data = Bytes::from_array(
    FixedArray::makei(chunks.length(), i => chunks[i]),
  )
  (@git.HttpResponse::new(response.code), data)
}

///|
pub async fn native_http_post(
  url : String,
  body : Bytes,
  headers : Map[String, String],
) -> (@git.HttpResponse, Bytes) raise @git.GitError {
  let auth_headers = apply_auth_header(url, headers)
  let client = @http.post_stream(url, headers=auth_headers) catch {
    e => raise @git.GitError::IoError("HTTP POST failed: \{e}")
  }
  client.write(body) catch {
    e => raise @git.GitError::IoError("HTTP POST write failed: \{e}")
  }
  let response = client.end_request() catch {
    e => raise @git.GitError::IoError("HTTP POST end_request failed: \{e}")
  }
  let chunks : Array[Byte] = []
  while true {
    let chunk = client.read_some() catch {
      err if @async.is_cancellation_error(err) =>
        raise @git.GitError::IoError(err.to_string())
      _ => break
    }
    match chunk {
      Some(b) =>
        for byte in b {
          chunks.push(byte)
        }
      None => break
    }
  }
  client.close()
  let data = Bytes::from_array(
    FixedArray::makei(chunks.length(), i => chunks[i]),
  )
  (@git.HttpResponse::new(response.code), data)
}
