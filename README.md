# Azure DevOps Service Connection Audit & Modernization Toolkit

This repository provides two PowerShell scripts for auditing, cleaning up, and modernizing Azure DevOps service connections, with a focus on migrating from legacy Service Principal authentication to Workload Identity Federation (WIF).

---

## Scripts

### 1. wif-investigation.ps1

**Purpose:**  
Audits all Azure DevOps service connections in your organization and provides actionable recommendations for each connection.

**Key Features:**
- Enumerates all projects and AzureRM service connections.
- Cross-references each connection’s subscription and service principal with Azure and Microsoft Graph.
- Identifies orphaned, misconfigured, or legacy connections.
- Recommends actions: delete, investigate, convert to WIF, or no action required.
- Outputs results to an Excel file (AzureDevOpsServiceConnections.xlsx).

**Usage:**
1. Ensure you have the [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated.
2. Update the `$OrganizationUrl` variable with your Azure DevOps organization URL.
3. Run the script in PowerShell:
   ```powershell
   .\wif-investigation.ps1
   ```
4. Review the generated Excel file for recommendations.

---

### 2. convert-to-wif.ps1 (or `service-connection-lifecycle-manager.ps1`)

**Purpose:**  
Interactively manages Azure DevOps service connections, including conversion to WIF, deletion of orphaned connections, and cleanup of unused service principals.

**Key Features:**
- Interactive prompts to select projects and service connections.
- Checks for missing subscriptions or service principals and offers deletion.
- Creates federated credentials for eligible service principals.
- Converts service connections to Workload Identity Federation using the Azure DevOps REST API.
- Provides clear feedback and confirmation prompts for all actions.

**Usage:**
1. Ensure you have the [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) installed and authenticated.
2. Update the `$OrganizationUrl` variable with your Azure DevOps organization URL.
3. Run the script in PowerShell:
   ```powershell
   .\convert-to-wif.ps1
   ```
4. Follow the interactive prompts to audit, convert, or clean up service connections.

---

## Prerequisites

- PowerShell 7.x recommended
- Azure CLI installed and logged in (`az login`)
- Sufficient permissions in Azure DevOps and Azure AD to read and modify service connections and service principals

---

## Notes

- **Sensitive Data:**  
  The scripts process project names, subscription IDs, and service principal IDs. Review and redact any sensitive information before sharing outputs.
- **Customization:**  
  Update organization-specific variables (e.g., `$OrganizationUrl`) as needed.
- **Excel Export:**  
  The investigation script uses `Export-Excel`. Install the [ImportExcel PowerShell module](https://github.com/dfinke/ImportExcel) if not already present:
  ```powershell
  Install-Module -Name ImportExcel -Scope CurrentUser
  ```

---

## License

MIT License

---

## Disclaimer

These scripts are provided as-is. Test in a non-production environment before use in production. Use at your own risk.

---

**Contributions and feedback are welcome!**
