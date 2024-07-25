#!/bin/bash -e
set -o pipefail

export GOVC_URL=
export GOVC_USERNAME=
export GOVC_PASSWORD=
export GOVC_INSECURE=true
export GOVC_DATACENTER=

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
		echo "Error: Unable to get vCenter information from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	GOVC_USERNAME=$(grep -i user /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${GOVC_USERNAME}" ]
	then
		echo "Error: Unable to get vCenter username from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
    	dc=$(grep -i datacenters /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${dc}" ]
	then
		echo "Error: Unable to get Datacenter name from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	# The password has a lot of random characters. Care needs to be taken to read it. We probably need to find a better solution. 
	TEMP_PASSWORD=$(grep -i password /tmp/cns.txt |awk -F' = ' '{print $2}')
	if [ -z "${TEMP_PASSWORD}" ]
	then
		echo "Error: Unable to get vCenter password from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	GOVC_PASSWORD_0="${TEMP_PASSWORD%\"}"
	GOVC_PASSWORD_0="${GOVC_PASSWORD_0#\"}"
	echo "${GOVC_PASSWORD_0}"
	IFS=
	read -r pw <<< "${GOVC_PASSWORD_0}"
	echo "$pw"
	#Filter out PVs that are created on the Supervisor only
	GOVC_PASSWORD="$pw" govc session.login
	IFS=$' \t\n'

    	GOVC_DATACENTER=$(govc datacenter.info --json|jq -r --arg dc "$dc" '.datacenters[]|select(.self.value == $dc)|.name')
    	if [ -z "${GOVC_DATACENTER}" ]
	then
		echo "Error: Unable to get valid Datacenter name. Exiting..."
		exit 1
	fi

	# Get all CNS volumes for the vCenter containing ContainerClusterArray item of type GUEST_CLUSTER. This filters out the PVs created directly on the Supervisor.
	# Need to check how to filter by storage/cluster???
	workload_pv=$(govc volume.ls -json | jq -r '[ .volume[]|select(.Metadata.ContainerClusterArray != null and any (.Metadata.ContainerClusterArray[]; .ClusterFlavor == "GUEST_CLUSTER")) ]')
	if [ -z "${workload_pv}" ]
	then
		echo "Status: No Workload Cluster specific persistant volume found. Exiting..."
		exit 0
	fi

	# Dumping the above array to individual files.
	echo "${workload_pv}"| jq -cr '.[]| .VolumeId.Id, .' | awk 'NR%2{f=$0".json";next} {print >f;close(f)}'

	for filename in *.json
	do
		#echo "Status: Now processing file ${filename}."
		num_cluster_flavor=$(jq -r '.Metadata.ContainerClusterArray|length' "${filename}")

		# We may need to filter the volume with only one GUEST_CLUSTER and one WORKLOAD. Only WORKLOAD implies a PV created on a Supervisor Cluster.
		# Need to check if the value can be more than 2 (probably for RWM??)
		if [ "$num_cluster_flavor" -eq 2 ]
		then
            		# Once we have filtered this, we need to get the .Metadata.ContainerClusterArray[].ClusterID value where the .Metadata.ContainerClusterArray[].ClusterFlavor == "GUEST_CLUSTER".
			# Get the clusterID of the Guest cluster. 
            		# This is the TKG cluster ID.
			clusterid=$(jq -r '.Metadata.ContainerClusterArray[]| select(.ClusterFlavor == "GUEST_CLUSTER")|.ClusterId' "${filename}")

			# Search for the above ClusterID in .Metadata.EntityMetadata[].ClusterID where .Metadata.EntityMetadata[].EntityType = PERSISTENT_VOLUME or .Metadata.EntityMetadata[].EntityType = PERSISTENT_VOLUME_CLAIM. If found, ignore.
			cluster_found=$(jq -r --arg cid "$clusterid" '.Metadata.EntityMetadata[]|select (.ClusterID == $cid and (.EntityType == "PERSISTENT_VOLUME" or .EntityType == "PERSISTENT_VOLUME_CLAIM"))' "${filename}")
			if [ "$cluster_found" ]
			then
				echo "Status: ${filename} has no orphan volumes."
				rm -f "${filename}"
			else
				echo "Status: ${filename} has an orphaned volume that may need to be removed."

				storagepolicyid=$(jq -r '.StoragePolicyId' "${filename}")
				pv_name=$(jq -r '.Name' "${filename}")
				pvc_name=$(jq -r '.Metadata.EntityMetadata[]|select (.EntityType == "PERSISTENT_VOLUME_CLAIM")|.Namespace' "${filename}")
				namespace=$(jq -r '.Metadata.EntityMetadata[]|select (.EntityType == "PERSISTENT_VOLUME_CLAIM")|.EntityName' "${filename}")

				# Before deleting, check if the .StoragePolicyId is in the list of StoragePolicyId of all the StorageClasses of the current Supervisor.
				spid_found=$(kubectl get storageclass -o json | jq -r --arg spid "$storagepolicyid" '.items[].parameters|select (.storagePolicyID == $spid)')
				if [ "$spid_found" ]
				then
					# If the reclaim policy of the PV is Delete, then delete the corresponding PVC.
                    			reclaimpolicy=$(kubectl get pv "${pv_name}" -o json|jq -r '.spec.persistentVolumeReclaimPolicy')
                    			if [ "$reclaimpolicy" == "Delete" ]
                    			then
						echo "kubectl delete pvc ${pvc_name} -n ${namespace}"
                    			else
                        			echo "${pv_name} has a reclaimpolicy of Retain. Ignoring..."
                    			fi
				fi
			fi
		fi
	done

else
	echo "Error: Unable to extract vSphere login credentials. Make sure the secret vsphere-config-secret in vmware-system-csi namespace has valid information. Exiting..."
	exit 1
fi

#Cleanup before you exit
#rm -f /tmp/cns.txt
