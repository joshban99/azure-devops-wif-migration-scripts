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

# Main loop to allow processing multiple projects/service endpoints
while ($true) {
    # Prompt the user to enter the name of the project they want to select or choose to skip
    $selectedProjectName = Read-Host "Enter the name of the project you want to select (or type 'skip' to not pick a specific project, or 'exit' to quit)"
    if ($selectedProjectName -eq 'exit') {
        Write-Host "Exiting script."
        break
    }
    if ($selectedProjectName -eq 'skip') {
        Write-Host "No specific project selected. Proceeding without selecting a project."
        $projectsToProcess = $projects | Sort-Object name
        $selectedServiceEndpointName = 'skip'
    }
    else {
        # Find the project with the specified name
        $selectedProject = $projects | Where-Object { $_.name -eq $selectedProjectName }
        if ($null -eq $selectedProject) {
            Write-Host "Project '$selectedProjectName' not found."
            continue
        }
        # Filter the list of projects to only include the selected project
        $projectsToProcess = $selectedProject
    }

    # Iterate over each project in the list of projects
    foreach ($project in $projectsToProcess) {
        # Define choices for the user to decide what to do with the project
        $projectChoices = @(
            [System.Management.Automation.Host.ChoiceDescription]::new("&Check", "Checking project '$($project.name)'...")
            [System.Management.Automation.Host.ChoiceDescription]::new("&Skip", "Skipping project '$($project.name)'...")
            [System.Management.Automation.Host.ChoiceDescription]::new("&Exit", "Exit script")
        )
        # Prompt message for the project
        $projectPrompt = "Check project '$($project.name)'?"
        # Prompt the user to choose an action for the project
        $projectDecision = $Host.UI.PromptForChoice([string]::Empty, $projectPrompt, $projectChoices, 0)

        # Handle the user's decision
        if ($projectDecision -eq 0) {
            Write-Host "$($projectChoices[$projectDecision].HelpMessage)"
        }
        elseif ($projectDecision -eq 1) {
            Write-Host "$($PSStyle.Formatting.Warning)$($projectChoices[$projectDecision].HelpMessage)$($PSStyle.Reset)"
            continue 
        }
        elseif ($projectDecision -ge 2) {
            Write-Host "$($PSStyle.Formatting.Warning)$($projectChoices[$projectDecision].HelpMessage)$($PSStyle.Reset)"
            break
        }

        # Inner loop for service endpoint selection in the same project
        while ($true) {
            # Prompt for service endpoint name
            $selectedServiceEndpointName = Read-Host "Enter the name of the service endpoint you want to select (or type 'skip' to process all endpoints, or 'exit' to quit this project)"
            if ($selectedServiceEndpointName -eq 'exit') {
                Write-Host "Exiting current project."
                break
            }

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
            # Filter service endpoints if a specific name was provided
            if ($selectedServiceEndpointName -and $selectedServiceEndpointName -ne 'skip') {
                $serviceEndpoints = $serviceEndpoints | Where-Object { $_.name -eq $selectedServiceEndpointName }
                if (!$serviceEndpoints -or ($serviceEndpoints.count -eq 0)) {
                    Write-Warning "Service endpoint '$selectedServiceEndpointName' not found in project '$($project.name)'"
                    continue
                }
            }

            # Iterate over each service endpoint in the list
            foreach ($serviceEndpoint in $serviceEndpoints) {
                Write-Host "`n$(($PSStyle.Foreground.Cyan) + 'DETAILS:' + $PSStyle.Reset) Checking service connection '$($serviceEndpoint.name)' in project '$($project.name)'..." -ForegroundColor Cyan

                # Check if the subscription exists
                $subscriptionId = $serviceEndpoint.data.subscriptionid
                if (!$subscriptionId) {
                    Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' does not have a subscription ID." -ForegroundColor Yellow
                    $subscription = $null
                }
                else {
                    $subscription = $allSubs | Where-Object { $_.id -eq $subscriptionId }
                }
                if (!$subscription) {
                    # Prompt to delete the service connection if the subscription is missing
                    $deleteSubScChoices = @(
                        [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Delete service connection '$($serviceEndpoint.name)'")
                        [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Do not delete service connection '$($serviceEndpoint.name)'")
                    )
                    $deleteSubScPrompt = "$(($PSStyle.Foreground.Blue) + 'QUESTION: ' + $PSStyle.Reset) Subscription with ID '$subscriptionId' not found. Do you want to delete service connection '$($serviceEndpoint.name)'?"
                    $deleteSubScDecision = $Host.UI.PromptForChoice([string]::Empty, $deleteSubScPrompt, $deleteSubScChoices, 0)
                    if ($deleteSubScDecision -eq 0) {
                        $servicePrincipalId = $serviceEndpoint.authorization.parameters.serviceprincipalid
                        $servicePrincipal = $allSpns | Where-Object { $_.appId -eq $servicePrincipalId }
                        if ($servicePrincipal -and ($servicePrincipal.passwordCredentials | Where-Object { $_.displayName -ne "Automated creation" }).count -eq 0) {
                            # prompt to delete the service principal
                            $deleteSpChoices = @(
                                [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Delete service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))")
                                [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Do not delete service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))")
                            )
                            $deleteSpPrompt = "$(($PSStyle.Foreground.Blue) + 'QUESTION: ' + $PSStyle.Reset) Do you want to delete the service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))?"
                            $deleteSpDecision = $Host.UI.PromptForChoice([string]::Empty, $deleteSpPrompt, $deleteSpChoices, 0)
                            if ($deleteSpDecision -eq 0) {
                                Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Deleting service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))..." -ForegroundColor Yellow
                                az ad sp delete --id $servicePrincipalId
                                Write-Host "$(($PSStyle.Foreground.Green) + 'SUCCESS:' + $PSStyle.Reset) Service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId)) deleted." -ForegroundColor Green
                                Write-Host "$(($PSStyle.Foreground.Red) + 'ERROR:' + $PSStyle.Reset) Subscription with ID '$subscriptionId' not found. Deleting service connection '$($serviceEndpoint.name)'." -ForegroundColor Red
                                $deleteApiUrl = "${OrganizationUrl}/_apis/serviceendpoint/endpoints/$($serviceEndpoint.id)?projectIds=$($project.id)&api-version=7.1"
                                Invoke-RestMethod -Uri $deleteApiUrl -Method Delete -Headers $header
                                Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' deleted." -ForegroundColor Yellow
                            }
                            else {
                                Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId)) not deleted." -ForegroundColor Yellow
                            }
                        }
                        else {
                            if (($servicePrincipal.passwordCredentials | Where-Object { $_.displayName -ne "Automated creation" }).count -gt 0) {
                                Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId)) has secrets so skipping service connection." -ForegroundColor Yellow
                                continue
                            }
                        }
                        if (!$servicePrincipal) {
                            Write-Host "$(($PSStyle.Foreground.Red) + 'ERROR:' + $PSStyle.Reset) Service principal with ID '$servicePrincipalId' not found. Deleting service connection '$($serviceEndpoint.name)'." -ForegroundColor Red
                            $deleteApiUrl = "${OrganizationUrl}/_apis/serviceendpoint/endpoints/$($serviceEndpoint.id)?projectIds=$($project.id)&api-version=7.1"
                            Invoke-RestMethod -Uri $deleteApiUrl -Method Delete -Headers $header
                            Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' deleted." -ForegroundColor Yellow
                        }
                    }
                    else {
                        Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' not deleted." -ForegroundColor Yellow
                    }
                    continue
                }
                else {
                    # Check if the service principal exists
                    $servicePrincipalId = $serviceEndpoint.authorization.parameters.serviceprincipalid
                    $servicePrincipal = $allSpns | Where-Object { $_.appId -eq $servicePrincipalId }
                    if (!$servicePrincipal) {
                        # Prompt to delete the service connection if the service principal is missing
                        $deleteScChoices = @(
                            [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Delete service connection '$($serviceEndpoint.name)'")
                            [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Do not delete service connection '$($serviceEndpoint.name)'")
                        )
                        $deleteScPrompt = "$(($PSStyle.Foreground.Blue) + 'QUESTION: ' + $PSStyle.Reset) Service principal with ID '$servicePrincipalId' not found. Do you want to delete service connection '$($serviceEndpoint.name)'?"
                        $deleteScDecision = $Host.UI.PromptForChoice([string]::Empty, $deleteScPrompt, $deleteScChoices, 0)
                        if ($deleteScDecision -eq 0) {
                            Write-Host "$(($PSStyle.Foreground.Red) + 'ERROR:' + $PSStyle.Reset) Service principal with ID '$servicePrincipalId' not found. Deleting service connection '$($serviceEndpoint.name)'." -ForegroundColor Red
                            $deleteApiUrl = "${OrganizationUrl}/_apis/serviceendpoint/endpoints/$($serviceEndpoint.id)?projectIds=$($project.id)&api-version=7.1"
                            Invoke-RestMethod -Uri $deleteApiUrl -Method Delete -Headers $header
                            Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' deleted." -ForegroundColor Yellow
                        }
                        else {
                            Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' not deleted." -ForegroundColor Yellow
                        }
                        continue
                    }
                    elseif (($servicePrincipal.passwordCredentials | Where-Object { $_.displayName -ne "Automated creation" }).count -eq 0) {
                        $deleteSpChoices = @(
                            [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Delete service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))")
                            [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Do not delete service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))")
                        )
                        $deleteSpPrompt = "$(($PSStyle.Foreground.Blue) + 'QUESTION: ' + $PSStyle.Reset) Do you want to delete the service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))?"
                        $deleteSpDecision = $Host.UI.PromptForChoice([string]::Empty, $deleteSpPrompt, $deleteSpChoices, 0)
                        if ($deleteSpDecision -eq 0) {
                            Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Deleting service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))..." -ForegroundColor Yellow
                            az ad sp delete --id $servicePrincipalId
                            Write-Host "$(($PSStyle.Foreground.Green) + 'SUCCESS:' + $PSStyle.Reset) Service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId)) deleted." -ForegroundColor Green
                            Write-Host "$(($PSStyle.Foreground.Red) + 'ERROR:' + $PSStyle.Reset) Subscription with ID '$subscriptionId' not found. Deleting service connection '$($serviceEndpoint.name)'." -ForegroundColor Red
                            $deleteApiUrl = "${OrganizationUrl}/_apis/serviceendpoint/endpoints/$($serviceEndpoint.id)?projectIds=$($project.id)&api-version=7.1"
                            Invoke-RestMethod -Uri $deleteApiUrl -Method Delete -Headers $header
                            Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' deleted." -ForegroundColor Yellow
                        }
                        else {
                            Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId)) not deleted." -ForegroundColor Yellow
                        }
                        continue
                    }
                    else {
                        Write-Host "$(($PSStyle.Foreground.Green) + 'SUCCESS:' + $PSStyle.Reset) Service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId)) exists." -ForegroundColor Green
                    }

                    if ($serviceEndpoint.authorization.scheme -ne "ServicePrincipal") {
                        Write-Host "$(($PSStyle.Foreground.Yellow) + 'INFO:' + $PSStyle.Reset) Service connection '$($serviceEndpoint.name)' uses federated credential. Skipping conversion." -ForegroundColor Yellow
                        continue
                    }

                    # Define choices for the user to decide what to do with the service endpoint
                    $choices = @(
                        [System.Management.Automation.Host.ChoiceDescription]::new("&Convert", "$(($PSStyle.Foreground.Cyan) + 'DETAILS:' + $PSStyle.Reset) Converting service connection '$($serviceEndpoint.name)'...")
                        [System.Management.Automation.Host.ChoiceDescription]::new("&Skip", "$(($PSStyle.Foreground.Cyan) + 'DETAILS:' + $PSStyle.Reset) Skipping service connection '$($serviceEndpoint.name)'...")
                        [System.Management.Automation.Host.ChoiceDescription]::new("&Exit", "$(($PSStyle.Foreground.Cyan) + 'DETAILS:' + $PSStyle.Reset) Exit script")
                    )
                    # Prompt message for the service endpoint
                    $prompt = $serviceEndpoint.isShared ? "$(($PSStyle.Foreground.Blue) + 'QUESTION: ' + $PSStyle.Reset) Convert shared service connection '$($serviceEndpoint.name)'?" : "$(($PSStyle.Foreground.Blue) + 'QUESTION: ' + $PSStyle.Reset)Convert service connection '$($serviceEndpoint.name)'?"
                    # Prompt the user to choose an action for the service endpoint
                    $decision = $Host.UI.PromptForChoice([string]::Empty, $prompt, $choices, $serviceEndpoint.isShared ? 1 : 0)

                    # Handle the user's decision
                    if ($decision -eq 0) {
                        Write-Host "$($choices[$decision].HelpMessage)"
                    }
                    elseif ($decision -eq 1) {
                        Write-Host "$($PSStyle.Formatting.Warning)$($choices[$decision].HelpMessage)$($PSStyle.Reset)"
                        continue
                    }
                    elseif ($decision -ge 2) {
                        Write-Host "$($PSStyle.Formatting.Warning)$($choices[$decision].HelpMessage)$($PSStyle.Reset)"
                        break
                    }

                    # Create a federated credential for the service principal
                    Write-Host ("$(($PSStyle.Foreground.Cyan) + 'DETAILS:' + $PSStyle.Reset) Creating federated credential in '$($serviceEndpoint.authorization.parameters.serviceprincipalid)'" ) -ForegroundColor Cyan
                    $json = '{\"name\": \"ADO-' + ($project.name -replace " ", "") + '\", \"issuer\": \"https://vstoken.dev.azure.com/TENANT_ID\", \"subject\": \"sc://ORG_NAME/' + $project.name + '/' + $serviceEndpoint.name + '\", \"audiences\": [\"api://AzureADTokenExchange\"]}'
                    $federatedCredential = az ad app federated-credential create --id $serviceEndpoint.authorization.parameters.serviceprincipalid --parameters $json
                    if (!$federatedCredential) {
                        Write-Host "$(($PSStyle.Foreground.Red) + 'ERROR:' + $PSStyle.Reset) Failed to create federated credential for service principal $($servicePrincipal.displayName) ($($servicePrincipal.appId))" -ForegroundColor Red
                        continue
                    }

                    # Wait for the federated credential to be created
                    Write-Host ("$(($PSStyle.Foreground.Cyan) + 'DETAILS:' + $PSStyle.Reset) Waiting for federated credential to sync...") -ForegroundColor Cyan
                    Start-Sleep -Seconds 20

                    # Prepare request body for converting the service connection
                    $convertBody = @{
                        id                               = $serviceEndpoint.id
                        type                             = "AzureRM"
                        authorization                    = @{ scheme = "WorkloadIdentityFederation" }
                        serviceEndpointProjectReferences = @(@{
                                description      = ""
                                name             = $serviceEndpoint.name
                                projectReference = @{
                                    id   = $project.id
                                    name = $project.name
                                }
                            })
                    } | ConvertTo-Json -Depth 100 -Compress
                    $putApiUrl = "${OrganizationUrl}/_apis/serviceendpoint/endpoints/$($serviceEndpoint.id)?operation=ConvertAuthenticationScheme&api-version=${apiVersion}"
                    # Convert the service connection
                    $header["Content-Type"] = "application/json"
                    $updatedServiceEndpoint = Invoke-RestMethod -Uri $putApiUrl -Method Put -Body $convertBody -Headers $header

                    # Output the result of the conversion
                    if ($updatedServiceEndpoint) {
                        Write-Host "$(($PSStyle.Foreground.Green) + 'SUCCESS:' + $PSStyle.Reset) Successfully converted service connection '$($serviceEndpoint.name)'" -ForegroundColor Green
                    }
                    else {
                        Write-Host "$(($PSStyle.Foreground.Red) + 'ERROR:' + $PSStyle.Reset) Failed to convert service connection '$($serviceEndpoint.name)'" -ForegroundColor Red
                        continue
                    }
                }
            }
            # After processing, prompt to continue with another service endpoint in the same project
            $continueSE = Read-Host "Do you want to process another service endpoint in this project? (y/n)"
            if ($continueSE -notin @('y', 'Y', 'yes', 'Yes')) {
                break
            }
        }
    }
    # Prompt to process another project/service endpoint or exit
    $continueChoice = Read-Host "Do you want to process another project or service endpoint? (y/n)"
    if ($continueChoice -notin @('y', 'Y', 'yes', 'Yes')) {
        Write-Host "Exiting script."
        break
    }
}
