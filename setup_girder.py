#!/usr/bin/env python3
import json  # noqa: I001
import requests
import time
import os
import sys

params = {
    "login": "admin",
    "email": "root@sivacor.org",
    "firstName": "Deus",
    "lastName": "Ex Machina",
    "password": "XWgnWW7R",
    "admin": True,
}
headers = {"Content-Type": "application/json", "Accept": "application/json"}
domain = os.environ.get("domain")
if not domain:
    raise RuntimeError(
        "domain environment variable is not set; cannot configure Girder"
    )

# Stata license, seeded into the sivacor.stata_license setting so ephemeral
# workers can fetch it at run time (plan D7 / item 3b). Git-ignored, like the
# rest of volumes/; absent is fine and just means no Stata support.
stata_license_path = os.environ.get(
    "STATA_LICENSE_HOSTPATH", "volumes/licenses/stata.lic.19"
)
try:
    with open(stata_license_path) as fp:
        stata_license = fp.read().strip()
    print(f"--- seeding Stata license from {stata_license_path} ---")
except OSError:
    stata_license = ""
    print(f"--- no Stata license at {stata_license_path}; Stata images disabled ---")


def final_msg():
    print("-------------- You should be all set!! -------------")
    print(f"try going to https://girder.{domain} and log in with: ")
    print(f"  user : {params['login']}")
    print(f"  pass : {params['password']}")


api_url = f"https://girder.{domain}/api/v1"

# Give girder time to start
while True:
    print("Waiting for Girder to start")
    r = requests.get(api_url)
    if r.status_code == 200:
        break
    time.sleep(2)

print("Creating admin user")
r = requests.post(api_url + "/user", params=params, headers=headers)
if r.status_code == 400:
    print("Admin user already exists. Database was not purged.")
    print("If that is OK:")
    final_msg()
    sys.exit()
# Store token for future requests
headers["Girder-Token"] = r.json()["authToken"]["token"]

print("Creating default assetstore")
r = requests.post(
    api_url + "/assetstore",
    headers=headers,
    params={
        "type": 0,
        "name": "Base",
        "root": "/srv/data/base",
    },
)

print("Setting up Plugin")

settings = [
    {
        "key": "core.cors.allow_origin",
        "value": f"http://localhost:4200,https://submit.{domain}",
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
    {"key": "oauth.providers_enabled", "value": ["globus"]},
    {
        "key": "sivacor.tro_gpg_fingerprint",
        "value": os.environ.get("GIRDER_SIVACOR_TRO_GPG_FINGERPRINT"),
    },
    {
        "key": "sivacor.tro_gpg_passphrase",
        "value": os.environ.get("GIRDER_SIVACOR_TRO_GPG_PASSPHRASE"),
    },
    # Served to ephemeral workers at run time, only for Stata images. Read from a
    # file rather than an env var: a license is multi-line-ish and does not
    # belong in .env, and this keeps it out of user-data entirely (see the plan's
    # D7 and item 3b). Empty when the file is absent, which simply means this
    # deployment cannot run Stata -- and says so at submit-to-container time.
    {
        "key": "sivacor.stata_license",
        "value": stata_license,
    },
]


r = requests.put(
    api_url + "/system/setting", headers=headers, params={"list": json.dumps(settings)}
)
try:
    r.raise_for_status()
except requests.exceptions.HTTPError:
    if r.status_code >= 400 and r.status_code < 500:
        print(f"Request died with {r.status_code}: {r.reason}")
        print(f"Returned: {r.text}")
    raise

final_msg()
