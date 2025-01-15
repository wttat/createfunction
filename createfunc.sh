#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e


# Function to display help message
show_help() {
    echo "Usage: $0 -s SUBSCRIPTION -g RESOURCE_GROUP -l LOCATION -f FUNCTION_APP_NAME -r RUNTIME -o OS -t FUNCTION_TYPE -k SKU"
    echo "  -s  Subscription ID"
    echo "  -g  Resource group name"
    echo "  -l  Location"
    echo "  -f  Function app name"
    echo "  -r  Runtime (e.g., java nodejs, python)"
    echo "  -v  Runtime version (e.g., 8, 12, 3.8)"
    echo "  -o  OS (e.g., Windows, Linux)"
    echo "  -t  Function type (e.g., consumption, premium)"
    echo "  -k  SKU (e.g., EP1, P1v2), only for premium plan or App Service plan"
    echo "  -h  Display help"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f abcfun12 -r java -v 8.0 -o Linux -t premium -k EP1"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f abcfun12 -r java -v 8.0 -o Linux -t consumption"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f abcfun12 -r java -v 8.0 -o Linux -t appserviceplan -k B1"
}

# Parse command line arguments
while getopts ":s:g:l:f:r:v:o:t:k:h" opt; do
  case ${opt} in
    s ) subscription_id=$OPTARG;;
    g ) resource_group=$OPTARG;;
    l ) location=$OPTARG;;
    f ) function_app_name=$OPTARG;;
    r ) runtime=$OPTARG;;
    v ) runtime_version=$OPTARG;;
    o ) os=$OPTARG;;
    t ) function_type=$OPTARG;;
    k ) sku=$OPTARG;;
    h ) show_help; exit 0;;
    \? ) echo "Invalid option: $OPTARG" 1>&2; show_help; exit 1;;
    : ) echo "Invalid option: $OPTARG requires an argument" 1>&2; show_help; exit 1;;
  esac
done



# Ensure all mandatory parameters are specified
if [ -z "$resource_group" ] || [ -z "$subscription_id" ] || [ -z "$location" ] || [ -z "$function_app_name" ] || [ -z "$runtime" ] || [ -z "$runtime_version" ] || [ -z "$os" ] || [ -z "$function_type" ]; then
    echo "Error: All parameters are required"
    show_help
    exit 1
fi

# Check if function type is valid
if [[ ! "$function_type" =~ ^(consumption|premium|appserviceplan|flex-consumption)$ ]]; then
    echo "Error: Invalid function type specified. Supported values are: consumption, premium, appserviceplan, flex-consumption"
    show_help
    exit 1
fi

# Check if type is premium or app service plan, then SKU is required
# Validate SKU for premium and appserviceplan types
if [[ "$function_type" =~ ^(premium|appserviceplan)$ ]] && [ -z "$sku" ]; then
    echo "Error: SKU is required for premium or appserviceplan types"
    show_help
    exit 1
fi

# Function to validate runtime and runtime version
validate_runtime() {
    os_type=$1
    runtime=$2
    runtime_version=$3
    # runtime lower case
    runtime=$(echo $runtime | tr '[:upper:]' '[:lower:]')

    if [ "$os_type" == "Linux" ]; then
        valid_runtimes=$(az functionapp list-runtimes --os "linux" | jq -r '.[] | select(.runtime == "'$runtime'" and .version == "'$runtime_version'")')
    else
        valid_runtimes=$(az functionapp list-runtimes --os "windows" | jq -r '.[] | select(.runtime == "'$runtime'" and .version == "'$runtime_version'")')
    fi

    if [ -z "$valid_runtimes" ]; then
        echo "Invalid or unsupported runtime specified for OS $os_type. Supported runtimes and versions are:"
        az functionapp list-runtimes --os "$os_type" | jq -r '.[] | "\(.runtime) \(.version)"'
        exit 1
    fi
}

validate_sku() {
    function_type=$1
    sku=$2

    # Validate sku for premium plan
    if [ "$function_type" == "premium" ]; then
        valid_skus=(EP1 EP2 EP3)
        if [[ ! " ${valid_skus[@]} " =~ " ${sku} " ]]; then
            echo "Invalid SKU specified for premium $sku. Supported SKUs are: ${valid_skus[@]}"
            exit 1
        fi
    elif [ "$function_type" == "appserviceplan" ]; then
        valid_skus=(B1 S1 P1v2 B2 S2 P2v2 B3 S3 P3v2 P0v3 P1v3 P2v3 I2v2 P1mv3 P3v3 P2mv3 I4v2 P3mv3 P4mv3 P5mv3)
        if [[ ! " ${valid_skus[@]} " =~ " ${sku} " ]]; then
            echo "Invalid SKU specified for appserviceplan $sku. Supported SKUs are: ${valid_skus[@]}"
            exit 1
        fi    
    fi
}    
    


# Validate runtime against the specified OS
validate_runtime $os $runtime $runtime_version
validate_sku $function_type $sku

# storage account name lowercase
storage_account_name=$(echo "${function_app_name}storage" | tr '[:upper:]' '[:lower:]')
functionsVersion="4"
function_app_plan_name="${function_app_name}-plan"
funcapp_sp_name="${function_app_name}-sp"




# Create a storage account for the function app
echo "Creating storage account $storage_account_name in resource group $resource_group."
# check if storage account exists, if 
az storage account create --name $storage_account_name --location $location --resource-group $resource_group --sku Standard_LRS
echo "Storage account $storage_account_name created successfully in resource group $resource_group."

# Determine OS settings
if [ "$os" == "Linux" ]; then
    is_linux=true
else
    is_linux=false
fi

# Create azure function plan based on function type
if [ "$function_type" == "appserviceplan" ]; then
    az functionapp plan create --resource-group $resource_group --name $function_app_plan_name --location $location --sku $sku --is-linux $is_linux
    az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $function_app_plan_name
elif [ "$function_type" == "consumption" ]; then
    az functionapp create --consumption-plan-location $location --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion
elif [ "$function_type" == "flex-consumption" ]; then
   az functionapp create --flexconsumption-location $location --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion
elif [ "$function_type" == "premium" ]; then
    az functionapp plan create --resource-group $resource_group --name $function_app_plan_name --location $location --sku $sku --is-linux $is_linux
    az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $function_app_plan_name
else
    echo "Invalid function type specified. Supported values are: consumption, premium, appserviceplan"
    exit 1    
fi

echo "Function app $function_app_name created successfully in resource group $resource_group."

# create assign service principal access to azure function 
# Subscription ID (replace with your actual subscription ID)
#subscription_id=$(az account show --query "id" -o tsv)
sp_output=$(az ad sp create-for-rbac --name $funcapp_sp_name --output json)
echo "$sp_output"
client_id=$(echo $sp_output | jq -r '.appId')
client_secret=$(echo $sp_output | jq -r '.password')
tenant_id=$(echo $sp_output | jq -r '.tenant')
funcappscope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Web/sites/$function_app_name"
storagescope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Storage/storageAccounts/$storage_account_name"

# Assign Owner role to the service principal for the function app
echo "Assgin $funcapp_sp_name Owner to function app $function_app_name."
az role assignment create --assignee $client_id --role Owner --scope $funcappscope

#echo "exec az ad sp create-for-rbac --name $funcapp_sp_name  --role \"Owner\" --scopes /subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Web/sites/$function_app_name --output json"
#sp_output=$(az ad sp create-for-rbac --name $funcapp_sp_name  --role Owner --scopes /subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Web/sites/$function_app_name --output json)




echo "Service principal $funcapp_sp_name created successfully with client ID $client_id."

# save the service principal details to a fucntion app file
echo "export AZURE_SUBSCRIPTION_ID=$subscription_id" > $function_app_name.env
echo "export AZURE_FUNCTIONAPP_NAME=$function_app_name" >> $function_app_name.env
echo "export AZURE_STORAGE_ACCOUNT_NAME=$storage_account_name" >> $function_app_name.env
echo "export AZURE_CLIENT_ID=$client_id" >> $function_app_name.env
echo "export AZURE_CLIENT_SECRET=$client_secret" >> $function_app_name.env
echo "export AZURE_TENANT_ID=$tenant_id" >> $function_app_name.env


# Assign the storage account write access to the service principal
echo "Assigning Storage Account Contributor role to service principal $funcapp_sp_name"
az role assignment create --role "Storage Account Contributor" --assignee $client_id --scope $storagescope
echo "Service principal $funcapp_sp_name has been assigned the Storage Account Contributor role for storage account $storage_account_name."

# done
echo "Function app $funcapp_sp_name has been created successfully."
