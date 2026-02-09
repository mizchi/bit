///| Compatibility bridge for native HTTP I/O.

///|
pub type NativeHttpClient = @gitionative.NativeHttpClient

///|
pub async fn native_http_get(
  url : String,
  headers : Map[String, String],
) -> (@git.HttpResponse, Bytes) raise @git.GitError {
  @gitionative.native_http_get(url, headers)
}

///|
pub async fn native_http_post(
  url : String,
  body : Bytes,
  headers : Map[String, String],
) -> (@git.HttpResponse, Bytes) raise @git.GitError {
  @gitionative.native_http_post(url, body, headers)
}
