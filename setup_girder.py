#!/usr/bin/env python3
"""First-run Girder bootstrap, run by `make dev` after every deploy.

It configures a NEW database only. If Girder already has an admin it changes
nothing and exits 0 -- which is what makes `make dev` safe to use as the
redeploy command on a deployment holding data. Do not teach it to "carry on"
on an existing database: everything below would overwrite live settings.

Every request sends its parameters in a urlencoded form body, never in the
URL, and never as JSON: Girder answers a JSON-bodied PUT /system/setting with
200 having changed nothing, which is why every setting is read back below. Traefik's
access log keeps every 4xx together with its query string, so a URL parameter
is a credential written to disk on any failure -- the admin password on
`POST /user`, the GPG passphrase on `PUT /system/setting`.
"""
import json  # noqa: I001
import requests
import subprocess
import time
import os
import sys

headers = {"Accept": "application/json"}
domain = os.environ.get("domain")
if not domain:
    raise RuntimeError(
        "domain environment variable is not set; cannot configure Girder"
    )

api_url = f"https://girder.{domain}/api/v1"

# Long enough for a fresh host's DNS-01 challenge: until the certificate
# arrives Traefik serves its self-signed default and every request here fails
# verification. Verification is never turned off to get past that -- this
# script sends the admin password.
STARTUP_TIMEOUT = 15 * 60


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def girder_error(r):
    # Girder's own message and field only. Not r.text, and not the request:
    # either can carry what was sent.
    try:
        body = r.json()
        detail = body.get("message", "")
        if body.get("field"):
            detail = f"{body['field']}: {detail}"
    except ValueError:
        detail = r.reason
    return f"{r.request.method} {r.url} -> {r.status_code}: {detail}"


# Stata license, seeded into the sivacor.stata_license setting so ephemeral
# workers can fetch it at run time (plan D7 / item 3b). Git-ignored, like the
# rest of volumes/; absent is fine and just means no Stata support. Read up
# front but reported only when it is actually seeded, below -- on an existing
# deployment nothing is.
stata_license_path = os.environ.get(
    "STATA_LICENSE_HOSTPATH", "volumes/licenses/stata.lic.19"
)
try:
    with open(stata_license_path) as fp:
        stata_license = fp.read().strip()
except OSError:
    stata_license = None

# Which OAuth providers the login page offers. Explicit rather than derived
# from which client ids are set: production carries ORCID credentials with
# ORCID deliberately switched off, so deriving would turn it back on at its
# next rebuild. The default reproduces what this script has always done.
oauth_providers = [
    p.strip()
    for p in os.environ.get("GIRDER_OAUTH_PROVIDERS", "globus").split(",")
    if p.strip()
]
for provider in oauth_providers:
    if provider not in ("globus", "orcid"):
        fail(f"GIRDER_OAUTH_PROVIDERS: unknown provider {provider!r}")
    if not os.environ.get(f"{provider.upper()}_CLIENT_ID"):
        # Caught here, before anything is created: an enabled provider with
        # no app makes the login page show "Authentication Error", and with
        # only one provider that is the whole login page.
        fail(
            f"GIRDER_OAUTH_PROVIDERS enables {provider} but "
            f"{provider.upper()}_CLIENT_ID is not set"
        )


def wait_for_girder():
    deadline = time.monotonic() + STARTUP_TIMEOUT
    while True:
        try:
            r = requests.get(api_url, timeout=10)
            if r.status_code == 200:
                return
            print(f"Waiting for Girder to start ({r.status_code})")
        except requests.exceptions.SSLError:
            print("Waiting for the TLS certificate (Traefik still serves its default)")
        except requests.exceptions.ConnectionError:
            print("Waiting for Girder to start (connection refused)")
        if time.monotonic() > deadline:
            fail(
                f"https://girder.{domain} did not come up within "
                f"{STARTUP_TIMEOUT // 60} minutes. If the certificate never "
                "arrived, add `log: {level: DEBUG}` to traefik/config.yml to "
                "see the ACME challenge, then rerun `make dev`."
            )
        time.sleep(5)


def admin_exists():
    # Asked of the girder container's model layer, the way `make reset_girder`
    # reaches the database, because nothing anonymous over HTTP can tell:
    # listing users needs a login, a failed login says "Login failed." either
    # way, and POST /user validates password and email before it checks the
    # login is taken.
    cids = subprocess.run(
        ["docker", "ps", "--filter=name=wt_girder", "-q"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if not cids:
        fail("no running wt_girder container to check for an existing admin")
    r = subprocess.run(
        ["docker", "exec", cids[0], "python3", "-c",
         "from girder.models.user import User;"
         "print(User().findOne({'admin': True}) is not None)"],
        capture_output=True, text=True,
    )
    answer = r.stdout.strip().splitlines()[-1:] if r.returncode == 0 else []
    if answer not in (["True"], ["False"]):
        # Unknown is not "no": guessing "no" could create a second admin.
        fail(f"could not check for an existing admin: {r.stderr.strip()}")
    return answer == ["True"]


wait_for_girder()

if admin_exists():
    print("--- Girder already has an admin user; nothing was changed. ---")
    print("Settings are seeded only on a new database, so edits to .env")
    print("(GPG key, Stata license, OAuth) do not take effect here --")
    print("change them through the settings API instead (see ENVIRONMENT.md).")
    print()
    print("If this is a NEW install whose setup failed part-way:")
    print("    make clean && make dev")
    print("That deletes the database and the assetstore. Never run it on a")
    print("deployment holding data you want.")
    # 0, not 1: this is the normal path of every redeploy.
    sys.exit()

# Required only here, when an admin is about to be created: an existing
# deployment's .env need not carry it, and the check above never reads it.
admin_password = os.environ.get("GIRDER_ADMIN_PASSWORD")
if not admin_password:
    fail(
        "GIRDER_ADMIN_PASSWORD is not set. It is the password of the Girder "
        "admin this script is about to create; add it to .env (with `export`) "
        "and rerun `make dev`."
    )

print("Creating admin user")
r = requests.post(
    api_url + "/user",
    headers=headers,
    data={
        "login": "admin",
        "email": os.environ.get("GIRDER_ADMIN_EMAIL", "root@sivacor.org"),
        "firstName": "Deus",
        "lastName": "Ex Machina",
        "password": admin_password,
        "admin": True,
    },
)
if not r.ok:
    fail(girder_error(r))
# Store token for future requests
headers["Girder-Token"] = r.json()["authToken"]["token"]

print("Creating default assetstore")
r = requests.post(
    api_url + "/assetstore",
    headers=headers,
    data={
        "type": 0,
        "name": "Base",
        "root": "/srv/data/base",
    },
)
if not r.ok:
    fail(girder_error(r))

print("Setting up Plugin")

settings = [
    {
        "key": "core.cors.allow_origin",
        # Written the way Girder's validator normalises it (", "-joined), so
        # the read-back below compares equal. Stored value is unchanged.
        "value": f"http://localhost:4200, https://submit.{domain}",
    },
    {
        "key": "core.cors.allow_headers",
        "value": (
            "Accept-Encoding, Authorization, Content-Disposition, Set-Cookie, "
            "Content-Type, Cookie, Girder-Authorization, Girder-Token, "
            "X-Requested-With, X-Forwarded-Server, X-Forwarded-For, "
            "X-Forwarded-Host, Remote-Addr, Cache-Control"
        ),
    },
    {"key": "core.cookie_domain", "value": f".{domain}"},
    # Without this, getWorkerApiUrl() falls back to getApiUrl(), which is
    # derived from the incoming request -- so a worker's callback URL would
    # depend on whichever proxy headers happened to be on the submit request.
    # Off-box workers need a stable public URL.
    {"key": "worker.api_url", "value": f"https://girder.{domain}/api/v1"},
    {"key": "oauth.globus_client_id", "value": os.environ.get("GLOBUS_CLIENT_ID")},
    {
        "key": "oauth.globus_client_secret",
        "value": os.environ.get("GLOBUS_CLIENT_SECRET"),
    },
    {"key": "oauth.orcid_client_id", "value": os.environ.get("ORCID_CLIENT_ID")},
    {
        "key": "oauth.orcid_client_secret",
        "value": os.environ.get("ORCID_CLIENT_SECRET"),
    },
    {"key": "oauth.providers_enabled", "value": oauth_providers},
    # Both of these override the plugin defaults (24h / 7 days), which stay put
    # for deploy-dev and anyone else. Our worst real workflows need days, not
    # hours.
    #
    # THEY MOVE TOGETHER. cleanup_submissions() deletes a submission folder
    # `retention_days` after the folder was CREATED, not after the run ended,
    # and does not check whether the job is still running. So retention must
    # exceed max_runtime, or a long job's results are swept away as it finishes
    # -- exactly the submissions the raised cap exists to serve. 14 vs 7 days
    # leaves a full week to download after a worst-case run.
    #
    # SIVACOR_MAX_LIFETIME_HOURS in docker-stack.autoscaler.yml must in turn stay
    # above max_runtime, or the autoscaler deletes workers the reaper still
    # considers healthy. Current chain: 168h run < 180h VM lifetime, 14d retention.
    # Both MUST be floats, not ints: the validators are isinstance(value, float)
    # and an int is rejected outright (girder_sivacor/__init__.py:45,57). The
    # plugin's own int default slips through only because defaults skip validation.
    {"key": "sivacor.max_runtime", "value": 168.0},
    {"key": "sivacor.retention_days", "value": 14.0},
    {
        "key": "sivacor.tro_gpg_fingerprint",
        "value": os.environ.get("GIRDER_SIVACOR_TRO_GPG_FINGERPRINT"),
    },
    {
        "key": "sivacor.tro_gpg_passphrase",
        "value": os.environ.get("GIRDER_SIVACOR_TRO_GPG_PASSPHRASE"),
    },
]
# Served to ephemeral workers at run time, only for Stata images. Read from a
# file rather than an env var: a license is multi-line-ish and does not
# belong in .env, and this keeps it out of user-data entirely (see the plan's
# D7 and item 3b). Left out entirely when the file is absent, which simply
# means this deployment cannot run Stata -- and says so at submit-to-container
# time. Not sent as "": the plugin's validator rejects an empty license, and
# that rejection would fail the whole settings request.
if stata_license is not None:
    print(f"--- seeding Stata license from {stata_license_path} ---")
    settings.append({"key": "sivacor.stata_license", "value": stata_license})
else:
    print(f"--- no Stata license at {stata_license_path}; Stata images disabled ---")

# Where researcher-facing messages, mail and the web UI's Contact Support send
# people. Seeded only when given, so a deployment that sets nothing keeps the
# plugin's default (support@sivacor.org) rather than a copy of it.
# Deliberately not GIRDER_ADMIN_EMAIL: that is the mail sender.
if os.environ.get("SIVACOR_SUPPORT_EMAIL"):
    settings.append(
        {"key": "sivacor.support_email", "value": os.environ["SIVACOR_SUPPORT_EMAIL"]}
    )

# Where the analysis-image allow-list is fetched from. Unset leaves the plugin
# default, which is "never fetch": sivacor.image_tags is then the list itself,
# and its built-in value is old -- curate it on the plugin's config page. A
# rebuilt SIVACOR deployment wants this set (see ENVIRONMENT.md); prefer a
# pinned commit to a branch, which reaches the deployment without a deploy.
if os.environ.get("SIVACOR_IMAGE_TAGS_URL"):
    settings.append(
        {"key": "sivacor.image_tags_url", "value": os.environ["SIVACOR_IMAGE_TAGS_URL"]}
    )

# An unset .env variable is left out rather than sent as null, so the setting
# keeps the plugin's default and the read-back below has something definite to
# compare. Named, never valued: some of these are secrets.
for unset in [item["key"] for item in settings if item["value"] is None]:
    print(f"--- not set in .env, left at the default: {unset} ---")
settings = [item for item in settings if item["value"] is not None]


r = requests.put(
    api_url + "/system/setting", headers=headers, data={"list": json.dumps(settings)}
)
if not r.ok:
    fail(girder_error(r))

# A 200 is not proof anything was stored (see the docstring), so check. Keys go
# in the URL; values never do, and a mismatch is reported by key alone.
r = requests.get(
    api_url + "/system/setting",
    headers=headers,
    params={"list": json.dumps([item["key"] for item in settings])},
)
if not r.ok:
    fail(girder_error(r))
stored = r.json()
mismatched = [item["key"] for item in settings if stored.get(item["key"]) != item["value"]]
if mismatched:
    fail(
        "Girder accepted the settings but did not store: " + ", ".join(mismatched)
        + ". Nothing was rolled back; fix the cause, then `make clean && make dev`."
    )

print("-------------- You should be all set!! -------------")
print(f"Log in at https://girder.{domain} as `admin`, with GIRDER_ADMIN_PASSWORD.")
