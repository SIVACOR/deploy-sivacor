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

services: dirs

dev: services 
	. ./.env && docker stack config --compose-file docker-stack.yml | docker stack deploy --compose-file - wt
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
