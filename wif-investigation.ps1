# Define the Azure DevOps organization URL
$OrganizationUrl = "https://dev.azure.com/ORG_NAME"

# Define the API version to use for Azure DevOps REST API
$apiVersion = "6.0-preview.4"

# Define the Azure DevOps resource application ID
$azdoResource = "499b84ac-1321-427f-aa17-267ca6975798"

$token = (az account get-access-token --resource $azdoResource | ConvertFrom-Json).accessToken
$header = @{authorization = "Bearer $token" }

# Construct the URL to get the list of projects from Azure DevOps
$getProjectsUrl = "${OrganizationUrl}/_apis/projects?api-version=${apiVersion}"

# Use the Azure CLI to make a REST API call to Azure DevOps to get the list of projects
# Convert the JSON response to a PowerShell object and store it in the $projects variable
$projects = Invoke-RestMethod -Uri $getProjectsUrl -Method Get -Headers $header | Select-Object -ExpandProperty value

$allSubs = az account list --output json | ConvertFrom-Json

$spnToken = (az account get-access-token --resource "https://graph.microsoft.com" | ConvertFrom-Json).accessToken
$spnHeader = @{ authorization = "Bearer $spnToken" }

# Loop to handle @odata.nextLink for applications
$allSpns = @()
$graphUrl = "https://graph.microsoft.com/beta/myorganization/applications"
do {
    $response = Invoke-RestMethod -Uri $graphUrl -Headers $spnHeader
    if ($response.value) {
        $allSpns += $response.value
    }
    $graphUrl = $response.'@odata.nextLink'
} while ($graphUrl)

$results = @()

foreach ($project in $projects) {
    Write-Output "Processing project: $($project.name)"
    # Construct the URL to get the list of service endpoints for the project
    $getApiUrl = "${OrganizationUrl}/$($project.name)/_apis/serviceendpoint/endpoints?type=azurerm&includeFailed=false&includeDetails=true&api-version=${apiVersion}"
    # Use the Azure CLI to make a REST API call to get the list of service endpoints
    Invoke-RestMethod -Uri $getApiUrl -Method Get -Headers $header | Set-Variable rawResponse
    # Convert the JSON response to a PowerShell object and store it in the $serviceEndpoints variable
    $serviceEndpoints = $rawResponse.value | Where-Object { !($_.isShared -and $_.serviceEndpointProjectReferences[0].projectReference.name -ne $project.name) }
    if (!$serviceEndpoints -or ($serviceEndpoints.count -eq 0)) {
        Write-Warning "No convertible service connections found"
        continue
    }

    foreach ($serviceEndpoint in $serviceEndpoints) {
        $resultObject = [PSCustomObject]@{
            ProjectName         = $project.name
            ServiceEndpointName = $serviceEndpoint.name
            AuthScheme          = $serviceEndpoint.authorization.scheme
        }

        if ($serviceEndpoint.data.subscriptionid) {
            $subName = $allSubs | Where-Object { $_.id -eq $serviceEndpoint.data.subscriptionid } | Select-Object -ExpandProperty name
            if (!$subName) {
                $subName = "Not exist"
            }
            $resultObject | Add-Member -NotePropertyName Subscription -NotePropertyValue $subName
            $resultObject | Add-Member -NotePropertyName ManagementGroup -NotePropertyValue "Not applicable"
        }
        elseif ($serviceEndpoint.data.managementGroupName) {
            $resultObject | Add-Member -NotePropertyName ManagementGroup -NotePropertyValue $serviceEndpoint.data.managementGroupName
            $resultObject | Add-Member -NotePropertyName Subscription -NotePropertyValue "Not applicable"
        }
        else {
            $resultObject | Add-Member -NotePropertyName Subscription -NotePropertyValue "Not found"
            $resultObject | Add-Member -NotePropertyName ManagementGroup -NotePropertyValue "Not found"
        }

        if ($serviceEndpoint.authorization.scheme -eq "ServicePrincipal") {
            if ($serviceEndpoint.authorization.parameters.serviceprincipalid) {
                $spnName = $allSpns | Where-Object { $_.appId -eq $serviceEndpoint.authorization.parameters.serviceprincipalid } | Select-Object -ExpandProperty displayName
                if (!$spnName) {
                    $spnName = "Not exist"
                    $spnSecrets = "No secrets found"
                }
                else {
                    $spnSecretsObj = $allSpns | Where-Object { $_.appId -eq $serviceEndpoint.authorization.parameters.serviceprincipalid } | Select-Object -ExpandProperty passwordCredentials | Where-Object { $_.displayName -ne "Automated creation" }
                    $spnSecrets = if ($spnSecretsObj) { ($spnSecretsObj | Measure-Object).Count.ToString() + " secrets found" } else { "No secrets found" }
                }
            }
            else {
                $spnName = "Not found"
            }
            $resultObject | Add-Member -NotePropertyName SpnName -NotePropertyValue $spnName
            $resultObject | Add-Member -NotePropertyName SpnSecrets -NotePropertyValue $spnSecrets
        }

        if (
    ($resultObject.Subscription -eq "Not found" -or $resultObject.Subscription -eq "Not exist" -or $resultObject.Subscription -eq "Not applicable") -and
    ($resultObject.SpnName -eq "Not found" -or $resultObject.SpnName -eq "Not exist") -and
    ($resultObject.ManagementGroup -eq "Not applicable" -or $resultObject.ManagementGroup -eq "null" -or $resultObject.ManagementGroup -eq "Null") -and
            $resultObject.SpnSecrets -eq "No secrets found"
        ) {
            $advice = "Subscription, Service Principal and Secrets not found"
            $action = "Delete service connection"
        }
        elseif (
    ($resultObject.Subscription -ne "Not found" -and $resultObject.Subscription -ne "Not exist" -or $resultObject.Subscription -ne "Not applicable") -and
    ($resultObject.SpnName -eq "Not found" -or $resultObject.SpnName -eq "Not exist")
        ) {
            $advice = "Service Principal not found"
            $action = "Delete service connection"
        }
        elseif (
            $resultObject.SpnSecrets -eq "No secrets found" -and
    ($resultObject.Subscription -eq "Not found" -or $resultObject.Subscription -eq "Not exist" -or $resultObject.Subscription -eq "Not applicable") -and
    ($resultObject.SpnName -ne "Not found" -and $resultObject.SpnName -ne "Not exist") -and
    ($resultObject.ManagementGroup -eq "Not applicable" -or $resultObject.ManagementGroup -eq "null" -or $resultObject.ManagementGroup -eq "Null")
        ) {
            $advice = "Subscription not found and Service Principal has no secrets"
            $action = "Delete service connection and service principal"
        }
        elseif (
    ($resultObject.Subscription -eq "Not found" -or $resultObject.Subscription -eq "Not exist" -or $resultObject.Subscription -eq "Not applicable") -and
    ($resultObject.SpnName -ne "Not found" -and $resultObject.SpnName -ne "Not exist") -and
    ($resultObject.ManagementGroup -eq "Not applicable" -or $resultObject.ManagementGroup -eq "null" -or $resultObject.ManagementGroup -eq "Null")
        ) {
            $advice = "Subscription not found"
            $action = "Investigate service principal with secrets"
        }
        elseif ($resultObject.AuthScheme -eq "ServicePrincipal" -and $serviceEndpoint.name -notlike "*avs*") {
            $advice = "Convert to WIF"
            $action = "Convert to WIF"
        }
        else {
            $advice = "No action required"
            $action = "No action required"
        }

        $resultObject | Add-Member -NotePropertyName Advice -NotePropertyValue $advice
        $resultObject | Add-Member -NotePropertyName Action -NotePropertyValue $action

        if ($advice -ne "No action required" -and $advice -ne "Convert to WIF") {
            $usageHistoryUri = "${OrganizationUrl}/$($project.name)/_apis/serviceendpoint/$($serviceEndpoint.id)/executionhistory?top=30"
            Invoke-RestMethod -Uri $usageHistoryUri -Method Get -Headers $header | Set-Variable usageRawResponse
            $lastUsedTime = $usageRawResponse.value[0].data.finishTime
            $planType = $usageRawResponse.value[0].data.planType
            if ($lastUsedTime -and ($planType -eq "Pipeline" -or $planType -eq "Build")) {
                $resultObject | Add-Member -NotePropertyName LastUsedTime -NotePropertyValue $lastUsedTime
            }
        }

        $results += $resultObject
    }
}

$results | Export-Excel -Path "AzureDevOpsServiceConnections.xlsx" -AutoSize -AutoFilter -ClearSheet -BoldTopRow -FreezeTopRow
