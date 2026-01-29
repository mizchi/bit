///| Smart HTTP helpers for receive-pack

///|
pub struct HttpResponse {
  status : Int
  headers : Map[String, String]
  body : Bytes
}

///|
pub fn receive_pack_info_refs_response(
  fs : &@git.RepoFileSystem,
  root : String,
  auth_header : String?,
  token : String,
  agent? : String = "git/moonbit",
) -> HttpResponse raise @git.GitError {
  if not(check_bearer_token(auth_header, token)) {
    return {
      status: 401,
      headers: { "Content-Type": "text/plain", "WWW-Authenticate": "Bearer" },
      body: Bytes::from_array([]),
    }
  }
  let adv = build_receive_pack_advertisement(fs, root, agent~)
  let body = build_smart_advertisement("git-receive-pack", adv)
  {
    status: 200,
    headers: {
      "Content-Type": "application/x-git-receive-pack-advertisement",
      "Cache-Control": "no-cache",
      "Pragma": "no-cache",
    },
    body,
  }
}

///|
pub fn receive_pack_response(
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  root : String,
  auth_header : String?,
  token : String,
  body : Bytes,
) -> HttpResponse raise @git.GitError {
  if not(check_bearer_token(auth_header, token)) {
    return {
      status: 401,
      headers: { "Content-Type": "text/plain", "WWW-Authenticate": "Bearer" },
      body: Bytes::from_array([]),
    }
  }
  let result = receive_pack(fs, rfs, root, body)
  {
    status: 200,
    headers: {
      "Content-Type": "application/x-git-receive-pack-result",
      "Cache-Control": "no-cache",
      "Pragma": "no-cache",
    },
    body: result,
  }
}

///|
fn build_smart_advertisement(service : String, adv : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let line = @git.pktline_encode("# service=\{service}\n")
  for b in line {
    out.push(b)
  }
  for b in @git.pktline_flush() {
    out.push(b)
  }
  for b in adv {
    out.push(b)
  }
  Bytes::from_array(FixedArray::makei(out.length(), fn(i) { out[i] }))
}

///|
fn check_bearer_token(auth_header : String?, token : String) -> Bool {
  match auth_header {
    None => false
    Some(value) => {
      if not(value.has_prefix("Bearer ")) {
        return false
      }
      let received = String::unsafe_substring(
        value,
        start=7,
        end=value.length(),
      )
      received == token
    }
  }
}
