# Proof of concept: Swift distributed actors over Homa

Status: correctness-first actor runtime implemented over TCP on macOS; Linux Homa adapter validated over loopback in an Apple `container` VM running Linux 6.17.8 with Homa built in; not yet validated on physical Linux hosts. Benchmark and inference work are deferred.  
Prepared: 2026-09-28.

## Objective

Build a minimal Swift distributed actor system that exchanges remote invocations using Homa on Linux. Measure whether Homa improves small-request latency under competing bulk traffic, and how much of any transport advantage survives actor dispatch, serialization, and Swift task scheduling.

The current milestone is narrower: demonstrate that the distributed actor system itself works. It now has a separate-process TCP demo and focused correctness tests. Homa validation on Linux is the next transport step; the benchmark comparisons below remain a future plan rather than a current deliverable.

The initial test machine is a Mac mini reported to run Linux (described as “omachy,” possibly Omarchy). Its CPU architecture, distribution, kernel, Ethernet hardware, and access details remain unverified. A second Linux machine and a switch with configurable priorities have not been confirmed.

This POC is a transport and runtime experiment. It does not implement distributed inference or establish that Homa will outperform exo, MLX, or Thunderbolt RDMA.

## Motivation and hypothesis

An exo maintainer identified networking as a major inference bottleneck. Homa offers a relevant hypothesis: when small coordination messages compete with large transfers, receiver-controlled grants and message priorities can reduce waiting behind bulk traffic.

Swift's `DistributedActorSystem` protocol permits a custom runtime and transport. Homa's request/response semantics fit remote actor invocation: encode a call, transmit a request, invoke the destination actor, and return a response or error.

Three hypotheses will be evaluated independently:

1. Homa can operate correctly on the available Linux hardware.
2. A minimal Swift actor runtime can preserve a useful portion of Homa's measured transport performance.
3. On a suitable physical network, Homa improves small-request tail latency under mixed traffic without an unacceptable loss of useful throughput or increase in CPU cost.

A negative result is useful if the measurements identify its cause. No particular speedup is an acceptance requirement.

## Scope

### Included

- Linux compatibility and network inventory.
- A small C shim around Homa's socket API and receive-buffer management.
- A persistent TCP transport for comparison.
- One custom Swift actor-system implementation with interchangeable transports.
- Static peer addresses and preconfigured actor identifiers.
- A benchmark service, bounded concurrent requests, deadlines, and clean shutdown.
- A load generator, machine-readable results, plots, and a decision report.

### Deferred

- Automatic discovery, membership gossip, leader election, actor migration, or durable recovery.
- Model loading, GPU kernels, tensor collectives, and integration with exo or MLX.
- GPU-direct transfer and zero-copy claims.
- A macOS Homa implementation.
- Production authentication, encryption, and cross-version wire compatibility. Initial runs use an isolated, trusted test network.

## Hardware stages and limits

| Stage | Equipment | What it can establish |
| --- | --- | --- |
| A: local integration | Linux Mac mini; client and server in separate processes | Compatibility, correctness, buffer lifetime, and preliminary runtime overhead |
| B: physical link | Two Linux hosts connected by Ethernet | NIC-path request latency, throughput, and sender-side competition |
| C: incast | Three Linux senders and one Linux receiver through a suitable switch | Competing sender traffic converging on the receiver link and the effect of switch priorities |

Local routing or network namespaces may help development if supported by the selected Homa revision. Their operation must be verified. They bypass the physical network and cannot validate Homa's switch-queue behavior. Multiple processes on one sending host share its uplink and do not reproduce independent physical senders.

Stage A is the first bounded milestone. Stage B requires another Linux endpoint. Stage C is the minimum planned topology for the congestion experiment, not a prerequisite for starting development.

## Milestone 0: compatibility gate

Record CPU architecture, distribution, kernel release/configuration, compiler versions, RAM, Ethernet controller and driver, negotiated speed, MTU, offload capabilities, and available switch configuration. Establish whether the system can build and load an out-of-tree module.

Build and load a pinned Homa revision, then demonstrate a request/response exchange using an existing upstream utility before adding Swift. Record any kernel adaptations separately from the benchmark code.

The Homa installation guide currently identifies Linux 6.17.8 as a known-working main-branch configuration and provides selected RHEL branches. This is not a guarantee for the Mac mini's installed kernel. The guide also identifies important NIC, pacing, and switch settings; some offload paths have documented limitations.

Configure only the measured test path, record every setting, and retain restoration instructions. An inability to run Homa locally is a compatibility finding, not evidence about its network performance.

**Exit condition:** a documented, repeatable Homa request/response exchange and a working Swift release toolchain on the target, or a concrete compatibility blocker with a proposed remedy.

## Implementation design

### Package layout

Proposed components:

```text
Package.swift
Sources/
  CHoma/                 C syscall and buffer-management shim
  BenchmarkTransport/    Homa and TCP adapters, common message envelope
  HomaActorSystem/       DistributedActorSystem and invocation handling
  BenchmarkService/      Echo and acknowledge operations
  BenchmarkCLI/          Server, client, and load-generation commands
Tests/                   Correctness, concurrency, and resource-lifetime tests
scripts/                 Inventory, reproducible runs, and plotting
results/                 Per-run metadata and measurement files
```

`HomaActorSystem` is a working name. The same runtime must support the TCP comparison path. Apple's full `ClusterSystem` is a reference implementation, not the TCP baseline, because comparing a full cluster runtime with a minimal runtime would confound the transport comparison.

### Invocation path

```text
Caller -> invocation encoder -> transport request
       -> receive loop -> decoder -> destination actor
       -> result handler -> transport response -> waiting Swift task
```

Implement actor identity assignment/resolution, lifecycle registration, invocation encoding/decoding, remote calls, and result/error handling. Use a fixed set of benchmark operations and a compact binary representation. Both transports carry equivalent application envelopes and payloads.

Homa's RPC ID and completion cookie map responses to pending calls. TCP uses an application call ID and length-prefixed frames over persistent connections with TCP_NODELAY. Both paths support multiple outstanding calls and out-of-order completion matching.

The C shim owns Homa's receive pool. Buffers must remain valid until decoding or processing finishes, then be returned exactly once. Socket receive work runs on dedicated I/O threads or an appropriate nonblocking loop; it must not block Swift's cooperative executor. Pending calls have bounded storage, deadlines, and defined shutdown behavior.

### Benchmark operations

- `acknowledge`: consume a request payload and return a fixed-size reply containing its ID and status.
- `echo`: return the original payload for correctness checks.
- `fail`: return a controlled remote error for failure-path testing.

No inference work runs inside these operations. Preallocate payloads, avoid per-request logging, and validate payload integrity outside the primary latency measurement where possible. Use monotonic timestamps on the client so round-trip measurements do not depend on synchronized host clocks.

The current Homa API caps each request or response at 1,000,000 payload bytes. Initial payloads remain below that limit; chunking is deferred. Eventual tensor chunking would change the messages Homa schedules and needs its own experiment.

## Benchmark comparisons

| Mode | Path | Purpose |
| --- | --- | --- |
| Direct TCP | Swift harness -> TCP adapter -> direct handler | TCP transport baseline |
| Direct Homa | Swift harness -> Homa adapter -> direct handler | Homa transport baseline |
| Actor TCP | Swift harness -> distributed actor runtime -> TCP | Actor cost with TCP |
| Actor Homa | Swift harness -> distributed actor runtime -> Homa | Actor cost with Homa |

Direct modes use the same harness, application encoding, and adapters while bypassing distributed actor dispatch. Report full distributions for each mode. Differences between P99 values are descriptive comparisons, not an exact decomposition of per-call overhead. Optional sampled instrumentation can separate encoding, dispatch, and completion costs without burdening every timed call.

Use upstream `cp_node` as an independent sanity check where practical, not as a substitute for the controlled four-mode comparison.

## Initial workload matrix

| Workload | Parameters | Primary measurement |
| --- | --- | --- |
| Unloaded | 64 B, 4 KiB, 256 KiB requests; one outstanding; fixed 64 B application reply | Baseline round-trip latency |
| Concurrent | 4 KiB requests; 8 and 32 outstanding | Throughput and scheduling overhead |
| Mixed | Independently scheduled 64 B probes competing with 256 KiB requests; 64 B replies | Small-request latency as bulk offered load rises |

Payload sizes exclude transport and application-envelope headers. All modes use identical application contents.

For mixed traffic, first determine sustainable goodput for each mode. Then test the same absolute offered rates across modes, starting below saturation and approaching the common sustainable range. Report overload behavior separately rather than silently comparing different loads. Record both offered and achieved rates.

Run TCP with probe and bulk traffic sharing a connection, then with separate connections. Identify those results explicitly. This distinguishes TCP stream ordering from interference elsewhere in the host or network.

Stage C adds independent bulk senders targeting the probe receiver. Record priority mapping and switch scheduling policy. Compare configurations with and without effective switch priorities where feasible, rather than assuming a switch honors packet markings.

## Measurement method

- Release builds with debug logging disabled on timed paths.
- Start with 5 seconds of warm-up and 30 seconds of measurement, repeated three times. Extend runs for adequate tail samples or unstable results.
- Record P50, P95, P99, request count, useful throughput, CPU usage, timeouts, errors, queue depth, and peak outstanding calls.
- Report P99.9 only when sample counts support it; retain enough data to assess run-to-run variation.
- For mixed traffic, schedule probes independently of previous completions. Record intended send time, actual dispatch, and completion. Report scheduled-to-completion latency and dispatch delay alongside wire-facing round-trip time.
- Bound outstanding work. Count admission failures and deadline misses; never omit them to make latency appear lower. Include timeout rates alongside successful-call percentiles.
- Alternate or randomize mode order. Record CPU placement, frequency policy, background activity, MTU, interrupt settings, offloads, Homa settings, and switch configuration.
- Compare equivalent workloads and document any protocol-specific tuning. Interpret low-speed-link results as measurements of that environment, not projections for a datacenter fabric.

## Correctness checks

Before performance runs, verify payload integrity, concurrent response matching, remote errors, deadline expiry, late replies, server termination, clean shutdown, and buffer reclamation under sustained activity. Check that request IDs do not cross-deliver replies and that memory use reaches a stable range.

Transport-level reliability does not resolve application ambiguity after a timeout. The POC does not automatically retry state-changing calls or claim exactly-once execution across failures. Benchmark operations remain side-effect-free.

## Milestones and decision gates

1. **Compatibility:** upstream Homa exchange succeeds on the target; hardware and software inventory captured.
2. **Direct transports:** TCP and Homa adapters pass correctness checks; direct-mode measurements are reproducible.
3. **Actor integration:** all four modes run; actor-specific overhead and CPU cost can be compared.
4. **Physical network:** repeat on two hosts, then perform incast testing when the required hosts and switch are available.
5. **Decision report:** identify whether the limiting factor is transport, runtime scheduling, copying, CPU saturation, or network setup.

If direct Homa improves latency but Actor Homa loses the benefit, optimize the adapter/runtime before implementing inference. If gains only appear under incast, identify whether the intended inference topology actually produces that traffic. If the available network does not expose a gain, distinguish an unsuitable test environment from an implementation defect.

Only after this gate should a follow-up prototype add one real inference communication pattern, including GPU/CPU synchronization and memory transfers. Actor-only gains do not establish faster tensor collectives or token generation.

## Deliverables

- Buildable benchmark package and focused correctness tests.
- Target inventory and reproducible setup/run instructions.
- Pinned software revisions and per-run configuration metadata.
- Raw results and plots of small-request P99 versus offered load, plus throughput and CPU cost.
- A short report stating supported conclusions, remaining uncertainties, and whether to proceed to an inference prototype.

## References

- [Swift distributed actor runtime design](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0344-distributed-actor-runtime.md)
- [Apple's distributed actor cluster implementation](https://github.com/apple/swift-distributed-actors)
- [Homa installation and network configuration](https://github.com/PlatformLab/HomaModule/blob/main/INSTALL.md)
- [Homa userspace API and message limit](https://github.com/PlatformLab/HomaModule/blob/main/homa.h)
- [Homa receive-buffer documentation](https://github.com/PlatformLab/HomaModule/blob/main/man/homa.7)
- [Homa benchmark utility](https://github.com/PlatformLab/HomaModule/blob/main/util/cp_node.cc)
- [Homa change history](https://github.com/PlatformLab/HomaModule#significant-changes)
- [Exo's MLX backend initialization](https://github.com/exo-explore/exo/blob/main/src/exo/worker/engines/mlx/utils_mlx.py)
- [MLX distributed communication](https://ml-explore.github.io/mlx/build/html/usage/distributed.html)

Repository links track moving branches. Pin exact revisions during implementation. In particular, Homa's September 2026 change introduced START_MSG for fully scheduled messages; older protocol prose still describes sending initial unscheduled data for those messages. Treat the selected revision's implementation and API as authoritative when resolving such differences.
