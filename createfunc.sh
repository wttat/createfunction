#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to extract vnet name from subnet ID
extract_vnet_name() {
    local subnet_id=$1
    # Extract vnet name from subnet ID using regex
    if [[ $subnet_id =~ virtualNetworks/([^/]+)/subnets ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

# Function to display help message
show_help() {
    echo "Usage: $0 -s SUBSCRIPTION -g RESOURCE_GROUP -l LOCATION -b MAX_BURST -f FUNCTION_APP_NAME -r RUNTIME -o OS -t FUNCTION_TYPE -k SKU [-p PLAN_NAME] [-n SUBNET_ID] [-i SP_ID] [-a STORAGE_ACCOUNT] [-m APP_INSIGHTS]"
    echo "  -s  Subscription ID"
    echo "  -g  Resource group name"
    echo "  -l  Location"
    echo "  -b  The maximum number of elastic workers for App plan."
    echo "  -f  Function app name"
    echo "  -r  Runtime (e.g., java nodejs, python)"
    echo "  -v  Runtime version (e.g., 8, 12, 3.8)"
    echo "  -o  OS (e.g., Windows, Linux)"
    echo "  -t  Function type (e.g., consumption, premium)"
    echo "  -k  SKU (e.g., EP1, P1v2), only for premium plan or App Service plan"
    echo "  -p  Existing plan name (optional)"
    echo "  -n  Subnet ID for VNet integration (optional)"
    echo "      Format: /subscriptions/{subscription}/resourceGroups/{resourceGroup}/providers/Microsoft.Network/virtualNetworks/{vnetName}/subnets/{subnetName}"
    echo "  -i  Service Principal ID to assign (optional)"
    echo "  -a  Existing storage account name (optional)"
    echo "  -m  Existing Application Insights name (optional)"
    echo "  -h  Display help"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f yutefun12 -r java -v 8.0 -o Linux -t premium -k EP1"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f yutefun12 -r java -v 8.0 -o Linux -t consumption"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f yutefun12 -r java -v 8.0 -o Linux -t appserviceplan -k B1"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f yutefun12 -r java -v 8.0 -o Linux -t premium -k EP1 -n /subscriptions/sub-id/resourceGroups/rg-name/providers/Microsoft.Network/virtualNetworks/vnet-name/subnet/subnet-name"
    echo " eg :./createfunc.sh -s subscriptionid -g functiontest11 -l eastus2 -f yutefun12 -r java -v 8.0 -o Linux -t premium -k EP1 -m existing-appinsights"
}

# Parse command line arguments
while getopts ":s:g:l:b:f:r:v:o:t:k:p:n:i:a:m:h" opt; do
  case ${opt} in
    s ) subscription_id=$OPTARG;;
    g ) resource_group=$OPTARG;;
    l ) location=$OPTARG;;
    b ) max_burst=$OPTARG;;
    f ) function_app_name=$OPTARG;;
    r ) runtime=$OPTARG;;
    v ) runtime_version=$OPTARG;;
    o ) os=$OPTARG;;
    t ) function_type=$OPTARG;;
    k ) sku=$OPTARG;;
    p ) existing_plan_name=$OPTARG;;
    n ) subnet_id=$OPTARG;;
    i ) sp_id=$OPTARG;;
    a ) storage_account=$OPTARG;;
    m ) app_insights=$OPTARG;;
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

# Validate existing plan if specified
if [ -n "$existing_plan_name" ]; then
    echo "Validating existing plan: $existing_plan_name"
    if ! az appservice plan show --name "$existing_plan_name" --resource-group "$resource_group" >/dev/null 2>&1; then
        if [ "$function_type" == "premium" ]; then
            echo "Premium plan $existing_plan_name does not exist, creating it..."
            az functionapp plan create --resource-group "$resource_group" --name "$existing_plan_name" --location "$location" --sku "$sku" --is-linux $is_linux --max-burst $max_burst
            echo "Premium plan $existing_plan_name created successfully"
        elif [ "$function_type" == "appserviceplan" ]; then
            echo "App Service Plan $existing_plan_name does not exist, creating it..."
            az appservice plan create --resource-group "$resource_group" --name "$existing_plan_name" --location "$location" --sku "$sku" --is-linux $is_linux --max-burst $max_burst
            echo "App Service Plan $existing_plan_name created successfully"
        else
            echo "Error: App Service Plan $existing_plan_name does not exist in resource group $resource_group"
            exit 1
        fi
    fi
    echo "Existing plan $existing_plan_name validated successfully"
fi


# Set storage account name
if [ -n "$storage_account" ]; then
    echo "Using existing storage account: $storage_account"
    storage_account_name=$storage_account
    # Verify the storage account exists
    if ! az storage account show --name $storage_account_name --resource-group $resource_group >/dev/null 2>&1; then
        echo "Error: Storage account $storage_account_name does not exist in resource group $resource_group"
        exit 1
    fi
else
    # Use default naming convention for new storage account
    storage_account_name=$(echo "${function_app_name}storage" | tr '[:upper:]' '[:lower:]')
    echo "Creating storage account $storage_account_name in resource group $resource_group."
    az storage account create --name $storage_account_name --location $location --resource-group $resource_group --sku Standard_LRS
    echo "Storage account $storage_account_name created successfully in resource group $resource_group."
fi

functionsVersion="4"
function_app_plan_name="${function_app_name}-plan"
funcapp_sp_name="${function_app_name}-sp"

# Determine OS settings
if [ "$os" == "Linux" ]; then
    is_linux=true
else
    is_linux=false
fi

# Handle Application Insights
if [ -n "$app_insights" ]; then
    echo "Checking existing Application Insights: $app_insights"
    # Verify the Application Insights exists
    if ! az monitor app-insights component show --app $app_insights --resource-group $resource_group >/dev/null 2>&1; then
        echo "Application Insights $app_insights does not exist, creating it..."
        az monitor app-insights component create --app $app_insights --location $location --resource-group $resource_group --application-type web
        echo "Application Insights $app_insights created successfully"
    fi
    app_insights_key=$(az monitor app-insights component show --app $app_insights --resource-group $resource_group --query instrumentationKey -o tsv)
    echo "Using Application Insights: $app_insights"
fi



# Create azure function plan based on function type
if [ "$function_type" == "appserviceplan" ]; then
    if [ -n "$existing_plan_name" ]; then
        if [ -n "$app_insights" ]; then
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $existing_plan_name --app-insights $app_insights --app-insights-key $app_insights_key
        else
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $existing_plan_name
        fi
    else
        az functionapp plan create --resource-group $resource_group --name $function_app_plan_name --location $location --sku $sku --is-linux $is_linux
        if [ -n "$app_insights" ]; then
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $function_app_plan_name --app-insights $app_insights --app-insights-key $app_insights_key
        else
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $function_app_plan_name
        fi
    fi
elif [ "$function_type" == "consumption" ]; then
    if [ -n "$app_insights" ]; then
        az functionapp create --consumption-plan-location $location --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --app-insights $app_insights --app-insights-key $app_insights_key
    else
        az functionapp create --consumption-plan-location $location --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion
    fi
elif [ "$function_type" == "flex-consumption" ]; then
    if [ -n "$app_insights" ]; then
        az functionapp create --flexconsumption-location $location --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --app-insights $app_insights --app-insights-key $app_insights_key
    else
        az functionapp create --flexconsumption-location $location --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion
    fi
elif [ "$function_type" == "premium" ]; then
    if [ -n "$existing_plan_name" ]; then
        if [ -n "$app_insights" ]; then
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $existing_plan_name --app-insights $app_insights --app-insights-key $app_insights_key
        else
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $existing_plan_name
        fi
    else
        az functionapp plan create --resource-group $resource_group --name $function_app_plan_name --location $location --sku $sku --is-linux $is_linux
        if [ -n "$app_insights" ]; then
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $function_app_plan_name --app-insights $app_insights --app-insights-key $app_insights_key
        else
            az functionapp create --name $function_app_name --os-type $os --resource-group $resource_group --runtime $runtime --runtime-version $runtime_version --storage-account $storage_account_name --functions-version $functionsVersion --plan $function_app_plan_name
        fi
    fi
else
    echo "Invalid function type specified. Supported values are: consumption, premium, appserviceplan"
    exit 1    
fi


echo "Function app $function_app_name created successfully in resource group $resource_group."

az resource update --resource-group  $resource_group --name $function_app_name --set properties.dnsConfiguration.dnsAltServer=168.63.129.16 --resource-type "Microsoft.Web/sites"

if [ -z "$app_insights" ]; then
    app_insights="$function_app_name"
    
fi


# VNet integration if subnet_id is provided
if [ -n "$subnet_id" ]; then
    vnet_name=$(extract_vnet_name "$subnet_id")
    if [ -n "$vnet_name" ]; then
        # Extract resource group from subnet ID
        if [[ $subnet_id =~ resourceGroups/([^/]+)/providers ]]; then
            vnet_resource_group="${BASH_REMATCH[1]}"
            # Verify VNet exists
            if az network vnet show --name "$vnet_name" --resource-group "$vnet_resource_group" >/dev/null 2>&1; then
                echo "Integrating function app with VNet: $vnet_name, subnet: $subnet_id"
                az functionapp vnet-integration add --name $function_app_name --resource-group $resource_group --vnet $vnet_name --subnet $subnet_id
                echo "VNet integration completed successfully."
            else
                echo "Error: VNet $vnet_name not found in resource group $vnet_resource_group"
                exit 1
            fi
        else
            echo "Error: Could not extract resource group from subnet ID"
            exit 1
        fi
    else
        echo "current: $subnet_id"
        echo "Error: Invalid subnet ID format. Expected format:"
        echo "/subscriptions/{subscription}/resourceGroups/{resourceGroup}/providers/Microsoft.Network/virtualNetworks/{vnetName}/subnets/{subnetName}"
        exit 1
    fi
fi

# Handle service principal assignment

if [ -n "$sp_id" ]; then
    echo "Using existing service principal ID: $sp_id"
    funcappscope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Web/sites/$function_app_name"
    storagescope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Storage/storageAccounts/$storage_account_name"
    applicationinsightsscope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.insights/components/$app_insights"

    # Assign Owner role to the existing service principal for the function app
    echo "Assigning Owner role to existing service principal for function app $function_app_name"
    az role assignment create --assignee $sp_id --role Owner --scope $funcappscope
    
    # Assign Storage Account Contributor role to the existing service principal
    echo "Assigning Storage Account Contributor role to existing service principal"
    az role assignment create --role "Storage Account Contributor" --assignee $sp_id --scope $storagescope

    # Assign Application Insights owner role to the existing service principal
    echo "Assigning Application Insights Owner role to existing service principal"
    az role assignment create  --role "Owner" --assignee $sp_id --scope $applicationinsightsscope
    
    # Get service principal details for env file
    sp_details=$(az ad sp show --id $sp_id --query "{clientId:appId,tenantId:appOwnerOrganizationId}" -o json)
    client_id=$(echo $sp_details | jq -r '.clientId')
    tenant_id=$(echo $sp_details | jq -r '.tenantId')
    
    # Note: Client secret cannot be retrieved for existing SP, user needs to manage it separately
    echo "Using existing service principal. Please manage client secret separately."
else
    echo "no service principal ID provided, creating a new service principal."
    # create assign service principal access to azure function 
    # Subscription ID (replace with your actual subscription ID)
    #subscription_id=$(az account show --query "id" -o tsv)
    sp_output=$(az ad sp create-for-rbac --name $funcapp_sp_name --output json)

    client_id=$(echo $sp_output | jq -r '.appId')
    client_secret=$(echo $sp_output | jq -r '.password')
    
    tenant_id=$(echo $sp_output | jq -r '.tenant')
    funcappscope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Web/sites/$function_app_name"
    storagescope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.Storage/storageAccounts/$storage_account_name"
    applicationinsightsscope="/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.insights/components/$app_insights"


    # Assign the storage account write access to the service principal
    echo "Assigning Storage Account Contributor role to service principal $client_id for storage account $storage_account_name."
    az role assignment create --role "Storage Account Contributor" --assignee $client_id --scope $storagescope
    echo "Service principal $client_id has been assigned the Storage Account Contributor role for storage account $storage_account_name."

    # Assign Owner role to the service principal for the function app
    echo "Assgin $funcapp_sp_name Owner to function app $function_app_name."
    az role assignment create --assignee $client_id --role Owner --scope $funcappscope

    # Assign Application Insights owner role to the existing service principal
    echo "Assigning Application Insights Owner role to existing service principal"
    az role assignment create  --role "Owner" --assignee $sp_id --scope $applicationinsightsscope

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
    if [ -n "$app_insights" ]; then
        echo "export AZURE_APP_INSIGHTS_NAME=$app_insights" >> $function_app_name.env
        echo "export AZURE_APP_INSIGHTS_KEY=$app_insights_key" >> $function_app_name.env
    fi
fi



# Confirm successful creation of the function app
echo "Function app $function_app_name has been created successfully."

