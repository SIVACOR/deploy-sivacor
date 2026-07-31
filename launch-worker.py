#!/usr/bin/env python3
"""Launch (and list, and delete) SIVACOR worker instances via the OpenStack API.

Composes user-data from ``worker-cloud-init.sh``, injecting the two secrets and the
manager's address, so a booted worker configures and starts itself with no manual
step. This is the manual precursor to the P3 controller: same composition, same
tagging, same "no floating IP" rule -- just driven by a human.

    ./venv/bin/python launch-worker.py --dry-run          # see the user-data
    ./venv/bin/python launch-worker.py                    # create one worker
    ./venv/bin/python launch-worker.py --list
    ./venv/bin/python launch-worker.py --delete <id|name>

Credentials come from the usual OpenStack sources -- ``OS_*`` environment variables
(source the JS2 application-credential script) or ``clouds.yaml`` with ``--cloud``.

Costs real allocation: an m3.medium burns ~8 SU/hr, so creation asks for
confirmation unless ``--yes``. Instances are tagged ``sivacor-worker`` and named
``sivacor-worker-*`` so they can be found and reaped; anything created here is
expected to be deleted, since a worker serves one submission and stops.
"""

from __future__ import annotations

import argparse
import base64
import re
import shlex
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "worker-cloud-init.sh"
INJECT_MARKER = "#__SIVACOR_INJECT__"

#: Tag every instance so the P3 controller (and a human) can find the fleet
#: without relying on the name.
FLEET_TAG = "sivacor-worker"

#: Values read from the manager's .env. Both must reach the worker or it cannot
#: talk to the broker / decrypt job secrets.
REQUIRED_SECRETS = ("MASTER_KEY_HEX", "REDIS_PASSWORD")

DEFAULTS = {
    "flavor": "m3.medium",
    "image": "Featured-Ubuntu24",
    "network": "auto_allocated_network",
    "key_name": "shakuras",
}


def parse_env(path: Path) -> dict[str, str]:
    """Read ``export KEY=value`` lines out of a stack .env.

    deploy-sivacor/.env is shell-sourced by the Makefile, so every line carries
    ``export`` (see the plan's deployment trap 1). Values may be quoted.
    """
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        line = line.removeprefix("export ").strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        out[key] = value.strip().strip("'\"")
    return out


def build_userdata(
    secrets: dict[str, str],
    manager_ip: str,
    girder_host: str | None,
    worker_image: str | None,
    prepull: list[str],
) -> str:
    """Substitute the marker in the cloud-init template with shell assignments.

    Marker substitution rather than rewriting the assignment lines: the template
    keeps working when pasted by hand, and a missing marker fails loudly here
    instead of silently producing a worker with no credentials.
    """
    template = TEMPLATE.read_text()
    if INJECT_MARKER not in template:
        sys.exit(
            f"{TEMPLATE.name} has no {INJECT_MARKER} line -- cannot inject "
            "configuration. Restore the marker or update this script."
        )

    lines = [
        "# ---- injected by launch-worker.py ----",
        f"MASTER_KEY_HEX={shlex.quote(secrets['MASTER_KEY_HEX'])}",
        f"REDIS_PASSWORD={shlex.quote(secrets['REDIS_PASSWORD'])}",
        f"MANAGER_TENANT_IP={shlex.quote(manager_ip)}",
    ]
    if girder_host:
        lines.append(f"GIRDER_HOST={shlex.quote(girder_host)}")
    if worker_image:
        lines.append(f"WORKER_IMAGE={shlex.quote(worker_image)}")
    if prepull:
        joined = " ".join(shlex.quote(i) for i in prepull)
        lines.append(f"PREPULL_IMAGES=({joined})")
    return template.replace(INJECT_MARKER, "\n".join(lines))


def redact(userdata: str, secrets: dict[str, str]) -> str:
    for value in secrets.values():
        if value:
            userdata = userdata.replace(value, "<redacted>")
    return userdata


def connect(cloud: str | None):
    import openstack

    try:
        return openstack.connect(cloud=cloud) if cloud else openstack.connect()
    except Exception as exc:  # noqa: BLE001 - message matters more than the type
        sys.exit(
            f"Could not authenticate to OpenStack: {exc}\n"
            "Source your JS2 application-credential script, or pass --cloud NAME "
            "for a clouds.yaml entry."
        )


def cmd_list(conn) -> int:
    servers = [
        s
        for s in conn.compute.servers()
        if FLEET_TAG in (s.tags or []) or (s.name or "").startswith("sivacor-worker")
    ]
    if not servers:
        print(f"No instances tagged {FLEET_TAG}.")
        return 0
    print(f"{'name':38} {'status':10} {'created':22} id")
    for s in servers:
        print(f"{s.name:38} {s.status:10} {str(s.created_at):22} {s.id}")
    # Leaked instances are the expensive failure mode, so make the total obvious.
    print(f"\n{len(servers)} instance(s). Each m3.medium burns ~8 SU/hr while ACTIVE.")
    return 0


def cmd_delete(conn, target: str, assume_yes: bool) -> int:
    server = conn.compute.find_server(target, ignore_missing=True)
    if server is None:
        sys.exit(f"No instance matching {target!r}.")
    server = conn.compute.get_server(server.id)
    if not assume_yes:
        reply = input(f"Delete {server.name} ({server.id}, {server.status})? [y/N] ")
        if reply.strip().lower() not in ("y", "yes"):
            print("Aborted.")
            return 1
    conn.compute.delete_server(server.id)
    print(f"Deleted {server.name} ({server.id}).")
    return 0


def cmd_create(conn, args, userdata: str) -> int:
    name = args.name or f"sivacor-worker-{uuid.uuid4().hex[:8]}"

    image = conn.compute.find_image(args.image, ignore_missing=True)
    if image is None:
        sys.exit(f"No image named {args.image!r}. List them with: openstack image list")
    flavor = conn.compute.find_flavor(args.flavor, ignore_missing=True)
    if flavor is None:
        sys.exit(f"No flavor named {args.flavor!r}.")
    network = conn.network.find_network(args.network, ignore_missing=True)
    if network is None:
        sys.exit(f"No network named {args.network!r}.")

    # Checked before the confirmation prompt, like image/flavor/network: a mistyped
    # keypair otherwise fails inside Nova after you have already said yes.
    if args.key_name:
        if conn.compute.find_keypair(args.key_name, ignore_missing=True) is None:
            sys.exit(
                f"No keypair named {args.key_name!r} for this user. List them with:\n"
                "  openstack keypair list\n"
                'Or pass --key-name "" to launch without one.'
            )

    # 20 GB root disks (m3.tiny/small/quad) cannot hold an analysis image plus the
    # payload; D6 chose root disk only, so the flavor IS the disk budget.
    if flavor.disk and flavor.disk < 60:
        sys.exit(
            f"{args.flavor} has a {flavor.disk} GB root disk. Workers need 60 GB "
            "(no Cinder volume, so images and payload share it). Use m3.medium+."
        )

    print(f"  name      {name}")
    print(f"  flavor    {args.flavor} ({flavor.vcpus} vCPU, {flavor.disk} GB root)")
    print(f"  image     {args.image}")
    print(f"  network   {args.network}   (no floating IP, by design)")
    print(f"  keypair   {args.key_name or '<none>'}")
    print(f"  sec-grps  {', '.join(args.security_group) or '<default>'}")
    print(f"  manager   {args.manager_ip}")
    print(f"  user-data {len(userdata)} bytes")
    if not args.yes:
        reply = input("Create this instance? [y/N] ")
        if reply.strip().lower() not in ("y", "yes"):
            print("Aborted.")
            return 1

    # Nova requires user_data base64-encoded, and compute.create_server() passes it
    # through verbatim -- only the higher-level conn.create_server() encodes for you
    # (openstack/cloud/_compute.py: _encode_server_userdata). Passing raw text makes
    # Nova try to b64-decode a shell script and return
    #   500 Unexpected API Error ... <class 'UnicodeDecodeError'>
    # which reads like a Nova bug and is entirely our fault. The proxy layer is still
    # the right choice here: conn.create_server() would allocate a floating IP.
    encoded = base64.b64encode(userdata.encode()).decode()
    if len(encoded) > 65535:
        sys.exit(
            f"user_data is {len(encoded)} bytes base64-encoded; Nova's limit is 65535. "
            "Trim worker-cloud-init.sh."
        )

    kwargs = {
        "name": name,
        "image_id": image.id,
        "flavor_id": flavor.id,
        "networks": [{"uuid": network.id}],
        "user_data": encoded,
        # Tags are how the controller finds the fleet; metadata duplicates it for
        # the older nova filters some tooling still uses.
        "tags": [FLEET_TAG],
        "metadata": {"sivacor_role": "worker"},
    }
    if args.key_name:
        kwargs["key_name"] = args.key_name
    if args.security_group:
        kwargs["security_groups"] = [{"name": g} for g in args.security_group]

    server = conn.compute.create_server(**kwargs)
    print(f"\nCreated {server.name} ({server.id}); waiting for ACTIVE...")
    try:
        # auto_ip is NOT used anywhere here: openstacksdk's higher-level
        # create_server() would allocate a floating IP by default, and workers must
        # not have one -- they reach Girder over the tenant network.
        server = conn.compute.wait_for_server(server, wait=args.timeout)
    except Exception as exc:  # noqa: BLE001
        print(f"!! did not reach ACTIVE within {args.timeout}s: {exc}")
        print(f"   check: openstack console log show {server.id}")
        return 1

    addrs = [
        a["addr"] for lst in (server.addresses or {}).values() for a in lst
    ]
    print(f"ACTIVE. addresses: {', '.join(addrs) or '<none yet>'}")
    print(
        "\nProvisioning runs on first boot (~90 s plus any prepull). Then verify:\n"
        "  on the manager:  celery -A girder_worker.app inspect active_queues\n"
        f"  on the worker :  sudo tail -f /var/log/sivacor-provision.log\n"
        f"  when finished :  {Path(__file__).name} --delete {server.id}"
    )
    return 0


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--cloud", help="clouds.yaml entry; omit to use OS_* env vars")
    p.add_argument("--env-file", type=Path, help="stack .env holding the secrets")
    p.add_argument("--manager-ip", help="manager's TENANT ip (not its floating ip)")
    p.add_argument("--girder-host", help="override GIRDER_HOST in the template")
    p.add_argument("--worker-image", help="override WORKER_IMAGE in the template")
    p.add_argument(
        "--prepull",
        action="append",
        default=[],
        metavar="IMAGE:TAG",
        help="analysis image to fetch before the worker starts; repeatable",
    )
    p.add_argument("--name", help="instance name; default sivacor-worker-<random>")
    p.add_argument("--flavor", default=DEFAULTS["flavor"])
    p.add_argument("--image", default=DEFAULTS["image"], help="Glance image name")
    p.add_argument("--network", default=DEFAULTS["network"])
    p.add_argument(
        "--key-name",
        default=DEFAULTS["key_name"],
        help=(
            f"SSH keypair name (default: {DEFAULTS['key_name']}). "
            'Pass --key-name "" to launch with no keypair -- the worker self-starts, '
            "but then there is no way in if provisioning fails."
        ),
    )
    p.add_argument(
        "--security-group", action="append", default=[], help="repeatable"
    )
    p.add_argument("--timeout", type=int, default=600)
    p.add_argument("--yes", action="store_true", help="skip confirmation")
    p.add_argument("--dry-run", action="store_true", help="print user-data and exit")
    p.add_argument(
        "--show-secrets",
        action="store_true",
        help="with --dry-run, do not redact the injected secrets",
    )
    p.add_argument("--list", action="store_true", help="list fleet instances")
    p.add_argument("--delete", metavar="ID_OR_NAME", help="delete one instance")
    args = p.parse_args()

    if args.list:
        return cmd_list(connect(args.cloud))
    if args.delete:
        return cmd_delete(connect(args.cloud), args.delete, args.yes)

    env_path = args.env_file or next(
        (HERE / n for n in (".env", ".env.test") if (HERE / n).is_file()),
        HERE / ".env",
    )
    env = parse_env(env_path)
    secrets = {k: env.get(k, "") for k in REQUIRED_SECRETS}
    missing = [k for k, v in secrets.items() if not v]
    if missing:
        sys.exit(
            f"{', '.join(missing)} not found in {env_path}.\n"
            "Without both, the worker would boot with FILL_ME placeholders and "
            "refuse to start. Point --env-file at the manager's .env."
        )

    manager_ip = args.manager_ip or env.get("MANAGER_TENANT_IP", "")
    if not manager_ip:
        sys.exit(
            "Manager tenant IP unknown. Pass --manager-ip, or set "
            "MANAGER_TENANT_IP in the .env. On the manager:\n"
            "  ip -4 addr show dev enp1s0 | awk '/inet /{print $2}'"
        )

    # Deliberately NOT defaulted from the stack's GIRDER_SIVACOR_IMAGE: that pins the
    # *manager's* image, and silently reusing it for the worker means a stale or
    # deliberately-pinned manager value retargets every worker with no warning.
    # (.env.test really did carry :p0-correctness, four commits behind, when this was
    # written.) The template's WORKER_IMAGE is the authoritative worker value; only an
    # explicit --worker-image overrides it. A mismatch is still worth surfacing,
    # because worker and manager running different builds is its own class of bug.
    stack_image = env.get("GIRDER_SIVACOR_IMAGE")
    if stack_image and not args.worker_image:
        template_image = re.search(
            r'^WORKER_IMAGE="\$\{WORKER_IMAGE:-([^}]*)\}"',
            TEMPLATE.read_text(),
            re.M,
        )
        if template_image and stack_image not in template_image.group(1):
            print(
                f"note: stack GIRDER_SIVACOR_IMAGE={stack_image} differs from the "
                f"worker default {template_image.group(1)}. Using the worker default; "
                "pass --worker-image to override.",
                file=sys.stderr,
            )

    userdata = build_userdata(
        secrets,
        manager_ip,
        args.girder_host or (f"girder.{env['domain']}" if "domain" in env else None),
        args.worker_image,
        args.prepull,
    )

    if args.dry_run:
        print(userdata if args.show_secrets else redact(userdata, secrets))
        if not args.show_secrets:
            print(
                "\n# secrets redacted; --show-secrets to reveal",
                file=sys.stderr,
            )
        return 0

    return cmd_create(connect(args.cloud), args, userdata)


if __name__ == "__main__":
    sys.exit(main())
