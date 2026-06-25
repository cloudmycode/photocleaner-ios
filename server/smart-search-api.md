# Smart Search Client-Server API

## Overview

This document defines the server-side API contract for the iOS Smart Search feature.

After the recent client simplification, the iOS app no longer:

- builds prompt text on device
- calls a public LLM API directly
- displays parsed keyword/debug information in the UI
- infers extra tags locally from the user's sentence
- performs OCR/date/location semantic expansion during Smart Search

The client now does only three things:

1. sends the user's plain search text to your server
2. receives a keyword list from your server
3. matches those keywords against local `visualTags` on device

So the server is now fully responsible for query understanding.

## Client Behavior

The current iOS client implementation is in:

- [PhotoPreview.swift](</Users/wang/Project/antivirus/photocleaner-ios/PhotoCleaner/ PhotoPreview.swift:3135>)

Current client request behavior:

- HTTP method: `POST`
- Content-Type: `application/json`
- Timeout: `15s`
- Request body fields:
  - `query`
  - `locale`

Current client response expectation:

- HTTP 2xx
- JSON body with one field:
  - `keywords: string[]`

Any non-2xx response is treated as failure.
Any invalid JSON response is treated as failure.

## Endpoint

The app reads the endpoint from `Info.plist`:

- [Info.plist](/Users/wang/Project/antivirus/photocleaner-ios/PhotoCleaner/Info.plist:33)

Config key:

- `PhotoQueryParseEndpoint`

Suggested production endpoint:

```text
POST /api/smart-search/parse
```

Example full URL:

```text
https://your-domain.com/api/smart-search/parse
```

## Request Schema

### JSON body

```json
{
  "query": "找海边的狗狗照片",
  "locale": "zh-Hans_CN"
}
```

### Fields

| Field | Type | Required | Description |
|---|---|---:|---|
| `query` | `string` | yes | Raw text entered or spoken by the user after client-side trim |
| `locale` | `string` | yes | Current device locale identifier, for example `zh-Hans_CN`, `en_US`, `ja_JP` |

### Request rules

- `query` should be interpreted as plain natural language.
- The server should trim whitespace again for safety.
- Empty query should return a valid error response or `keywords: []`.
- `locale` should be used only as a language hint.

## Response Schema

### Success response

```json
{
  "keywords": ["beach", "dog"]
}
```

### Fields

| Field | Type | Required | Description |
|---|---|---:|---|
| `keywords` | `string[]` | yes | Parsed search keywords used by the client to match local `visualTags` |

### Response rules

- `keywords` must always be present on success.
- `keywords` may be an empty array.
- Each keyword should ideally be a short normalized concept string.
- Prefer English canonical labels because the client normalizes and matches using English-oriented `visualTags`.

## Matching Logic on Client

The client does local matching against indexed `visualTags`.

Current implementation:

- [PhotoPreview.swift](</Users/wang/Project/antivirus/photocleaner-ios/PhotoCleaner/ PhotoPreview.swift:3175>)

### Important behavior

The client normalizes each server keyword like this:

- trims whitespace
- case-insensitive
- removes diacritics
- converts `-` and `_` to spaces
- rejoins with `_`
- lowercases

Examples:

- `Red Clothing` -> `red_clothing`
- `red-clothing` -> `red_clothing`
- `DOG` -> `dog`

### Matching rule

For each returned keyword, the client considers it matched if one of the following is true:

1. exact normalized match against indexed `visualTags`
2. synonym match using the built-in synonym table
3. loose contains match between keyword and indexed tag

All returned keywords are ANDed together.

That means:

- `["person", "red_clothing"]` means the image must match both
- `["dog", "beach"]` means the image must match both

## Recommended Server Keyword Set

To maximize accuracy, the server should preferably return keywords close to the app's known visual concepts.

### Best-supported canonical keywords

These are the safest recommended outputs:

```text
person
people
human
red_clothing
blue_clothing
white_clothing
black_clothing
yellow_clothing
green_clothing
car
vehicle
food
meal
dish
beach
sea
ocean
dog
cat
pet
animal
building
architecture
sky
flower
plant
document
paper
receipt
invoice
```

### Synonyms already recognized by the client

The client currently includes synonym support for:

- `car`, `vehicle`, `automobile`, `motor_vehicle`, `land_vehicle`
- `food`, `meal`, `dish`, `cuisine`, `plate`
- `beach`, `sea`, `ocean`, `coast`, `shore`, `seashore`, `water`
- `dog`, `canine`
- `cat`, `feline`
- `pet`, `animal`, `dog`, `cat`, `canine`, `feline`
- `person`, `people`, `human`
- `building`, `architecture`, `house`, `skyscraper`
- `flower`, `plant`, `flora`
- `document`, `paper`, `receipt`, `invoice`

Even so, server output should still prefer canonical keywords when possible.

## Server-side Parsing Recommendations

The server should convert the user's sentence into a compact visual keyword list.

### Good examples

User query:

```text
找海边的狗狗照片
```

Recommended response:

```json
{
  "keywords": ["beach", "dog"]
}
```

User query:

```text
穿红衣服的人
```

Recommended response:

```json
{
  "keywords": ["person", "red_clothing"]
}
```

User query:

```text
建筑和天空
```

Recommended response:

```json
{
  "keywords": ["building", "sky"]
}
```

User query:

```text
宠物
```

Recommended response:

```json
{
  "keywords": ["pet"]
}
```

### Bad examples

Avoid returning long natural-language fragments:

```json
{
  "keywords": ["a dog running on the beach"]
}
```

Avoid returning Chinese phrases unless your matching strategy explicitly depends on fuzzy contains:

```json
{
  "keywords": ["海边", "狗狗"]
}
```

Avoid mixing non-visual concepts that the client no longer uses:

```json
{
  "keywords": ["last_year", "hainan", "vacation"]
}
```

Those concepts are no longer interpreted by the current client search path.

## Current Functional Scope

The current Smart Search scope is intentionally narrow:

- image search only
- visual tag matching only
- no server-side response fields other than `keywords`
- no OCR-driven search
- no date filtering
- no location filtering
- no media-type filtering
- no asset-type filtering

If you want those capabilities later, the client contract will need to be expanded again.

## Error Handling

Recommended server behavior:

- return `400` for invalid request body
- return `200` with `{"keywords":[]}` for valid but unrecognized queries
- return `500` for internal parse failures

### Suggested error response

The current client does not parse structured error bodies, so this is optional.

```json
{
  "error": "invalid_request",
  "message": "query is required"
}
```

## Response Time Expectations

Client timeout is currently `15s`.

Recommended target:

- p50 under `1s`
- p95 under `3s`
- hard upper bound under `10s`

If the server is slow, the client will show a generic network-unavailable error.

## Minimal Contract Summary

### Request

```json
{
  "query": "找海边的狗狗照片",
  "locale": "zh-Hans_CN"
}
```

### Response

```json
{
  "keywords": ["beach", "dog"]
}
```

## Implementation Notes for Server Developer

- Keep the server prompt and model details entirely on the server.
- The client should not know model name, system prompt, or vendor API key.
- Return stable, compact, canonical visual keywords.
- Prefer precision over recall. Bad keywords will directly lead to wrong local image matches.
- If in doubt, return fewer but more accurate keywords.

## Suggested Future Extensions

If later needed, this API can evolve to:

```json
{
  "keywords": ["dog", "beach"],
  "confidence": 0.92,
  "version": "2026-06-26",
  "debugId": "trace_xxx"
}
```

But for the current client, only `keywords` is used.
