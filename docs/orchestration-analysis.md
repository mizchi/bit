# Orchestration Analysis: Parallel Agent Coordination

## 1. Test Results Summary

2 agent parallel spawn + coordination directory polling + merge flow test.

### What Worked

| Component | Result |
|-----------|--------|
| Coordination directory structure | status/step/pid/branch files correctly read/written |
| Status transition (pending -> running -> done) | Both agents transitioned correctly |
| Step counter (polled via filesystem) | Agent-1: 0 -> 19 real-time tracking |
| Parallel process spawn (nohup + PID capture) | Two independent processes ran simultaneously |
| Completion detection (polling loop) | Both agents' `done` status detected |
| Git worktree isolation | Each agent had independent working directory |
| Branch merge (ort strategy) | Two branches merged without conflict |
| Worktree cleanup | Removed cleanly after merge |

### What Failed

| Component | Result | Root Cause |
|-----------|--------|-----------|
| LLM tool invocation | `list_directory` loop, never called `write_file` | Model capability issue, not protocol issue |
| Event sequence numbering | `ls | wc -l` returns same seq for concurrent writes | Race condition in seq counter |

### Key Observation

Coordination infrastructure is complete and functional. The bottleneck is **agent capability** (the inner loop), not orchestration (the outer loop).

## 2. Bottleneck Analysis

### The Inner Loop Problem

```
Orchestrator (outer loop)          Agent (inner loop)
  plan subtasks                      LLM.stream()
  spawn processes          -->       parse tool calls
  poll coordination dir              execute tool
  evaluate progress                  append result
  merge branches                     loop until done
```

The orchestrator can only be as effective as the agents it coordinates. In our test:

- Orchestrator correctly spawned, monitored, and detected completion
- Agents failed to accomplish their tasks (stuck in `list_directory` loop)
- Result: perfect coordination of zero useful work

This reveals a fundamental design constraint: **optimizing the outer loop is premature if the inner loop is unreliable**.

### Model Selection Impact

| Model | Behavior | Task Completion |
|-------|----------|----------------|
| OpenRouter default (kimi-k2.5) | `list_directory` loop, no tool args | 0% |
| Claude Sonnet 4 via OpenRouter | `list_directory` loop with args, no `write_file` | 0% |

The tool-calling capability of the LLM directly determines whether parallelization has any value.

## 3. When Orchestration Adds Value

### Effective Parallelization Requires

1. **Reliable inner loop**: Each agent must be able to complete its subtask independently
2. **Independent subtasks**: No file overlap between agents (otherwise merge conflicts)
3. **Sufficient task size**: Parallelization overhead (worktree creation, process spawn, merge) must be less than sequential execution time
4. **Cost tolerance**: N parallel agents = N x API calls (multiplicative cost)

### Orchestration ROI Matrix

| Task Type | Sequential Time | Parallel Time | Overhead | Net Benefit |
|-----------|----------------|---------------|----------|-------------|
| 2 independent module tests | 2T | T + setup + merge | ~30s | Positive if T > 30s |
| 5 independent file edits | 5T | T + setup + merge | ~60s | Positive if T > 15s |
| Tightly coupled refactoring | T (can't split) | T (no parallelism) | wasted setup | Negative |
| Single file bug fix | T | T (only 1 agent) | 0 | Neutral |

### The Break-Even Point

```
parallel_benefit = (N - 1) * avg_agent_time
parallel_cost = worktree_setup + process_spawn + polling_overhead + merge_time + risk_of_conflict

benefit > cost  =>  orchestrate
benefit <= cost =>  run single agent
```

For current implementation:
- `worktree_setup` ~ 2s per agent
- `process_spawn` ~ 1s per agent
- `polling_overhead` ~ 2s per iteration (negligible)
- `merge_time` ~ 5s total
- `risk_of_conflict` ~ depends on task decomposition quality

Break-even: if average agent task takes > 30s, 2+ agent parallelism is worthwhile.

## 4. Design Recommendations

### 4.1 Agent Reliability First

Before optimizing orchestration, ensure agents can reliably complete tasks:

- **Tool call validation**: If LLM returns same tool call 3 times in a row, force a different action or inject a hint
- **Progress detection**: If step count increases but no `write_file` or `run_command` is called, the agent is likely stuck
- **Model gating**: Only use models with proven tool-calling capability for orchestrated tasks
- **Task specificity**: More specific task descriptions lead to more reliable execution

### 4.2 Task Decomposition Quality

The LLM planner that splits tasks is critical:

```
Bad decomposition:
  "Add tests" -> ["Add tests for module A", "Add tests for module B"]
  Problem: both agents might edit shared test config files

Good decomposition:
  "Add tests" -> ["Add unit tests to src/math.mbt (only modify src/math_test.mbt)",
                   "Add unit tests to src/greeting.mbt (only modify src/greeting_test.mbt)"]
  Benefit: explicit file boundaries prevent merge conflicts
```

Recommendations:
- Include file-level constraints in subtask descriptions
- Have planner output both task description AND file scope
- Validate no file overlap before spawning agents
- Reject decompositions with shared dependencies

### 4.3 Monitoring Strategy

Current implementation polls every 2 seconds. This is sufficient for the monitoring use case, but the evaluation logic can be improved:

**Stall detection**:
```
if agent.step unchanged for > 60 seconds:
  check if process is alive (kill -0 $PID)
  if alive but stalled:
    cancel and re-queue with different strategy
```

**Error pattern detection**:
```
if last 3 events are all Error type:
  cancel agent
  log reason for post-mortem
```

**Progress quality check**:
```
if agent.step > 10 and no FileChanged events:
  agent is likely in a tool-calling loop
  cancel and retry with explicit hint
```

### 4.4 Event Sequence Fix

Current bug: `ls events/ | wc -l` returns stale count under concurrent writes.

Fix options:
1. Use `{timestamp_ns}_{agent_id}.json` instead of sequential numbering
2. Use atomic file creation with `mktemp` pattern
3. Per-agent event directories: `events/{agent_id}/{seq}.json`

Recommended: option 3 (per-agent directories), which also simplifies `coord_read_events_since`.

### 4.5 Graceful Degradation

```
if all agents fail:
  fall back to single-agent sequential execution
  use the original unsplit task
  log orchestration failure for analysis

if some agents fail:
  merge successful branches only
  report partial completion with list of failed subtasks
```

## 5. KV Integration Path

### Current: Filesystem-Based Coordination

```
coord_write_status(dir, agent_id, status)
  => printf 'status' > /tmp/bit-orch-{session}/agents/{agent_id}/status

coord_read_all_agents(dir)
  => ls /tmp/bit-orch-{session}/agents/ + read each file
```

This maps directly to KV semantics:
- `set("agents/{id}/status", "running")` = write file
- `get("agents/{id}/status")` = read file
- `list("agents/")` = list directory

### Future: Gossip-Based Distributed Coordination

```
Local orchestrator:
  kv.set("agents/agent-0/status", "running")
  kv.set("agents/agent-0/step", "5")

Remote orchestrator (via gossip sync):
  kv.get("agents/agent-0/status")  => "running"
  kv.get("agents/agent-0/step")    => "5"
```

Benefits:
- Multi-machine agent distribution
- No shared filesystem requirement
- Vector clock causality for event ordering
- Automatic conflict resolution via CRDT

Migration path:
1. Abstract coord functions behind a trait (`CoordStore`)
2. Implement `FileCoordStore` (current) and `KvCoordStore`
3. KvCoordStore uses `Kv::set`/`Kv::get`/`Kv::list` with gossip sync
4. Orchestrator receives `&CoordStore` trait reference

### Distributed Architecture

```
Machine A (orchestrator):
  - Plans subtasks
  - Writes task assignments to KV
  - Monitors progress via KV reads
  - Merges results

Machine B (worker):
  - Watches KV for assigned tasks
  - Runs agent on local worktree
  - Reports progress to KV
  - Gossip syncs with Machine A

Machine C (worker):
  - Same as Machine B
  - Gossip syncs with A and B
```

## 6. Hub Integration Path

### Post-Orchestration PR Flow

```
Orchestrator completes merge:
  1. Create Hub PR for combined branch
  2. Run validation (tests, type-check)
  3. Submit review (auto-approve if validation passes)
  4. Merge PR via hub.merge_pr()
```

### Per-Agent PR Flow (Alternative)

```
Each agent creates its own PR:
  1. Agent completes task on branch
  2. Orchestrator creates Hub PR per agent
  3. Run validation per PR
  4. Human or LLM reviews each PR
  5. Merge approved PRs sequentially
```

Benefits of per-agent PRs:
- Granular review (reject bad agent work, keep good)
- No merge conflict from combining all at once
- Better audit trail

## 7. Architectural Priorities

### Priority 1: Agent Inner Loop Reliability

Without reliable agents, orchestration is wasted infrastructure.

Actions:
- Add loop detection (same tool called N times = stuck)
- Add progress heuristic (steps without side effects = stalled)
- Test with multiple models and find minimum capability threshold
- Consider Claude Code provider as the most reliable option (it has its own agent loop)

### Priority 2: Task Decomposition Validation

The planner must produce truly independent subtasks.

Actions:
- Output file scope with each subtask
- Validate no file overlap before spawning
- Include dependency information (read-only vs write files)

### Priority 3: Monitoring and Recovery

Current monitoring is polling-only. Needs active intervention.

Actions:
- Stall detection with timeout
- Error pattern recognition
- Automatic retry with modified strategy
- Partial result preservation

### Priority 4: KV Migration

Abstract coordination behind trait for future distribution.

Actions:
- Define `CoordStore` trait
- Implement file-based and KV-based backends
- Test gossip sync between two orchestrators

## 8. Summary

The orchestration infrastructure (coordination protocol, parallel spawn, monitoring, merge) is **mechanically correct and complete**. The test validated the full lifecycle: spawn -> monitor -> detect completion -> commit -> merge -> cleanup.

The critical gap is **agent task completion reliability**. The LLM agents failed to accomplish their assigned tasks, making the orchestration irrelevant. This is the single highest-priority issue.

Effective orchestration design principle: **invest in agent reliability before investing in coordination complexity**. A single reliable agent outperforms ten unreliable agents running in parallel.
