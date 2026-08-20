# `.env` reference

`make dev` sources `./.env` before deploying the `wt` stack and before running
`setup_girder.py`. The file is git-ignored; this is the tracked list of what it
has to contain.

> **Every line must start with `export`.** The Makefile runs
> `. ./.env && docker stack config …`, and sourcing a bare `FOO=bar` creates a
> *shell* variable, which a child process never sees. Without `export`, `docker
> stack config` interpolates **every** `${…}` to the empty string.
>
> Only `REDIS_PASSWORD` fails loudly, because it is the one declared
> `${REDIS_PASSWORD:?…}`. Everything else renders empty and deploys: host rules
> become ``Host(`girder.`)``, `GOSU_USER` becomes `1000:1000:`, and the ACME
> request asks for a certificate for `.` — a stack that comes up and serves
> nothing. If you see
> `required variable REDIS_PASSWORD is missing a value` while `grep REDIS_PASS
> .env` clearly shows it, this is why: check for the `export` prefix, not the
> value.

## Required

| Variable | Purpose |
|---|---|
| `domain` | Public domain, e.g. `sivacor.org`. Used for every Traefik host rule and for `worker.api_url`. |
| `docker_group` | Host GID of the `docker` group (`getent group docker \| cut -d: -f3`). Feeds `GOSU_USER`, which **nothing reads** — see *Docker socket access* below. Must be `112` for the socket to work, because the image hardcodes that GID. |
| `CF_DNS_API_TOKEN` | Cloudflare token for Traefik's ACME DNS-01 challenge. |
| `GIRDER_SMTP_USERNAME` / `GIRDER_SMTP_PASSWORD` | Outgoing mail on `mail.spacemail.com`. |
| `GLOBUS_CLIENT_ID` / `GLOBUS_CLIENT_SECRET` | Globus OAuth. |
| `ORCID_CLIENT_ID` / `ORCID_CLIENT_SECRET` | ORCID OAuth (the primary login path). |
| `GIRDER_SIVACOR_TRO_GPG_FINGERPRINT` / `GIRDER_SIVACOR_TRO_GPG_PASSPHRASE` | TRS signing key, for `run_tro("sign")`. **Read only on a first-time setup.** `setup_girder.py` seeds these into `sivacor.tro_gpg_fingerprint` / `sivacor.tro_gpg_passphrase`, but it exits at its admin-user check on any database that already has an admin — so editing them here and re-running `make dev` changes nothing, and still prints "You should be all set!!". Change them through the settings API or the admin UI. Same applies to `sivacor.stata_license` from `STATA_LICENSE_HOSTPATH`. See *Deployment traps* 6 in `autoscaling_plan.md`. |
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
| `AEA_SIVACOR_IMAGE` | `xarthisius/aea-sivacor:latest` | Frontend image for `submit`. |
| `SIVACOR_MANAGER_QUEUES` | `local,sivacor,sivacor.static-01` | `local_worker`'s `--queues`. Drop `sivacor` to stop the manager accepting submissions once a remote worker exists. |
| `DOCKER_HOST_TMP_ROOT` | `/home/ubuntu/deploy-sivacor/volumes` | Host path `lib.py` builds sibling-container bind-mount sources from. Matches the production checkout; set it per host if yours differs. A wrong value does not error — Docker creates an empty directory at the missing mount source, and Stata then reports no valid license. |
| `STATA_LICENSE_HOSTPATH` | `…/deploy-sivacor/volumes/licenses/stata.lic.19` | Same caveat. |
| `GIRDER_EMAIL_TO_CONSOLE` | unset | Any **non-empty** value makes `notifications.py:_submitEmail` print the message to stdout and return before touching SMTP. Lets a test stack run with blank `GIRDER_SMTP_*`. Read the mail with `docker service logs -f wt_girder` — the `jobs.job.update.after` handler runs in the Girder server, so that is where submission mail is emitted, not the worker. **Note:** it is a bare truthiness check, so `false` also redirects; leave it unset to send for real. |
| `TRAEFIK_LOG_LEVEL` | `INFO` | Traefik's own default is `ERROR`, which makes certificate problems invisible. Use `DEBUG` to see lego's DNS-01 challenge steps when a cert is not appearing. Passed as a CLI flag because `traefik/config.yml` is a bind mount and is never interpolated. |
| `DOCS_URL` | `https://docs.sivacor.org/` | Where the apex host redirects. |
| `FEEDBACK_URL` | the Qualtrics form | Where `feedback.$domain` redirects. |
| `SIVACOR_AUTOSCALING` | unset (**off**) | Any non-empty value makes `make dev` merge `docker-stack.autoscaler.yml` and run the fleet controller. Off, the stack needs no OpenStack credentials at all. |
| `OS_CLOUD` | — | Entry in `clouds.yaml`. **Required when `SIVACOR_AUTOSCALING` is set**, unused otherwise. |
| `SIVACOR_MANAGER_TENANT_IP` | discovered | Manager's tenant address, **not** its floating IP — written into worker user-data. The Makefile derives it like `docker_group`; an explicit value wins. Only consulted with `SIVACOR_AUTOSCALING`. |
| `SIVACOR_DEPLOYMENT` | `$domain` (derived by the Makefile) | Which fleet this controller owns. Every instance it creates is tagged `sivacor-deployment:<this>`, and it **refuses to count or delete** any `sivacor-worker` instance without that tag. Load-bearing because production and the test mirror share **one OpenStack project**: with a single shared tag each controller reads the other's workers as available capacity (their claim markers live in the other deployment's Girder), so a queued submission gets no VM, and each reaps the other's `SHUTOFF`s. Only override it to run two fleets on one domain. |
| `SIVACOR_AUTOSCALER_IMAGE` | — | **Retired 2026-08-13 (P0.5).** The controller now runs from `GIRDER_SIVACOR_IMAGE`, like `beat` and `local_worker`. Setting this has no effect. |
| `OS_CLOUDS_FILE` | `/home/ubuntu/.config/openstack/clouds.yaml` | Host path bind-mounted read-only into the autoscaler, at `/etc/sivacor/clouds.yaml` and found via `OS_CLIENT_CONFIG_FILE`. Must be readable by uid 1000. |
| `SIVACOR_WORKER_QUEUES` | unset (`sivacor,<private queue>`) | A worker VM's celery `--queues`. Unset keeps both the shared dispatch queue and its own, which is what every worker has always done. Set it to **`private`** — the literal word — once **this** deployment has armed `sivacor.targeted_assignment` and nothing publishes to `sivacor` (P2 rollout step 4 in `worker_sizing_plan.md`). A variable rather than an edit to `worker-cloud-init.sh` because that file is one checkout bind-mounted by both deployments, which sit at different points of the rollout: narrowing it in the file strands every submission on whichever one is still flag-off. **It ends the one-flag rollback** — a worker that no longer consumes `sivacor` cannot serve a submission dispatched the old way — so set it only when you no longer intend to disarm. Named after `SIVACOR_MANAGER_QUEUES` but **not** a queue list like it: a worker's own queue is `sivacor.<its uuid>`, which cannot be written down off-box, and a `.env` saying `sivacor.$WORKER_UUID` arrives verbatim (injected values are shell-quoted) — the worker would then consume a queue nobody publishes to and idle while looking healthy. Hence one word. Any other value is passed through verbatim for a hand-made debug worker, and the VM warns at boot if it does not include its own queue. |
| `SIVACOR_PROVISION_DEADLINE_MINUTES` | unset (**off**) | Reap instances that never announce readiness. Off is the safe default; arming it against a worker image that does not announce deletes every healthy instance. |
| `SIVACOR_MAX_INSTANCES` | `5` | Fleet cap. Configure **below** the OpenStack quota — the same 25 instances carry the manager, the test mirror and any debug VM. |
| `SIVACOR_MAX_VCPUS` / `SIVACOR_MAX_RAM_GB` | unset (check off) | The other two quota dimensions (S6 in `worker_sizing_plan.md`, superseding D3). Unset means the check does not run, which is correct while every worker is the same shape: the instance count binds at the bottom rung and only there. Once the fleet is heterogeneous the count stops bounding cost — at 125 GiB the RAM quota binds at **nine** instances, not 25, and a controller enforcing `SIVACOR_MAX_INSTANCES` alone would take an OpenStack rejection instead. Set them **below** the real quota, for the same reason `SIVACOR_MAX_INSTANCES` is below it: live quota 2026-08-20 is 25 / 320 vCPU / 1220 GiB, and the two managers already hold 3 / 12 / 45 GiB of it. `QuotaExceeded` remains the outer net either way; these just stop it being the *first* thing that notices. |
| `SIVACOR_OS_FLAVOR` | `m3.medium` | **Now only a fallback, and only on the unarmed path.** Once targeted assignment is armed the flavour comes from the `sivacor.worker_sizes` catalogue, per submission. This still applies to demand read from queue *depth*, which carries no size, so it is what the shared-queue path boots. Production sets it to `m3.large`; the **test mirror sets nothing**, so it falls through to the `m3.medium` default — which matters when validating a size feature on the mirror, because the fallback and the catalogue then disagree. |
| `SIVACOR_MAX_LIFETIME_HOURS` | `180` | Delete a live instance older than this whatever it claims to be doing. Must stay above the server's `sivacor.max_runtime` (168h, seeded by `setup_girder.py`) — 12h of headroom for boot, a cold pull and the post-run upload. A stuck VM costs 8 SU/hr for the whole window. |
| `SIVACOR_BREAKER_THRESHOLD` | `3` | Stop creating after N consecutive instances fail to register. |
| `SIVACOR_INTERVAL` | `30` | Seconds between control-loop ticks. |
| `SIVACOR_OS_KEYPAIR` | unset | SSH key for workers. Keyless is legitimate but undebuggable; the controller warns. A key cannot be added to a running instance. |
| `SIVACOR_DIAGNOSTICS_DIR` / `SIVACOR_DIAGNOSTICS_HOSTPATH` | `/var/lib/sivacor/diagnostics` (in-container) / `/home/ubuntu/sivacor-diagnostics` (host) | Where the controller dumps an instance's **console log, Nova fault and action log immediately before deleting it**, whenever the reap is not a clean finish. A fleet worker has no floating IP and its journal dies with its disk, so this is its only post-mortem — and `delete_server` destroys the console buffer, which is why capture happens in the delete path rather than on a schedule. Added after 2026-08-10/11, when three submissions were reaped for "no heartbeat" and every VM that could have explained why had already been deleted. **`chown 1000:1000` the host directory** (the container runs as uid 1000) or capture warns and writes nothing. The directory **must also exist before deploy**, and that failure is the loud one, not the quiet one: Swarm rejects a task whose bind source is missing (`bind source path does not exist`), so `wt_autoscaler` never starts and sits at `0/1` while every other service is green — a fleet that boots nothing, looking idle. `make dirs` now creates and chowns it, reading this variable from `.env`; it was a manual step until 2026-08-19 and was missed on the first mirror rebuild after the controller moved onto this image. Dumps are `0600` and `user_data` is stripped, but treat them as secret-bearing: a console buffer is uncurated. Unset `SIVACOR_DIAGNOSTICS_DIR` to disable. |
| `SIVACOR_OS_IMAGE` / `SIVACOR_OS_FLAVOR` / `SIVACOR_OS_NETWORK` / `SIVACOR_OS_SECGROUPS` | `Featured-Ubuntu24` / `m3.medium` / `auto_allocated_network` / none | Worker instance shape. **`m3.medium` is a floor, and not for CPU**: JS2 gives 20 GB of root disk to `m3.tiny`/`small`/`quad` and 60 GB to everything above, and analysis images are pulled at run time. Larger flavors buy CPU and RAM, never disk. |
| `SIVACOR_WORKER_IMAGE` | **derived from `GIRDER_SIVACOR_IMAGE`** | The image worker VMs boot, injected into user-data. **Do not set it in `.env`.** It is the *same* image as the manager's — one `girder-sivacor` build serves `girder`, `beat`, `local_worker` and every VM — so the Makefile derives it, and two independently-set variables holding one value would just be a way to get manager/worker version skew silently. Set it only to test a new worker image against the current manager, and remember to remove it. |
| `SIVACOR_REDIS_URL` | `redis://:$REDIS_PASSWORD@redis:6379/` (set in the stack) | How the **controller** reaches the broker. Distinct from `SIVACOR_MANAGER_TENANT_IP`, which is how **workers** reach it. |

## Host rules and TLS

Every host rule **and the ACME certificate** derive from `domain`, so
`domain=test.sivacor.org` moves the whole stack to `*.test.sivacor.org` with no
file edits. Two things to know:

- A wildcard covers exactly one label. `*.sivacor.org` does **not** match
  `submit.test.sivacor.org`, which is why `tls.domains[0].main`/`.sans` are
  templated rather than pinned.
- Exactly one router requests the certificate — **`girder`**. Every other router
  carries a bare `tls=true` and is served from the resulting store by SNI, so
  those three labels decide TLS for the entire stack.

> **Why `girder` and not `traefik-secure`.** The request used to sit on the
> `traefik-secure` router, defined by labels on the `traefik` service — which
> carries `traefik.enable=false`. That flag makes the swarm provider discard
> **every** label on the service, so the router was never built, no certificate
> was ever requested, and `acme.json` stayed at `"Certificates": null` **with
> nothing logged** — nothing failed, nothing was attempted. Long-running
> deployments looked fine only because Traefik keeps renewing certificates
> already in its store; a fresh host had nothing to renew and silently served
> Traefik's self-signed default.
>
> The `traefik-secure` / `traefik` router labels are still on that service and
> still inert. Setting `traefik.enable=true` would activate them and publish the
> dashboard (behind the basicauth middleware already defined there), which looks
> like the original intent. Left off for now — the cert no longer depends on it.

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

## Docker socket access — `GOSU_USER` is inert, GID 112 is hardcoded

`girder` and `local_worker` both set `GOSU_USER=1000:1000:${docker_group}`.
**Nothing reads that variable.** Verified 2026-07-30:

| Checked | Result |
|---|---|
| `girder-sivacor` base image | `FROM python:3.12-slim` — no WholeTale base, nothing inherited |
| entrypoint scripts in the image | none; `ENTRYPOINT` is the gunicorn line directly |
| `gosu` binary in the image | absent |
| `GOSU_USER` in `girder_sivacor/**` (py, sh) | zero hits |
| `GOSU_USER` in the girder source (excluding `venv/`) | zero hits |

What actually grants socket access is baked into the image at build time —
`girder-sivacor/Dockerfile:98`:

```dockerfile
RUN groupadd -g 1000 girder && groupadd -g 112 docker \
 && useradd -g 1000 -G 112 -u 1000 -m -s /bin/bash girder
```

So the container's `girder` user is in **GID 112**, and the docker socket is
readable if and only if the *host's* docker GID is also 112. JS2 hosts are 112,
which is why this works in production and on the test stack.

**Why this matters.** `docker_group` looks like the per-host knob and is not. On a
host with a different docker GID, setting it correctly changes nothing: the
container still cannot open the socket, no analysis container can start, and the
only symptom is a `PermissionError(13)` from docker-py buried in a worker
traceback. Check the host before assuming:

```sh
getent group docker | cut -d: -f3        # must be 112
```

**The worker VM does not have this problem.** `deploy-sivacor/worker-cloud-init.sh`
passes `--group-add <discovered GID>` on `docker run`, which adds the host's real
GID as a supplementary group regardless of what the image baked in.

**The Swarm services cannot use that fix.** `docker stack config` rejects
compose's `group_add` (`Additional property group_add is not allowed`), so there
is no stack-file equivalent. The durable fix is to make the GID a build arg in
`girder-sivacor/Dockerfile` instead of a literal, at which point `docker_group`
could become meaningful. Until then, treat "host docker GID == 112" as a
deployment precondition, and `GOSU_USER` / `docker_group` as vestigial
(WholeTale-era) config kept only because removing it is a separate change.

## Pointing the UI at the right API

`submit` gets `PUBLIC_SIVACOR_API_URL=https://girder.${domain}/api/v1` from the
stack file, so it follows `domain` like everything else. Three things make this
worth knowing:

- **It is a runtime variable, not a build-time one.** The UI reads it through
  `$env/dynamic/public` and runs under `adapter-node` (`CMD ["node", "build"]`),
  so retargeting a deployment never needs an image rebuild.
- **A wrong name fails silently and dangerously.** `src/lib/api.ts:54` is
  `env.PUBLIC_SIVACOR_API_URL || 'https://girder.sivacor.org/api/v1'` — so a typo
  points the test UI straight at **production**, with no error. Several `.env*`
  files in `aea-sivacor` define a bare `SIVACOR_API_URL`, which is **not read**:
  `$env/dynamic/public` uses SvelteKit's `publicPrefix` (`PUBLIC_`), which is
  unrelated to the `envPrefix: 'SIVACOR_'` in `svelte.config.js`.
- **Verify what the browser actually got**, rather than trusting the container
  env — SvelteKit serves the public env as a real endpoint:

  ```sh
  curl -s https://submit.$domain/_app/env.js
  # export const env={"PUBLIC_SIVACOR_API_URL":"https://girder.test.sivacor.org/api/v1"}
  ```

Keep the `/api/v1` suffix: `api.ts:190` does `BASE_URL.replace('/api/v1', '')` to
build folder links.

> **Unrelated trap in the same service.** `svelte.config.js` sets adapter-node's
> `envPrefix: 'SIVACOR_'`, so the adapter reads `SIVACOR_PORT` / `SIVACOR_HOST` —
> **not** `PORT` / `HOST`. The `ENV PORT=3000` and `ENV HOST=0.0.0.0` lines in
> `aea-sivacor/Dockerfile` are therefore dead, and only work by coincidence
> because they match adapter-node's own defaults. Verified: `PORT=4000` is
> ignored and the app stays on 3000. If you ever need to move the port, set
> `SIVACOR_PORT` and update the Traefik `loadbalancer.server.port` label to match.

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


## The autoscaler

Runs the P3 controller as a stack service instead of a checkout plus a terminal on
the manager. `replicas: 1`, pinned to the manager node.

### Opt in with `SIVACOR_AUTOSCALING`

It lives in **`docker-stack.autoscaler.yml`**, a separate overlay merged on top of the
base stack, and `make dev` includes it only when `SIVACOR_AUTOSCALING` is set:

```sh
export SIVACOR_AUTOSCALING=1     # in .env
```

`make dev` prints which mode it is in — `--- autoscaling: ON ---` or `--- autoscaling:
off ---` — so the state is readable from the deploy rather than inferred.

**Why a separate file rather than a flag on the service.** `docker stack config`
interpolates the *whole* input before deploying anything, so the `OS_CLOUD:?` guard
would fail the **entire stack** when unset, not just that one service. Inline, the
stack could not be brought up at all without OpenStack credentials — which breaks
non-fleet deployments, and breaks the production rollout, where the stack deliberately
comes up **before** a fleet exists. Splitting also means unsetting the flag genuinely
removes `wt_autoscaler`, because `docker stack deploy` deletes services absent from the
merged file.

**Without the flag, the base stack needs no OpenStack anything** — no `clouds.yaml`, no
`OS_CLOUD`, no `SIVACOR_MANAGER_TENANT_IP`. Its only required variables are
`docker_group` and `REDIS_PASSWORD`.

For purely local development, `deploy-dev/` remains the right stack and is untouched by
any of this.

**⚠️ It is the highest-privilege service in the stack.** It holds an OpenStack
application credential and can create *and delete* instances across the whole
project — including the manager it runs on, and any hand-made debug VM.
`SIVACOR_MAX_INSTANCES` bounds what it creates; nothing bounds what it can delete
except the `sivacor-worker` tag it filters on. Treat `clouds.yaml` here the way the
GPG keyring is treated on `local_worker`.

**Never raise `replicas`.** Two controllers see the same queue depth and the same
fleet and both act on it: every submission gets two instances, and the allocation
burns at ~8 SU/hr per surplus VM until somebody notices. There is no leader election
and no locking — `replicas: 1` *is* the mutual exclusion.

### What it needs, and where each piece comes from

| | |
|---|---|
| OpenStack | `clouds.yaml` bind-mounted read-only + `OS_CLOUD`. `OS_*` variables work too — openstacksdk reads either — but a bind mount keeps one more credential out of `.env`. |
| Broker | `SIVACOR_REDIS_URL`, over the `celery` overlay by service name. |
| Job documents | `GIRDER_MONGO_URI`, over the `mongo` overlay. **No Girder API key.** |
| Notifications | `GIRDER_NOTIFICATION_REDIS_URL`, same value again. Creating the head step's child job makes Girder emit a user notification; unset, `girder.notification` tries `localhost:6379` and logs a `ConnectionError` traceback on every assignment. Caught, so the chain still goes out — but a traceback per submission in the log an operator reads to judge fleet health is not free. |
| Publishing chains | `GIRDER_WORKER_BROKER` + `GIRDER_WORKER_BACKEND`, the same values `girder` and `local_worker` get. Only used once targeted assignment is armed, and then load-bearing: the controller builds the submission's chain itself and publishes it to the chosen instance's private queue. Missing, the claim still succeeds and the publish raises — the submission is bound to a worker that is never told, and waits for the reaper. |
| Whether it assigns at all | The Girder setting `sivacor.targeted_assignment`, read from Mongo every tick. **Deliberately not an environment variable**: `submit_job` reads the same value to decide whether *it* publishes, and any state where the two disagree is broken — both publishing puts two workers on one workspace, neither means nothing runs while the fleet reads as healthy and idle. One document cannot disagree with itself. Flipping it takes effect within one interval, with no redeploy, and the controller logs the transition. |
| Which shapes it may boot | The Girder setting `sivacor.worker_sizes`, read **once at startup** and validated against Nova. Editing it therefore requires `docker service update --force wt_autoscaler`; the arm flag above does not. The asymmetry is deliberate: the arm flag must be per-tick so both processes agree within one interval, while the catalogue must not be, because the startup check is what stands between a flavour typo and a tripped circuit breaker — three failed creates stop the whole fleet — and a per-tick check would either re-hit Nova every 30 s or be skipped. Confirm a restart took by grepping for `worker sizes validated against Nova`. Read through Girder's model layer, so a deployment that never wrote the setting gets the plugin's own default rather than an empty catalogue. |
| Worker template | `./worker-cloud-init.sh` bind-mounted read-only. Not baked into the image: it is a deployment artifact that changes far more often than the controller, and two artifacts that must agree is the trap that ruled out a Packer image. |
| Worker secrets | `MASTER_KEY_HEX` + `REDIS_PASSWORD`, injected into user-data. Must match the manager byte for byte. |

### `SIVACOR_MANAGER_TENANT_IP` is discovered, not configured

`make dev` derives it from `ip -4 route get 1.1.1.1` and prints
`--- manager tenant ip: ... ---`. An explicit value in `.env` still wins, exactly as
with `docker_group`.

It is discovered for the same reason: it is a property of *this* host, it changes on
every test-mirror rebuild, and a stale value fails silently — workers boot fine and
then cannot reach the broker. Storing it in `.env` made it a standing per-session edit.

`route get` rather than a named interface, because `enp1s0` is not a constant across
hosts. On an OpenStack instance the NIC carries the **fixed** address; a floating IP is
NAT'd by the neutron router and never appears on the interface, so the source address
of an outbound route is exactly the tenant IP and the floating IP cannot be picked up
by mistake.

The `:?` guard in `docker-stack.yml` stays, so a hand-run `docker stack deploy` that
bypasses the Makefile still fails loudly instead of deploying a worker template
pointing at nothing.

**One place still holds a hardcoded copy**: `worker-cloud-init.sh`'s `MANAGER_TENANT_IP`
in the config block. That is only a fallback for a manual `launch-worker.py` run
without `--manager-ip`; the autoscaler always injects the discovered value, so the
stack path no longer depends on it.

### Two Redis paths, deliberately

`SIVACOR_REDIS_URL` is how the *controller* reaches the broker; the stack points it at
the `redis` service name on the overlay. `SIVACOR_MANAGER_TENANT_IP` is what gets
written into *worker* user-data, and a worker is off-box, so it must be the manager's
tenant address — never `redis`, never the floating IP.

Keeping them separate is what lets the autoscaler run on **production without
publishing Redis 6379**, which the P0 rollout deliberately does not do yet.

### Why the database and not the REST API

Two reasons, and the second is the one that bit:

1. **No credential to bootstrap.** An admin API key cannot exist until after Girder
   has been started once, so a fresh deployment could not bring the stack up in a
   single pass.
2. **No endpoint semantics to get wrong.** `GET /job` defaults `userId` to the
   authenticated caller and submissions belong to the researchers who made them, so
   it returned `200` and an empty list on every tick — silently, for the controller's
   entire life. A query has no hidden scoping.

This does **not** contradict the rule that housekeeping sweeps must stay HTTP calls.
That rule is about *writes*: failing a submission has to fire
`jobs.job.update.after`, which is bound only in the Girder server process. The
autoscaler only reads.

### Pin the image before merging to main

CI pushes `latest` from `main`, and both stack files default to `latest` — so merging
would change what production runs without anyone deploying. Since P0.5 the controller
shares the **girder-sivacor** image, so this is now the same pin that governs `girder`,
`beat` and `local_worker`, and one variable covers all four:

```sh
docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' wt_autoscaler
# -> export GIRDER_SIVACOR_IMAGE=docker.io/xarthisius/girder-sivacor@sha256:...
```

`girder-sivacor`'s workflow pushes an immutable `sha-<short>` tag for exactly this
purpose. It did **not** before 2026-08-13 — it pushed `latest` only, so pinning by tag
was impossible and this instruction could not be followed for anything on that image.
Adding it was part of P0.5, because consolidating onto a `latest`-only image would have
put the fleet controller behind the very failure mode this section warns about.

### Logs are secret-bearing until proven otherwise

`-v` raises only this package's logger, and the library loggers are pinned at INFO so
request bodies can no longer be logged — a Nova `POST /servers` body is base64, not
encryption, and one decode yields `MASTER_KEY_HEX` and `REDIS_PASSWORD` in cleartext.
That happened once. The container's default is quiet; add `-v` to the service's
`command:` when debugging, and check the output before pasting it anywhere.
