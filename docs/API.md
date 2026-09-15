# Simple Drive API reference

Base path: `/v1`. Request bodies and the application's responses are JSON
(`application/json; charset=utf-8`).

## Authentication

Every endpoint under `/v1` requires a bearer token (RFC 6750):

```http
Authorization: Bearer <token>
```

The token is the value of `SIMPLE_DRIVE_API_TOKEN` on the server. A missing header, another
scheme (`Basic`, `Token`), a malformed value or a wrong token yields `401 Unauthorized` with a
`WWW-Authenticate: Bearer realm="Simple Drive"` header. Authentication is the first step in the
controller, so an unauthenticated request never reaches validation or storage, and a body that is
not valid JSON is answered `401`, not `400`, when the token is missing or wrong.

A few requests are refused before the controller runs, whatever the token: an oversized body
(`413`), an unparsable `Content-Type` (`415`) or `Accept` (`406`) header, a path or body that is
not valid UTF-8, a query string or body that is not valid UTF-8 or percent-encoding (`400`), and a
path with no route (`404`). None of them returns data. The application has no unauthenticated
route.

## Error format

Every error the application returns has the same shape:

```json
{ "error": { "code": "not_found", "message": "No blob with this id exists" } }
```

`code` is stable and meant for programs; `message` is meant for people and may change.

| Status | `code`                   | When                                                                                     |
|--------|--------------------------|------------------------------------------------------------------------------------------|
| 400    | `invalid_json`           | The request body is not valid JSON.                                                      |
| 400    | `bad_request`            | The request could not be understood (for example an invalid byte sequence in the path).  |
| 401    | `unauthorized`           | Missing, malformed or wrong bearer token.                                                |
| 404    | `not_found`              | No blob has this id, or no route matches the path.                                       |
| 406    | `not_acceptable`         | The `Accept` header cannot be parsed.                                                    |
| 409    | `conflict`               | A blob with this id already exists.                                                      |
| 413    | `payload_too_large`      | The decoded data, or the request body itself, exceeds the configured limit.              |
| 415    | `unsupported_media_type` | `POST /v1/blobs` without `Content-Type: application/json`, or a `Content-Type` header that cannot be parsed. |
| 422    | `validation_failed`      | A field is missing, has the wrong type, the id is invalid, or `data` is not valid Base64. |
| 500    | `internal_error`         | An unexpected error; details are logged server-side only.                                |
| 503    | `storage_unavailable`    | The storage backend failed (I/O error, S3 or FTP error, timeout) or cannot serve this blob. |

A request body larger than twice the body limit described under `data` below is refused by the
web server itself, before the application runs, with a plain-text `413` and a closed connection
(a client that keeps sending may see the connection reset instead).

## POST /v1/blobs

Stores a blob.

Headers: `Authorization: Bearer <token>`, `Content-Type: application/json`.

Body:

```json
{
  "id": "any_valid_string_or_identifier",
  "data": "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh"
}
```

Only the JSON body is read; query-string parameters are ignored.

### `id`

An opaque identifier chosen by the client. It is stored and compared exactly as sent
(case-sensitive, no normalisation) and is never interpreted as a path by the server.

- Required, a JSON string of 1 to 1024 bytes in UTF-8 (so the percent-encoded id always fits in
  a request path).
- Must not be blank and must not contain control characters (U+0000 to U+001F, U+007F).
- Anything else is allowed: UUIDs, slashes, dots, spaces, non-ASCII text.
- Must be unique; a second `POST` with the same id is rejected with `409`.

### `data`

The blob content, Base64-encoded (RFC 4648, standard alphabet, with padding).

- Required, a JSON string. An empty string stores a zero-byte blob.
- Line breaks, tabs and spaces are ignored before decoding, so the wrapped output of
  `Base64.encode64`, `base64(1)` or `openssl base64` is accepted.
- Everything else is strict: characters outside the alphabet, the URL-safe alphabet (`-`, `_`),
  a wrong length or wrong padding are rejected with `422`.
- The decoded size must not exceed `SIMPLE_DRIVE_MAX_BLOB_BYTES` (10 MiB by default), otherwise
  `413`. Request bodies larger than the Base64 form of that limit (plus a small allowance) are
  refused with `413` before they are parsed.

### Responses

`201 Created`:

```json
{ "id": "any_valid_string_or_identifier", "size": "27", "created_at": "2026-09-14T09:31:02Z" }
```

A request that fails never leaves a blob behind: nothing is recorded, and bytes that were
already written are deleted again. If the server process stops first, or that deletion fails, the
bytes are removed the next time the operator runs `bin/rails blobs:sweep_orphans` (see the README).

`size` is the decoded size in bytes, rendered as a string exactly as in the specification;
`created_at` is the UTC time the blob was recorded, in ISO 8601 with second precision.

Failure responses: `400`, `401`, `406`, `409`, `413`, `415`, `422`, `503` as described above.

## GET /v1/blobs/{id}

Retrieves a blob.

Headers: `Authorization: Bearer <token>`.

The id goes in the path, percent-encoded as a URL path component (JavaScript
`encodeURIComponent`, Ruby `ERB::Util.url_encode`, Python `urllib.parse.quote(id, safe="")`).
Interior single slashes may be left unencoded, so `GET /v1/blobs/photos/2024/sunrise.jpg`
retrieves the id `photos/2024/sunrise.jpg`. Ids with a leading, trailing or doubled slash,
or containing `?`, `#`, `%` or spaces, must be encoded (`/` as `%2F`) because the router
normalises the raw path before matching. No `.format` suffix is split off: `report.pdf` is
the id `report.pdf`.

### Responses

`200 OK`:

```json
{
  "id": "any_valid_string_or_identifier",
  "data": "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh",
  "size": "27",
  "created_at": "2026-09-14T09:31:02Z"
}
```

`data` is the exact stored bytes, Base64-encoded without line breaks.

Failure responses: `400`, `401`, `404` (unknown id), `406`, `503` (the backend failed, or the
blob was stored by a backend other than the one currently configured).

## Examples

```bash
curl -i -X POST http://localhost:3000/v1/blobs \
  -H "Authorization: Bearer $SIMPLE_DRIVE_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"id": "hello", "data": "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh"}'
```

```bash
curl -i http://localhost:3000/v1/blobs/hello \
  -H "Authorization: Bearer $SIMPLE_DRIVE_API_TOKEN"
```

Store a file and read it back:

```bash
printf '{"id": "photos/2024/sunrise.jpg", "data": "%s"}' "$(base64 -w0 sunrise.jpg)" |
  curl -s -X POST http://localhost:3000/v1/blobs \
    -H "Authorization: Bearer $SIMPLE_DRIVE_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @-

curl -s http://localhost:3000/v1/blobs/photos/2024/sunrise.jpg \
  -H "Authorization: Bearer $SIMPLE_DRIVE_API_TOKEN" | jq -r .data | base64 -d > copy.jpg
```
