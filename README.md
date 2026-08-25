# deploy-sivacor

The production Docker Swarm stack for a [SIVACOR](https://docs.sivacor.org) deployment —
a platform for automated verification of reproducible computational social-science
research. It runs `*.sivacor.org` on ACCESS Jetstream2, but nothing here is specific to
that domain or that cloud: every host rule derives from `$domain`, and the OpenStack side
is opt-in.

This README is the orientation. **[`ENVIRONMENT.md`](ENVIRONMENT.md) is the reference** —
every variable, every default, and the reasoning behind the ones that fail silently.
Read it before your first deploy, not after.

For purely local development, use `deploy-dev/` instead. It bind-mounts source for live
reload; this stack runs published images.

## What gets deployed

One Swarm stack, named `wt`, on a single manager node:

| Service | What it is |
|---|---|
| `traefik` | Reverse proxy, TLS via Let's Encrypt DNS-01 (ports 80/443) |
| `girder` | Backend API — Girder 5 + the `girder-sivacor` plugin |
| `submit` | Researcher UI (`aea-sivacor`) |
| `local_worker` | Co-located celery worker; runs analysis containers via the Docker socket |
| `beat` | Periodic tasks (retention sweep) |
| `mongo`, `redis` | Database and broker |
| `vocabulary` | Static `sivacor:` vocabulary host, plus the apex and feedback redirects |
| `autoscaler` | **Optional** — creates and reaps OpenStack worker VMs from demand |

Without the autoscaler, submissions run on the manager and **the stack needs no
OpenStack anything** — no `clouds.yaml`, no credentials. That is the sane way to start.

## Prerequisites

- **One VM** with Docker and an initialized Swarm (`docker swarm init`), plus `sudo`.
  Ports 80 and 443 reachable. It runs analysis containers itself until you enable the
  fleet, so size it accordingly.
- **A domain** you control, with DNS hosted at **Cloudflare** — Traefik requests a
  wildcard certificate over the DNS-01 challenge, so you need an API token, not just an
  A record. Point `girder`, `submit`, `vocabulary`, `feedback` and the apex at the VM.
- **OAuth applications** at [ORCID](https://orcid.org/developer-tools) (the primary login
  path) and [Globus](https://app.globus.org/settings/developers).
- **An SMTP account** for outgoing mail. Set `GIRDER_EMAIL_TO_CONSOLE` to skip this while
  testing.
- **A GPG key** in `/home/ubuntu/.gnupg` on the manager. This is the TRS signing key —
  every TRO the deployment produces is signed with it, so it is the deployment's identity.
- Optional: an **OpenStack application credential** if you want the worker fleet, and a
  **Stata license file** at `volumes/licenses/stata.lic.19` if you want Stata images.

## Deploy

```sh
git clone https://github.com/SIVACOR/deploy-sivacor && cd deploy-sivacor
$EDITOR .env                 # see ENVIRONMENT.md; git-ignored
make dev
```

`make dev` creates the bind-mount directories, deploys the stack, waits for Girder, then
runs `setup_girder.py` to create the admin user, the assetstore, CORS, OAuth and the
SIVACOR settings. It prints the admin credentials at the end — **change the password**.

> **Every line of `.env` must start with `export`.** The Makefile sources it and passes
> the environment to `docker stack config`. Without `export`, only `REDIS_PASSWORD` fails
> loudly; everything else interpolates to empty and deploys a stack that comes up and
> serves nothing — host rules become ``Host(`girder.`)`` and ACME asks for a certificate
> for `.`.

Other targets: `make clean` (remove the stack and wipe runtime volumes), `make
tail_girder_err`, `make reset_girder` (drops the database).

## Two configuration planes

Roughly half of what you can configure is **not** in `.env`.

- **`.env`** — infrastructure: domain, credentials, images, fleet limits. Changing it
  requires a redeploy.
- **Girder settings** (`sivacor.*`, in MongoDB) — policy: the worker-size catalogue, the
  scratch-volume switch and budget, retention and runtime caps, targeted assignment. Set
  through the admin UI, the settings API, or `girder-shell` on the manager. Most take
  effect without a redeploy.

`setup_girder.py` seeds the second plane **only on a database with no admin user**. On an
existing deployment it exits early and still prints "You should be all set!!" — so editing
`.env` and re-running `make dev` does not change a Girder setting. Change those through
the API.

## Enabling the OpenStack fleet

Off by default. It lives in a separate overlay file so the base stack can deploy without
any OpenStack credential at all.

```sh
export SIVACOR_AUTOSCALING=1
export OS_CLOUD=my-cloud       # entry in ~/.config/openstack/clouds.yaml
```

`make dev` then merges `docker-stack.autoscaler.yml` and prints `--- autoscaling: ON ---`.
The controller reads queue depth and unclaimed submissions, boots worker VMs from
`worker-cloud-init.sh`, and reaps them.

Four things to know before you turn it on:

1. **It is the highest-privilege service in the stack.** It holds an OpenStack credential
   and can create *and delete* instances across the whole project — including the manager
   it runs on. It only refuses to touch instances lacking its own `sivacor-deployment:`
   tag. Treat `clouds.yaml` accordingly.
2. **Never raise `replicas` above 1.** There is no leader election; `replicas: 1` *is* the
   mutual exclusion. Two controllers boot two instances per submission and burn the
   allocation until someone notices.
3. **Set `SIVACOR_MAX_INSTANCES` (and the vCPU/RAM caps) below your real quota.** The same
   quota carries the manager and any debug VM.
4. **Pin your images before you depend on them.** Both stack files default to `:latest`,
   and CI pushes `latest` from `main` — so an upstream merge changes what you run without
   you deploying. Set `GIRDER_SIVACOR_IMAGE` to a digest.

Optional per-submission Cinder scratch volumes are documented in `ENVIRONMENT.md`; they
require targeted assignment to be armed first, and the orphan sweep to be armed before
the volumes are — it is the only thing that notices a leak.

## Files

| | |
|---|---|
| `docker-stack.yml` | The base stack |
| `docker-stack.autoscaler.yml` | Fleet-controller overlay, merged only when `SIVACOR_AUTOSCALING` is set |
| `Makefile` | Deploy and housekeeping targets; also discovers host-specific values |
| `setup_girder.py` | First-run Girder bootstrap |
| `worker-cloud-init.sh` | User-data template for fleet worker VMs |
| `launch-worker.py` | Launch a single worker by hand, for debugging |
| `ENVIRONMENT.md` | **The configuration reference** |
| `traefik/config.yml` | Static Traefik config (bind-mounted; never interpolated) |

`.env*`, `volumes/` and `traefik/acme.json` are git-ignored.

## License

MIT — see [LICENSE](LICENSE).
