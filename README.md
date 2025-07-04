# Investigating and Converting Azure DevOps Service Connections to WIF
Managing Azure DevOps service connections at scale can be challenging, especially when you need to audit, clean up, or migrate authentication schemes. Recently, I used a PowerShell script to investigate all Azure DevOps service connections in our organization, identify issues, and recommend actions—including converting legacy Service Principal connections to Workload Identity Federation (WIF).

## TL;DR
Managing Azure DevOps service connections at scale can be messy, especially with legacy Service Principal (SPN) auth. This blog walks through a PowerShell-based approach to:
- Audit all service connections across projects
- Identify issues like orphaned SPNs, missing secrets, or outdated auth
- Recommend actions (delete, investigate, or convert to WIF)
- Automate conversion of eligible connections to Workload Identity Federation (WIF) for improved security and reduced secret management
- Includes full PowerShell snippets for both investigation and conversion, plus tips for cleanup and validation. Ideal for DevOps teams modernizing their Azure pipeline security.

## Why Investigate Service Connections?
Service connections are critical for pipelines to access Azure resources. Over time, organizations accumulate many connections—some unused, some misconfigured, and some using outdated authentication methods. Migrating to WIF improves security and reduces secret management overhead.

## The Investigation Script
The script I used automates the following:
- **Enumerates all projects** in the Azure DevOps organization.
- **Lists all AzureRM service connections** for each project.
- **Cross-references** each connection’s subscription and service principal with Azure and Microsoft Graph.
- **Checks for missing or orphaned resources** (e.g., subscriptions, SPNs, secrets).
- **Recommends actions: delete**, investigate, or convert to WIF.

You can find the **full investigation script** on [GitHub}().

## Example: Key Excerpt from the Investigation Script
```pwsh
foreach ($serviceEndpoint in $serviceEndpoints) {
    $resultObject = [PSCustomObject]@{
        ProjectName         = $project.name
        ServiceEndpointName = $serviceEndpoint.name
        AuthScheme          = $serviceEndpoint.authorization.scheme
    }

    # Check for subscription or management group
    if ($serviceEndpoint.data.subscriptionid) {
        # ...lookup subscription...
    } elseif ($serviceEndpoint.data.managementGroupName) {
        # ...lookup management group...
    } else {
        # ...not found...
    }

    # Check for Service Principal and secrets
    if ($serviceEndpoint.authorization.scheme -eq "ServicePrincipal") {
        # ...lookup SPN and secrets...
    }

    # Recommend actions
    if ($resultObject.AuthScheme -eq "ServicePrincipal" -and $serviceEndpoint.name -notlike "*avs*") {
        $advice = "Convert to WIF"
        $action = "Convert to WIF"
    } else {
        $advice = "No action required"
        $action = "No action required"
    }

    $resultObject | Add-Member -NotePropertyName Advice -NotePropertyValue $advice
    $resultObject | Add-Member -NotePropertyName Action -NotePropertyValue $action

    $results += $resultObject
}
```

## What the Script Finds
The script outputs an Excel file with all service connections, their status, and recommended actions. Typical findings include:
- **Orphaned connections** (missing subscription or SPN)
- **Connections with no secrets** (potentially broken)
- **Legacy Service Principal connections** (candidates for WIF conversion)
- **Unused connections** (safe to delete)

## Converting Service Connections to WIF with PowerShell
After identifying which Azure DevOps service connections should be converted to Workload Identity Federation (WIF), I used a PowerShell script to automate the conversion process. This script allows you to interactively select projects and service connections, check their status, and convert eligible connections to WIF.

## What the Conversion Script Does
- **Prompts for project and service connection selection**  
  You can process all projects/endpoints or select specific ones.
- **Checks for missing subscriptions or service principals**  
  If a service connection is orphaned, it offers to delete both the connection and its service principal.
- **Creates a federated credential**  
  For eligible service principals, it creates a federated credential required for WIF.
- **Converts the service connection**  
  Uses the Azure DevOps REST API to update the authentication scheme to WorkloadIdentityFederation.
- **Provides clear feedback**  
  Each step outputs status and prompts for confirmation before making changes.

You can find the **full conversion script** on [GitHub}().

## Example: Key Steps from the Conversion Script
```pwsh
# Define the Azure DevOps organization URL
$OrganizationUrl = "https://dev.azure.com/YOUR_ORG"

# ...token and project setup...

while ($true) {
    $selectedProjectName = Read-Host "Enter the name of the project you want to select (or type 'skip' to not pick a specific project, or 'exit' to quit)"
    # ...project selection logic...

    foreach ($project in $projectsToProcess) {
        # ...project prompt...

        while ($true) {
            $selectedServiceEndpointName = Read-Host "Enter the name of the service endpoint you want to select (or type 'skip' to process all endpoints, or 'exit' to quit this project)"
            # ...service endpoint selection logic...

            foreach ($serviceEndpoint in $serviceEndpoints) {
                # ...checks for orphaned subscriptions/SPNs...

                # Create a federated credential for the service principal
                $json = '{\"name\": \"ADO-' + ($project.name -replace " ", "") + '\", \"issuer\": \"https://vstoken.dev.azure.com/YOUR_ORG_ID\", \"subject\": \"sc://YOUR_ORG/' + $project.name + '/' + $serviceEndpoint.name + '\", \"audiences\": [\"api://AzureADTokenExchange\"]}'
                az ad app federated-credential create --id $serviceEndpoint.authorization.parameters.serviceprincipalid --parameters $json
                Start-Sleep -Seconds 20

                # Convert the service connection to WIF
                $convertBody = @{
                    id = $serviceEndpoint.id
                    type = "AzureRM"
                    authorization = @{ scheme = "WorkloadIdentityFederation" }
                    serviceEndpointProjectReferences = @(@{
                        description = ""
                        name = $serviceEndpoint.name
                        projectReference = @{
                            id = $project.id
                            name = $project.name
                        }
                    })
                } | ConvertTo-Json -Depth 100 -Compress
                $putApiUrl = "${OrganizationUrl}/_apis/serviceendpoint/endpoints/$($serviceEndpoint.id)?operation=ConvertAuthenticationScheme&api-version=${apiVersion}"
                Invoke-RestMethod -Uri $putApiUrl -Method Put -Body $convertBody -Headers $header
            }
        }
    }
}
```

## Running the Script
1. Run the script in PowerShell (with Azure CLI installed and logged in).
1. Follow the prompts to select projects and service connections.
1. Review and confirm each conversion or deletion.
1. Check the output for success or error messages.
   
## Benefits
- Reduces manual effort in migrating to WIF.
- Ensures only valid, in-use connections are converted.
- Cleans up orphaned or unused service principals and connections.

## Conclusion
Automating the investigation and migration of Azure DevOps service connections to Workload Identity Federation (WIF) streamlines your DevOps security and management practices. By leveraging PowerShell scripts, you can efficiently audit all service connections, identify outdated or orphaned resources, and convert eligible connections to WIF with minimal manual effort. This not only reduces the risk associated with credential sprawl and secret management but also aligns your pipelines with modern, secure authentication standards.
With these tools and processes in place, your Azure DevOps environment will be more secure, maintainable, and ready for future growth.
