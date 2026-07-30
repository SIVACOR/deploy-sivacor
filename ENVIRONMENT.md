# `.env` reference

`make dev` sources `./.env` before deploying the `wt` stack and before running
`setup_girder.py`. The file is git-ignored; this is the tracked list of what it
has to contain.

## Required

| Variable | Purpose |
|---|---|
| `domain` | Public domain, e.g. `sivacor.org`. Used for every Traefik host rule and for `worker.api_url`. |
| `docker_group` | Host GID of the `docker` group, for `GOSU_USER`. **Differs per host** — `getent group docker \| cut -d: -f3`. |
| `CF_DNS_API_TOKEN` | Cloudflare token for Traefik's ACME DNS-01 challenge. |
| `GIRDER_SMTP_USERNAME` / `GIRDER_SMTP_PASSWORD` | Outgoing mail on `mail.spacemail.com`. |
| `GLOBUS_CLIENT_ID` / `GLOBUS_CLIENT_SECRET` | Globus OAuth. |
| `ORCID_CLIENT_ID` / `ORCID_CLIENT_SECRET` | ORCID OAuth (the primary login path). |
| `GIRDER_SIVACOR_TRO_GPG_FINGERPRINT` / `GIRDER_SIVACOR_TRO_GPG_PASSPHRASE` | TRS signing key, for `run_tro("sign")`. |
| `MASTER_KEY_HEX` | See below. |
| `REDIS_PASSWORD` | See below. **New — an existing `.env` without it will refuse to deploy.** |

## Optional

All of these have a default that reproduces current production behaviour, so an
existing `.env` needs none of them.

| Variable | Default | Purpose |
|---|---|---|
| `GIRDER_API_KEY` | unset | See below — **not required** for the co-located worker. |
| `GIRDER_ADMIN_EMAIL` | `admin@sivacor.org` | Contact + envelope-sender address. Deliberately **not** derived from `domain`: it has to be a mailbox the `mail.spacemail.com` account is authorized to send as, so on a test domain the default is usually still what you want. |
| `GIRDER_SIVACOR_IMAGE` | `docker.io/xarthisius/girder-sivacor:latest` | Backend image for `girder`, `beat` and `local_worker`. Point at a branch tag to test one. |
| `SIVACOR_MANAGER_QUEUES` | `local,sivacor,sivacor.static-01` | `local_worker`'s `--queues`. Drop `sivacor` to stop the manager accepting submissions once a remote worker exists. |
| `DOCKER_HOST_TMP_ROOT` | `/home/ubuntu/deploy-dev/volumes` | Host path `lib.py` builds sibling-container bind-mount sources from. The default is the P0.8 open question — a `deploy-dev` path inside the production stack. Set it per host. |
| `STATA_LICENSE_HOSTPATH` | `…/deploy-dev/volumes/licenses/stata.lic.19` | Same caveat. |
| `DOCS_URL` | `https://docs.sivacor.org/` | Where the apex host redirects. |
| `FEEDBACK_URL` | the Qualtrics form | Where `feedback.$domain` redirects. |

## Host rules and TLS

Every host rule **and the ACME certificate** derive from `domain`, so
`domain=test.sivacor.org` moves the whole stack to `*.test.sivacor.org` with no
file edits. Two things to know:

- A wildcard covers exactly one label. `*.sivacor.org` does **not** match
  `submit.test.sivacor.org`, which is why `tls.domains[0].main`/`.sans` are
  templated rather than pinned.
- Only the `traefik-secure` router requests a certificate. Every other router
  carries a bare `tls=true` and is served from the resulting store by SNI, so
  those two labels decide TLS for the entire stack.

The apex → docs and `feedback.$domain` → Qualtrics redirects used to live in
`traefik/extra.yml` as a **file provider**, which `docker stack config` never
interpolates — so they hardcoded `sivacor.org` and made any non-production host
serve production host rules and request ACME certs for them. They are now
traefik labels on the `vocabulary` service and follow `domain`. `extra.yml` and
the `file` provider are gone.

They sit on `vocabulary` only because a router needs *some* service to attach
to; `redirectregex` matches `^(.*)` and answers 302 before the backend is
consulted, which is how the old file-provider version worked with a service that
had zero servers. They also no longer carry their own `certResolver` — the
wildcard covers both the apex (as `main`) and `feedback.$domain` (as `*.`), so
this is two fewer certificates to issue.

## `MASTER_KEY_HEX`

Wrapping key for the AES-GCM envelope encryption of a submission's env secrets.
The **server encrypts and the worker decrypts**, so `girder`, `local_worker` and
`beat` must all be given the same value.

Generate with:

```sh
openssl rand -hex 32
```

Both `girder_sivacor/utils.py` and `worker_plugin/lib.py` fall back to the same
hardcoded dummy key when it is unset, which is why an unconfigured deployment
appears to work: the two sides agree by accident, using a key that is public.

**Rotation hazard:** changing this value makes any *already stored* encrypted
secret undecryptable. Check for pending submissions holding secrets before
rotating, and do it in a quiet window.

## `REDIS_PASSWORD`

Redis is the celery broker/backend and the log pubsub. Off-box workers reach it
directly, so `6379` is now published and it runs with `--requirepass`. The
celery message carries an **admin-scoped Girder token in plaintext**, which makes
broker confidentiality a security boundary, not a nicety.

```sh
openssl rand -base64 24 | tr -d '/+='
```

Keep it URL-safe — it is interpolated into `redis://:PASSWORD@host:6379/` in nine
places, and `/`, `+`, `@` or `:` would need percent-encoding.

Declared as `${REDIS_PASSWORD:?…}`, so `docker stack config` **hard-fails** when
it is unset rather than rendering `--requirepass ""` — which would disable auth
on a published port. This is why an existing `.env` must gain the variable before
the next `make dev`.

> **Swarm cannot bind a published port to one interface.** `host_ip` is rejected
> by `docker stack config`, so `6379` listens on *every* address of the node,
> floating IP included. The tenant-only restriction **must** come from the JS2
> security group — allow 6379 from the project CIDR and nothing else. Verify from
> outside the project that it is unreachable; `requirepass` is the second layer,
> not the first.

Rotating it restarts every service that talks to Redis and drops whatever is
queued, so do it in a quiet window.

## `GIRDER_API_KEY`

**Not needed for `local_worker`, and normally left unset.**

The periodic sweeps on `sivacor.maintenance` (retention cleanup and the
stranded-submission reaper) are published by `beat` with no submission
attached, so they have no worker token to inherit. But the only consumer of
that queue is `local_worker`, which has `GIRDER_MONGO_URI` and Girder's model
layer — so it mints its own short-lived admin token
(`Token().createToken(admin, days=1)`) instead of being handed a standing
credential. Nothing to configure.

Set this only for a worker that consumes `sivacor.maintenance` **without**
MongoDB access — not a configuration that exists today. When set it takes
precedence over the local token.

```sh
curl -X POST -H "Girder-Token: $TOKEN" \
  "https://girder.$domain/api/v1/api_key?name=maintenance"
```

If neither is available (no `GIRDER_API_URL`, no key, no model layer) both
sweeps log a skip and return — they do not fail the worker, so the symptom is
silently unbounded submission retention and stranded jobs that never
transition out of `RUNNING`.

## Queues

`local_worker` consumes three queues; each is load-bearing:

| Queue | Why |
|---|---|
| `local` | Girder core's own task queue (`deleteFolderTask`, `importDataTask`, …). Core's `ensure_local_worker_available()` returns **HTTP 503** if nothing consumes it, so dropping it breaks submission deletion. |
| `sivacor` | Shared dispatch queue that new submissions are published to. |
| `sivacor.static-01` | This worker's private queue. After its first step a submission's chain is pinned here, because every later step works out of a local directory. Pinned by `SIVACOR_WORKER_QUEUE`. |

Periodic housekeeping (retention sweep, stranded-submission reaper) rides
`local`. All that matters is that it stays off `sivacor`, whose depth an
autoscaler reads as a count of submissions waiting for a worker. A dedicated
`sivacor.maintenance` queue was tried and dropped: `--concurrency` is one pool
shared across every queue a worker consumes, so a separate queue name gives the
reaper no reserved execution slot. Real isolation would need a separate worker
process, and at `-c 4` with a 30-minute threshold re-firing every 10 minutes,
the sweeps do not need one.
