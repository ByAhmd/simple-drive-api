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
- [Cleaning up interrupted uploads](#cleaning-up-interrupted-uploads)
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
| Upload journal | `app/models/pending_upload.rb`, `app/services/blobs/sweep_orphans.rb`, `lib/tasks/blobs.rake` | One row per upload in progress, so that bytes left behind by an interrupted upload can be found and removed. |
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

Every command that loads the application, including `bin/rails console` and the rake tasks, needs
`SIMPLE_DRIVE_API_TOKEN`, so run `bin/setup` or create `.env` first; otherwise the command stops with
`SIMPLE_DRIVE_API_TOKEN must be set`.

On Windows, run the scripts through Ruby (`ruby bin/setup --skip-server`,
`ruby bin/rails server`, `ruby bin/rails test`); PowerShell does not execute the shebang line.
Run `ruby bin/rails db:test:prepare` once before the first `ruby bin/rails test`: Rails prepares
the test database by invoking `bin/rails` itself, which only works where the shebang line does.

## Configuration

All settings come from environment variables, read through `config/simple_drive.yml` and
validated at boot by `SimpleDrive::Settings` and by the selected backend, so a missing or
malformed value stops the process with a message naming the variable rather than failing on
the first request. A variable that is set but empty gets its default, like one that is unset.
In development and test, `dotenv-rails` loads `.env` (ignored by git); `.env.example` documents
every variable with placeholder values.

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
| `S3_TIMEOUT_SECONDS` | no | `30` | Read/write timeout per S3 request, which is never retried (connect timeout is 5 s). |
| `FTP_HOST`, `FTP_USERNAME`, `FTP_PASSWORD` | for `ftp` | – | FTP server and account. |
| `FTP_PORT` | no | `21` | Control connection port (1-65535). |
| `FTP_ROOT_PATH` | no | login directory | Directory for blob files on the server; created if missing (one level). |
| `FTP_PASSIVE` | no | `true` | Passive mode, which works through NAT and container port mappings. |
| `FTP_TLS` | no | `false` | Explicit FTPS (`AUTH TLS`). |
| `FTP_TIMEOUT_SECONDS` | no | `30` | Read timeout per FTP operation (connect timeout is 5 s). |

Production additionally requires two standard Rails variables: `SECRET_KEY_BASE` (for example
the output of `bin/rails secret`) and `DATABASE_URL` (for example
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
validation or storage, and a body that is not valid JSON is answered `401`, not `400`, when the
token is missing or wrong. A few requests are refused before the controller runs, whatever the
token: an oversized body (`413`), an unparsable `Content-Type` (`415`) or `Accept` (`406`)
header, a path or body that is not valid UTF-8 or percent-encoding (`400`), and a path with no
route (`404`). None of these returns data. Tokens are limited to the characters RFC 6750 allows
(letters, digits, `-._~+/` and trailing `=`), which is checked at boot so a token that could
never match is not silently accepted. There is no unauthenticated route: the health check that
`rails new` adds at `/up` has been removed, because the specification requires every request to
be authenticated.

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
S3_ENDPOINT=http://127.0.0.1:9000
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
FTP does not distinguish a missing file from an unreadable one; any other error reply is reported
as a storage failure. With the server from `compose.yaml`:

```dotenv
STORAGE_BACKEND=ftp
FTP_HOST=127.0.0.1
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
   certificates for `https` endpoints. It asks for `Accept-Encoding: identity`, so the stored
   bytes are never compressed and inflated on the way, and a response body shorter than its
   `Content-Length` is an error, never a truncated blob.

`Storage::S3Backend` interprets the responses: any 2xx is success; a `404` whose XML error code
is `NoSuchKey` means the object is absent (`Storage::NotFound`); every other status (403
`AccessDenied`, 404 `NoSuchBucket`, 301 redirects to another region, 5xx) and every transport
failure (timeouts, DNS errors, refused connections, TLS errors, malformed responses) becomes a
`Storage::Error`. Its message, which goes to the log and never to the client, carries the HTTP
status, the S3 error code and the request id, or for a transport failure the exception and its
message (which name the endpoint), never the credentials or the signature. Requests are not
retried: Net::HTTP's automatic retry is switched off, so `S3_TIMEOUT_SECONDS` really bounds each
operation and an upload is never sent twice. A failed store leaves no metadata, so the client can
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
server on port 2121 (user `drive`, password `drivepass`); then use the values shown above. Both
listen on `127.0.0.1` only, so use that address rather than `localhost`, which some systems
(Windows among them) try over IPv6 first, adding about two seconds to every connection.

To use the storage layer directly from Ruby, whatever backend is configured:

```bash
bin/rails console
```

```ruby
backend = Storage.backend
key = Storage::Backend.generate_key
backend.write(key, "hello".b)
backend.read(key)   # => "hello"
backend.delete(key)
```

## Cleaning up interrupted uploads

If the process stops between writing a blob's bytes and recording its metadata (a crash, a
deployment that kills the server), the bytes stay in storage with no blob pointing at them. They
are never visible through the API, and every such upload is recorded in the `pending_uploads`
table. This task deletes them:

```bash
bin/rails blobs:sweep_orphans
```

It only touches uploads older than `OLDER_THAN_MINUTES` (default `60`), so requests still in
progress are never affected, and it never deletes bytes that a blob points to. It works on the
configured backend and reports rows that belong to other backends. Run it on a schedule, for
example hourly from cron:

```bash
0 * * * * cd /srv/simple-drive && bin/rails blobs:sweep_orphans
```

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
- the local backend (directory layout, atomic writes and cleanup after a failed rename, rejection
  of non-UUID keys, filesystem errors) and the database backend (separate table, error
  translation on every operation);
- the SigV4 signer against the official AWS example vectors, and the S3 backend against
  stubbed HTTP: request shape, recomputable signatures, both addressing styles, key prefixes,
  binary bodies, 404/403/5xx/redirect handling, truncated and malformed responses, applied
  timeouts without retries, and refused connections;
- the FTP backend against an in-memory stand-in for `Net::FTP` that answers like a real server
  (temporary name and rename, root creation including a concurrent one, 550 versus other error
  replies, error translation, connection options, credentials kept out of messages);
- `Blobs::Store` and `Blobs::Retrieve`: strict Base64, type checks, size limits, duplicate ids,
  the race on the unique index and the cleanup that follows, backend failures, backend mismatch,
  and a simulated crash between writing and recording;
- the orphan sweep and its rake task: stale uploads removed, uploads in progress and referenced
  bytes left alone, failed deletions retried, run against every backend;
- the settings object and the real `config/simple_drive.yml` rendering, the body-size
  middleware and the exceptions app;
- request tests for authentication, both endpoints, every error the API layer produces (the
  generic `400` and `500` fallbacks are covered by the exceptions-app tests), binary fidelity,
  path-like identifiers, the size limits, and the same conversation against each backend.

Static analysis and dependency checks: `bin/rubocop`, `bin/brakeman`, `bin/bundler-audit`, or
all of them plus the tests with `bin/ci` (which drives the other scripts through the shell, so
it is for Linux and macOS). The GitHub Actions workflow in `.github/workflows/ci.yml`
runs the same set and starts MinIO and an FTP server so both integration suites run there too.

### Running every test, with no skips

Without the environment variables below, the S3 and FTP integration tests are skipped (17 skips).
To run everything, start MinIO and the FTP server with Docker, then set both groups of variables:

```bash
docker compose up -d
```

```bash
S3_TEST_ENDPOINT=http://127.0.0.1:9000 S3_TEST_BUCKET=simple-drive-test S3_TEST_ACCESS_KEY_ID=minioadmin S3_TEST_SECRET_ACCESS_KEY=minioadmin FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=2121 FTP_TEST_USERNAME=drive FTP_TEST_PASSWORD=drivepass bin/rails test
```

In PowerShell:

```powershell
$env:S3_TEST_ENDPOINT="http://127.0.0.1:9000"; $env:S3_TEST_BUCKET="simple-drive-test"; $env:S3_TEST_ACCESS_KEY_ID="minioadmin"; $env:S3_TEST_SECRET_ACCESS_KEY="minioadmin"; $env:FTP_TEST_HOST="127.0.0.1"; $env:FTP_TEST_PORT="2121"; $env:FTP_TEST_USERNAME="drive"; $env:FTP_TEST_PASSWORD="drivepass"; ruby bin/rails test
```

### Running the S3 integration tests

They are skipped unless `S3_TEST_ENDPOINT` is set, so the suite never needs a network or an
account. With MinIO from `compose.yaml`:

```bash
docker compose up -d
S3_TEST_ENDPOINT=http://127.0.0.1:9000 S3_TEST_BUCKET=simple-drive-test \
S3_TEST_ACCESS_KEY_ID=minioadmin S3_TEST_SECRET_ACCESS_KEY=minioadmin bin/rails test
```

`S3_TEST_REGION` (default `us-east-1`) and `S3_TEST_PATH_STYLE` (default `true`) can be set to
point the same tests at another S3-compatible service. The variables are deliberately distinct
from the application's `S3_*` variables so that a developer's `.env` can never make the test
suite talk to a real bucket. The tests write under the `integration-tests/` prefix of the bucket.

### Running the FTP integration tests

Skipped unless `FTP_TEST_HOST` is set. With the server from `compose.yaml`:

```bash
FTP_TEST_HOST=127.0.0.1 FTP_TEST_PORT=2121 FTP_TEST_USERNAME=drive FTP_TEST_PASSWORD=drivepass bin/rails test
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

Errors from the application always look like `{ "error": { "code": "...", "message": "..." } }`:

| Status | Code | Meaning |
|--------|------|---------|
| 400 | `invalid_json` / `bad_request` | Body is not JSON / request cannot be understood |
| 401 | `unauthorized` | Missing or wrong bearer token |
| 404 | `not_found` | Unknown id or route |
| 406 | `not_acceptable` | Unparsable `Accept` header |
| 409 | `conflict` | Id already stored |
| 413 | `payload_too_large` | Blob or request body above the limit |
| 415 | `unsupported_media_type` | `POST` without `Content-Type: application/json`, or an unparsable `Content-Type` |
| 422 | `validation_failed` | Missing/invalid `id` or `data`, invalid Base64 |
| 500 | `internal_error` | Unexpected error (details only in the log) |
| 503 | `storage_unavailable` | Backend failure, timeout, or blob stored by another backend |

A request body larger than twice the documented limit never reaches the application: Puma answers
with a plain-text `413` and closes the connection (a client that keeps sending may see the
connection reset instead).

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
writers (SQLite allows a single writer at a time).

**Interrupted uploads are journaled, not guessed.** Without distributed transactions, a process
that dies after writing the bytes but before inserting the blob leaves an orphaned object. So
`Blobs::Store` records a `pending_uploads` row before it writes and deletes that row in the same
transaction that inserts the blob. A row that outlives its request therefore names exactly the
objects that may be orphaned, including the bytes of a failed store whose cleanup also failed and
of an S3 upload that timed out after the server had stored it. `bin/rails blobs:sweep_orphans`
deletes them; no backend needs a "list everything" operation. The cost is two small SQL statements
per upload.

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
(malformed JSON, unknown routes, unparsable headers, unexpected exceptions) so no HTML page is
ever returned. Every environment renders errors this way (`consider_all_requests_local = false`
in development and test too), so a developer sees the contract clients get and request tests
assert it; the details go to the log. Programming errors are not rescued; they surface as `500`
and as failures in tests. The only non-JSON error is Puma's own `413` for a body far above the
limit.

**Request size is bounded twice.** `SimpleDrive::RequestBodyLimit` refuses a body whose
`Content-Length` exceeds the Base64 form of the largest blob (plus room for JSON-escaped line
breaks, the id and JSON syntax) before Rails parses it, answering with the API's JSON shape; Puma's
`http_content_length_limit` is set to twice that number, so bodies between the two limits still
get the JSON error while anything larger, or an endless chunked upload, is cut off while it is
still arriving. Both derive from `SIMPLE_DRIVE_MAX_BLOB_BYTES`.

**Metadata table.** `blobs` has a surrogate primary key and a unique `identifier` column
(up to 1024 bytes, so that the percent-encoded id always fits within Puma's 8192-byte request
path), the decoded `size` with a non-negative check constraint, the backend name, the unique
storage key and timestamps. The `created_at` returned by the API is this row's
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
  filter covers anything named `token`). Blob contents are not logged for well-formed requests:
  `data` is in `filter_parameters`, so request logs show `[FILTERED]`, and binary SQL values are
  logged as a byte count. For a body that is not valid JSON, Rails logs a short excerpt of it
  with the parse error, and the whole body at `debug` level, so do not run production with
  `RAILS_LOG_LEVEL=debug`. Storage errors are logged with their backend message, which never
  includes credentials.
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
  in the server log. Rails' debug error pages are switched off in every environment.
- **Host authorization**: not needed locally, where Rails allows `localhost`. When deploying, set
  `config.hosts` in `config/environments/production.rb` to the public hostname, as the generated
  comment suggests; that blocks DNS rebinding, which matters less here because every request also
  needs the token.
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
- **No retries** against S3 or FTP; a failed store leaves no trace and the client retries the
  whole request.
- **Orphaned objects** can exist between a crash and the next run of
  `bin/rails blobs:sweep_orphans` (see Design decisions). They are never visible through the
  API; scheduling the task is up to the operator.
- **No rate limiting.** The specification does not ask for it, and with one shared token a
  per-client limit would mean nothing. Put the service behind a reverse proxy or API gateway that
  limits requests, or use Rails' built-in `rate_limit` if it is ever needed.
- **Switching backends does not move data.** Blobs stored by a previous backend answer `503`
  until that backend is configured again or the data is migrated.
- **SQLite** is the default database: single-writer, file-based, appropriate for this scope.
  The schema uses portable types and constraints, so PostgreSQL needs only the `pg` gem and a
  `database.yml` change; MySQL would additionally need a shorter unique index on `identifier`
  (InnoDB keys are limited to 3072 bytes) and a `longblob` column for `blob_contents.data`.
- **Oversized requests** above twice the body limit are refused by Puma with a plain-text `413`
  (or a connection reset, for a client that keeps sending) instead of the JSON error shape.
  Chunked uploads are de-chunked by Puma, so the JSON `413` from the Rack middleware applies to
  them like to any other body.
- **Identifiers with a leading, trailing or doubled slash** must be percent-encoded in `GET`
  URLs because the router normalises the path; interior single slashes work unencoded.
- **Puma on Windows** runs in single-process mode; MinIO's community container images are
  frozen at the pinned release used in `compose.yaml` and CI.
- **FTP** is plain FTP unless `FTP_TLS` enables explicit FTPS; a `550` reply on download
  (missing or unreadable file) surfaces as `503` on `GET`, and `FTP_ROOT_PATH` is created one
  level deep only.
