///|
fn make_test_oid(byte : Byte) -> @git.ObjectId {
  @git.ObjectId::new(FixedArray::make(20, byte))
}

///|
test "midx stdin pack normalize supports idx and pack paths" {
  assert_eq(
    midx_normalize_stdin_pack_name(
      "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.idx",
    ),
    Some("pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack"),
  )
  assert_eq(
    midx_normalize_stdin_pack_name(
      "/tmp/pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
    ),
    Some("pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack"),
  )
  assert_eq(midx_normalize_stdin_pack_name("foo.txt"), None)
}

///|
test "midx stdin pack selection keeps include order and applies excludes" {
  let selected = midx_select_pack_files_from_stdin(
    [
      "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
      "pack-cccccccccccccccccccccccccccccccccccccccc.pack",
    ],
    [
      "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.idx", "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack",
      "pack-unknown.idx",
    ],
    ["pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.idx"],
  )
  assert_eq(selected.length(), 1)
  assert_eq(selected[0], "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack")
}

///|
test "midx stdin pack selection with empty stdin keeps no packs" {
  let selected = midx_select_pack_files_from_stdin(
    [
      "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
    ],
    [],
    [],
  )
  assert_eq(selected.length(), 0)
}

///|
test "midx build writes BTMP chunk only when --bitmap is requested" {
  let pack_files = [
    "pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack", "pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack",
    "pack-cccccccccccccccccccccccccccccccccccccccc.pack",
  ]
  let entries : Array[MidxEntry] = [
    { id: make_test_oid(b'\x01'), pack_idx: 0, offset_hi: 0, offset: 1 },
    { id: make_test_oid(b'\x02'), pack_idx: 0, offset_hi: 0, offset: 2 },
    { id: make_test_oid(b'\x03'), pack_idx: 2, offset_hi: 0, offset: 3 },
  ]
  let with_bitmap = midx_build(pack_files, entries, true)
  let chunk_count = with_bitmap[6].to_int()
  let btmp_offset = midx_find_chunk(with_bitmap, chunk_count, "BTMP")
  assert_true(btmp_offset > 0)
  let btmp_end = midx_find_chunk_end(with_bitmap, chunk_count, "BTMP")
  assert_eq(btmp_end - btmp_offset, pack_files.length() * 8)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset), 0)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 4), 2)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 8), 2)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 12), 0)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 16), 2)
  assert_eq(midx_read_u32(with_bitmap, btmp_offset + 20), 1)
  let without_bitmap = midx_build(pack_files, entries, false)
  let without_chunk_count = without_bitmap[6].to_int()
  assert_eq(midx_find_chunk(without_bitmap, without_chunk_count, "BTMP"), 0)
}
