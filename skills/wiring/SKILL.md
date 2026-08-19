---
name: wiring
description: Map what talks to what in a ROS 2 system and prove it — nodes, topics, services, actions, and the QoS on both ends of every connection. Prefers live introspection on the robot, falls back to reading source, and always says which it used. Use for "wiring", "what publishes /scan", "what does this node connect to", "what breaks if I change this", "why isn't this topic arriving".
---

# wiring

Answer one question about one system: **what talks to what, right now, and how do
I know.**

Not a tutorial and not a learning path — that is `teach`. Not a change-impact
analysis — that is `blast-radius`. This is a map of real connections, with the
evidence attached.

## Invocation

| Call | Answers |
|---|---|
| `wiring` | whole-system map: nodes, the topics between them, where data enters and leaves |
| `wiring <file>` | what this file publishes, subscribes, serves, and calls; who is on the other end of each; what breaks if it changes |
| `wiring <topic>` | who publishes it, who subscribes, message type, QoS on each end, what stops working if it stops |
| `wiring <node>` | every connection that node has, in and out |

## Rule zero: say which evidence you used

Every answer opens with one of these, and it is not optional:

```
Evidence: LIVE — <bot name>, <timestamp>, N nodes running
Evidence: STATIC — source only, robot not consulted
Evidence: MIXED — live for <X>, static for <Y> (say why)
```

An unlabelled map is worse than no map, because the reader cannot tell whether
they are looking at what is running or at what someone intended to run.

## Live mode (preferred)

Live is ground truth. It reflects remappings, launch arguments, namespaces, and
which nodes actually came up — none of which the source reliably tells you.

Check the robot is up first: `bot status <name>`. If it reports unreachable or
stale, **do not retry** — fall back to static, say so, and say why. See
"When the robot is down" below.

Then, through `bot run <name> -- <cmd>`:

```bash
bot run <name> -- ros2 node list                 # what is actually running
bot run <name> -- ros2 topic list -t             # every topic, with its type
bot run <name> -- ros2 node info /some_node      # that node's pubs/subs/services/actions
bot run <name> -- ros2 topic info /some_topic -v # endpoint-by-endpoint, with QoS
bot run <name> -- ros2 service list -t
bot run <name> -- ros2 action list -t
bot run <name> -- ros2 param list                # topic names often live in params
bot run <name> -- ros2 param dump /some_node
```

`ros2 topic info -v` is the important one. It is the only command that prints the
QoS profile of each publisher and each subscriber separately, and QoS mismatches
are invisible in every other view.

Two more, when a connection is claimed to exist but nothing is arriving:

```bash
bot run <name> -- ros2 topic hz /some_topic          # is anything actually flowing
bot run <name> -- ros2 topic echo --once /some_topic # is the content what you expect
```

A topic that lists, has a publisher, and reports no `hz` is a real finding.

## Static mode (fallback)

Use static when the robot is unreachable, or when the repo is not a live system
at all — a GUI, a library, a message package. Static is also the only way to see
code paths that are not currently running.

What to read, in order:

1. **Launch files** first, not source. They decide namespaces, remappings, and
   which nodes exist at all. `launch/*.launch.py` (`Node(...)` with
   `remappings=[...]`, `parameters=[...]`, `namespace=...`), `*.launch.xml`
   (`<remap from=… to=…/>`), and `ComposableNode(...)` for anything composed.
2. **Parameter YAML** — `config/*.yaml`, keyed by node name under
   `ros__parameters`.
3. **Endpoint construction** in source:
   - Python: `create_publisher(`, `create_subscription(`, `create_service(`,
     `create_client(`, `ActionServer(`, `ActionClient(`
   - C++: `create_publisher<`, `create_subscription<`, `create_service<`,
     `create_client<`, `rclcpp_action::create_server`, `create_client`
4. **Message and service definitions** — `msg/*.msg`, `srv/*.srv`,
   `action/*.action` — for what actually crosses the wire.

### The traps static mode falls into

- **A topic name that is a parameter.** `self.declare_parameter('camera_topic',
  '/camera/image_raw')` followed by `create_subscription(Image,
  self.get_parameter('camera_topic').value, ...)`. Grepping for the topic finds
  the default and misses every deployment that overrides it. Always check the
  parameter YAML and the launch file before believing a topic name in source.
- **Namespaces and `~`.** A node in namespace `/arm` publishing `~/status`
  produces `/arm/node_name/status`. The string in the source is not the topic.
- **Remappings.** The topic in the code is the topic *before* the launch file
  gets to it.
- **Conditional construction.** Endpoints created inside an `if` on a parameter
  exist in some deployments and not others. Say so rather than picking one.

## QoS is a first-class output

Report reliability and durability for **both ends** of every connection. Not a
footnote, not "defaults" — the actual values, from `ros2 topic info -v` when
live, or from the QoS profile argument in the constructor when static
(`SensorDataQoS`, `rclcpp::QoS(10)`, `qos_profile_sensor_data`, an explicit
`QoSProfile(...)`).

The subscriber's request must be no stricter than the publisher's offer.
Otherwise the two never connect, and **nothing anywhere reports an error** —
the topic simply never arrives:

| Publisher offers | Subscriber requests | Result |
|---|---|---|
| BEST_EFFORT | RELIABLE | **Incompatible — no delivery, silently** |
| RELIABLE | BEST_EFFORT | Fine |
| VOLATILE | TRANSIENT_LOCAL | **Incompatible — no latched data for late joiners** |
| TRANSIENT_LOCAL | VOLATILE | Fine |
| deadline 100ms | deadline 50ms | **Incompatible — publisher too slow to promise it** |
| liveliness lease 5s | liveliness lease 1s | **Incompatible** |

This is the single most common real bug in a ROS 2 stack, and it is the reason
this skill exists. A sensor driver using `SensorDataQoS` (best-effort) against a
subscriber built with the default `QoS(10)` (reliable) is a dead connection that
looks like a code bug for hours.

Flag depth mismatches too. They do not break the connection, but a depth-1
subscriber on a 200 Hz topic drops almost everything, which reads as a bug in
the callback.

## When live and static disagree

They will, constantly, and **the disagreement is the useful part.** Report it;
never quietly reconcile it.

| What you see | What it usually means |
|---|---|
| In the code, absent live | The node isn't running, or a remap redirected it |
| Live, absent from the code | Another package, a composed node, or a remap target |
| Same topic, different type | Two things named alike that are not the same thing |
| Same topic, different QoS per endpoint | The mismatch above — check delivery |
| Publisher exists, `hz` reports nothing | Node is up but not publishing; look at its state or its inputs |

Each of these is a finding worth more than the map it appeared in.

## Rules

- **Cite evidence for every claim.** A file and line, or the exact command run.
  No claim without one of the two.
- **Never infer a connection from a name.** `/camera/image_raw` appearing in two
  files is not a connection until both endpoints have been seen. Matching
  strings are a hypothesis, not a finding.
- **State unknowns as unknowns.** An incomplete map that is correct beats a
  complete one that is invented. "I could not determine the subscriber for
  `/foo`" is a legitimate and useful output.
- **Do not guess QoS.** If the profile could not be determined, write `unknown`.

## Cross-check the decisions

Read `~/dev/notes/<repo>/decisions.md` before finishing, and flag anywhere the
live system contradicts a recorded decision — a topic that was supposed to be
removed, a QoS setting that was chosen deliberately and is now something else, a
node that was meant to be merged into another.

**That contradiction is worth more than the map.** Lead with it.

## Writing it down

Offer to write the result to `~/dev/notes/<repo>/architecture.md`. Never do it
unasked. That file is regenerated rather than maintained, so overwriting it is
fine once the user says yes.

Anything learned about *why* — a QoS choice that turned out to be deliberate, a
remap that exists for a reason — belongs in `decisions.md` instead, and that one
is appended to, never overwritten.

**Never write anything to the mount.** Notes live under `~/dev/notes/`. Files
written under `~/dev/<bot>/` land on the robot's shared disk.

## When the robot is down

If `bot status <name>` reports unreachable or stale, the robot is powered off,
off wifi, or out of range. Say that plainly, switch to static, and label the
output `STATIC`.

Do not retry the command, do not remount, and do not claim live evidence you do
not have. Two consecutive connectivity failures means stop and report.
