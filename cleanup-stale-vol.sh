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

echo "Status: Initializing script..."
kubectl get secret -n vmware-system-csi vsphere-config-secret -o json|jq -r '.data."vsphere-cloud-provider.conf"'|base64 -d > /tmp/cns.txt
if [ -f /tmp/cns.txt ]
then
	GOVC_URL=$(grep -i VirtualCenter /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${GOVC_URL}" ]
	then
		echo "Error: Unable to get vCenter information from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
        echo "Init: vCenter URL is - ${GOVC_URL}"

	GOVC_USERNAME=$(grep -i user /tmp/cns.txt |awk -F'"' '{print $2}')
	if [ -z "${GOVC_USERNAME}" ]
	then
		echo "Error: Unable to get vCenter username from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
     	echo "Init: vCenter Username is - ${GOVC_USERNAME}"
    
    	supervisor=$(grep -i supervisor-id /tmp/cns.txt |awk -F'"' '{print $2}')
    	if [ -z "${supervisor}" ]
    	then
        	echo "Error: Unable to get Supervisor ID from secret vsphere-config-secret. Exiting..."
        	exit 1
    	fi
	SUPERVISOR_ID=vSphereSupervisorID-"${supervisor}"
	echo "Init: Supervisor ID is - ${SUPERVISOR_ID}"

	TEMP_PASSWORD=$(grep -i password /tmp/cns.txt |awk -F' = ' '{print $2}')
	if [ -z "${TEMP_PASSWORD}" ]
	then
		echo "Error: Unable to get vCenter password from secret vsphere-config-secret. Exiting..."
		exit 1
	fi
	GOVC_PASSWORD_0="${TEMP_PASSWORD%\"}"
	GOVC_PASSWORD_0="${GOVC_PASSWORD_0#\"}"
#	echo "${GOVC_PASSWORD_0}"

	IFS=
	read -r pw <<< "${GOVC_PASSWORD_0}"
#	echo "$pw"
	#Filter out PVs that are created on the Supervisor only
	#GOVC_PASSWORD="${pw}" govc session.login -verbose=true
	GOVC_PASSWORD="${pw}"
	IFS=$' \t\n'

	# Get all CNS volumes for the vCenter containing ContainerClusterArray item of type GUEST_CLUSTER. This filters out the PVs created directly on the Supervisor. Only PVs that have been created on guest clusters are returned. 
	workload_pv=$(govc volume.ls -json | jq -r '[ .volume[]|select(.Metadata.ContainerClusterArray != null and any (.Metadata.ContainerClusterArray[]; .ClusterFlavor == "GUEST_CLUSTER")) ]')
	if [ -z "${workload_pv}" ]
	then
		echo "Status: No Workload Cluster persistant volume found. Exiting..."
		exit 0
	fi

	# Dumping the above array of CNS volumes to individual files.
	echo "${workload_pv}"| jq -cr '.[]| .VolumeId.Id, .' | awk 'NR%2{f=$0".json";next} {print >f;close(f)}'

    	echo;echo;
	echo "Status: Checking for Orphan CNS volumes created on workload clusters..."
    	for filename in *.json
	do
		echo "Status: Now processing file ${filename}."

		# Check if the CNS volume belongs to the Supervisor with the ID of SUPERVISOR_ID. If not, skip to the next file. If it does, do further processing. 
		supid=$(jq -r '.Metadata.ContainerCluster.ClusterId' "${filename}")
		if [ -n "${supid}" ]
		then
			if [ "${supid}" != "$SUPERVISOR_ID" ]
			then
				echo "Status: The CNS volume in json file does not belong to the Supervisor. Ignoring file..."
				rm -f "${filename}"
                		continue
			fi
		else
			echo "Error: Could not capture valid Metadata.ContainerCluster.ClusterId in the json file. Ignoring file..."
			rm -f "${filename}"
            		continue
		fi

       	 	# Get the number of items in .Metadata.ContainerClusterArray. It should not have a count of 1 but greater than 1. 
		num_cluster_flavor=$(jq -r '.Metadata.ContainerClusterArray|length' "${filename}")
		if [ "$num_cluster_flavor" -gt 1 ]
		then
            		# Once we have filtered this, we need to get the .Metadata.ContainerClusterArray[].ClusterID value where the .Metadata.ContainerClusterArray[].ClusterFlavor == "GUEST_CLUSTER".
			# Get the all the clusterID of the Guest cluster.
            		# These are the TKG cluster IDs.
			clusterids=$(jq -r '.Metadata.ContainerClusterArray[]| select(.ClusterFlavor == "GUEST_CLUSTER")|.ClusterId' "${filename}")
#            		echo "$clusterids"

            		found=0
            		for clusterid in $clusterids
            		do
                		# Search for the above ClusterID in .Metadata.EntityMetadata[].ClusterID where .Metadata.EntityMetadata[].EntityType = PERSISTENT_VOLUME or .Metadata.EntityMetadata[].EntityType = PERSISTENT_VOLUME_CLAIM. If found, ignore.
                		cluster_found=$(jq -r --arg cid "$clusterid" '.Metadata.EntityMetadata[]|select (.ClusterID == $cid and (.EntityType == "PERSISTENT_VOLUME" or .EntityType == "PERSISTENT_VOLUME_CLAIM"))' "${filename}")
                		if [ "$cluster_found" ]
                		then
                    			echo "Status: ${filename} has no orphan volumes."
                    			found=1
                		fi
            		done

            		if [ "$found" -eq 0 ]
            		then        
                		echo "Status: ${filename} has an orphaned volume that needs to be cleaned."
                		pv_name=$(jq -r '.Name' "${filename}")
               	 		storagepolicyid=$(jq -r '.StoragePolicyId' "${filename}")
                		namespace=$(jq -r '.Metadata.EntityMetadata[]|select (.EntityType == "PERSISTENT_VOLUME_CLAIM")|.Namespace' "${filename}")
                		pvc_name=$(jq -r '.Metadata.EntityMetadata[]|select (.EntityType == "PERSISTENT_VOLUME_CLAIM")|.EntityName' "${filename}")

                		# Before deleting, check if the .StoragePolicyId is in the list of StoragePolicyId of all the StorageClasses of the current Supervisor.
                		spid_found=$(kubectl get storageclass -o json | jq -r --arg spid "$storagepolicyid" '.items[].parameters|select (.storagePolicyID == $spid)')
                		if [ "$spid_found" ]
                		then
                			# If reclaim policy of the PV is Delete, then delete the corrosponding PVC.
                    			reclaimpolicy=$(kubectl get pv "${pv_name}" -o json|jq -r '.spec.persistentVolumeReclaimPolicy')
                    			if [ "$reclaimpolicy" == "Delete" ]
                    			then
                        			echo "kubectl delete pvc ${pvc_name} -n ${namespace}"
                    			else
                        			echo "Status: ${pv_name} has a reclaimPolicy of Retain. Ignoring..."
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
