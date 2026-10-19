NAMESPACE      ?= biasharaos
IMAGE_VERSION  ?= 0.2.0
KUBECTL        ?= kubectl

.DEFAULT_GOAL  := help

.PHONY: help apply secrets delete rollout logs status smoke build-image bootstrap

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

apply: ## Apply namespace + PV + PVC + Service + Ingress + Deployment (in order)
	$(KUBECTL) apply -f k8s/namespace.yaml
	$(KUBECTL) apply -f k8s/persistentvolume.yaml
	$(KUBECTL) apply -f k8s/persistentvolumeclaim.yaml
	$(KUBECTL) apply -f k8s/service.yaml
	$(KUBECTL) apply -f k8s/ingress.yaml
	$(KUBECTL) apply -f k8s/deployment.yaml

secrets: ## Create / update biasharaos-s3 + biasharaos-invoice-token from .env
	./scripts/create-secrets.sh

delete: ## Remove the workload (PV + namespace left intact to protect data)
	$(KUBECTL) delete -f k8s/deployment.yaml --ignore-not-found
	$(KUBECTL) delete -f k8s/ingress.yaml --ignore-not-found
	$(KUBECTL) delete -f k8s/service.yaml --ignore-not-found
	$(KUBECTL) delete -f k8s/persistentvolumeclaim.yaml --ignore-not-found
	$(KUBECTL) delete -f k8s/persistentvolume.yaml --ignore-not-found

rollout: ## Wait up to 180s for the Deployment to roll out
	$(KUBECTL) rollout status deployment/biasharaos -n $(NAMESPACE) --timeout=180s

logs: ## Tail logs from the active Pod
	$(KUBECTL) logs -n $(NAMESPACE) deployment/biasharaos --tail=100 -f

status: ## Show everything in the namespace
	$(KUBECTL) get all,ing,pv,pvc,secret -n $(NAMESPACE)

smoke: ## Hit the Ingress and the upload endpoint
	./scripts/smoke-test.sh

build-image: ## Build + import localhost/biasharaos:$(IMAGE_VERSION) on the worker
	VERSION=$(IMAGE_VERSION) ./scripts/build-and-load-image.sh

bootstrap: ## Fresh-install kernel/sysctl prereqs on this host (NOT for a live cluster)
	./scripts/bootstrap.sh
