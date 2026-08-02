.PHONY: clean dirs dev images \
	restart_worker restart_girder status update_src 

SUBDIRS = src volumes/base volumes/licenses volumes/tmp
TAG = latest
MEM_LIMIT = 2048
NODE = node --max_old_space_size=${MEM_LIMIT}
NG = ${NODE} ./node_modules/@angular/cli/bin/ng
YARN = /usr/local/bin/yarn

images:
	docker pull traefik:alpine
	docker pull mongo:4.4
	docker pull redis:latest
	docker pull node:carbon-slim
	docker pull xarthisius/girder:$(TAG)

dirs: $(SUBDIRS)
	@touch traefik/acme.json && chmod 600 traefik/acme.json

$(SUBDIRS):
	@sudo mkdir -p $@
	@sudo chown -R $$(id -u):$$(id -g) $@

services: dirs

# Discovered here, not stored in .env: the docker group's GID is a property of THIS
# host, and a stale value in .env is invisible until analysis containers stop
# starting. local_worker's `user:` needs it because Swarm has no group_add. Exported
# after sourcing .env so an explicit value there still wins if a host needs one.
#
# SIVACOR_MANAGER_TENANT_IP is the same kind of value and the same kind of hazard,
# which is why it is discovered the same way. It is the address the autoscaler writes
# into worker user-data, so a stale one produces workers that boot fine and then fail
# to reach the broker -- and on the test mirror it changes on every rebuild, which
# made it a standing per-session edit (10.3.37.91 -> .197 -> ...).
#
# `route get` rather than a named interface: the plan's old recipe was
# `ip -4 addr show dev enp1s0`, and the interface name is not a constant across hosts.
# On an OpenStack instance the NIC carries the FIXED (tenant) address -- a floating IP
# is NAT'd by the neutron router and never appears on the interface -- so the source
# address of any outbound route is exactly the value wanted here, and the floating IP
# cannot be picked up by accident.
dev: services
	. ./.env && export docker_group="$${docker_group:-$$(getent group docker | cut -d: -f3)}" && \
	  export SIVACOR_MANAGER_TENANT_IP="$${SIVACOR_MANAGER_TENANT_IP:-$$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($$i=="src") {print $$(i+1); exit}}')}" && \
	  autoscaler=""; \
	  if [ -n "$${SIVACOR_AUTOSCALING:-}" ]; then \
	    autoscaler="--compose-file docker-stack.autoscaler.yml"; \
	    echo "--- autoscaling: ON (fleet instances will be created and deleted) ---"; \
	  else \
	    echo "--- autoscaling: off (set SIVACOR_AUTOSCALING=1 in .env to enable) ---"; \
	  fi; \
	  echo "--- docker group on this host: $${docker_group} ---" && \
	  echo "--- manager tenant ip: $${SIVACOR_MANAGER_TENANT_IP} ---" && \
	  docker stack config --compose-file docker-stack.yml $${autoscaler} | docker stack deploy --compose-file - wt
	cid=$$(docker ps --filter=name=wt_girder -q);
	while [ -z $${cid} ] ; do \
		  echo $${cid} ; \
		  sleep 1 ; \
	    cid=$$(docker ps --filter=name=wt_girder -q) ; \
	done; \
	true
	. ./.env && ./setup_girder.py

restart_girder:
	docker exec --user=root -ti $$(docker ps --filter=name=wt_girder -q) touch /venv/lib/python3.12/site-packages/requests/__init__.py

restart_worker:
	docker exec --user=root -ti $$(docker ps --filter=name=wt_girder -q) pip install -e /gwvolman
	docker service update --force --image=$$(docker service inspect wt_celery_worker --format={{.Spec.TaskTemplate.ContainerSpec.Image}}) wt_celery_worker

tail_girder_err:
	docker exec -ti $$(docker ps --filter=name=wt_girder -q) \
		tail -n 200 /home/girder/.girder/logs/error.log

reset_girder:
	docker exec -ti $$(docker ps --filter=name=wt_girder -q) \
		python3 -c 'from girder.models import getDbConnection;getDbConnection().drop_database("girder")'

clean:
	-docker stack rm wt
	limit=15 ; \
	until [ -z "$$(docker service ls --filter label=com.docker.stack.namespace=wt -q)" ] || [ "$${limit}" -lt 0 ]; do \
	  sleep 2 ; \
	  limit="$$((limit-1))" ; \
	done; true
	limit=15 ; \
	until [ -z "$$(docker network ls --filter label=com.docker.stack.namespace=wt -q)" ] || [ "$${limit}" -lt 0 ]; do \
	  sleep 2 ; \
	  limit="$$((limit-1))" ; \
	done; true
	for dir in volumes/mountpoints/* ; do \
	  for subdir in $$dir/* ; do \
	    sudo umount -lf $$subdir || true ; \
	  done \
	done; true
	for dir in ps workspaces homes base versions runs mountpoints ; do \
	  sudo rm -rf volumes/$$dir ; \
	done; true
	-docker volume rm wt_mongo-cfg wt_mongo-data
	rm -rf traefik/certs || true
