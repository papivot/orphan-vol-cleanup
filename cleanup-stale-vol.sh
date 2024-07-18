#!/bin/bash -e
set -o pipefail

export GOVC_URL=
export GOVC_USERNAME=
export GOVC_PASSWORD=
export GOVC_INSECURE=true

if ! command -v govc &> /dev/null
then
	echo "Error: govc could not be found in the PATH. Download and install the latest binary before proceeding. Exiting..."
	exit 1
fi

kubectl get secret -n vmware-system-csi vsphere-config-secret -o json|jq -r '.data."vsphere-cloud-provider.conf"'|base64 -d > /tmp/cns.txt
if [ -f /tmp/cns.txt ]
then
	GOVC_URL=$(grep -i VirtualCenter /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${GOVC_URL}" ]
	then
		echo "Error: Unable to vCenter information from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	GOVC_USERNAME=$(grep -i user /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${GOVC_USERNAME}" ]
	then
		echo "Error: Unable to vCenter username from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	GOVC_PASSWORD=$(grep -i password /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${GOVC_PASSWORD}" ]
	then
		echo "Error: Unable to vCenter password from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	
	#Filter out PVs that are created on the Supervisor only
	workload_pv=$(govc volume.ls -json | jq -r '[ .volume[]|select(.Metadata.ContainerClusterArray != null and any (.Metadata.ContainerClusterArray[]; .ClusterFlavor == "GUEST_CLUSTER")) ]')
	if [ -z "${workload_pv}" ]
	then
		echo "Status: No Workload Cluster persistant volume found. Exiting..."
		exit 0
	fi

	# Dumping this to individual files.
	echo "${workload_pv}"| jq -cr '.[]| .VolumeId.Id, .' | awk 'NR%2{f=$0".json";next} {print >f;close(f)}'

	for filename in *.json
	do
    		#echo "Status: Now processing file ${filename}."
		num_cluster_flavor=$(jq -r '.Metadata.ContainerClusterArray|length' "${filename}")

		# We may need to filter the volume with only ONE GUEST_CLUSTER and ONE WORKLOAD. Only WORKLOAD implies a PV created on a Supervisor Cluster.
		# Need to check if the value can be more than 2 (probably for RWM??)
		if [ "$num_cluster_flavor" -eq 2 ]
		then
			# Once we have filtered this, we need to get the .Metadata.ContainerClusterArray[].ClusterID value where the .Metadata.ContainerClusterArray[].ClusterFlavor == "GUEST_CLUSTER".
			# This is the TKG cluster ID. 
			clusterid=$(jq -r '.Metadata.ContainerClusterArray[]| select(.ClusterFlavor == "GUEST_CLUSTER")|.ClusterId' "${filename}")

			# Search for the above ClusterID in .Metadata.EntityMetadata[].ClusterID where .Metadata.EntityMetadata[].EntityType = PERSISTENT_VOLUME or .Metadata.EntityMetadata[].EntityType = PERSISTENT_VOLUME_CLAIM. If found, ignore. 
			found=$(jq -r --arg cid "$clusterid" '.Metadata.EntityMetadata[]|select (.ClusterID == $cid and (.EntityType == "PERSISTENT_VOLUME" or .EntityType == "PERSISTENT_VOLUME_CLAIM"))' "${filename}")
			if [ "$found" ]
			then
				echo "Status: ${filename} does not have any orphan volumes."
				rm -f "${filename}"
			else
				echo "Status: ${filename} has an orphaned volume that needs to be cleaned."
				pv_name=$(jq -r '.Name' "${filename}")
				echo "kubectl delete pv ${pv_name}"
			fi
		fi
	done

else
	echo "Error: Unable to extract vSphere login credentials. Make sure the secret vsphere-config-secret in vmware-system-csi namespace has valid information. Exiting..."
	exit 1
fi

#Cleanup before you exit
rm -f /tmp/cns.txt
