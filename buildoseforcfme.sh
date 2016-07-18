#!/bin/bash
# Create an OSEv3 group that contains the masters and nodes groups
 
MASTERFQDN='master.local.domb.com'
#NODE1FQDN='node1.local.domb.com'
#NODE2FQDN='node2.local.domb.com'
#NODE3FQDN='node3.local.domb.com'
SUBDOMAIN='apps.local.domb.com'
HAWKULARFQDN=$MASTERFQDN
USER1=admin
USER2=''
######################################################################
 
cd ~
 
echo "Writing Ansible HOSTS File"
cat <<EOF | tee /etc/ansible/hosts
[OSEv3:children]
masters
nodes
 
# Set variables common for all OSEv3 hosts
[OSEv3:vars]
# SSH user, this user should allow ssh based auth without requiring a password
ansible_ssh_user=root
osm_default_subdomain=$SUBDOMAIN
 
# If ansible_ssh_user is not root, ansible_sudo must be set to true
#ansible_sudo=true
 
deployment_type=openshift-enterprise
 
# uncomment the following to enable htpasswd authentication; defaults to DenyAllPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/htpasswd'}]
 
# host group for masters
[masters]
$MASTERFQDN
 
# host group for nodes, includes region info
[nodes]
$MASTERFQDN openshift_node_labels="{'region': 'infra', 'zone': 'default'}"
#$NODE1FQDN openshift_node_labels="{'region': 'primary', 'zone': 'east'}"
#$NODE2FQDN openshift_node_labels="{'region': 'primary', 'zone': 'west'}"
#$NODE3FQDN openshift_node_labels="{'region': 'primary', 'zone': 'west'}"
EOF
 
echo "Running Asible"
ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml
 
echo "making master node schedulable"
oadm manage-node $MASTERFQDN --schedulable=true
 
 
if [ -n "${USER1}" ]; then
    echo "Creating user $USER1"
    htpasswd /etc/origin/htpasswd $USER1
    oadm policy add-cluster-role-to-user cluster-admin $USER1
fi
 
if [ -n "${USER2}" ]; then
    echo "Creating user $USER2"
    htpasswd /etc/origin/htpasswd $USER2
fi
 
echo "login as admin"
oc login -u system:admin
 
echo "creating registery"
oadm registry --service-account=registry --config=/etc/origin/master/admin.kubeconfig --credentials=/etc/origin/master/openshift-registry.kubeconfig --images='registry.access.redhat.com/openshift3/ose-${component}:${version}' --mount-host=/images
 
echo "creating cert"
CA=/etc/origin/master
oadm ca create-server-cert --signer-cert=$CA/ca.crt --signer-key=$CA/ca.key --signer-serial=$CA/ca.serial.txt --hostnames='*.$SUBDOMAIN' --cert=cloudapps.crt --key=cloudapps.key
cat cloudapps.crt cloudapps.key $CA/ca.crt > cloudapps.router.pem
 
echo "Adding router"
#oadm router --default-cert=cloudapps.router.pem --credentials='/etc/origin/master/openshift-router.kubeconfig' --selector='region=infra' --images='registry.access.redhat.com/openshift3/ose-${component}:${version}' --service-account router
 
oc project management-infra
oadm policy add-role-to-user -n management-infra admin -z management-admin
oadm policy add-role-to-user -n management-infra management-infra-admin -z management-admin
oadm policy add-cluster-role-to-user cluster-reader system:serviceaccount:management-infra:management-admin
oadm policy add-scc-to-user privileged system:serviceaccount:management-infra:management-admin
oc sa get-token -n management-infra management-admin > /root/cfme4token.txt
 
echo "Createing Metrics"
oc project openshift-infra
oc create -f - <<API
apiVersion: v1
kind: ServiceAccount
metadata:
  name: metrics-deployer
secrets:
- name: metrics-deployer
API
 
oadm policy add-role-to-user \
    edit system:serviceaccount:openshift-infra:metrics-deployer
 
oadm policy add-cluster-role-to-user \
    cluster-reader system:serviceaccount:openshift-infra:heapster
 
oc secrets new metrics-deployer nothing=/dev/null
cp /usr/share/openshift/examples/infrastructure-templates/enterprise/metrics-deployer.yaml metrics-deployer.yaml
oc new-app -f metrics-deployer.yaml \
    -p HAWKULAR_METRICS_HOSTNAME=$HAWKULARFQDN \
    -p USE_PERSISTENT_STORAGE=false
 
 
############## Not needed for CF 4.1 and OSE 3.2 ######################################################
echo "creating router for managmeent metrics"
#### This router must, at the moment, run on the master nodes to expose the metrics on the port 5000 to CloudForms Management Engine, hence the need for a selector on the kubernetes.io/hostname of the master node. ####
 
oadm router management-metrics -n default --credentials=/etc/origin/master/openshift-router.kubeconfig --service-account=router --ports='443:5000' --selector="kubernetes.io/hostname=$MASTERFQDN" --stats-port=1937 --host-network=false
 
#######################################################################################################
 
echo "MAUNUAL SETPS"
echo "add line to /etc/origin/master-config.yaml"
echo "assetConfig:"
echo "metricsPublicURL: https://$MASTERFQDN/hawkular/metrics"
