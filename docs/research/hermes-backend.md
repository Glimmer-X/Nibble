# Hermes backend notes

How Nibble talks to [Hermes Agent](https://github.com/NousResearch/hermes-agent), checked against
Hermes 0.22. Hermes's own documentation of the API server:
hermes-agent.nousresearch.com/docs/user-guide/features/api-server.

## Setting Hermes up for Nibble

- The API server runs inside `hermes gateway` (not inside the `hermes serve` backend that Hermes
  Desktop starts for itself). It serves `127.0.0.1:8642` by default.
- It turns on when a profile's `.env` has a usable `API_SERVER_KEY` (16 or more characters, not a
  placeholder); `gateway.api_server.enabled: false` in `config.yaml` turns it off. The key is
  required even on loopback, because the agent can run commands.
- One gateway serves every profile: the default profile at `/`, the others at `/p/<profile>/`,
  each with its own key in its own `.env`. There is no endpoint that lists profiles; Nibble reads
  the profile folders under `~/.hermes/profiles`.
- To keep the gateway running, `hermes gateway install --start-now --start-on-login` installs it
  as a login service (`hermes gateway uninstall` removes it). Besides the API server it runs any
  messaging platform that is configured and ticks the profiles' scheduled jobs.
- With Hermes on the same Mac and no key pasted into Nibble, Nibble reads the profile's
  `API_SERVER_KEY` from its `.env`.

## The route Nibble uses

`POST /v1/chat/completions` with `stream: true` and an `X-Hermes-Session-Id` of Nibble's own
(`nibble-…`). With the header (which needs a key), Hermes keeps the conversation and loads its
history from its own state, so each turn sends only the new message; a compression of the context
is followed on the server side. Images go as `image_url` parts with `data:` URLs. Stopping closes
the connection, which interrupts the run.

The stream carries everything the panel shows:

- reasoning as `delta.reasoning_content`;
- tool calls as named `hermes.tool.progress` events (`{tool, label, toolCallId, status:
  running|completed}`), mapped by tool name to searching (`web_search`, `x_search`,
  `search_files`, `session_search`, `skills_list`), reading (`web_extract`, `read_file`,
  `skill_view`, `browser_navigate`, `browser_snapshot`, `browser_console`, `feishu_doc_read`),
  looking (`vision_analyze`, `video_analyze`, `browser_vision`, `browser_get_images`) or a tool;
- waits and retries as `hermes.status` lines (those starting with ⏳);
- approvals as `approval.request` events;
- usage in the last chunk.

The Sessions API (`/api/sessions/{id}/chat/stream`) streams no reasoning and no status lines, so
Nibble does not use it for turns.

## Approvals

An `approval.request` carries the run, the request id, the command, the `choices` the client may
send back, and, under Hermes's session authority, the run's `execution_generation`. The answer
goes to `POST /v1/runs/{run}/approval` as `{choice, request_id}` plus `execution_generation` when
the request had one; with the authority, any other field makes Hermes answer 400.

Choices: `once`, `session` (this kind of command is allowed for the rest of the session),
`always` (written to the profile's permanent allowlist) and `deny`. Hermes offers only `once` and
`deny` after its own check refused the command. Nibble offers Allow (`once`), Allow for this chat
(`session`, when offered) and Deny; never `always`.

With `approvals.mode: smart`, Hermes first asks an auxiliary model whether a flagged command is
safe, with a 16-token budget for the one-word verdict. A model that thinks before answering and
cannot turn thinking off (Gemini 3 and later, for one) spends the budget thinking, the verdict
comes back empty and every flagged command is passed to the reader (NousResearch/hermes-agent
issues #108163 and #68263).

## Deleting a conversation

`DELETE /api/sessions/{id}` (under `/p/<profile>/` with that profile's key) removes the session's
rows and messages, its delegate sessions, `sessions/<id>.json(l)` and `request_dump_<id>_*.json`,
and the images sent with it that nothing else holds. It answers 404 when the session is gone and
409 while a run still holds it. When Hermes compressed the conversation it carries on in a new
session that the delete leaves alone: `GET /api/sessions/{id}/messages?limit=0` names the live one
as `session_id`, and each session's `parent_session_id` (`GET /api/sessions/{id}`) leads back to
the first.

Files the agent writes while answering are not recorded per session. They go to the profile's
`cache/scratch` (where `TMPDIR` points for the agent's commands), which Hermes clears a day after
the last write.

## Other notes

- Sessions made through the API are tagged `api_server`.
- Each turn runs with the profile's full toolset, memory included; `memory.memory_enabled` and
  `memory.user_profile_enabled` turn memory off per profile.
- Limits: 10 concurrent runs (HTTP 429 beyond), images only (no other files), data-URL media over
  5 MB skipped on some paths.
- Every Hermes turn carries the agent's full system prompt and tool definitions, so the first
  token arrives later than from a bare model API. Quick questions may suit a direct API backend
  better; questions that need tools or the agent's memory suit Hermes.
