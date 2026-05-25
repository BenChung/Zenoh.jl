# Wrapper coverage report

Inventory of what `Zenoh.jl` (`src/`) currently exposes versus the C API
declared in `gen/LibZenohC.jl`. Regenerate by reading `src/` and grepping
`^function (z|zc|ze)_` against `gen/LibZenohC.jl`.

Last refreshed against **libzenohc_jll 1.9.0**.

## Headline numbers

| | Count |
|---|---|
| C entrypoints in bindings | 647 |
| Referenced by `src/` | ~89 (~14%) |
| Plumbing (`_loan`/`_move`/`_drop`/`_take`/`_clone`/`_options_default`/`internal_*`) | 332 — auto-handled by `src/ownership.jl` or never user-facing |
| OS portability layer (`z_mutex/condvar/task/time/clock/random/sleep/malloc/free/realloc`) | 30 — duplicates Base, skip |
| Public surface left to wrap | ~201 |

### Delta vs. libzenohc_jll 1.6.2

- Added: `z_locality_default`, `z_query_accepts_replies`, `z_reply_keyexpr_default`
- Removed: `z_internal_congestion_control_default_response`
- Several opaque struct sizes grew (`z_owned_config_t`, `z_owned_publisher_t`,
  `z_owned_querier_t`, `z_owned_queryable_t`, `z_owned_string_t`). Wrapper
  treats these as opaque, so no `src/` changes were needed.

## What the wrapper exposes today

| Area | Julia surface | C entrypoints touched |
|---|---|---|
| Session | `Session`, `open(::Config)`, `close`, `isopen`, `zid` | `z_open`, `z_close`, `z_session_is_closed`, `z_info_zid` |
| Discovery (info) | `router_zids`, `peer_zids` | `z_info_routers_zid`, `z_info_peers_zid`, `z_closure_zid` |
| Config | `Config(; from_env/file/str)`, `getindex`, `setindex!`, `toJson`, `show` | `z_config_default`, `z_config_clone`, `zc_config_from_{env,file,str}`, `zc_config_get_from_str`, `zc_config_insert_json5`, `zc_config_to_string` |
| Key expressions | `Keyexpr(::String; autocanonize)`, `@kexpr_str`, `==`, `hash`, `String`/`string`/`print`/`show`, `includes`, `intersects`, `concat`, `Base.join`, `canonize`, `is_canon` | `z_keyexpr_from_str{,_autocanonize}`, `z_keyexpr_{equals,includes,intersects,concat,join,canonize,is_canon,as_view_string}` |
| Publisher | `Publisher`, `put`, `close` | `z_declare_publisher`, `z_undeclare_publisher`, `z_publisher_put` |
| Subscriber (callback) | `open(f, s, k)`, `close` | `z_declare_subscriber`, `z_undeclare_subscriber`, `z_closure_sample`, `z_sample_clone` (single-slot try-lock: I/O thread clones into an inline cell + signals `uv_async_send`; slow consumers lose messages — use the buffered form for queued semantics) |
| Subscriber (buffered) | `open(s, k; channel=:fifo|:ring, capacity)`, `iterate`, `take!`, `tryrecv!`, `close` | `z_{fifo,ring}_channel_sample_new`, `z_{fifo,ring}_handler_sample_{recv,try_recv}` |
| Get / Reply | `get(s, k, params; channel, capacity, target, consolidation, timeout_ms, payload, encoding, attachment)`, `Reply`, `is_ok`, `sample`, `error_payload`, `error_encoding` | `z_get`, `z_get_options_default`, `z_query_consolidation_{auto,none,monotonic,latest}`, `z_{fifo,ring}_channel_reply_new`, `z_{fifo,ring}_handler_reply_{recv,try_recv}`, `z_reply_{is_ok,ok,err,err_payload,err_encoding}` |
| Session-level put | `put(s, k, payload; timestamp, encoding)` | `z_put` |
| Sample (owned/loaned) | `Sample{Owned|Loaned}`; `payload`, `timestamp`, `kind`, `keyexpr`, `attachment`, `encoding`, `congestion_control`, `priority`, `express` | `z_sample_{payload,timestamp,kind,keyexpr,attachment,encoding,congestion_control,priority,express}`, `z_sample_drop` |
| Encoding | `Encoding`, `Encodings.*` (53 constants), schema kwarg, MIME/String coercion | `z_encoding_from_str`, `z_encoding_set_schema_from_str`, `z_encoding_to_string`, `z_encoding_loan_mut` |
| ZBytes | constructors + `length`/iterate/`open(::Val{:read,:readslice})` | `z_bytes_from_{buf,str,static_str}`, `z_bytes_len`, `z_bytes_get_{reader,slice_iterator}`, `z_bytes_slice_iterator_next`, `z_bytes_reader_*` |
| ZSlice | `ZSlice()`, `ZSlice(::Vector{UInt8}; copy)`, `length`, `isempty` | `z_slice_{empty,copy_from_buf,from_buf,len,is_empty,data}`, `z_view_slice_loan` |
| Timestamps | `ZTimestamp(::Session/::Ptr)`, `zid`, `ntp64_time` | `z_timestamp_{new,id,ntp64_time}` |
| Liveliness | `LivelinessToken`, `LivelinessSubscriber`, `LivelinessSubscriberHandler`, `liveliness_get` (channel + callback) | `z_liveliness_declare_token`, `z_liveliness_undeclare_token`, `z_liveliness_token_{options_default,drop}`, `z_liveliness_declare_subscriber`, `z_liveliness_subscriber_options_default`, `z_liveliness_get`, `z_liveliness_get_options_default` |
| Queryable (callback) | `Queryable(f, s, k; complete, allowed_origin)`, `close` | `z_declare_queryable`, `z_undeclare_queryable`, `z_closure_query`, `z_query_clone`, `z_queryable_options_default` (single-slot latest-wins — prefer the channel form for real query workloads) |
| Queryable (buffered) | `Queryable(s, k; channel=:fifo|:ring, capacity, complete, allowed_origin)`, `iterate`, `take!`, `tryrecv!`, `close` | `z_{fifo,ring}_channel_query_new`, `z_{fifo,ring}_handler_query_{recv,try_recv,drop}` |
| Query (server-side) | `Query`, `keyexpr`, `parameters`, `payload`, `encoding`, `attachment`, `accepts_replies`; `reply(q, payload, k; encoding, timestamp, attachment, congestion_control, priority, is_express)`, `reply_err(q, payload; encoding)`, `reply_del(q, k; timestamp, attachment, congestion_control, priority, is_express)` | `z_query_{keyexpr,parameters,payload,encoding,attachment,accepts_replies,clone,drop}`, `z_query_reply{,_err,_del}`, `z_query_reply{,_err,_del}_options_default` |
| Matching listeners | `MatchingListener(f, ::Publisher; should_close_on_error)`, `close`, `matching_status(::Publisher)` | `z_publisher_declare_matching_listener`, `z_publisher_get_matching_status`, `z_undeclare_matching_listener`, `z_matching_listener_drop`, `z_closure_matching_status{,_call,_drop}` (POD-shape closure: payload `z_matching_status_t` is byte-copied into the inline cell — no clone/drop, no channel handlers) |
| Scouting | `scout(config; …) -> Vector{Hello}`, `scout(f, config; …)`, `Hello`, `whatami_string` | `z_scout`, `z_scout_options_default`, `z_closure_hello`, `z_hello_{loan,zid,whatami,locators,clone,drop}`, `z_whatami_to_view_string`, `z_string_array_{loan,len,get,drop}` |
| Locality | `Locality`, `Localities.{ANY,SESSION_LOCAL,REMOTE}` | `z_locality_default` |
| Logging | `setup_logging()` | `zc_init_log_from_env_or` |
| Errors | `ZenohError`, `_handle_result` | — |

## What's missing — by feature area

Counts below are public (non-plumbing) entrypoints in each area.

| Area | Public fns | Why it matters |
|---|---:|---|
| Encoding / MIME types | ~10 | Done as structured `Encoding` value + `Encodings.*` constants + schema kwarg. Still unwrapped: `z_encoding_equals` (use `==` on `Encoding`), `z_encoding_from_substr`, `z_encoding_set_schema_from_substr`, `z_encoding_clone`, `z_encoding_loan_default`. |
| Serializer / Deserializer (`ze_*`) | 69 | High-level structured (de)serialization layered on `ZBytes`. Four sub-APIs: `ze_serialize_*` (16), `ze_deserialize_*` (13), `ze_serializer_*` (24), `ze_deserializer_*` (16). |
| Querier | ~14 | Queryable + Query + reply are now wrapped. Remaining: the entire `z_querier_*` family (declare + put + get + matching listeners + options), `z_queryable_keyexpr`, `z_declare_background_queryable`, `z_query_consolidation_*` (already wrapped for `get` but not exposed as a public Julia API), `z_query_target_default`. |
| Liveliness | 1 | Mostly done. Remaining: `z_liveliness_declare_background_subscriber` (no handle returned; needs session-scoped closure lifetime). |
| Matching listeners | 3 | Publisher form is wrapped (`MatchingListener` + `matching_status`). Remaining: `z_publisher_declare_background_matching_listener`, and the entire querier counterpart (`z_querier_declare_matching_listener`, `z_querier_get_matching_status`, background variant) — blocked on the unwrapped `Querier`. |
| Closures (high-level) | 5 | `z_closure_{sample,reply,query,hello}` are stamped out by `@closure_kind :owned` and `z_closure_matching_status` by `@closure_kind :pod` in `closure_kinds.jl`; `z_closure_zid` is hand-wired. Missing: `zc_closure_log`. |
| ZBytes writer | 4 | Build payloads incrementally; mirror of `ZBytesReader`. `z_bytes_writer_{empty,append,write_all,finish}` + `z_bytes_empty`. |
| ZBytes alternate constructors | 7 | `z_bytes_from_{slice,static_buf,string}`, `z_bytes_copy_from_{buf,slice,str,string}`, `z_bytes_{is_empty,to_slice,to_string}`. |
| View types (`z_view_keyexpr_*`, `z_view_string_*`, `z_view_slice_*`) | 15 | Non-owning constructors that avoid allocation; not currently wrapped. |
| String / string array | 12 | `z_string_*` (used internally via `_string` helper), `z_string_array_*` — no `ZString` / `ZStringArray` wrappers. |
| Keyexpr utilities | 0 | Done. `concat`, `Base.join`, `==`/`hash`, `includes`, `intersects`, `canonize`, `is_canon`, and `String`/`show` cover the nine `z_keyexpr_*` ops actually exported by `libzenohc 1.9.0` (the previously listed `z_keyexpr_relation_to` isn't in the bindings). Substring variants (`z_keyexpr_from_substr{,_autocanonize}`, `z_keyexpr_canonize_null_terminated`) and the `z_view_keyexpr_*` non-owning constructors remain unwrapped — see "View types" row. |
| Session: delete | 1 | `z_delete` — one-shot delete on a key expression. |
| QoS enums | 1 | `Locality` wrapper + `Localities.*` constants are wired. Remaining: `z_priority_default` and other QoS helpers, needed once `put`/`subscriber` options are extended. |

## Partially exposed

- **Sample** — `payload`, `timestamp`, `kind`, `keyexpr`, `attachment`, `encoding`, `congestion_control`, `priority`, `express` wired. Missing: `z_sample_payload_mut`.
- **Put options** (`z_publisher_put_options_t` / `z_put_options_t`) — `timestamp` and `encoding` wired. Missing fields: `attachment`, `congestion_control`, `priority`, `is_express`, `allowed_destination` (the last is session-`put` only).
- **Subscriber** — `z_declare_subscriber` is called with `C_NULL` options; `z_subscriber_options_default` and any flags it surfaces aren't reachable.
- **Publisher** — `z_publisher_options_default` is initialized but not configured; CCC/priority/encoding/reliability/express not wired through.
- **Config** — JSON get/set works but typed convenience setters (listen endpoints, mode, …) live only as raw JSON strings.

## Out of scope (probably skip)

- **OS portability layer** — `z_mutex_*` (8), `z_condvar_*` (8), `z_task_*` (6), `z_time_*` (5), `z_clock_*` (4), `z_random_*` (5), `z_sleep_*` (3), `z_malloc`/`z_free`/`z_realloc`. Julia Base already provides equivalents.
- **`internal_*` plumbing** — 78 entrypoints used by the move/loan/drop machinery; already handled implicitly by `src/ownership.jl`.

## Suggested priority order

Biggest user-visible payoff first:

1. ~~**Sample accessors**~~ — done.
2. ~~**Encoding on puts**~~ — done as structured `Encoding` + `Encodings.*` constants.
3. **`z_get` + Reply consumption** — unblocks the entire request/reply pattern.
4. ~~**Queryable + Query reply**~~ — done. `Queryable` (callback + channel), `Query` accessors, `reply`/`reply_err`/`reply_del`, `Locality` wrapper. Background queryable deferred.
5. **FIFO/Ring channel handlers** — replace the callback-only subscriber model with idiomatic blocking `recv`.
6. ~~**Liveliness**~~ — done (foreground forms; background subscriber deferred).
7. **`z_delete`** — trivial one-liner, useful for completeness.
8. **Serializer / Deserializer** (`ze_*`) — large but cohesive; can be its own layer on top of `ZBytes`.
9. ~~**Matching listeners**~~ — done for publishers (foreground); querier
   counterpart + background variant deferred.
10. **ZBytes writer + view types + ~~keyexpr ops~~** — keyexpr ops done; writer + view types still nice-to-have polish.

SHM remains a separate, larger project — none of those entrypoints are public
yet in this binding generation pass.
