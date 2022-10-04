# Set environment variables
export COMPUTE_GROUP?=k3s-compute
export STORAGE_GROUP?=k3s-storage
export LOCATION?=eastus
export MASTER_COUNT?=1
export MASTER_SKU?=Standard_B1ls
export AGENT_COUNT?=3
export AGENT_SKU?=Standard_B1ls
export AGENT_PRIORITY?=Spot
export MASTER_FQDN=$(COMPUTE_GROUP)-master0.$(LOCATION).cloudapp.azure.com
export LOADBALANCER_FQDN=$(COMPUTE_GROUP)-agents-lb.$(LOCATION).cloudapp.azure.com
export VMSS_NAME=agents
export ADMIN_USERNAME?=cluster
export TIMESTAMP=`date "+%Y-%m-%d-%H-%M-%S"`
export FILE_SHARES=config data registry
export STORAGE_ACCOUNT_NAME?=shared0$(shell echo $(MASTER_FQDN)|shasum|base64|tr '[:upper:]' '[:lower:]'|cut -c -16)
export SHARE_NAME?=data
export SSH_PORT?=2211
export APPLY_CLOUDFLARE_NSG?=false
# This will set both your management and ingress NSGs to your public IP address 
# - since using "*" in an NSG may be disabled by policy
export APPLY_ORIGIN_NSG?=true
export USE_DOCKER?=false
export ENABLE_NVIDIA?=false
export K3S_VERSION=v1.25.2+k3s1
export SHELL=/bin/bash


# Permanent local overrides
-include .env

SSH_KEY_FILES:=$(ADMIN_USERNAME).pem $(ADMIN_USERNAME).pub
SSH_KEY:=$(ADMIN_USERNAME).pem

# Do not output warnings, do not validate or add remote host keys (useful when doing successive deployments or going through the load balancer)
SSH_TO_MASTER:=ssh -p $(SSH_PORT) -q -A -i keys/$(SSH_KEY) $(ADMIN_USERNAME)@$(MASTER_FQDN) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

# dump resource groups
resources:
	az group list --output table

# Dump list of location IDs
locations:
	az account list-locations --output table

sizes:
	az vm list-sizes --location=$(LOCATION) --output table

# Generate SSH keys for the cluster (optional)
keys:
	mkdir keys
	ssh-keygen -b 2048 -t rsa -f keys/$(ADMIN_USERNAME) -q -N ""
	mv keys/$(ADMIN_USERNAME) keys/$(ADMIN_USERNAME).pem
	chmod 0600 keys/*

# Generate the Azure Resource Template parameter files
params:
	$(eval STORAGE_ACCOUNT_KEY := $(shell az storage account keys list \
		--resource-group $(STORAGE_GROUP) \
	    	--account-name $(STORAGE_ACCOUNT_NAME) \
		--query "[0].value" \
		--output tsv | tr -d '"'))
	@mkdir parameters 2> /dev/null; STORAGE_ACCOUNT_KEY=$(STORAGE_ACCOUNT_KEY) python3 genparams.py > parameters/cluster.json

# Cleanup parameters
clean:
	rm -rf parameters

deploy-storage:
	-az group create --name $(STORAGE_GROUP) --location $(LOCATION) --output table 
	-az storage account create \
		--name $(STORAGE_ACCOUNT_NAME) \
		--resource-group $(STORAGE_GROUP) \
		--location $(LOCATION) \
		--https-only \
		--output table
	$(foreach SHARE_NAME, $(FILE_SHARES), \
		az storage share create --account-name $(STORAGE_ACCOUNT_NAME) --name $(SHARE_NAME) --output tsv;)


# Create a resource group and deploy the cluster resources inside it
deploy-compute:
	-az group create --name $(COMPUTE_GROUP) --location $(LOCATION) --output table 
	az group deployment create \
		--template-file templates/cluster.json \
		--parameters @parameters/cluster.json \
		--resource-group $(COMPUTE_GROUP) \
		--name cli-$(LOCATION) \
		--output table \
		--no-wait

redeploy:
	-make destroy-compute
	make params
	while [[ $$(az group list | grep Deleting) =~ "Deleting" ]]; do sleep 30; done
	make deploy-compute

# create a set of SMB shares on the storage account
create-shares:
	$(eval STORAGE_ACCOUNT := $(shell az storage account list --resource-group ci-swarm-cluster --output tsv --query "[].name"))
	$(foreach SHARE_NAME, $(FILE_SHARES), \
		az storage share create --account-name $(STORAGE_ACCOUNT_NAME) --name $(SHARE_NAME) --output tsv;)

# Destroy the entire resource group and all cluster resources

destroy-cluster:
	make destroy-compute
	make destroy-storage

destroy-compute:
	az group delete \
		--name $(COMPUTE_GROUP) \
		--no-wait

destroy-storage:
	az group delete \
		--name $(STORAGE_GROUP) \
		--no-wait

# SSH to master node
proxy:
	-cat keys/cluster.pem | ssh-add -k -
	$(SSH_TO_MASTER) \
	-L 9080:localhost:80 \
	-L 9081:localhost:81 \
	-L 8080:localhost:8080 \
	-L 4040:localhost:4040 \
	-L 5000:localhost:5000

# Show k3s helper log
tail-helper:
	-cat keys/cluster.pem | ssh-add -k -
	$(SSH_TO_MASTER) \
	sudo journalctl -f -u k3s-helper

# View deployment details
view-deployment:
	az group deployment operation list \
		--resource-group $(COMPUTE_GROUP) \
		--name cli-$(LOCATION) \
		--query "[].{OperationID:operationId,Name:properties.targetResource.resourceName,Type:properties.targetResource.resourceType,State:properties.provisioningState,Status:properties.statusCode}" \
		--output table

# Watch deployment
watch-deployment:
	watch az resource list \
		--resource-group acme-prod-k3s-compute \
		--output table

# List VMSS instances
list-agents:
	az vmss list-instances \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--output table 

# Scale VMSS instances
scale-agents-%:
	az vmss scale \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--new-capacity $* \
		--output table \
		--no-wait

# Stop all VMSS instances
stop-agents:
	az vmss stop \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--no-wait

# Start all VMSS instances
start-agents:
	az vmss start \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--no-wait

# Show info
show-agents:
	az vmss show \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--output json

# Individual agent size
resize-agents-up:
	az vmss update \
	   --resource-group $(COMPUTE_GROUP) \
	   --name $(VMSS_NAME) \
	   --set sku.name=Standard_F8s_v2 \
	&& az vmss update-instances \
	   --resource-group $(COMPUTE_GROUP) \
	   --name $(VMSS_NAME) \
	   --instance-ids=* \
	   --no-wait

resize-agents-down:
	az vmss update \
	   --resource-group $(COMPUTE_GROUP) \
	   --name $(VMSS_NAME) \
	   --set sku.name=Standard_F2s_v2 \
	&& az vmss update-instances \
	   --resource-group $(COMPUTE_GROUP) \
	   --name $(VMSS_NAME) \
	   --instance-ids=* \
	   --no-wait

# Reimage VMSS instances
reimage-agents-parallel:
	az vmss reimage --resource-group $(COMPUTE_GROUP) --name $(VMSS_NAME) --no-wait

reimage-agents-serial:
	az vmss list-instances \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--query [].instanceId \
		--output tsv \
	| xargs -I{} az vmss reimage \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--instance-id {} \
		--output table

chaos-monkey:
	az vmss list-instances \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--query [].instanceId \
		--output tsv \
	| shuf \
	| xargs -I{} az vmss restart \
		--resource-group $(COMPUTE_GROUP) \
		--name $(VMSS_NAME) \
		--instance-id {} \
		--output table

# List endpoints
list-endpoints:
	az network public-ip list \
		--resource-group $(COMPUTE_GROUP) \
		--query '[].{dnsSettings:dnsSettings.fqdn}' \
		--output table

