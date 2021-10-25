.PHONY: all help build run docker-build docker-run

all: help

help:
	@echo "run 'make build' and than 'make run'"

build: docker-build
build-dev: docker-build-dev
run: docker-run
dev: docker-run-dev
test: docker-run-test
test-watch: docker-run-dev-test-watch

IMAGE_NAME := minioci
DEV_IMAGE_NAME := $(IMAGE_NAME)-dev
GPU_IMAGE_NAME := $(IMAGE_NAME)-gpu
CONDA_ENV_NAME := minioci
NVIDIA_IMAGE_NAME := nvcr.io/nvidia/pytorch:21.02-py3
REGISTRY := localhost:32000

SHELL=/bin/bash
CONDA_ACTIVATE=source $$(conda info --base)/etc/profile.d/conda.sh ; conda activate ; conda activate
.ONESHELL:
setup-dev-env:
	conda env create -f conda_dev_environment.yml
	($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; pip install -r requirements.dev.txt --extra-index-url=https://blank:$(shell cat .secret.python_packages_pat)@pkgs.dev.azure.com/DatasenticsCommon/_packaging/DatasenticsCommon/pypi/simple/)
	($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; pre-commit install )

local-run-dev:
	@($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; cd src/ && DEBUG=True WORKERS=1 ACCESS_LOG=True ./cli.py)

local-run-test:
	@($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; pytest --cov )

local-run-test-watch:
	@($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; ptw )

deploy-local-start: docker-build
	@docker stack deploy -c docker-compose.local.yml $(CONDA_ENV_NAME)

deploy-local-stop:
	@docker stack rm $(CONDA_ENV_NAME)

deploy-local-logs:
	@docker service logs $(CONDA_ENV_NAME)_base_service -f

docker-run-dev:
	@docker run -it --rm  \
		-v$(shell pwd)/src/app_ocr_extraction:/app/app_ocr_extraction \
		-v$(shell pwd)/src/cli.py:/app/cli.py \
		-v$(shell pwd)/tests:/app/tests \
		-eDEBUG=True \
		-eWORKERS=1 \
		-eACCESS_LOG=True \
		-p5001:5000 \
		$(DEV_IMAGE_NAME) \
		bash

docker-run-test:
	@docker run -t --rm  \
		-v$(shell pwd)/src/app_ocr_extraction:/app/app_ocr_extraction \
		-v$(shell pwd)/tests:/app/tests \
		$(DEV_IMAGE_NAME) \
		pytest

docker-run-dev-test-watch:
	@docker exec -it $(shell docker ps -q -f ancestor=${DEV_IMAGE_NAME}) ptw

docker-run:
	@docker run -it --rm \
		-p5001:5000 \
		$(IMAGE_NAME)

docker-build:
	@DOCKER_BUILDKIT=1 docker build \
		-t $(IMAGE_NAME) \
		--progress=plain \
		--secret id=python_packages_pat,src=.secret.python_packages_pat \
		-f Dockerfile .

docker-build-dev: docker-build
	@DOCKER_BUILDKIT=1 docker build \
		--build-arg=BASE_IMAGE=$(IMAGE_NAME) \
		-t $(DEV_IMAGE_NAME) \
		--progress=plain \
		--secret id=python_packages_pat,src=.secret.python_packages_pat \
		-f Dockerfile.dev .

docker-gpu-build:
	@DOCKER_BUILDKIT=1 docker build \
		--build-arg=BASE_IMAGE=$(NVIDIA_IMAGE_NAME) \
		-t $(GPU_IMAGE_NAME) \
		--progress=plain \
		--secret id=python_packages_pat,src=.secret.python_packages_pat \
		-f Dockerfile.gpu .

trigger:
	@($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; cd src/ && python ./cli.py trigger)

docker-gpu-build-dev: docker-gpu-build
	@DOCKER_BUILDKIT=1 docker build \
		--build-arg=BASE_IMAGE=$(GPU_IMAGE_NAME) \
		-t $(DEV_IMAGE_NAME)-gpu \
		--progress=plain \
		--secret id=python_packages_pat,src=.secret.python_packages_pat \
		-f Dockerfile.gpu.dev .

docker-gpu-run:
	@docker run --gpus all --rm -it \
		-p 5001:5000 \
		--env-file ./src/.env \
		$(GPU_IMAGE_NAME):latest

docker-gpu-build-dev-handtest:
	@DOCKER_BUILDKIT=1 docker build \
		--build-arg=BASE_IMAGE=$(NVIDIA_IMAGE_NAME) \
		-t $(GPU_IMAGE_NAME) \
		--progress=plain \
		--secret id=python_packages_pat,src=.secret.python_packages_pat \
		-f Dockerfile.test.dev . \
		&& docker run --gpus all --rm -it \
		-v$(shell pwd)/src/app_ocr_extraction:/app/app_ocr_extraction \
		-v$(shell pwd)/:/app/rootdir \
		-v$(shell pwd)/tests:/app/tests \
		-p 5050:5000 \
		$(GPU_IMAGE_NAME)

docker-push: docker-build
	@docker tag $(IMAGE_NAME) $(REGISTRY)/$(IMAGE_NAME)
	@docker push $(REGISTRY)/$(IMAGE_NAME)

docker-gpu-push: docker-gpu-build
	@docker tag $(GPU_IMAGE_NAME) $(REGISTRY)/$(GPU_IMAGE_NAME)
	@docker push $(REGISTRY)/$(GPU_IMAGE_NAME)

RENAME ?= changed_name_repo
rename-repo:
	@find . -type f -not -path './.git/*' -print0 | xargs -0 sed -i 's/ocr_extraction/$(RENAME)/g'
	@find . -type f -not -path './.git/*' -print0 | xargs -0 sed -i 's/app_ocr_extraction/app_$(RENAME)/g'
	@mv src/app_ocr_extraction src/app_$(RENAME)
	@git add src/app_$(RENAME)

helm-test:
	helm --namespace datasentics-invoicereader --kube-context=digitoo-staging upgrade --install minioci -f charts/values.dev.yaml charts --dry-run --debug

k8s-local-deploy: docker-push
	helm upgrade --install ds-invoice-ocr-extraction -f charts/values.dev.yaml charts


k8s-digitoo-stage-deploy:
	helm --namespace datasentics-invoicereader --kube-context=digitoo-staging upgrade --install minioci-stage -f charts/values.digitoo-stage.secret.yaml charts

k8s-digitoo-stage-uninstall:
	helm uninstall --namespace datasentics-invoicereader --kube-context=digitoo-staging minioci

k8s-test-deploy:
	helm --namespace gpu-resources --kube-context=digitoo-test upgrade --install minioci -f charts/values.ds-test.secret.yaml charts

k8s-test-uninstall:
	helm uninstall --namespace gpu-resources --kube-context=digitoo-test minioci

install_common:
	@pip uninstall ds-invoicereader-common -y
	@pip install /home/dominik/Documents/invoice/rabbitmq/invoicereader_common/dist/ds_invoicereader_common-1.0.0-py3-none-any.whl

post:
	@curl -F 'image=@tests/invoices/page_images/ae7057a2fa114c0b82b5869f815efc7f_pagenum_0.png' http://localhost:5000/api/v1/ocr


HELM_IMAGE_TAG ?=
HELM_KUBE_CTX ?= digitoo-staging
HELM_NAMESPACE ?= datasentics-invoicereader
HELM_COMMON_CHART ?= values.digitoo-common.yaml
HELM_VALUES_CHART ?= values.digitoo-staging.yaml
HELM_SECRET_CHART ?= values.digitoo-staging.secret.yaml
HELM_SERVICE_NAME ?= $(IMAGE_NAME)
k8s-digitoo-deploy:
	helm secrets upgrade \
		--install $(HELM_SERVICE_NAME)\
		--namespace=$(HELM_NAMESPACE)\
		--kube-context=$(HELM_KUBE_CTX)\
		-f charts/$(HELM_COMMON_CHART)\
		-f charts/$(HELM_VALUES_CHART)\
		-f charts/$(HELM_SECRET_CHART)\
		charts\
		--set image.tag=$(HELM_IMAGE_TAG)

k8s-digitoo-dry:
	helm secrets upgrade --dry-run \
		--install $(HELM_SERVICE_NAME)\
		--namespace=$(HELM_NAMESPACE)\
		--kube-context=$(HELM_KUBE_CTX)\
		-f charts/$(HELM_COMMON_CHART)\
		-f charts/$(HELM_VALUES_CHART)\
		-f charts/$(HELM_SECRET_CHART)\
		charts\
		--set image.tag=$(HELM_IMAGE_TAG)

get-document:
	mc cp -r $(digienv)/documents/$(id) ./tests/invoices/

ocr:
	@($(CONDA_ACTIVATE) $(CONDA_ENV_NAME) ; python src/cli.py ocr)
