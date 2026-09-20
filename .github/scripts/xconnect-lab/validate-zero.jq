.kind == "XConnectZeroControlPlane" and
.metadata.name == "xconnect-zero" and
.metadata.environment == "uat" and
.spec.source_of_truth == "accounts-api-and-portal" and
.spec.accounts_api_url == "https://accounts-uat.onwalk.net" and
.spec.portal_url == "https://console-serverless-uat.onwalk.net/panel/xconnect-zero" and
(.spec.resources | sort) == (["acks", "devices", "gateways", "invitations", "networks", "policies", "signed-config"] | sort) and
.spec.tenant_isolation == "account-scoped" and
.spec.vault.address == "https://vault.svc.plus" and
.spec.vault.auth_method == "github-actions-jwt" and
.spec.vault.runtime_secret_path == "kv/data/uat/xconnect-one" and
.spec.vault.gateway_tls_path == "kv/data/CICD/domains/svc.plus" and
.spec.vault.observability_path == "kv/data/CICD/observability" and
(.spec.vault.sensitive_fields | sort) == (["VLESS_ID", "ZERO_OWNER_EMAIL", "ZERO_SERVICE_TOKEN", "tls_ca_pem_b64", "tls_fullchain_pem_b64", "tls_key_pem_b64", "tls_trust_bundle_pem_b64"] | sort) and
(.spec.boundary.gitops_contains | sort) == (["endpoints", "network-and-transport-policy", "paths", "versions"] | sort) and
(.spec.boundary.vault_contains | sort) == (["certificates", "credentials", "private-keys", "service-tokens"] | sort) and
.spec.boundary.zero_carries_vpn_data == false and
.spec.boundary.gateway_and_one_data_plane == "wireguard-over-vless"
