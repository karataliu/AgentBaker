#!/bin/bash -e

required_env_vars=(
    "SUBSCRIPTION_ID"
    "RESOURCE_GROUP_NAME"
    "GEN2_CAPTURED_SIG_VERSION"
    "LOCATION"
    "OS_TYPE"
    "SIG_IMAGE_NAME"
)


for v in "${required_env_vars[@]}"
do
    if [ -z "${!v}" ]; then
        echo "$v was not set!"
        exit 1
    fi
done

if [[ -z "$SIG_GALLERY_NAME" ]]; then
  SIG_GALLERY_NAME="PackerSigGalleryEastUS"
fi

echo "SIG_GALLERY_NAME is ${SIG_GALLERY_NAME}"
echo "SIG_GALLERY_NAME_FROM_JSON is ${SIG_GALLERY_NAME_FROM_JSON}"

sig_resource_id="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.Compute/galleries/${SIG_GALLERY_NAME}/images/${SIG_IMAGE_NAME}/versions/${GEN2_CAPTURED_SIG_VERSION}"
# Adding ${RANDOM} as suffix because Windows Gen 2 is reusing sigMode. The $GEN2_CAPTURED_SIG_VERSION comes from $SIG_IMAGE_VERSION, which may
# be the same "1.0.0" for cpncurrent production pipelines. If one pipeline fails, the disk resource will not be deleted successfully, leading to the following error
# "(PropertyChangeNotAllowed) Changing property 'imageReference' is not allowed." This is because for later pipeline runs, the $disk_resource_id is the same, but the image
# reference $sig_resource_id is different.
disk_resource_id="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.Compute/disks/${GEN2_CAPTURED_SIG_VERSION}${RANDOM}"

echo "sig_resource_id is ${sig_resource_id}"
echo "disk_resource_id is ${disk_resource_id}"

az resource create --id $disk_resource_id  --is-full-object --location $LOCATION --properties "{\"location\": \"$LOCATION\", \
  \"properties\": { \
    \"osType\": \"$OS_TYPE\", \
    \"creationData\": { \
      \"createOption\": \"FromImage\", \
      \"galleryImageReference\": { \
        \"id\": \"${sig_resource_id}\" \
      } \
    } \
  } \
}"
# shellcheck disable=SC2102
sas=$(az disk grant-access --ids $disk_resource_id --duration-in-seconds 3600 --query [accessSas] -o tsv)

azcopy-preview copy "${sas}" "${CLASSIC_BLOB}/${GEN2_CAPTURED_SIG_VERSION}.vhd${CLASSIC_SAS_TOKEN}" --recursive=true

echo "Converted $sig_resource_id to ${CLASSIC_BLOB}/${GEN2_CAPTURED_SIG_VERSION}.vhd"

az disk revoke-access --ids $disk_resource_id 

az resource delete --ids $disk_resource_id

echo "Deleted $disk_resource_id"