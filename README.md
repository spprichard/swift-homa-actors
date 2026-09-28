# Swift distributed actor transport POC

This package runs Swift `distributed actor` calls between separate processes. TCP is the verified development transport. A Linux Homa adapter uses Homa's `sendmsg`/`recvmsg` socket interface and an application-owned receive pool; it has not been run against a Homa kernel module yet.

The demo service offers `echo`, `add`, a void `acknowledge`, and a deliberate remote error. Both transports use the same invocation encoder, actor dispatch, reply format, static actor ID, call deadlines, and bounded request table. The wire format is JSON for clarity, so this is a correctness POC, not a latency benchmark.

## Build and test on macOS

```sh
swift build
swift test
```

Start a server in one terminal, then a client in another:

```sh
swift run actor-demo server 39117 127.0.0.1
swift run actor-demo client 39117 127.0.0.1
```

The client prints echo and arithmetic results, confirms void and error calls, and checks 32 concurrent calls. Stop the server with Ctrl-C.

## Linux Homa run

First install and load a HomaModule revision compatible with the Linux kernel, then validate its upstream userspace utility. Check the installed `homa.h` against `Sources/CHoma/homa.c`; this adapter mirrors the UAPI fields and constants from [HomaModule `homa.h`](https://github.com/PlatformLab/HomaModule/blob/main/homa.h) as reviewed on 2026-09-28. The adapter deliberately fails at socket creation if Homa is absent. It does not fall back to TCP.

```sh
swift build -c release
swift test
swift run -c release actor-demo server-homa 7317 0.0.0.0
swift run -c release actor-demo client-homa 7317 SERVER_IPV4
```

Use separate terminals or machines for server and client. Homa uses its own port space, separate from TCP; explicit server ports must be in `1...32767`. Run the two processes on one Linux host first, then across a physical network. The Homa path needs the kernel module and network configuration described in [Homa's manual](https://github.com/PlatformLab/HomaModule/blob/main/man/homa.7). It has not been compiled or tested on Linux in this workspace. The adapter ABI was reviewed from HomaModule main; pin a matching module revision before Linux validation.

## Behavior and limits

- Actor IDs are configured before construction with `prepareActor(id:)`; peers resolve by that same ID. There is no discovery or migration.
- This POC uses a client to server call direction; a system created with `listen` or `listenHoma` does not initiate outgoing calls.
- Calls have a configurable deadline (five seconds by default, accepted range greater than zero and at most one hour). Timeout or cancellation removes the pending call; a late reply is ignored. Calls are not retried.
- At most 1,024 client calls can be pending. Overflow fails immediately. TCP frames are capped at 2 MB; Homa messages are capped at 1,000,000 bytes by its API.
- `shutdown()` fails pending calls, closes transport activity, and releases registered actors. Calls after shutdown fail.
- Remote errors are returned as descriptions in `ActorSystemFailure.remote`; concrete error types are not serialized.
- The initial wire format has no authentication, encryption, or cross-version compatibility guarantee. Use it on a trusted test network.
- The Homa adapter copies received bytes before returning its buffer pages in the next `recvmsg`. Linux module compatibility, sustained buffer recycling, failure handling, and shutdown still require tests on the target host.

The original experiment and later benchmark plan are in [POC.md](POC.md). Inference and performance claims are deferred until the actor runtime is verified on Linux.
