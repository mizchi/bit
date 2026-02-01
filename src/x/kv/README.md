# GitDb - Git-based Distributed KV Store

A distributed key-value store built on Git primitives with gossip protocol synchronization.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                        GitDb                            │
├─────────────────────────────────────────────────────────┤
│  Hierarchical KV Store                                  │
│  - Keys: "/users/alice/profile" → Git tree path         │
│  - Values: Bytes → Git blob                             │
├─────────────────────────────────────────────────────────┤
│  GitFs (Copy-on-Write Layer)                            │
│  - Read: Git tree/blob traversal with caching           │
│  - Write: In-memory working layer                       │
│  - Snapshot: Creates Git commits                        │
├─────────────────────────────────────────────────────────┤
│  Gossip Protocol                                        │
│  - VectorClock: Causal ordering                         │
│  - Announce: Broadcast HEAD state                       │
│  - Sync: Exchange Git objects                           │
│  - Merge: LWW / KeepBoth / Custom strategies            │
└─────────────────────────────────────────────────────────┘
```

## Features

- **Hierarchical Keys**: Keys are mapped to Git tree structure (e.g., `/users/alice/profile`)
- **Content-Addressable**: Values stored as Git blobs with SHA-1 hashing
- **Versioned**: Full history via Git commits
- **Distributed**: P2P sync via gossip protocol
- **Conflict Resolution**: Last-Write-Wins, KeepBoth, or custom merge strategies
- **Offline-First**: Work offline, sync later

## API

### KV Operations

```moonbit
let db = GitDb::empty(NodeId::new("node1"), "/repo/.git")

// Set/Get
db.set("/users/alice/name", b"Alice")
let name = db.get(fs, "/users/alice/name")  // Some(b"Alice")

// List keys
let users = db.list(fs, "/users")  // ["alice", "bob"]

// Delete
db.delete("/users/alice/name")
```

### Versioning

```moonbit
// Commit changes
let commit_id = db.commit(fs, fs, "Add user alice", timestamp)

// Rollback uncommitted changes
db.rollback()
```

### Gossip Sync

```moonbit
// Get current state for broadcasting
let state = db.get_gossip_state(timestamp)

// Handle incoming gossip message
let response = db.handle_gossip(fs, message, timestamp)

// Select random peers for gossip
let peers = db.select_gossip_peers(3, seed)

// Merge with remote state
let result = db.merge(fs, fs, their_head, their_clock, LastWriteWins, timestamp)
```

## Design Decisions

### Why Not Raft?

Git's Merkle DAG with gossip provides eventual consistency, which is sufficient for many use cases:

| Approach | Consistency | Complexity | Use Case |
|----------|-------------|------------|----------|
| Raft | Strong (CP) | High (leader election, log replication) | Financial, config management |
| Git + Gossip | Eventual | Low (push/pull + conflict resolution) | Code, data, config |

This follows the same approach as [Noms](https://github.com/attic-labs/noms) and [Dolt](https://github.com/dolthub/dolt).

### Vector Clocks

Vector clocks track causal relationships between updates:
- Each node maintains a logical clock
- On update: increment own clock
- On sync: merge clocks, take max for each node
- Enables detection of concurrent updates for conflict resolution

### Merge Strategies

- **LastWriteWins**: Take the value with the higher vector clock (or timestamp as tie-breaker)
- **KeepBoth**: Create conflict markers (like Git merge conflicts)
- **Custom**: User-provided resolver function

## Intended Use Case: Cloudflare Workers

```typescript
// Durable Object
export class GitDbNode {
  private db: GitDb;

  async fetch(request: Request) {
    const msg = await request.json() as GossipMessage;
    const response = this.db.handle_gossip(msg, Date.now());
    return Response.json(response);
  }

  // Periodic gossip with random peers
  async alarm() {
    const peers = this.db.select_gossip_peers(3, Date.now());
    for (const peer of peers) {
      const state = this.db.get_gossip_state(Date.now());
      await fetch(peer.endpoint, {
        method: 'POST',
        body: JSON.stringify({ type: 'Announce', state })
      });
    }
  }
}
```

## Prior Art

- [Noms](https://github.com/attic-labs/noms) - Versioned, forkable, syncable database (Go, archived)
- [Dolt](https://github.com/dolthub/dolt) - Git for Data, SQL database with Git semantics (Go, active)
- [OrbitDB](https://github.com/orbitdb/orbitdb) - Peer-to-peer database for IPFS (JavaScript)

## Status

Experimental. Part of the `src/x/` experimental modules.
