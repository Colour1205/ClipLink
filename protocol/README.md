# protocol/

Platform-agnostic wire format definitions, shared by every client (the Windows app, iOS/Android/HarmonyOS apps).

Kept here — outside any single platform folder — so all clients generate their message types from the same source of truth instead of hand-rolling matching structs per platform.

- `schema/` — schema definitions (see below). Format TBD: Protobuf is a reasonable default (codegen for C#, Swift, Kotlin, and ArkTS/HarmonyOS all exist), JSON Schema is a lighter-weight alternative if codegen tooling becomes a pain on HarmonyOS.

See `../docs/protocol.md` for the behavioral spec these schemas implement.
