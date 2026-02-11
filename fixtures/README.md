# Fixtures

## Regenerate idx fixtures

```sh
./fixtures/regen_idx.sh
```

## workspace_flow fixture (workspace flow e2e)

Bootstrap nested repositories for workspace-flow tests:

```sh
./fixtures/workspace_flow/bootstrap.sh /tmp/ws-flow
```

Then initialize workspace metadata and install fixture manifests:

```sh
cd /tmp/ws-flow
bit workspace init
cp /path/to/repo/fixtures/workspace_flow/workspace.toml .git/workspace.toml
# failure profile
cp /path/to/repo/fixtures/workspace_flow/workspace.fail.toml .git/workspace.toml
```

## hello.pack

Generated via:

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
printf "hello\n" > hello.txt
git add hello.txt
git commit -m "init" -q
OBJ_LIST=$(git rev-list --objects --all)
printf "%s\n" "$OBJ_LIST" | git pack-objects --stdout > /path/to/fixtures/hello.pack
# Verify
cd /path/to/repo
git index-pack fixtures/hello.pack
```

## oracle.pack

Non-delta packfile with compression level 0 (stored blocks).

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
git config user.name "Test"
git config user.email "test@example.com"
printf "hello\n" > hello.txt
printf "world\n" > world.txt
git add hello.txt world.txt
GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git commit -q -m "initial"
git rev-list --objects --all | cut -d' ' -f1 | \
  git -c core.compression=0 pack-objects --stdout --window=0 --depth=0 --no-reuse-delta --no-reuse-object \
  > /path/to/fixtures/oracle.pack
# Verify
cd /path/to/repo
git index-pack fixtures/oracle.pack
```

## oracle_deflate.pack

Non-delta packfile with deflate compression.

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
git config user.name "Test"
git config user.email "test@example.com"
printf "hello\n" > hello.txt
printf "world\n" > world.txt
git add hello.txt world.txt
GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git commit -q -m "initial"
git rev-list --objects --all | cut -d' ' -f1 | \
  git -c core.compression=1 pack-objects --stdout --window=0 --depth=0 --no-reuse-delta --no-reuse-object \
  > /path/to/fixtures/oracle_deflate.pack
# Verify
cd /path/to/repo
git index-pack fixtures/oracle_deflate.pack
git verify-pack -v fixtures/oracle_deflate.pack
```

## oracle_delta.pack

Delta packfile with deflate compression.

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
git config user.name "Test"
git config user.email "test@example.com"
head -c 2048 /dev/zero | tr '\0' 'a' > big.txt
printf '\n' >> big.txt
head -c 1024 /dev/zero | tr '\0' 'a' > big2.txt
printf 'b' >> big2.txt
head -c 1023 /dev/zero | tr '\0' 'a' >> big2.txt
printf '\n' >> big2.txt
git add big.txt big2.txt
GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git commit -q -m "initial"
git rev-list --objects --all | cut -d' ' -f1 | \
  git -c core.compression=1 pack-objects --stdout --window=10 --depth=10 --no-reuse-object \
  > /path/to/fixtures/oracle_delta.pack
# Verify
cd /path/to/repo
git index-pack fixtures/oracle_delta.pack
git verify-pack -v fixtures/oracle_delta.pack
```

## oracle_thin.pack

Thin packfile (missing base objects). This will not index without the base objects
present in the repository.

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
git config user.name "Test"
git config user.email "test@example.com"
head -c 2048 /dev/zero | tr '\0' 'a' > big.txt
printf '\n' >> big.txt
git add big.txt
GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git commit -q -m "c1"
commit1=$(git rev-parse HEAD)
head -c 1024 /dev/zero | tr '\0' 'a' > big.txt
printf 'b' >> big.txt
head -c 1023 /dev/zero | tr '\0' 'a' >> big.txt
printf '\n' >> big.txt
git add big.txt
GIT_AUTHOR_DATE="1700000001 +0000" GIT_COMMITTER_DATE="1700000001 +0000" git commit -q -m "c2"
commit2=$(git rev-parse HEAD)
printf "%s\n^%s\n" "$commit2" "$commit1" | \
  git -c core.compression=1 pack-objects --thin --stdout --window=10 --depth=10 --no-reuse-object --revs \
  > /path/to/fixtures/oracle_thin.pack

# Verify in a repo that has commit1
git index-pack fixtures/oracle_thin.pack # expected: unresolved delta
cat fixtures/oracle_thin.pack | git index-pack --fix-thin --stdin
```

## oracle_thin_base.pack

Base pack for resolving `oracle_thin.pack` (commit c1 only, no deltas).

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
git config user.name "Test"
git config user.email "test@example.com"
head -c 2048 /dev/zero | tr '\0' 'a' > big.txt
printf '\n' >> big.txt
git add big.txt
GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git commit -q -m "c1"
git rev-list --objects --all | cut -d' ' -f1 | \
  git -c core.compression=1 pack-objects --stdout --window=0 --depth=0 --no-reuse-delta --no-reuse-object --no-delta-base-offset \
  > /path/to/fixtures/oracle_thin_base.pack
```

## oracle_after_delta.pack

Ref-delta pack with base object placed after the delta (reordered).

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q
git config user.name "Test"
git config user.email "test@example.com"
head -c 2048 /dev/zero | tr '\0' 'a' > big.txt
printf '\n' >> big.txt
git add big.txt
GIT_AUTHOR_DATE="1700000000 +0000" GIT_COMMITTER_DATE="1700000000 +0000" git commit -q -m "c1"
head -c 1024 /dev/zero | tr '\0' 'a' > big.txt
printf 'b' >> big.txt
head -c 1023 /dev/zero | tr '\0' 'a' >> big.txt
printf '\n' >> big.txt
git add big.txt
GIT_AUTHOR_DATE="1700000001 +0000" GIT_COMMITTER_DATE="1700000001 +0000" git commit -q -m "c2"
printf "%s\n" "$(git rev-parse HEAD)" | \
  git -c core.compression=1 pack-objects --stdout --window=10 --depth=10 --no-reuse-object --no-delta-base-offset --revs \
  > /tmp/tmp_refdelta.pack

# Reorder to put delta before base (REF_DELTA is safe to reorder)
cd /path/to/repo
git index-pack /tmp/tmp_refdelta.pack
node -e 'const fs=require("fs"); const crypto=require("crypto"); const {execSync}=require("child_process"); const packPath="/tmp/tmp_refdelta.pack"; const buf=fs.readFileSync(packPath); const trailerOffset=buf.length-20; const out=execSync("git verify-pack -v "+packPath,{encoding:"utf8"}); const lines=out.trim().split("\\n").filter(l=>/^[0-9a-f]{40} /.test(l)); const entries=lines.map(l=>{const parts=l.trim().split(/\\s+/); return {offset: parseInt(parts[4],10), isDelta: parts.length>=7};}).sort((a,b)=>a.offset-b.offset); const offsets=entries.map(e=>e.offset).concat([trailerOffset]); const slices=entries.map((e,i)=>({isDelta:e.isDelta, buf: buf.slice(e.offset, offsets[i+1])})); const reordered=slices.filter(s=>s.isDelta).concat(slices.filter(s=>!s.isDelta)); const header=buf.slice(0,12); const body=Buffer.concat(reordered.map(s=>s.buf)); const content=Buffer.concat([header, body]); const trailer=crypto.createHash("sha1").update(content).digest(); fs.writeFileSync("/path/to/fixtures/oracle_after_delta.pack", Buffer.concat([content,trailer]));'
```

## upload-pack v2 fixtures (advertise/ls-refs/fetch)

These are embedded as hex strings in `src/tests/upload_pack_fixture_test.mbt`.

```sh
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
git init -q repo
cd repo
echo hello > hello.txt
git add hello.txt
git commit -q -m init
cd ..

# Advertise refs (protocol v2)
GIT_PROTOCOL=version=2 git-upload-pack --stateless-rpc --advertise-refs repo > adv.bin

# Build ls-refs request and capture response
node - <<'NODE'
const fs=require('fs');
function pkt(s){const b=Buffer.from(s,'utf8');const len=b.length+4;const hdr=len.toString(16).padStart(4,'0');return Buffer.concat([Buffer.from(hdr,'ascii'),b]);}
const chunks=[];
chunks.push(pkt('command=ls-refs\n'));
chunks.push(pkt('agent=git/moonbit\n'));
chunks.push(pkt('object-format=sha1\n'));
chunks.push(Buffer.from('0001','ascii'));
chunks.push(pkt('peel\n'));
chunks.push(pkt('symrefs\n'));
chunks.push(pkt('unborn\n'));
chunks.push(pkt('ref-prefix refs/heads/\n'));
chunks.push(pkt('ref-prefix refs/tags/\n'));
chunks.push(pkt('ref-prefix HEAD\n'));
chunks.push(Buffer.from('0000','ascii'));
fs.writeFileSync('lsreq.bin', Buffer.concat(chunks));
NODE
GIT_PROTOCOL=version=2 git-upload-pack --stateless-rpc repo < lsreq.bin > lsresp.bin

# Build fetch request and capture response
HEAD=$(git -C repo rev-parse HEAD)
HEAD="$HEAD" node - <<'NODE'
const fs=require('fs');
const head=process.env.HEAD;
function pkt(s){const b=Buffer.from(s,'utf8');const len=b.length+4;const hdr=len.toString(16).padStart(4,'0');return Buffer.concat([Buffer.from(hdr,'ascii'),b]);}
const chunks=[];
chunks.push(pkt('command=fetch\n'));
chunks.push(pkt('agent=git/moonbit\n'));
chunks.push(pkt('object-format=sha1\n'));
chunks.push(Buffer.from('0001','ascii'));
chunks.push(pkt('thin-pack\n'));
chunks.push(pkt('no-progress\n'));
chunks.push(pkt('ofs-delta\n'));
chunks.push(pkt(`want ${head}\n`));
chunks.push(pkt('done\n'));
chunks.push(Buffer.from('0000','ascii'));
fs.writeFileSync('fetchreq.bin', Buffer.concat(chunks));
NODE
GIT_PROTOCOL=version=2 git-upload-pack --stateless-rpc repo < fetchreq.bin > fetchresp.bin

# Convert to hex for embedding
node - <<'NODE'
const fs=require('fs');
for (const f of ['adv.bin','lsresp.bin','fetchresp.bin']) {
  const b=fs.readFileSync(f);
  console.log(f+':'+b.toString('hex'));
}
NODE
```
