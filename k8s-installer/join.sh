#!bin/bash
rm -rf /var/lib/kubelet/pki/kubelet-client-current.pem

IDS=$(ls /var/lib/cloud/instances/)
while true
do
    for ID in $IDS
    do
        /usr/local/bin/kubectl --kubeconfig ~/.kube/config patch node $HOSTNAME -p "{\"spec\":{\"providerID\":\"$ID\"}}"
    done
sleep 30
done
