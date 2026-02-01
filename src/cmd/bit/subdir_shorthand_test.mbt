///| Tests for GitHub shorthand parsing (@user/repo and @user/repo/path)
///| Verifies that the shorthand doesn't conflict with existing git URL patterns

// ============================================================================
// Tests for @user/repo (full repo clone)
// ============================================================================

///|
test "github shorthand: @user/repo" {
  let result = parse_github_shorthand("@user/repo")
  assert_eq(result, Some(Repo("https://github.com/user/repo")))
}

///|
test "github shorthand: @mizchi/bit" {
  let result = parse_github_shorthand("@mizchi/bit")
  assert_eq(result, Some(Repo("https://github.com/mizchi/bit")))
}

// ============================================================================
// Tests for @user/repo/path (subdir clone)
// ============================================================================

///|
test "github shorthand: @user/repo/src" {
  let result = parse_github_shorthand("@user/repo/src")
  assert_eq(result, Some(Subdir("https://github.com/user/repo", "src")))
}

///|
test "github shorthand: @user/repo/src/lib/core (deep path)" {
  let result = parse_github_shorthand("@user/repo/src/lib/core")
  assert_eq(result, Some(Subdir("https://github.com/user/repo", "src/lib/core")))
}

///|
test "github shorthand: @mizchi/bit/src/x/bitfs" {
  let result = parse_github_shorthand("@mizchi/bit/src/x/bitfs")
  assert_eq(result, Some(Subdir("https://github.com/mizchi/bit", "src/x/bitfs")))
}

// ============================================================================
// Tests for patterns that should NOT trigger shorthand
// ============================================================================

///|
test "NOT shorthand: full HTTPS URL" {
  let result = parse_github_shorthand("https://github.com/user/repo")
  assert_eq(result, None)
}

///|
test "NOT shorthand: SSH URL" {
  let result = parse_github_shorthand("git@github.com:user/repo.git")
  assert_eq(result, None)
}

///|
test "NOT shorthand: plain user/repo (no @ prefix)" {
  let result = parse_github_shorthand("user/repo")
  assert_eq(result, None)
}

///|
test "NOT shorthand: plain user/repo/path (no @ prefix)" {
  let result = parse_github_shorthand("user/repo/path")
  assert_eq(result, None)
}

///|
test "NOT shorthand: local path" {
  let result = parse_github_shorthand("./local/repo/path")
  assert_eq(result, None)
}

///|
test "NOT shorthand: absolute path" {
  let result = parse_github_shorthand("/home/user/repo")
  assert_eq(result, None)
}

///|
test "NOT shorthand: URL with .git suffix" {
  let result = parse_github_shorthand("user/repo.git")
  assert_eq(result, None)
}

// ============================================================================
// Edge cases
// ============================================================================

///|
test "NOT shorthand: @ only" {
  let result = parse_github_shorthand("@")
  assert_eq(result, None)
}

///|
test "NOT shorthand: @user only (single component)" {
  let result = parse_github_shorthand("@user")
  assert_eq(result, None)
}

///|
test "github shorthand: trailing slash @user/repo/" {
  let result = parse_github_shorthand("@user/repo/")
  assert_eq(result, Some(Repo("https://github.com/user/repo")))
}

///|
test "github shorthand: trailing slash @user/repo/src/" {
  let result = parse_github_shorthand("@user/repo/src/")
  assert_eq(result, Some(Subdir("https://github.com/user/repo", "src")))
}

///|
test "github shorthand: multiple slashes @user/repo//src" {
  let result = parse_github_shorthand("@user/repo//src")
  assert_eq(result, Some(Subdir("https://github.com/user/repo", "src")))
}
