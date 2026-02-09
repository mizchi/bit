///| Whitebox tests for relay transport helpers in hub sync.

///|
priv struct FixedClock {
  now_ts : Int64
}

///|
impl @lib.Clock for FixedClock with now(self) {
  self.now_ts
}

///|
async fn relay_test_http_get_ok(
  _url : String,
  _headers : Map[String, String],
) -> (@git.HttpResponse, Bytes) raise @git.GitError {
  let no_ops : Array[async () -> Unit] = []
  ignore(
    @async.all(no_ops) catch {
      err => raise @git.GitError::IoError(err.to_string())
    },
  )
  let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":1,\"envelopes\":[{\"room\":\"main\",\"id\":\"msg-1\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"hub.record\",\"record\":\"version 1\\nkey hub/pr/1/meta\\nkind hub.pr\\nclock node-a=1\\ntimestamp 1\\nnode node-a\\ndeleted 0\\n\\npayload\"},\"signature\":null}]}"
  (@git.HttpResponse::new(200), @utf8.encode(body))
}

///|
async fn relay_test_http_post_ok(
  _url : String,
  _body : Bytes,
  _headers : Map[String, String],
) -> (@git.HttpResponse, Bytes) raise @git.GitError {
  let no_ops : Array[async () -> Unit] = []
  ignore(
    @async.all(no_ops) catch {
      err => raise @git.GitError::IoError(err.to_string())
    },
  )
  (
    @git.HttpResponse::new(200),
    @utf8.encode("{\"ok\":true,\"accepted\":true,\"cursor\":1}"),
  )
}

///|
test "relay: parse_relay_base_url handles explicit prefixes" {
  assert_eq(
    parse_relay_base_url("relay+http://127.0.0.1:8787"),
    Some("http://127.0.0.1:8787"),
  )
  assert_eq(
    parse_relay_base_url("relay+https://relay.example.com"),
    Some("https://relay.example.com"),
  )
  assert_eq(
    parse_relay_base_url("relay://127.0.0.1:8787"),
    Some("http://127.0.0.1:8787"),
  )
  assert_eq(parse_relay_base_url("http://127.0.0.1:8787"), None)
}

///|
test "relay: should_fallback_to_relay only for http 404 smart-http errors" {
  assert_true(
    should_fallback_to_relay(
      @git.GitError::ProtocolError("Failed to fetch info/refs: HTTP 404"),
      "http://127.0.0.1:8787",
    ),
  )
  assert_true(
    should_fallback_to_relay(
      @git.GitError::ProtocolError("Failed to discover refs: HTTP 404"),
      "https://relay.example.com",
    ),
  )
  assert_false(
    should_fallback_to_relay(
      @git.GitError::ProtocolError("Failed to fetch info/refs: HTTP 500"),
      "http://127.0.0.1:8787",
    ),
  )
  assert_false(
    should_fallback_to_relay(
      @git.GitError::IoError("connection refused"),
      "http://127.0.0.1:8787",
    ),
  )
}

///|
test "relay: parse_relay_poll_body extracts hub records and cursor" {
  let body = "{\"ok\":true,\"room\":\"main\",\"next_cursor\":1,\"envelopes\":[{\"room\":\"main\",\"id\":\"msg-1\",\"sender\":\"node-a\",\"topic\":\"notify\",\"payload\":{\"kind\":\"hub.record\",\"record\":\"version 1\\nkey hub/pr/1/meta\\nkind hub.pr\\nclock node-a=1\\ntimestamp 1\\nnode node-a\\ndeleted 0\\n\\npayload\"},\"signature\":null}]}"
  let (cursor, records) = parse_relay_poll_body(body)
  assert_eq(cursor, 1)
  assert_eq(records.length(), 1)
  assert_eq(records[0].key, "hub/pr/1/meta")
  assert_eq(records[0].payload, "payload")
}

///|
test "relay: apply_relay_records stores imported record into notes" {
  let fs = @git.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let incoming = @hub.HubRecord::new(
    "hub/pr/1/meta",
    "hub.pr",
    "payload",
    "node-a",
    1L,
    clock={ "node-a": 1 },
  )
  let changed = apply_relay_records(
    store,
    objects,
    refs,
    [incoming],
    1L,
    "relay import",
  )
  assert_true(changed)
  let reloaded = @hub.HubStore::load(objects, refs, node_id="node-local")
  let loaded = reloaded.get_record(objects, "hub/pr/1/meta")
  assert_true(loaded is Some(_))
  guard loaded is Some(record) else { panic() }
  assert_eq(record.payload, "payload")
}

///|
async test "relay: relay_fetch_with_http imports records and stores cursor" {
  let fs = @git.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let hub = @hub.Hub::load(objects, refs, node_id="node-local")
  let result = relay_fetch_with_http(
    hub, fs, fs, git_dir, "http://relay.test", relay_test_http_get_ok,
  )
  assert_true(result.success())
  let reloaded = @hub.HubStore::load(objects, refs, node_id="node-local")
  let loaded = reloaded.get_record(objects, "hub/pr/1/meta")
  assert_true(loaded is Some(_))
  let cursor_path = relay_cursor_path(git_dir, "http://relay.test")
  assert_true(fs.is_file(cursor_path))
}

///|
async test "relay: relay_push_with_http sends local hub records" {
  let fs = @git.TestFs::new()
  let git_dir = "/repo/.git"
  fs.mkdir_p(git_dir)
  let db = @lib.ObjectDb::load_lazy(fs, git_dir)
  let native_objects : NativeObjectStore = { db, rfs: fs, fs, git_dir }
  let native_refs : NativeRefStore = { fs, rfs: fs, git_dir }
  let objects : &@lib.ObjectStore = native_objects
  let refs : &@lib.RefStore = native_refs
  let store = @hub.HubStore::load(objects, refs, node_id="node-local")
  let clock : FixedClock = { now_ts: 1L }
  let clock_ref : &@lib.Clock = clock
  ignore(
    store.put_record(
      objects, refs, clock_ref, "hub/pr/1/meta", "hub.pr", "payload", "node-local",
    ),
  )
  let hub = @hub.Hub::load(objects, refs, node_id="node-local")
  let result = relay_push_with_http(
    fs, git_dir, "http://relay.test", relay_test_http_post_ok,
  )
  ignore(hub)
  assert_true(result.success())
  assert_true(result.message().contains("relay accepted 1/1"))
}
