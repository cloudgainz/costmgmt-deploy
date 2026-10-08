# Cost Management exports + Data Mover

Deploys FOCUS cost exports for your Microsoft Customer Agreement (MCA) billing
profile, plus an Azure Data Factory that copies those exports to CloudGainz on a
daily and monthly schedule.

**[Deploy to Azure](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudgainz%2Fcostmgmt-deploy%2Fmain%2Farm%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudgainz%2Fcostmgmt-deploy%2Fmain%2Fui%2FcreateUiDefinition.json)**

```
https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudgainz%2Fcostmgmt-deploy%2Fmain%2Farm%2FmainTemplate.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fcloudgainz%2Fcostmgmt-deploy%2Fmain%2Fui%2FcreateUiDefinition.json
```

The first line of the form shows the template version, e.g.
`Template version: 20261008080808`.

---

## What gets deployed

In the resource group you pick:

- A storage account the cost exports are written to, with a private endpoint,
  virtual network and private DNS zone
- An Azure Data Factory with a pipeline and two schedules (daily and monthly)
  that copy the exports to CloudGainz

On your billing profile:

- Three FOCUS cost exports: one-time, daily (month to date) and monthly (last
  month)

---

## Before you start

### Values from CloudGainz

CloudGainz provides these. Use them exactly as given:

- **Site name** (the destination container)
- **Customer storage account name**
- **Customer SAS token**
- **The export identity setup command** (below)

### The export identity

The exports are created on your billing profile, which sits outside any
subscription. The deployment can't grant itself access there, so it needs a
user-assigned managed identity that already holds **Billing profile
contributor** on the billing profile.

CloudGainz sends you a command that creates this identity and grants the role,
with your values filled in. Run it in **Azure Cloud Shell (Bash)** as someone
who is a **Billing profile owner** and can create resources in the
subscription. For the example values below it looks like this:

```bash
NAME='contoso-adf-focus-umi'
RG='rg-contoso-identity'
LOCATION='eastus'
ACCT='1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d:7e8f9a0b-1c2d-3e4f-5a6b-7c8d9e0f1a2b_2019-05-31'
PROF='AB12-CD34-EF5-GH67'

# resource group only gets created if it isn't there already
if [ "$(az group exists -n "$RG")" != "true" ]; then
  az group create -n "$RG" -l "$LOCATION" -o none
fi
az identity create -g "$RG" -n "$NAME" -l "$LOCATION" -o none
PRINCIPAL=$(az identity show -g "$RG" -n "$NAME" --query principalId -o tsv)
TENANT=$(az account show --query tenantId -o tsv)

# new identities take a moment to show up in Entra
sleep 30

# grant Billing profile contributor on the billing profile
az rest --method post \
  --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$ACCT/billingProfiles/$PROF/createBillingRoleAssignment?api-version=2024-04-01" \
  --body "{\"principalId\":\"$PRINCIPAL\",\"principalTenantId\":\"$TENANT\",\"roleDefinitionId\":\"/providers/Microsoft.Billing/billingAccounts/$ACCT/billingProfiles/$PROF/billingRoleDefinitions/40000000-aaaa-bbbb-cccc-100000000001\"}"

echo "Pick this identity in the deployment form: $NAME"
```

Subscription Owner or Global Administrator alone isn't enough for the last
step. It needs a billing role on the billing profile.

### Finding your billing account and profile IDs

The identity command (`ACCT` and `PROF`) and the deployment form (**Billing
account ID** and **Billing profile ID**) both need these. In **Cloud Shell
(Bash)**:

```bash
# billing accounts you can see - the ACCT column is the billing account ID
az rest --method get \
  --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2024-04-01" \
  --query "value[].{ACCT:name, name:properties.displayName}" -o table

# billing profiles under that account - the PROF column is the billing profile ID
ACCT='1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d:7e8f9a0b-1c2d-3e4f-5a6b-7c8d9e0f1a2b_2019-05-31'
az rest --method get \
  --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$ACCT/billingProfiles?api-version=2024-04-01" \
  --query "value[].{PROF:name, name:properties.displayName}" -o table
```

Example output:

```
ACCT                                                                                  Name
------------------------------------------------------------------------------------  ------------
1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d:7e8f9a0b-1c2d-3e4f-5a6b-7c8d9e0f1a2b_2019-05-31  Contoso Ltd

PROF                Name
------------------  ------------
AB12-CD34-EF5-GH67  Contoso Ltd
```

The commands only list accounts and profiles you have a billing role on. If
nothing comes back, run them as someone with billing access.

In the portal: **Cost Management + Billing → Billing scopes** → your billing
account → **Settings → Properties** shows the billing account ID. **Billing
profiles** → your profile → **Settings → Properties** shows the billing profile
ID.

### Who runs the deployment

Whoever fills in the form needs **Owner** on the target subscription or
resource group. The deployment creates role assignments for the export
identity and the Data Factory.

---

## Example values

These are made up but realistic, and the rest of this guide uses them.

### Basics

| Form field | Example | Notes |
|---|---|---|
| Subscription | `contoso-prod-01` | |
| Resource group | `rg-contoso-costmgmt` | Create new |
| Region | `East US` | |
| Name prefix | `contosocm` | 3-14 lowercase letters/numbers. The storage account becomes this plus 6 random characters, e.g. `contosocm4x7k2q` |

### Cost Management exports

| Form field | Example | Notes |
|---|---|---|
| Billing account ID | `1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d:7e8f9a0b-1c2d-3e4f-5a6b-7c8d9e0f1a2b_2019-05-31` | See *Finding your billing account and profile IDs* |
| Billing profile ID | `AB12-CD34-EF5-GH67` | See *Finding your billing account and profile IDs* |
| Export managed identity | `contoso-adf-focus-umi` | The identity from the setup command |
| Export name prefix | *(blank)* | Blank reuses the name prefix, so exports are named `contosocm-focus-daily` etc. |
| Export container | `cost-exports` | |
| Export format | `Parquet` | |
| FOCUS dataset version | `1.2-preview` | |

### Networking

| Form field | Example | Notes |
|---|---|---|
| Create a private endpoint for the export storage | ticked | |
| Virtual network | Create new: `vnet-costmgmt`, `10.60.0.0/16` | Or pick an existing VNet |
| Private endpoint subnet | `snet-privateendpoints`, `10.60.1.0/24` | |
| Private DNS zone | `Create a new zone` | Pick "Use an existing zone" if the VNet already has a `privatelink.blob.core.windows.net` zone linked |

### Data mover

| Form field | Example | Notes |
|---|---|---|
| Deploy the Data Factory mover | ticked | |
| Site name (destination container) | `contoso-adf-focus` | **From CloudGainz** |
| Customer storage account name | `cgzcontoso01` | **From CloudGainz** |
| Customer SAS token | `sv=2025-07-05&ss=b&srt=sco&sp=rwdlac&se=2027-10-08T00%3A00%3A00Z&sig=Xy...%3D` | **From CloudGainz** |
| Time zone | `Eastern Standard Time` | |
| Daily run time (HH:mm) | `02:00` | |
| Monthly run time (HH:mm) | `02:00` | |
| Monthly run day | `6` | |
| Catch-up cutoff day | `5` | Runs on the 1st-5th still copy last month's folder |

### Names that come out of these values

| Thing | Name |
|---|---|
| Export storage account | `contosocm4x7k2q` (random suffix; also in the deployment's Outputs as `storageAccountName`) |
| Data Factory | `contoso-adf-focus-adf` |
| Pipeline | `contoso-adf-focus-DataMoverPipeline` |
| Schedules | `contoso-adf-focus-DailyTrigger`, `contoso-adf-focus-MonthlyTrigger` |
| Data Factory private endpoint | `contoso-adf-focus-SourceStoragePE` |
| Exports | `contosocm-focus-onetime`, `contosocm-focus-daily`, `contosocm-focus-monthly` |

---

## After the deployment

### 1. Approve the Data Factory's private endpoint

The Data Factory reaches the export storage through its own private endpoint,
which waits for approval on the storage account. Until it's approved, every
pipeline run fails.

1. Search **Resource groups** → click **`rg-contoso-costmgmt`**.
2. Click the storage account **`contosocm4x7k2q`**.
3. Left menu: **Security + networking → Networking** → **Private endpoint connections** tab.
4. Tick the **Pending** row (`contoso-adf-focus-SourceStoragePE`) → **Approve**.

Leave the other row, `pe-contosocm4x7k2q-blob`, alone. It's already approved.

To check it from the Data Factory side: open **`contoso-adf-focus-adf`** →
**Launch Studio** → **Manage** → **Managed private endpoints**.
`contoso-adf-focus-SourceStoragePE` should show **Approved**. It can take a
minute to update.

### 2. Start the schedules

The daily and monthly schedules are created switched off. Turn them on in
**Cloud Shell**:

```bash
az datafactory trigger start -g rg-contoso-costmgmt --factory-name contoso-adf-focus-adf -n contoso-adf-focus-DailyTrigger
az datafactory trigger start -g rg-contoso-costmgmt --factory-name contoso-adf-focus-adf -n contoso-adf-focus-MonthlyTrigger
```

The deployment's Outputs include the same command as `startTriggersCommand`.

---

## Running the daily copy by hand

### Make sure there's data first

The scheduled exports start about 24 hours after the deployment. To get data
sooner, someone with billing access opens **Cost Management → Exports**, scoped
to the billing profile, selects **`contosocm-focus-daily`** and clicks **Run
now**.

The data is ready when files appear in storage account `contosocm4x7k2q`,
container `cost-exports`, under
`focus-daily/contosocm-focus-daily/<yyyyMMdd-yyyyMMdd>/<guid>/`.

### From Data Factory Studio

1. Open **`rg-contoso-costmgmt`** → **`contoso-adf-focus-adf`** → **Launch Studio**.
2. Click **Author** (pencil icon) → **Pipelines** → **`contoso-adf-focus-DataMoverPipeline`**.
3. Click **Add trigger → Trigger now**. The parameters already default to the
   daily copy, so click **OK** without changing them.
4. Click **Monitor** (gauge icon) → **Pipeline runs** to follow it.

The first run sits for a few minutes before doing anything while the private
network runtime starts up.

### From Cloud Shell (Bash)

```bash
RG=rg-contoso-costmgmt
ADF=contoso-adf-focus-adf

RUN=$(az datafactory pipeline create-run -g $RG --factory-name $ADF \
  --name contoso-adf-focus-DataMoverPipeline --query runId -o tsv)
echo "Run ID: $RUN"

# rerun this until status is Succeeded or Failed
az datafactory pipeline-run show -g $RG --factory-name $ADF --run-id $RUN \
  --query "{status:status, message:message}" -o table
```

The first `az datafactory` command may ask to install the Data Factory CLI
extension. Say yes.

### What a good run produces

On the CloudGainz storage account (`cgzcontoso01`), in container
`contoso-adf-focus`:

```
focus-daily/contosocm-focus-daily/<yyyyMMdd-yyyyMMdd>/<guid>/manifest.json
focus-daily/contosocm-focus-daily/<yyyyMMdd-yyyyMMdd>/<guid>/part_0_0001.snappy.parquet
```

Plus a run log, `contoso-adf-focus-daily-<run id>.json`, in the `logs`
container.
