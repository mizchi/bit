///| Native hub sync operations (push/fetch requiring network access)

///|
/// Native adapter: ObjectDb + RepoFileSystem -> ObjectStore
priv struct NativeObjectStore {
  db : @lib.ObjectDb
  rfs : &@git.RepoFileSystem
  fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for NativeObjectStore with get(self, id) {
  self.db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for NativeObjectStore with put(self, obj_type, content) {
  let (id, compressed) = @git.create_object(obj_type, content)
  @hub.write_object_bytes(self.fs, self.git_dir, id, compressed)
  id
}

///|
impl @lib.ObjectStore for NativeObjectStore with has(self, id) {
  let obj = self.db.get(self.rfs, id)
  obj is Some(_)
}

///|
/// Native read-only adapter for relay push.
priv struct NativeReadObjectStore {
  db : @lib.ObjectDb
  rfs : &@git.RepoFileSystem
}

///|
impl @lib.ObjectStore for NativeReadObjectStore with get(self, id) {
  self.db.get(self.rfs, id)
}

///|
impl @lib.ObjectStore for NativeReadObjectStore with put(
  _self,
  _obj_type,
  _content,
) {
  raise @git.GitError::InvalidObject("NativeReadObjectStore is read-only")
}

///|
impl @lib.ObjectStore for NativeReadObjectStore with has(self, id) {
  let obj = self.db.get(self.rfs, id)
  obj is Some(_)
}

///|
/// Native adapter: FileSystem + git_dir -> RefStore
priv struct NativeRefStore {
  fs : &@git.FileSystem
  rfs : &@git.RepoFileSystem
  git_dir : String
}

///|
impl @lib.RefStore for NativeRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.rfs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for NativeRefStore with update(self, ref_name, id) {
  match id {
    Some(commit_id) => {
      let ref_path = join_path(self.git_dir, ref_name)
      let dir = parent_path(ref_path)
      self.fs.mkdir_p(dir)
      self.fs.write_string(ref_path, commit_id.to_hex() + "\n")
    }
    None => ()
  }
}

///|
impl @lib.RefStore for NativeRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
/// Native read-only ref adapter for relay push.
priv struct NativeReadRefStore {
  rfs : &@git.RepoFileSystem
  git_dir : String
}

///|
impl @lib.RefStore for NativeReadRefStore with resolve(self, ref_name) {
  @lib.resolve_ref(self.rfs, self.git_dir, ref_name)
}

///|
impl @lib.RefStore for NativeReadRefStore with update(_self, _ref_name, _id) {
  ()
}

///|
impl @lib.RefStore for NativeReadRefStore with list(self, _prefix) {
  ignore(self)
  []
}

///|
fn join_path(a : String, b : String) -> String {
  if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
fn parent_path(path : String) -> String {
  let chars = path.to_array()
  let mut i = chars.length()
  while i > 0 {
    let idx = i - 1
    if chars[idx] == '/' {
      if idx == 0 {
        return "."
      }
      return String::unsafe_substring(path, start=0, end=idx)
    }
    i = i - 1
  }
  "."
}

///|
fn trim_trailing_slash(url : String) -> String {
  if url.length() > 1 && url.has_suffix("/") {
    String::unsafe_substring(url, start=0, end=url.length() - 1)
  } else {
    url
  }
}

///|
fn is_http_url(url : String) -> Bool {
  url.has_prefix("http://") || url.has_prefix("https://")
}

///|
fn parse_relay_base_url(remote_url : String) -> String? {
  if remote_url.has_prefix("relay+http://") ||
    remote_url.has_prefix("relay+https://") {
    let raw = String::unsafe_substring(
      remote_url,
      start=6,
      end=remote_url.length(),
    )
    Some(trim_trailing_slash(raw))
  } else if remote_url.has_prefix("relay://") {
    let suffix = String::unsafe_substring(
      remote_url,
      start=8,
      end=remote_url.length(),
    )
    Some(trim_trailing_slash("http://" + suffix))
  } else {
    None
  }
}

///|
fn should_fallback_to_relay(err : @git.GitError, remote_url : String) -> Bool {
  if not(is_http_url(remote_url)) {
    return false
  }
  match err {
    @git.GitError::ProtocolError(msg) => msg.contains("HTTP 404")
    _ => false
  }
}

///|
fn json_get_string(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(Json::String(value)) => value
    Some(Json::Number(value, ..)) => value.to_string()
    Some(Json::True) => "true"
    Some(Json::False) => "false"
    _ => fallback
  }
}

///|
fn json_get_int(obj : Map[String, Json], key : String, fallback : Int) -> Int {
  match obj.get(key) {
    Some(Json::Number(value, ..)) => value.to_int()
    Some(Json::String(value)) =>
      @strconv.parse_int(value) catch {
        _ => fallback
      }
    _ => fallback
  }
}

///|
fn parse_relay_publish_accepted(text : String) -> Bool {
  let parsed = @json.parse(text) catch { _ => Json::object({}) }
  match parsed {
    Json::Object(obj) =>
      match obj.get("accepted") {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
fn parse_relay_poll_body(
  text : String,
) -> (Int, Array[@hub.HubRecord]) raise @git.GitError {
  let parsed = @json.parse(text) catch {
    err =>
      raise @git.GitError::InvalidObject(
        "invalid relay poll response: \{err.to_string()}",
      )
  }
  guard parsed is Json::Object(root) else {
    raise @git.GitError::InvalidObject(
      "invalid relay poll response: expected object",
    )
  }
  let next_cursor = json_get_int(root, "next_cursor", 0)
  let records : Array[@hub.HubRecord] = []
  match root.get("envelopes") {
    Some(Json::Array(items)) =>
      for item in items {
        guard item is Json::Object(envelope_obj) else { continue }
        guard envelope_obj.get("payload") is Some(Json::Object(payload_obj)) else {
          continue
        }
        if json_get_string(payload_obj, "kind", "") != "hub.record" {
          continue
        }
        let record_text = json_get_string(payload_obj, "record", "")
        if record_text.length() == 0 {
          continue
        }
        records.push(@hub.parse_hub_record(record_text))
      }
    _ => ()
  }
  (next_cursor, records)
}

///|
fn hub_record_entry_name(key : String) -> String {
  let (target_id, _) = @git.create_blob_string(key)
  target_id.to_hex()
}

///|
fn commit_relay_notes(
  store : @hub.HubStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  message : String,
  timestamp : Int64,
) -> @git.ObjectId raise @git.GitError {
  let tree_entries : Array[@git.TreeEntry] = []
  for item in store.entries.to_array() {
    let (name, blob_id) = item
    tree_entries.push(@git.TreeEntry::new("100644", name, blob_id))
  }
  tree_entries.sort_by((a, b) => String::compare(a.name, b.name))
  let tree_bytes = @git.serialize_tree(tree_entries)
  let tree_id = objects.put(@git.ObjectType::Tree, tree_bytes)
  let parents = match store.head {
    Some(p) => [p]
    None => []
  }
  let commit = @git.Commit::new(
    tree_id,
    parents,
    "Hub <hub@local>",
    timestamp,
    "+0000",
    "Hub <hub@local>",
    timestamp,
    "+0000",
    message + "\n",
  )
  let commit_bytes = @git.serialize_commit_content(commit)
  let commit_id = objects.put(@git.ObjectType::Commit, commit_bytes)
  refs.update(@hub.hub_notes_ref_name(), Some(commit_id))
  commit_id
}

///|
fn apply_relay_record(
  store : @hub.HubStore,
  objects : &@lib.ObjectStore,
  record : @hub.HubRecord,
) -> Bool raise @git.GitError {
  let entry_name = hub_record_entry_name(record.key)
  let incoming_bytes = @utf8.encode(record.serialize())
  let current_blob_id = store.entries.get(entry_name)
  match current_blob_id {
    None => {
      let next_blob_id = objects.put(@git.ObjectType::Blob, incoming_bytes)
      store.entries[entry_name] = next_blob_id
      true
    }
    Some(existing_blob_id) => {
      let existing_obj = objects.get(existing_blob_id)
      match existing_obj {
        None => {
          let next_blob_id = objects.put(@git.ObjectType::Blob, incoming_bytes)
          store.entries[entry_name] = next_blob_id
          true
        }
        Some(existing_blob) => {
          let merged = @hub.merge_record_bytes(
            existing_blob.data,
            incoming_bytes,
          )
          if merged == existing_blob.data {
            false
          } else {
            let next_blob_id = objects.put(@git.ObjectType::Blob, merged)
            store.entries[entry_name] = next_blob_id
            true
          }
        }
      }
    }
  }
}

///|
fn apply_relay_records(
  store : @hub.HubStore,
  objects : &@lib.ObjectStore,
  refs : &@lib.RefStore,
  records : Array[@hub.HubRecord],
  commit_timestamp : Int64,
  message : String,
) -> Bool raise @git.GitError {
  let mut changed = false
  for record in records {
    if apply_relay_record(store, objects, record) {
      changed = true
    }
  }
  if changed {
    let ts = if commit_timestamp <= 0L { 1L } else { commit_timestamp }
    ignore(commit_relay_notes(store, objects, refs, message, ts))
  }
  changed
}

///|
fn relay_cursor_key(remote_url : String) -> String {
  let (id, _) = @git.create_blob_string(remote_url)
  id.to_hex()
}

///|
fn relay_cursor_path(git_dir : String, remote_url : String) -> String {
  join_path(git_dir, "hub/relay-cursor/" + relay_cursor_key(remote_url))
}

///|
fn read_relay_cursor(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> Int {
  let path = relay_cursor_path(git_dir, remote_url)
  if not(rfs.is_file(path)) {
    return 0
  }
  let content = rfs.read_file(path) catch { _ => return 0 }
  let text = @utf8.decode_lossy(content[:])
  let first = match text.split("\n").iter().next() {
    Some(line) => line.to_string()
    None => ""
  }
  @strconv.parse_int(first) catch {
    _ => 0
  }
}

///|
fn write_relay_cursor(
  fs : &@git.FileSystem,
  git_dir : String,
  remote_url : String,
  cursor : Int,
) -> Unit raise @git.GitError {
  let path = relay_cursor_path(git_dir, remote_url)
  let dir = parent_path(path)
  fs.mkdir_p(dir)
  fs.write_string(path, cursor.to_string() + "\n")
}

///|
fn relay_publish_url(base_url : String, event_id : String) -> String {
  "\{base_url}/api/v1/publish?room=main&sender=bit&topic=notify&id=\{event_id}"
}

///|
fn relay_poll_url(base_url : String, after : Int, limit : Int) -> String {
  "\{base_url}/api/v1/poll?room=main&after=\{after}&limit=\{limit}"
}

///|
async fn relay_push_with_http(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @git.HttpResponse,
    Bytes,
  ) raise @git.GitError,
) -> @hub.PrSyncResult raise @git.GitError {
  let ref_name = @hub.hub_notes_ref_name()
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  guard local_commit is Some(local_id) else {
    return @hub.PrSyncResult::new(
      false,
      "No local hub notes ref found",
      None,
      None,
    )
  }
  let base_url = trim_trailing_slash(remote_url)
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let ro_objects : NativeReadObjectStore = { db, rfs }
  let ro_refs : NativeReadRefStore = { rfs, git_dir }
  let objects : &@lib.ObjectStore = ro_objects
  let refs : &@lib.RefStore = ro_refs
  let store = @hub.HubStore::load(objects, refs, node_id="relay")
  let records = store.list_records(objects, "hub/", include_deleted=true)
  let headers : Map[String, String] = { "Content-Type": "application/json" }
  let mut accepted = 0
  for record in records {
    let payload_obj : Map[String, Json] = {}
    payload_obj["kind"] = Json::string("hub.record")
    payload_obj["record"] = Json::string(record.serialize())
    let payload_text = Json::object(payload_obj).stringify()
    let (record_blob_id, _) = @git.create_blob_string(record.serialize())
    let event_id = record_blob_id.to_hex()
    let url = relay_publish_url(base_url, event_id)
    let (response, response_body) = http_post(
      url,
      @utf8.encode(payload_text),
      headers,
    )
    if response.code != 200 {
      let body_text = @utf8.decode_lossy(response_body[:])
      return @hub.PrSyncResult::new(
        false,
        "Relay publish failed: HTTP \{response.code} \{body_text}",
        Some(local_id),
        None,
      )
    }
    if parse_relay_publish_accepted(@utf8.decode_lossy(response_body[:])) {
      accepted += 1
    }
  }
  @hub.PrSyncResult::new(
    true,
    "Push successful (relay accepted \{accepted}/\{records.length()})",
    Some(local_id),
    Some(local_id),
  )
}

///|
async fn relay_fetch_with_http(
  hub : @hub.Hub,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
  http_get : async (String, Map[String, String]) -> (@git.HttpResponse, Bytes) raise @git.GitError,
) -> @hub.PrSyncResult raise @git.GitError {
  let base_url = trim_trailing_slash(remote_url)
  let before = @lib.resolve_ref(rfs, git_dir, @hub.hub_notes_ref_name())
  let cursor = read_relay_cursor(rfs, git_dir, base_url)
  let url = relay_poll_url(base_url, cursor, 200)
  let headers : Map[String, String] = { "Accept": "application/json" }
  let (response, data) = http_get(url, headers)
  if response.code != 200 {
    let body_text = @utf8.decode_lossy(data[:])
    return @hub.PrSyncResult::new(
      false,
      "Relay poll failed: HTTP \{response.code} \{body_text}",
      before,
      None,
    )
  }
  let poll_text = @utf8.decode_lossy(data[:])
  let (next_cursor, records) = parse_relay_poll_body(poll_text)
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="relay")
  let mut max_ts : Int64 = 0
  for record in records {
    if record.timestamp > max_ts {
      max_ts = record.timestamp
    }
  }
  let changed = apply_relay_records(
    store, objects, refs, records, max_ts, "hub relay fetch",
  )
  write_relay_cursor(fs, git_dir, base_url, next_cursor)
  if changed {
    hub.reload_store(objects, refs)
  }
  let after = @lib.resolve_ref(rfs, git_dir, @hub.hub_notes_ref_name())
  if changed {
    @hub.PrSyncResult::new(
      true,
      "Fetched relay records (\{records.length()})",
      after,
      after,
    )
  } else {
    @hub.PrSyncResult::new(
      true,
      "Already up to date (relay cursor=\{next_cursor})",
      before,
      before,
    )
  }
}

///|
/// Push hub notes ref to remote (git smart-http transport)
async fn hub_push_git_http(
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> @hub.PrSyncResult raise @git.GitError {
  let ref_name = @hub.hub_notes_ref_name()
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  guard local_commit is Some(local_id) else {
    return @hub.PrSyncResult::new(
      false,
      "No local hub notes ref found",
      None,
      None,
    )
  }
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let objects = @lib.collect_reachable_objects(db, rfs, local_id)
  let pack = @pack.create_packfile(objects)
  let remote = @protocol.Remote::new(remote_url)
  let refs = @gitnative.discover_receive_refs_http(remote)
  let (old_id, push_ref) = @hub.find_remote_notes_ref(refs)
  let req = @protocol.PushRequest::new(old_id, local_id, push_ref, pack)
  let result = @gitnative.push(remote, req)
  if result.has_prefix("unpack ok") ||
    result.has_prefix("ok ") ||
    result.has_prefix("Push successful") {
    @hub.PrSyncResult::new(
      true,
      "Push successful",
      Some(local_id),
      Some(local_id),
    )
  } else {
    @hub.PrSyncResult::new(
      false,
      "Push failed: \{result}",
      Some(local_id),
      None,
    )
  }
}

///|
/// Fetch hub notes ref from remote and merge (git smart-http transport)
async fn hub_fetch_git_http(
  hub : @hub.Hub,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> @hub.PrSyncResult raise @git.GitError {
  let ref_name = @hub.hub_notes_ref_name()
  let (refs, _, _, _) = @gitnative.discover_upload_refs_http(remote_url, true)
  let remote_id = @hub.find_upload_notes_ref(refs)
  guard remote_id is Some((rid, remote_ref)) else {
    return @hub.PrSyncResult::new(
      false,
      "No remote hub notes ref found",
      @lib.resolve_ref(rfs, git_dir, ref_name),
      None,
    )
  }
  let pack = @gitnative.fetch_pack_http(remote_url, [rid], true)
  let objects = @pack.parse_packfile(pack)
  @pack.write_packfile_with_index(fs, git_dir, pack, objects)
  let remote_short = @hub.short_ref_name(remote_ref)
  let remote_ref_path = join_path(
    git_dir,
    "refs/remotes/origin/" + remote_short,
  )
  let dir = parent_path(remote_ref_path)
  fs.mkdir_p(dir)
  fs.write_string(remote_ref_path, rid.to_hex() + "\n")
  let local_commit = @lib.resolve_ref(rfs, git_dir, ref_name)
  let db = @lib.ObjectDb::load(rfs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs, git_dir }
  let obj_store : &@lib.ObjectStore = native_objects
  let ref_store : &@lib.RefStore = native_refs
  match local_commit {
    None => {
      ref_store.update(@hub.hub_notes_ref_name(), Some(rid))
      hub.reload_store(obj_store, ref_store)
      @hub.PrSyncResult::new(
        true,
        "Fetched remote hub notes ref",
        Some(rid),
        Some(rid),
      )
    }
    Some(lid) =>
      if lid == rid {
        @hub.PrSyncResult::new(true, "Already up to date", Some(lid), Some(rid))
      } else {
        @hub.merge_notes_commits(
          hub, fs, git_dir, obj_store, ref_store, lid, rid,
        )
      }
  }
}

///|
/// Push hub notes ref to remote
pub async fn hub_push(
  _hub : @hub.Hub,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> @hub.PrSyncResult raise @git.GitError {
  match parse_relay_base_url(remote_url) {
    Some(base_url) =>
      relay_push_with_http(rfs, git_dir, base_url, @gitnative.native_http_post)
    None =>
      hub_push_git_http(rfs, git_dir, remote_url) catch {
        err if should_fallback_to_relay(err, remote_url) =>
          relay_push_with_http(
            rfs,
            git_dir,
            trim_trailing_slash(remote_url),
            @gitnative.native_http_post,
          )
        other => raise other
      }
  }
}

///|
/// Fetch hub notes ref from remote and merge
pub async fn hub_fetch(
  hub : @hub.Hub,
  fs : &@git.FileSystem,
  rfs : &@git.RepoFileSystem,
  git_dir : String,
  remote_url : String,
) -> @hub.PrSyncResult raise @git.GitError {
  match parse_relay_base_url(remote_url) {
    Some(base_url) =>
      relay_fetch_with_http(
        hub, fs, rfs, git_dir, base_url, @gitnative.native_http_get,
      )
    None =>
      hub_fetch_git_http(hub, fs, rfs, git_dir, remote_url) catch {
        err if should_fallback_to_relay(err, remote_url) =>
          relay_fetch_with_http(
            hub,
            fs,
            rfs,
            git_dir,
            trim_trailing_slash(remote_url),
            @gitnative.native_http_get,
          )
        other => raise other
      }
  }
}
