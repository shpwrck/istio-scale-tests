# Single password for every cluster’s cluster-admin user (ROSA minimum 14 chars + complexity).
resource "random_password" "cluster_admin" {
  length           = 24
  special          = true
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "-_=+."
}
