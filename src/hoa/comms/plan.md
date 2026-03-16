# Inter-Agent Communication — Design Plan

> **Future Work:** This module is planned for a future iteration. This plan documents the intended design for vision purposes. Phase 0 focuses on single-agent execution with human-in-the-loop oversight — no inter-agent messaging is needed.

## Context

The comms module is a structured communication protocol for hierarchical agent coordination. It defines the messaging patterns — direction flowing downward and issues escalating upward — that enable multi-agent hierarchies. As a standalone protocol, it specifies message formats, escalation semantics, and aggregation rules independent of the other components.

**Not in Phase 0 scope.** This plan exists so that other modules can design their interfaces with future comms integration in mind, without coupling to it.

---

## Dependencies

```
comms/  →  core/  (agent identity model — agent_id, tier used in Message and Escalation)
```

**`core/`** is a **required dependency** (when this module is built). Messages reference agent IDs and tier numbers defined by the core orchestration model. The `Message.from_agent_id`, `to_agent_id`, `from_tier`, `to_tier` fields use the same identity scheme as `core/lifecycle.py`'s `AgentConfig.task_id` and the tier hierarchy.

**Note:** Since this module is future work, no imports exist yet. The data models defined here use `str` for agent IDs and `int` for tiers — matching the core module's conventions — so integration will be straightforward when the time comes.

---

## Public Interface

The comms module exposes three things: a message data model, channels for routing messages, and an escalation protocol for upward issue flow.

### `Message` — The atomic unit of communication (`protocol.py`)

```python
class MessageType(str, Enum):
    DIRECTION = "direction"              # task assignment flowing down
    STATUS = "status"                    # progress report flowing up
    ESCALATION = "escalation"            # issue flowing up with options
    RESOLUTION = "resolution"            # decision flowing down in response to escalation
    QUERY = "query"                      # information request (either direction)
    RESPONSE = "response"                # answer to a query

class Message(BaseModel):
    """A single message between agents. Immutable, serializable."""
    id: str                              # ULID
    type: MessageType
    from_agent_id: str
    to_agent_id: str
    from_tier: int
    to_tier: int
    payload: dict                        # type-specific content
    parent_message_id: str | None = None # for threading (response to a previous message)
    timestamp: datetime
    ttl_seconds: int | None = None       # optional expiry

    def is_downward(self) -> bool:
        """True if message flows from higher tier (lower number) to lower tier."""
        return self.from_tier < self.to_tier

    def is_upward(self) -> bool:
        """True if message flows from lower tier to higher tier."""
        return self.from_tier > self.to_tier
```

**Design decisions:**
- Messages are **flat and immutable**. The `payload` dict carries type-specific data (task spec for DIRECTION, options list for ESCALATION, etc.).
- Direction is inferred from tier numbers, not from message type. A QUERY can flow in either direction.
- `parent_message_id` enables threading — an ESCALATION and its RESOLUTION are linked.
- `ttl_seconds` allows time-boxed messages (e.g., "respond within 60 seconds or I'll assume approval").

### `Channel` — Message routing (`channels.py`)

```python
class Channel(Protocol):
    """A bidirectional communication channel between two agents."""
    async def send(self, message: Message) -> None: ...
    async def receive(self, timeout: float | None = None) -> Message | None: ...
    async def receive_all(self) -> list[Message]: ...
    @property
    def pending_count(self) -> int: ...

class InMemoryChannel:
    """For testing and Phase 0 (same-process agents)."""
    def __init__(self, agent_a_id: str, agent_b_id: str): ...

class ChannelRegistry:
    """Manages channels between agents."""
    def get_channel(self, agent_a_id: str, agent_b_id: str) -> Channel: ...
    def get_channels_for(self, agent_id: str) -> list[Channel]: ...
    def create_channel(self, agent_a_id: str, agent_b_id: str) -> Channel: ...
    def close_channel(self, agent_a_id: str, agent_b_id: str) -> None: ...
```

**Design decisions:**
- `Channel` is a **Protocol**. Phase 0 (if ever used) would be in-memory queues. Future: HTTP, WebSocket, or message broker.
- Channels are **bidirectional** — direction is determined by the `Message.is_downward()`/`is_upward()` methods.
- `ChannelRegistry` is the lookup mechanism — agents don't hold direct references to channels, they ask the registry.

### `EscalationProtocol` — Structured issue flow (`escalation.py`)

```python
class EscalationOption(BaseModel):
    """One possible resolution to an escalated issue."""
    label: str                           # short label (e.g., "A", "B", "C")
    description: str                     # what this option entails
    estimated_effort: str | None = None  # e.g., "30 minutes", "requires new subtask"

class Escalation(BaseModel):
    """A structured escalation from a child agent to its parent."""
    id: str                              # ULID
    from_agent_id: str
    to_agent_id: str
    task_id: str
    what_was_attempted: str
    what_failed: str
    blocker_analysis: str
    options: list[EscalationOption]      # at least 2 options
    context: dict = {}                   # additional context for the parent
    timestamp: datetime

class EscalationResponse(BaseModel):
    escalation_id: str
    chosen_option: str | None = None     # label of the chosen option
    free_form_direction: str | None = None  # or custom direction
    additional_permissions: dict | None = None  # if privilege escalation

class EscalationHandler(Protocol):
    """Handles escalations. Phase 0: human via CLI. Future: parent agent."""
    async def handle(self, escalation: Escalation) -> EscalationResponse: ...

class HumanEscalationHandler:
    """Presents escalation to human via CLI prompt."""
    async def handle(self, escalation: Escalation) -> EscalationResponse: ...
```

**Design decisions:**
- `Escalation` is richer than a plain `Message` — it has structured fields for what was attempted, what failed, and a list of options. This enforces the principle that escalating agents must do analysis, not just dump problems.
- `EscalationOption` includes `estimated_effort` so the parent can make informed decisions.
- `EscalationHandler` is a **Protocol**. Phase 0 (when this module is eventually built): human answers via CLI. Future: parent agent decides.
- Options require at least 2 entries — the escalating agent must always present alternatives.

---

## Integration Points

| Consumer | What it uses | How |
|----------|-------------|-----|
| `core/scheduler.py` | `Channel`, `EscalationHandler` | Scheduler routes messages during multi-agent execution |
| `core/lifecycle.py` | `Message(type=DIRECTION)` | Direction messages carry task specs to child agents |
| `inspection/logger.py` | `Message`, `Escalation` | All messages and escalations are logged |
| `security/permissions.py` | `ChannelRegistry` | Security module can restrict which channels an agent can access |
| `cli/run.py` | `HumanEscalationHandler` | CLI prompts human for escalation responses |

**All integration is deferred.** Since this module is future work, no other module imports from `comms/`. The interfaces are documented here so that:
1. `core/` can design `AgentLauncher` to be extensible for message-passing
2. `inspection/` can reserve `EventType` values for communication events
3. `security/` can include communication scope in `PermissionManifest`

---

## Files to Create

| File | Purpose |
|------|---------|
| `src/hoa/comms/__init__.py` | Package init (empty for now) |
| `src/hoa/comms/protocol.py` | `Message`, `MessageType` — data models only |
| `src/hoa/comms/channels.py` | `Channel` protocol, `InMemoryChannel`, `ChannelRegistry` |
| `src/hoa/comms/escalation.py` | `Escalation`, `EscalationOption`, `EscalationResponse`, `EscalationHandler` protocol |
| `tests/unit/test_comms_protocol.py` | Message model validation |
| `tests/unit/test_comms_channels.py` | Channel protocol and in-memory implementation |
| `tests/unit/test_comms_escalation.py` | Escalation model and handler protocol |

---

## Test Strategy

Even though the module is future work, the **data models can be implemented and tested now** — they inform the design of other modules. The protocol implementations are deferred.

### Unit tests — Protocol (`test_comms_protocol.py`)

| Test | What it validates |
|------|------------------|
| `test_message_model_roundtrip` | Serialize → deserialize is lossless |
| `test_message_is_downward` | Tier 0 → Tier 1 → `is_downward()` is True |
| `test_message_is_upward` | Tier 1 → Tier 0 → `is_upward()` is True |
| `test_message_same_tier` | Same tier → both `is_downward()` and `is_upward()` are False |
| `test_message_threading` | `parent_message_id` links response to original |
| `test_message_type_values` | All MessageType values are lowercase strings |

### Unit tests — Channels (`test_comms_channels.py`)

| Test | What it validates |
|------|------------------|
| `test_in_memory_send_receive` | Send message → receive returns it |
| `test_in_memory_receive_empty` | No messages → receive returns None |
| `test_in_memory_receive_all` | Multiple messages → all returned in order |
| `test_in_memory_pending_count` | Pending count reflects unread messages |
| `test_channel_protocol_compliance` | InMemoryChannel satisfies Channel protocol |
| `test_registry_create_and_get` | Create channel → get returns it |
| `test_registry_get_channels_for` | Returns all channels for an agent |
| `test_registry_close_channel` | Close → get returns new channel or None |

### Unit tests — Escalation (`test_comms_escalation.py`)

| Test | What it validates |
|------|------------------|
| `test_escalation_model_roundtrip` | Serialize → deserialize is lossless |
| `test_escalation_requires_options` | At least 2 options validated |
| `test_escalation_option_model` | Option with label, description, effort |
| `test_escalation_response_chosen` | Response references chosen option label |
| `test_escalation_response_freeform` | Response with free-form direction instead of option |
| `test_handler_protocol_compliance` | Mock handler satisfies EscalationHandler protocol |

---

## Phase 0 → Phase 1 Evolution

| Area | Phase 0 (current) | Phase 1 (when built) | Phase 2 |
|------|-------------------|---------------------|---------|
| Status | Data models only | In-memory channels, CLI escalation handler | HTTP/WebSocket channels for Docker agents |
| Channels | Not implemented | `InMemoryChannel` (same-process) | `HttpChannel` for cross-container |
| Escalation | Human via CLI (in `core/`) | Human via CLI (in `comms/`) | Parent agent handles via protocol |
| Message routing | N/A | Direct agent-to-agent | Broadcast, fan-out, aggregation |
| Persistence | N/A | Messages logged by inspection module | Message queue with replay |

The `Message`, `Channel`, `Escalation`, and `EscalationHandler` interfaces are designed now and stay stable as implementations evolve.
