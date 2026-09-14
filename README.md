# Simple Drive

Simple Drive is a small object storage service written in Ruby on Rails. Clients store a blob of
binary data under an identifier of their choosing and read it back later, through a JSON API
protected by a bearer token. Where the bytes actually live is a deployment decision: the same
API is served by a local directory, a database table, any S3-compatible service or an FTP
server, and the S3 integration speaks the S3 protocol directly over HTTP with a hand-written
Signature V4 signer rather than an SDK.

The API reference lives in [docs/API.md](docs/API.md).

## Contents

- [Architecture](#architecture)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Storage backends](#storage-backends)
- [How the S3 implementation works](#how-the-s3-implementation-works)
- [Running the application](#running-the-application)
- [Running the tests](#running-the-tests)
- [API overview](#api-overview)
- [Design decisions](#design-decisions)
- [Security considerations](#security-considerations)
- [Limitations and trade-offs](#limitations-and-trade-offs)

## Architecture

```text
HTTP request
   │
   ▼
Rack middleware ─ SimpleDrive::RequestBodyLimit (refuses oversized bodies before parsing)
   │
   ▼
V1::BlobsController ─ BearerAuthentication (401), JSON content type (415)
   │
   ▼
Blobs::Store / Blobs::Retrieve ─ validation, Base64, metadata row, consistency rules
   │
   ▼
Storage::Backend ─ write(key, data) / read(key) / delete(key)
   ├── Storage::LocalBackend      files below a configured directory
   ├── Storage::DatabaseBackend   the blob_contents table
   ├── Storage::S3Backend         Storage::S3::Client + Storage::S3::Signer over Net::HTTP
   └── Storage::FtpBackend        files on an FTP server through Net::FTP (bonus)
```

| Layer | Where | Responsibility |
|-------|-------|----------------|
| Controller | `app/controllers/v1/blobs_controller.rb` | Reads the JSON body, calls the application layer, renders the response. `ApplicationController` maps application errors to HTTP statuses. |
| Authentication | `app/controllers/concerns/bearer_authentication.rb` | Parses `Authorization: Bearer …` and compares the token in constant time. |
| Application layer | `app/services/blobs/` | `Blobs::Store` validates, decodes, writes to the backend and records metadata; `Blobs::Retrieve` loads metadata and reads the bytes back. Errors are plain Ruby classes in `app/services/blobs.rb`. |
| Storage abstraction | `app/services/storage.rb`, `app/services/storage/backend.rb` | The backend interface, the error classes and `Storage.backend`, which builds the configured backend from settings. |
| Backends | `app/services/storage/*_backend.rb`, `app/services/storage/s3/` | One class per backend; each translates its own failures into `Storage::Error` / `Storage::NotFound`. |
| Metadata | `app/models/blob.rb`, `db/migrate/…create_blobs.rb` | The tracking table: identifier, size, backend name, storage key, timestamps. Never holds blob bytes. |
| Database backend table | `app/models/blob_content.rb`, `db/migrate/…create_blob_contents.rb` | Storage key plus bytes. Independent of the metadata table. |
| Boot-time code | `lib/simple_drive/` | Settings validation, the shared JSON error shape, the body-size middleware and the JSON exceptions app. Required explicitly from `config/application.rb`. |

Everything above `Storage::Backend` deals only in opaque storage keys and the three-method
interface; switching backends is a configuration change and touches no controller or service.

## Requirements

- Ruby 3.4 (developed and tested with 3.4.10; see `.ruby-version`)
- Rails 8.1 (8.1.3.1 in `Gemfile.lock`), installed by Bundler
- SQLite 3, through the `sqlite3` gem (no separate server needed)
- Optional: Docker, to run MinIO (S3) and an FTP server locally for the integration tests

The Gemfile adds five gems to the Rails defaults: `dotenv-rails` (development/test, loads
`.env`), `webmock` and `minitest-mock` (test), `net-ftp` (Ruby's own FTP client, a bundled gem
that has to be declared) and a `json < 3` pin, because json 3.0 changed the signature of
`JSON.parse` in a way Active Support 8.1.3 does not handle yet.

## Installation

```bash
git clone https://github.com/ByAhmd/simple-drive-api.git
cd simple-drive-api
bin/setup --skip-server
```

`bin/setup` installs the gems, copies `.env.example` to `.env` if there is no `.env` yet, and
creates and migrates the SQLite database (`bin/rails db:prepare`). Then edit `.env` and set
`SIMPLE_DRIVE_API_TOKEN` to a real secret, for example the output of `bin/rails secret` or
`openssl rand -hex 32`.

Manual equivalent:

```bash
bundle install
cp .env.example .env        # then set SIMPLE_DRIVE_API_TOKEN
bin/rails db:prepare
```

The schema is created from `db/schema.rb` by `db:prepare` on a fresh database; running the
migrations in `db/migrate` against an empty database produces the same schema.

On Windows, run the scripts through Ruby (`ruby bin/setup --skip-server`,
`ruby bin/rails server`, `ruby bin/rails test`); PowerShell does not execute the shebang line.
Run `ruby bin/rails db:test:prepare` once before the first `ruby bin/rails test`: Rails prepares
the test database by invoking `bin/rails` itself, which only works where the shebang line does.

## Configuration

All settings come from environment variables, read through `config/simple_drive.yml` and
validated at boot by `SimpleDrive::Settings` and by the selected backend, so a missing or
malformed value stops the process with a message naming the variable rather than failing on
the first request. In development and test, `dotenv-rails` loads `.env` (ignored by git);
`.env.example` documents every variable with placeholder values.

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `SIMPLE_DRIVE_API_TOKEN` | yes | – | The bearer token clients must present (RFC 6750 characters: letters, digits, `-._~+/`, trailing `=`). |
| `STORAGE_BACKEND` | no | `local` | `local`, `database`, `s3` or `ftp`. |
| `SIMPLE_DRIVE_MAX_BLOB_BYTES` | no | `10485760` (10 MiB) | Largest accepted blob, in decoded bytes. Also sizes the request body limit. |
| `LOCAL_STORAGE_PATH` | for `local` | `storage/blobs` | Directory for blob files; relative paths resolve from the application root. |
| `S3_ENDPOINT` | for `s3` | – | `http(s)://host[:port]` of the S3-compatible service. |
| `S3_REGION` | for `s3` | `us-east-1` | Region used in the signature scope. |
| `S3_BUCKET` | for `s3` | – | Bucket name; the bucket must already exist. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | for `s3` | – | Credentials used to sign requests. |
| `S3_PATH_STYLE` | no | `true` | `true` for `http://host/bucket/key` (MinIO), `false` for `http://bucket.host/key` (AWS default). |
| `S3_KEY_PREFIX` | no | – | Optional prefix inside the bucket, e.g. `blobs`. Letters, digits, `.`, `_`, `-` and `/`. |
| `S3_TIMEOUT_SECONDS` | no | `30` | Read/write timeout per S3 request (connect timeout is 5 s). |
| `FTP_HOST`, `FTP_USERNAME`, `FTP_PASSWORD` | for `ftp` | – | FTP server and account. |
| `FTP_PORT` | no | `21` | Control connection port. |
| `FTP_ROOT_PATH` | no | login directory | Directory for blob files on the server; created if missing (one level). |
| `FTP_PASSIVE` | no | `true` | Passive mode, which works through NAT and container port mappings. |
| `FTP_TLS` | no | `false` | Explicit FTPS (`AUTH TLS`). |
| `FTP_TIMEOUT_SECONDS` | no | `30` | Read timeout per FTP operation (connect timeout is 5 s). |

Production additionally requires two standard Rails variables: `SECRET_KEY_BASE` (or
`RAILS_MASTER_KEY` for `config/credentials.yml.enc`) and `DATABASE_URL` (for example
`sqlite3:storage/production.sqlite3`; the generated `config/database.yml` leaves the production
database to the deployment). `RAILS_LOG_LEVEL`, `PORT` and `RAILS_MAX_THREADS` are optional.

The test environment does not read these variables: `config/simple_drive.yml` pins the test
token, the local backend, a temporary directory and a 1 MiB size limit, so a developer's
`.env` cannot change what the suite tests.

### Authentication

Every request to `/v1/...` must carry `Authorization: Bearer <token>`, where the token equals
`SIMPLE_DRIVE_API_TOKEN`. There is one token for the deployment, chosen by the operator; the
service neither issues nor stores tokens, which keeps the mechanism as simple as the
specification asks for. The comparison is constant-time
(`ActiveSupport::SecurityUtils.secure_compare`), the token is never logged, and a rejected
request gets `401` with a `WWW-Authenticate: Bearer realm="Simple Drive"` header.
Authentication is the first step in the controller, so an unauthenticated request never reaches
validation or storage; a malformed body without a valid token is answered `401`, not `400`.
Tokens are limited to the characters RFC 6750 allows (letters, digits, `-._~+/` and trailing
`=`), which is checked at boot so a token that could never match is not silently accepted. The
Rails health check at `/up` is the only unauthenticated route; it returns a plain status page
with no application data.

### Selecting the storage backend

Set `STORAGE_BACKEND` to `local`, `database`, `s3` or `ftp` and provide that backend's variables.
`Storage.backend` maps the name to a class and lets the class validate its own settings, so
an unknown name or a missing S3 credential is reported at boot. Each metadata row records which
backend stored it; if the configured backend later differs, `GET` answers `503` rather than
pretending the blob does not exist.

## Storage backends

### Local filesystem (`STORAGE_BACKEND=local`)

The only setting is `LOCAL_STORAGE_PATH`, the directory that holds the files (created on first
write). Files are named after the application-generated storage key, a UUID, and spread over
two levels of prefix directories (`storage/blobs/3f/9a/3f9a…`). Client identifiers never become
part of a path, so `../` or absolute paths in an id are simply characters in a string. Writes go
to a temporary sibling file that is renamed into place, so a crash cannot leave a truncated
object; all I/O is binary.

### Database table (`STORAGE_BACKEND=database`)

Bytes go into the `blob_contents` table (`storage_key`, `data` as a binary column, timestamps),
which is separate from the `blobs` metadata table and needs no extra configuration. There is
deliberately no foreign key between the two tables: `blob_contents` is one interchangeable place
bytes can live, and it is empty when another backend is in use.

### S3-compatible service (`STORAGE_BACKEND=s3`)

Works with AWS S3, MinIO, DigitalOcean Spaces, Linode Object Storage and anything else that
implements the S3 REST API with Signature Version 4. For MinIO started with the included
`compose.yaml`:

```dotenv
STORAGE_BACKEND=s3
S3_ENDPOINT=http://localhost:9000
S3_BUCKET=simple-drive
S3_ACCESS_KEY_ID=minioadmin
S3_SECRET_ACCESS_KEY=minioadmin
S3_PATH_STYLE=true
```

For AWS: `S3_ENDPOINT=https://s3.eu-west-1.amazonaws.com`, `S3_REGION=eu-west-1`,
`S3_PATH_STYLE=false`, plus the bucket and an access key limited to that bucket. Keep
`S3_PATH_STYLE=true` for bucket names that contain dots: with virtual-hosted `https` addressing
they do not match the service's wildcard certificate.

### FTP server (`STORAGE_BACKEND=ftp`, bonus)

`Storage::FtpBackend` uses Ruby's `Net::FTP`. Each object is one file named after its storage
key inside `FTP_ROOT_PATH` (created on first use when missing). A connection is opened per
operation, transfers are binary, uploads go to a temporary name and are renamed into place, and
passive mode is on by default. A `550` reply to a download is reported as "no object" because
FTP does not distinguish a missing file from an unreadable one. With the server from
`compose.yaml`:

```dotenv
STORAGE_BACKEND=ftp
FTP_HOST=localhost
FTP_PORT=2121
FTP_USERNAME=drive
FTP_PASSWORD=drivepass
FTP_ROOT_PATH=blobs
```

## How the S3 implementation works

No S3 library is involved; `Storage::S3::Client` uses Ruby's `Net::HTTP` and
`Storage::S3::Signer` implements AWS Signature Version 4 from the protocol description.

For every request the client:

1. Builds the object URL: `endpoint/bucket/key` (path style) or `bucket.endpoint/key`
   (virtual-hosted style). The key is URI-encoded once with the S3 rules (unreserved characters
   and `/` untouched, everything else as uppercase `%XX`), and that encoded path is both what is
   sent and what is signed.
2. Hashes the body with SHA-256 and sets `x-amz-content-sha256` to the hex digest (the hash of
   the empty string for GET and DELETE), sets `x-amz-date` (`YYYYMMDDTHHMMSSZ`) and `Host`
   (including the port when it is not the scheme's default, since S3 signs exactly what is sent).
3. Asks the signer for the `Authorization` header. The signer canonicalises the request (method,
   encoded path, sorted query string, lowercased and trimmed headers, the signed header list and
   the payload hash), hashes it into the string to sign together with the date and the scope
   `date/region/s3/aws4_request`, derives the signing key with the HMAC chain
   `AWS4<secret> → date → region → s3 → aws4_request`, and returns
   `AWS4-HMAC-SHA256 Credential=…, SignedHeaders=…, Signature=…`.
4. Sends `PUT` (upload, `Content-Type: application/octet-stream`), `GET` (download) or `DELETE`
   with a 5-second connect timeout and the configured read/write timeout, verifying TLS
   certificates for `https` endpoints. A response body shorter than its `Content-Length` is an
   error, never a truncated blob.

`Storage::S3Backend` interprets the responses: any 2xx is success; a `404` whose XML error code
is `NoSuchKey` means the object is absent (`Storage::NotFound`); every other status (403
`AccessDenied`, 404 `NoSuchBucket`, 301 redirects to another region, 5xx) and every transport
failure (timeouts, DNS errors, refused connections, TLS errors) becomes a `Storage::Error`
whose message carries only the HTTP status, the S3 error code and the request id, never the
credentials or the signature. Net::HTTP's built-in single retry of an idempotent request on a
dropped connection is kept (every operation here is idempotent, because keys are never reused);
there are no application-level retries, and a failed store leaves no metadata, so the client can
simply retry the whole request.

The signer is verified against the four worked examples in the Amazon S3 API reference (GET
Object, PUT Object, GET Bucket Lifecycle, List Objects), the client against stubbed HTTP with
WebMock, and the whole backend against a real MinIO server in the opt-in integration tests.

## Running the application

```bash
bin/rails server          # http://localhost:3000, uses .env in development
```

With environment variables set directly:

```bash
SIMPLE_DRIVE_API_TOKEN=change-me STORAGE_BACKEND=local LOCAL_STORAGE_PATH=/srv/simple-drive bin/rails server
```

```powershell
$env:SIMPLE_DRIVE_API_TOKEN = "change-me"; ruby bin/rails server
```

To try the S3 or FTP backend locally, start the servers first: `docker compose up -d` brings
up MinIO on port 9000 (creating the `simple-drive` and `simple-drive-test` buckets) and an FTP
server on port 2121 (user `drive`, password `drivepass`); then use the values shown above.

## Running the tests

```bash
bin/rails test
```

The suite (Minitest, `test/`) covers:

- models: validations and the database constraints (unique identifier and storage key,
  non-negative size, binary round trip in `blob_contents`);
- `test/support/storage_backend_contract.rb`: the behaviour every backend must share (every
  byte value, empty and large objects, isolation by key, not-found and delete semantics), run
  against the local, database, S3 and FTP backends;
- the local backend (directory layout, atomic writes, rejection of non-UUID keys, filesystem
  errors) and the database backend (separate table, error translation);
- the SigV4 signer against the official AWS example vectors, and the S3 backend against
  stubbed HTTP: request shape, recomputable signatures, both addressing styles, key prefixes,
  binary bodies, 404/403/5xx/redirect handling, timeouts and refused connections;
- the FTP backend against an in-memory stand-in for `Net::FTP` that answers like a real server
  (temporary name and rename, root creation, 550 handling, error translation, connection
  options, credentials kept out of messages);
- `Blobs::Store` and `Blobs::Retrieve`: strict Base64, type checks, size limits, duplicate ids,
  the race on the unique index and the cleanup that follows, backend failures, backend mismatch;
- the settings object, the body-size middleware and the exceptions app;
- request tests for authentication, both endpoints, every error the API layer produces (the
  generic `400` and `500` fallbacks are covered by the exceptions-app tests), binary fidelity,
  path-like identifiers, the size limits, and the same conversation against each backend.

Static analysis and dependency checks: `bin/rubocop`, `bin/brakeman`, `bin/bundler-audit`, or
all of them plus the tests with `bin/ci` (which drives the other scripts through the shell, so
it is for Linux and macOS). The GitHub Actions workflow in `.github/workflows/ci.yml`
runs the same set and starts MinIO and an FTP server so both integration suites run there too.

### Running the S3 integration tests

They are skipped unless `S3_TEST_ENDPOINT` is set, so the suite never needs a network or an
account. With MinIO from `compose.yaml`:

```bash
docker compose up -d
S3_TEST_ENDPOINT=http://localhost:9000 S3_TEST_BUCKET=simple-drive-test \
S3_TEST_ACCESS_KEY_ID=minioadmin S3_TEST_SECRET_ACCESS_KEY=minioadmin bin/rails test
```

`S3_TEST_REGION` (default `us-east-1`) and `S3_TEST_PATH_STYLE` (default `true`) can be set to
point the same tests at another S3-compatible service. The variables are deliberately distinct
from the application's `S3_*` variables so that a developer's `.env` can never make the test
suite talk to a real bucket. The tests write under the `integration-tests/` prefix of the bucket.

### Running the FTP integration tests

Skipped unless `FTP_TEST_HOST` is set. With the server from `compose.yaml`:

```bash
FTP_TEST_HOST=localhost FTP_TEST_PORT=2121 FTP_TEST_USERNAME=drive FTP_TEST_PASSWORD=drivepass bin/rails test
```

The tests use the `integration-tests` directory below the account's login directory.

## API overview

Full details, including every error, are in [docs/API.md](docs/API.md).

Store a blob:

```bash
curl -X POST http://localhost:3000/v1/blobs \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "hello",
    "data": "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh"
  }'
```

```json
{ "id": "hello", "size": "27", "created_at": "2026-09-14T09:31:02Z" }
```

Retrieve it:

```bash
curl http://localhost:3000/v1/blobs/hello -H "Authorization: Bearer YOUR_TOKEN"
```

```json
{
  "id": "hello",
  "data": "SGVsbG8gU2ltcGxlIFN0b3JhZ2UgV29ybGQh",
  "size": "27",
  "created_at": "2026-09-14T09:31:02Z"
}
```

Errors always look like `{ "error": { "code": "...", "message": "..." } }`:

| Status | Code | Meaning |
|--------|------|---------|
| 400 | `invalid_json` / `bad_request` | Body is not JSON / request cannot be understood |
| 401 | `unauthorized` | Missing or wrong bearer token |
| 404 | `not_found` | Unknown id or route |
| 409 | `conflict` | Id already stored |
| 413 | `payload_too_large` | Blob or request body above the limit |
| 415 | `unsupported_media_type` | `POST` without `Content-Type: application/json` |
| 422 | `validation_failed` | Missing/invalid `id` or `data`, invalid Base64 |
| 500 | `internal_error` | Unexpected error (details only in the log) |
| 503 | `storage_unavailable` | Backend failure, timeout, or blob stored by another backend |

## Design decisions

**Identifiers are opaque; storage keys are generated.** The specification says the id "should
not have any meaning or semantics", and an id used as a file or object name would acquire
exactly that (plus path traversal risks). So every blob gets a random UUID storage key, recorded
in the metadata row, and that key is the only thing backends ever see. Backends still validate
the key format before deriving a path or object name, as defence in depth. The cost is one
indirection on `GET`; the benefit is that the local backend cannot be escaped by construction
and that concurrent uploads of the same id can never write over each other.

**Write first, claim the id second.** `Blobs::Store` writes the bytes to the backend and only
then inserts the metadata row. A metadata row can therefore never point at bytes that were not
stored. The unique index on `blobs.identifier` is the arbiter between concurrent requests for the
same id: exactly one insert succeeds, the loser deletes the object it wrote and answers `409`.
A cheap existence check before the upload spares the backend the work in the common case. No
database transaction is held across a backend write, so a slow S3 upload never blocks other
writers (SQLite allows a single writer at a time). The accepted gap: if the process dies between
the write and the insert, an orphaned object with no metadata remains; it is harmless, invisible
to the API and can be reclaimed by comparing storage keys with the metadata table.

**Uniqueness is enforced by the database, not by a Rails validation.** An Active Record
uniqueness validation is racy and would turn a lost race into a validation error; the unique
index cannot be bypassed, and `RecordNotUnique` is mapped to `409`.

**Base64 is decoded strictly, with one concession.** `Base64.strict_decode64` rejects any
non-alphabet character, wrong length or wrong padding, so a body that is not Base64 is refused
as the specification requires (lenient decoding would silently accept garbage). Line breaks and
spaces are removed before decoding because MIME-style encoders (`Base64.encode64`, `base64(1)`,
`openssl base64`) wrap their output, and whitespace carries no data, so accepting it is
unambiguous. Responses always use unwrapped Base64.

**`size` is a JSON string.** The specification's example renders it as `"27"`, so the API does
the same rather than second-guessing the contract; changing it to a number is a one-line edit in
the controller.

**Status codes.** Malformed JSON is `400`; a well-formed body whose content is unacceptable
(missing field, wrong type, invalid id, invalid Base64) is `422`; too much data is `413`; a
duplicate id is `409`; storage failures are `503` with a fixed message, because the request may
succeed later and the client must not learn anything about the backend.

**Errors are JSON everywhere.** Controllers map application errors with `rescue_from`;
`SimpleDrive::ExceptionsApp` (Rails' `config.exceptions_app`) handles what escapes them
(malformed JSON, unknown routes, unexpected exceptions) so no HTML page is ever returned. The
test environment renders errors the production way (`consider_all_requests_local = false`) so
request tests assert the real contract. Programming errors are not rescued; they surface as
`500` in production and as failures in tests.

**Request size is bounded twice.** `SimpleDrive::RequestBodyLimit` refuses a body whose
`Content-Length` exceeds the Base64 form of the largest blob (plus room for line breaks, the id
and JSON syntax) before Rails parses it, answering with the API's JSON shape; Puma's
`http_content_length_limit` is set to twice that number, so bodies between the two limits still
get the JSON error while anything larger, or an endless chunked upload, is cut off while it is
still arriving. Both derive from `SIMPLE_DRIVE_MAX_BLOB_BYTES`.

**Metadata table.** `blobs` has a surrogate primary key and a unique `identifier` column
(up to 1024 characters), the decoded `size` with a non-negative check constraint, the backend
name, the unique storage key and timestamps. The `created_at` returned by the API is this row's
timestamp in UTC.

**Configuration.** `config/simple_drive.yml` with `config_for` is the Rails convention for
application settings; wrapping the result in `SimpleDrive::Settings` gives typed access and one
place where every variable is validated and named. Boot-time code lives in `lib/` and is
required explicitly because it is needed while the application is still being configured.

## Security considerations

- **Secrets** (the API token, S3 credentials) come only from the environment; `.env*` files are
  ignored by git (except `.env.example`, which holds placeholders) and `config/master.key` is
  ignored as generated. Nothing in the repository is a real credential.
- **Authentication** is enforced by a `before_action` in `ApplicationController`, so every
  controller inherits it; the token comparison is constant-time and malformed headers are rejected.
- **Logging** never includes the token (Rails does not log request headers, and the parameter
  filter covers anything named `token`) nor blob contents (`data` is added to
  `filter_parameters`, so request logs show `[FILTERED]` instead of payloads). Storage errors are
  logged with their backend message, which never includes credentials.
- **Path traversal** is impossible: ids never touch the filesystem, keys are UUIDs validated
  against a strict pattern, and files always live under the configured root.
- **SQL** goes through Active Record's parameterised queries; there is no string interpolation
  into SQL anywhere.
- **XSS** does not apply: the application renders JSON only and never HTML, and client-supplied
  strings are returned inside JSON with proper escaping.
- **Uploaded data** is treated as opaque bytes: it is decoded, sized, stored and re-encoded, never
  interpreted or executed.
- **Resource limits**: decoded blob size, Base64-aware request body limit in Rack and in Puma,
  strict id length, S3 connect/read/write timeouts. Put a reverse proxy with its own body limit in
  front of the service in production, as for any Rails application.
- **Transport**: production has `force_ssl` and `assume_ssl` on (Rails 8 defaults), so the token
  is only ever sent over HTTPS behind a TLS-terminating proxy; S3 connections verify certificates.
- **API-only stack**: no sessions, cookies or CSRF surface; no CORS middleware is installed, so
  browsers cannot call the API cross-origin unless an operator adds `rack-cors` deliberately.
- **Error responses** carry fixed messages; stack traces, paths, S3 endpoints and signatures stay
  in the server log. Debug output is limited to `development`.
- **Host authorization**: set `config.hosts` in `config/environments/production.rb` to the public
  hostname when deploying, as the generated comment suggests.
- Static analysis (`bin/brakeman`) and the dependency audit (`bin/bundler-audit`) run in CI
  and report nothing.

## Limitations and trade-offs

- **Single token.** One shared secret for the whole deployment, per the "keep it simple"
  instruction. Rotating it means restarting with a new value; there are no per-client tokens.
- **Blobs are handled in memory.** A request's Base64 text, the decoded bytes and the S3
  response body are all buffered; this is fine at the default 10 MiB limit and simple to reason
  about, but the design would need streaming for very large objects.
- **No listing, overwrite or delete endpoints.** The specification defines store and retrieve
  only; ids are immutable once stored.
- **No application-level retries** against S3 or FTP beyond Net::HTTP's single retry of an
  idempotent request on a dropped connection; a failed store leaves no trace and the client
  retries the whole request.
- **Orphaned objects** can remain after a crash between the backend write and the metadata
  insert (see Design decisions); they never affect API behaviour.
- **Switching backends does not move data.** Blobs stored by a previous backend answer `503`
  until that backend is configured again or the data is migrated.
- **SQLite** is the default database: single-writer, file-based, appropriate for this scope.
  The schema uses portable types and constraints, so PostgreSQL is a `database.yml` change away;
  MySQL would additionally need a shorter unique index on `identifier` and a `longblob` column
  for `blob_contents.data`.
- **Bodies without `Content-Length`** are not caught by the Rack middleware; Puma's
  `http_content_length_limit` covers chunked uploads at the server level, and the decoded size
  check always applies.
- **Identifiers with a leading, trailing or doubled slash** must be percent-encoded in `GET`
  URLs because the router normalises the path; interior single slashes work unencoded.
- **Puma on Windows** runs in single-process mode; MinIO's community container images are
  frozen at the pinned release used in `compose.yaml` and CI.
- **FTP** is plain FTP unless `FTP_TLS` enables explicit FTPS; a `550` reply on download
  (missing or unreadable file) surfaces as `503` on `GET`, and `FTP_ROOT_PATH` is created one
  level deep only.
