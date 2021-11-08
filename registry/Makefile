# This Makefile tests deploying the private registry, copying a container to it and deploying from there

test-all: deploy-registry copy-hello-world deploy-hello-world cleanup-hello-world


deploy-registry:
	-kubectl apply -f ./registry.yml
	kubectl --namespace kube-system get pods

copy-hello-world:
	docker pull hello-world
	docker tag hello-world:latest master0:5000/hello-world
	docker push master0:5000/hello-world

deploy-hello-world:
	-kubectl create namespace test
	kubectl apply -f ./hello.yml
	kubectl --namespace test get pods
	@echo "Sleeping 10s"
	@sleep 10
	kubectl --namespace test logs -f hello

cleanup-hello-world:
	kubectl --namespace test delete pod hello
	kubectl delete namespace test

