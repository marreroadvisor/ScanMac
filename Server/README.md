# ScanMac private server

Python 3.9 or newer; standard library only. This is a separate private service you control, with account authentication and versioned document storage. It does not connect to CamScanner accounts or infrastructure.

From this directory, run:

```sh
python3 server.py --host 127.0.0.1 --port 8765 --data-dir ./data
```

The address is local to this Mac. To stop, press Control-C. The native app may launch the same command with its own private data directory after an explicit Start action. `GET http://127.0.0.1:8765/health` returns `{"status":"ok","service":"ScanMacPrivate","api_version":1}`. No account is created until you explicitly register through the app or API. Test accounts exist only in temporary test storage.

Run automated tests:

```sh
python3 -m unittest -v
```

Tests bind an ephemeral loopback port, use synthetic PDF bytes and a temporary SQLite database, then shut down and remove their storage.

## API

JSON bodies require `Content-Type: application/json` and `Content-Length`. Dates inside `record` use the native Swift `JSONEncoder` numeric dates (seconds since 2001-01-01); service expiration timestamps use Unix seconds since 1970-01-01. Document identifiers are canonical UUID strings, returned uppercase. All errors return `{"error":"message"}`. Routes other than registration, login, health, and public share reads require `Authorization: Bearer <token>`.

| Request | Body | Success |
| --- | --- | --- |
| `POST /v1/register` | `{username,password}` | 201 `{token,expires_at,username}` |
| `POST /v1/login` | `{username,password}` | 200 `{token,expires_at,username}` |
| `GET /v1/documents` | — | 200 `{documents:[{record,version}]}` |
| `GET /v1/documents/{UUID}` | — | 200 `{record,pdf_base64,version}` |
| `PUT /v1/documents/{UUID}` | `{record,pdf_base64,expected_version}` | 200 `{record,version}` |
| `POST /v1/shares` | `{document_id,expires_hours}` | 201 `{url_path,expires_at}` |
| `GET /s/{token}` | — | PDF bytes; 404 after expiration |

Registration accepts usernames of 3–64 ASCII letters, digits, underscores, dots or dashes, normalized lowercase. Passwords must contain 10–1024 characters. Tokens expire after 30 days. Sign in again to obtain another token. Passwords are stored as salted PBKDF2-HMAC-SHA256 hashes with 600,000 iterations; token and share secrets are stored as SHA256 hashes.

`record` contains `id`, `name`, numeric `date`, Boolean `starred`, string `text`, and optional `folder`, `tags`, `trashedAt`, `signed`, `updatedAt`. Unknown fields are retained. Set `expected_version` to zero on the first upload. Each successful upload increments the version; a stale expected version returns 409 with `current_version`. The original PDF and metadata remain in the `versions` table. Every read and write uses the authenticated account identity; the same UUID can exist independently in different accounts. There is no permanent-delete endpoint; use `trashedAt` metadata.

The native app now offers 1 hour, 1 day, 7 days or 30 days expiration (default 30 days); the API default remains 24 hours.

Shares are read-only snapshots of the document revision when created, with expiration greater than zero and at most 720 hours (default 24). Anyone possessing the share URL can read that snapshot until it expires. Changing the document does not change an existing share. A loopback share URL works only on the same Mac; it is not a public internet link.

## Storage and limits

SQLite transactions serialize revision checks and writes. Original PDF revisions remain available in the database; the current API exposes the latest revision. Back up the entire data directory while the service is stopped, including SQLite WAL files if present. Protect that directory: PDF files are not encrypted at rest by this service. FileVault or an encrypted volume can protect storage independently.

Uploads allow at most 30 MiB of decoded PDF data; JSON requests allow 42 MiB, authentication/share requests 8 KiB. PDF header validation rejects obvious non-PDF uploads; it does not validate every internal PDF structure. Socket operations time out after 15 seconds, database lock waits after 10 seconds, and at most 16 request threads run concurrently. Requests, passwords, tokens, share paths and bodies are not logged by the service. Exceptions return generic errors without traces. Thread slots exceeding the limit are closed rather than queued indefinitely.

## Optional remote deployment

Local operation is the default and needs no public deployment. For another device to connect, explicitly configure a TLS reverse proxy such as Caddy or nginx on a host you control; proxy to `127.0.0.1:8765`. Keep the Python service on loopback, require HTTPS externally, configure body limits and timeouts compatible with the limits above, and add proxy-level rate limits for login/registration. Restrict who can reach registration using your firewall, VPN or proxy access rules: registration is enabled for any client that can reach this service. Disable or redact proxy access logs for `/s/` because the path contains a share credential. Do not send passwords or bearer tokens over plaintext networks. Setting `--host` to a non-loopback address is an explicit operator action and does not add TLS.

This private backend has no email verification, password reset, admin console, multi-instance database coordination, end-to-end encryption, or production abuse controls. No public endpoint is deployed by this package.
