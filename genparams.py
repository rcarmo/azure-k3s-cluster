#!/bin/env python3 
from base64 import b64encode
from os import environ
from json import dumps, loads
from os.path import exists, join
from sys import stderr, stdout
from string import Template
from urllib.request import urlopen

def slurp(filename, as_template=True):
    with open("cloud-config/" + filename, "r") as config:
        if as_template:
            # parse a YAML file and replace ${VALUE}s
            buffer = Template(config.read()).safe_substitute(environ)
        else:
            buffer = config.read()
    return b64encode(bytes(buffer, 'utf-8')).decode()

ADMIN_USERNAME = environ['ADMIN_USERNAME']
OWN_PUBKEY = join(environ['HOME'],'.ssh','id_rsa.pub')
GEN_PUBKEY = 'keys/' + ADMIN_USERNAME + '.pub'

if (environ.get('OWN_KEY','false').lower() == 'true') and exists(OWN_PUBKEY):
    admin_public_key = open(OWN_PUBKEY,'r').read()
    stderr.write('Warning: using %s instead of freshly generated keys.\n' % OWN_PUBKEY)
elif exists(GEN_PUBKEY):
    admin_public_key = open(GEN_PUBKEY,'r').read()
else:
    stderr.write('No public keys found, exiting.\n')
    exit(1)

# Figure out our public IP address and apply an ACL
if (environ.get('APPLY_ORIGIN_NSG','false').lower() == 'true'):
    allowed_management_ips = []
    res = loads(urlopen('https://ipinfo.io/json').read().decode('utf-8'))
    ip = res['ip']
    stderr.write('Your public IP is ' + ip + '. Applying NSG to SSH.\n')
    allowed_management_ips.append(ip)
else:
    allowed_management_ips = ["*"]

# Retrieve the list of Cloudflare proxies and apply an ACL so the ingress only accepts traffic from those
if (environ.get('APPLY_CLOUDFLARE_NSG','false').lower() == 'true'):
    allowed_ingress_ips = allowed_management_ips
    cf = loads(urlopen('https://api.cloudflare.com/client/v4/ips').read().decode("utf-8"))
    if cf['success'] is True:
        stderr.write('Adding Cloudflare CIDRs to HTTP(S) NSG.\n')
        for i in cf['result']['ipv4_cidrs']:
            allowed_ingress_ips.append(i)
        # IPv6 cannot currently be specified in the same rule, so we're leaving it out for now
        #for i in cf['result']['ipv6_cidrs']:
        #    allowed_ingress_ips.append(i)
        # allow access from controlling machine
        res = loads(urlopen('https://ipinfo.io/json').read().decode('utf-8'))
        ip = res['ip']
        stderr.write('Your public IP is ' + ip + '. Adding to HTTP(S) NSG.\n')
    else:
        stderr.write('Could not retrieve Cloudflare CIDRs, exiting.\n')
        exit(1)
else:
    allowed_ingress_ips = allowed_management_ips

params = {
    "adminUsername": {
        "value": ADMIN_USERNAME
    },
    "adminPublicKey": {
        "value": admin_public_key
    },
    "masterCount": { 
        "value": int(environ.get('MASTER_COUNT', 1))
    },
    "masterSSHPort": { 
        "value": int(environ.get('SSH_PORT', 22))
    },
    "masterManagementAllowedSourceAddressPrefixes": { 
    "value": allowed_management_ips
    },
    "masterIngressAllowedSourceAddressPrefixes": { 
        "value": allowed_ingress_ips
    },
    "masterCustomData": {
        "value": slurp("master.yml")
    },
    "agentCount": {
        "value": int(environ.get('AGENT_COUNT', 2))
    },
    "minAgentCount": {
        "value": int(environ.get('MIN_AGENT_COUNT', 1))
    },
    "maxAgentCount": {
        "value": int(environ.get('MAX_AGENT_COUNT', 5))
    },
    "agentCustomData": {
        "value": slurp("agent.yml")
    },
    "masterSize": {
        "value": "Standard_B2s"
    },
    "agentSize": {
        "value": "Standard_F2s_v2"
    },
    "diskType": {
        "value": "Standard_LRS"
    }
}

stdout.write(dumps(params, indent=4))
