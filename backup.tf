locals {
  # Determine if backup enrollment should be created
  # Based only on plan-time-known variables to avoid "count depends on resource attributes" errors
  enable_backup_enrollment = var.service_criticality >= 4 && !var.single_server

  # Construct backup policy ID from vault ID and policy name
  backup_policy_id = local.enable_backup_enrollment ? "${try(data.azurerm_data_protection_backup_vault.vault[0].id, null)}/backupPolicies/${var.backup_policy_name}" : null
}

data "azurerm_data_protection_backup_vault" "vault" {
  count               = local.enable_backup_enrollment ? 1 : 0
  name                = var.backup_vault_name
  resource_group_name = var.backup_vault_resource_group

  lifecycle {
    precondition {
      condition     = var.backup_vault_name != null && var.backup_vault_resource_group != null && var.backup_policy_name != null
      error_message = "backup_vault_name, backup_vault_resource_group, and backup_policy_name must be provided when service_criticality >= 4."
    }
  }
}

# NOTE: The backup vault's managed identity also requires "Reader" role on the
# resource group containing the PostgreSQL server. This is managed in the
# backup vault module (cpp-module-terraform-azurerm-backup-vault) to avoid
# conflicts when multiple PostgreSQL instances share the same resource group.

resource "azurerm_role_assignment" "backup_vault_postgres_ltr" {
  count                = local.enable_backup_enrollment ? 1 : 0
  scope                = local.primary_server_id
  role_definition_name = "PostgreSQL Flexible Server Long Term Retention Backup Role"
  principal_id         = data.azurerm_data_protection_backup_vault.vault[0].identity[0].principal_id

  # Prevent role assignment from being destroyed before backup instance
  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_data_protection_backup_instance_postgresql_flexible_server" "main" {
  count    = local.enable_backup_enrollment ? 1 : 0
  name     = "${var.server_name}-backup-instance"
  location = var.location

  vault_id         = data.azurerm_data_protection_backup_vault.vault[0].id
  server_id        = local.primary_server_id
  backup_policy_id = local.backup_policy_id

  # NOTE: On immutable vaults, backup instances cannot be deleted while recovery
  # points exist. This is by design — immutability protects against deletion.
  # To remove this resource from Terraform state without deleting it:
  #   terraform state rm '<resource_address>'
  # To fully delete, first disable immutability on the vault, then stop
  # protection and delete the backup instance via Azure CLI or portal.

  # Ensure RBAC permissions are in place before attempting enrollment
  # Without these, enrollment will fail with "Unauthorized" error
  # NOTE: Reader role on RG is managed by the backup vault module
  depends_on = [
    azurerm_role_assignment.backup_vault_postgres_ltr,
    azurerm_postgresql_flexible_server.flexible_server
  ]
}
