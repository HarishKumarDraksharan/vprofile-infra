# VProfile AWS Infrastructure

Terraform configuration for an AWS network and Amazon EKS foundation intended to support the VProfile platform. The repository defines a VPC with public subnets, an EKS cluster and managed node group, IAM roles/policy attachments, the EKS OIDC provider, and the EBS CSI driver add-on. It also contains an IAM policy document for AWS Load Balancer Controller permissions and a standalone Kubernetes Ingress manifest for Argo CD.

> **Status and scope:** This README describes resources declared in the repository. It does not imply that Terraform has been applied, that the cluster exists, or that Argo CD or an AWS Load Balancer Controller is installed. No deployment state or live-cluster evidence is included here.
>
> **Before use:** Review the region, network ranges, IAM permissions, S3 backend, and hard-coded cloud-specific settings. Use AWS credentials supplied through an approved authentication mechanism; never commit access keys or other credentials.

## Table of contents

- [Project overview](#project-overview)
- [Infrastructure architecture](#infrastructure-architecture)
- [AWS services and resources](#aws-services-and-resources)
- [Repository structure](#repository-structure)
- [Terraform files](#terraform-files)
- [Prerequisites](#prerequisites)
- [AWS CLI configuration and authentication](#aws-cli-configuration-and-authentication)
- [Terraform workflow](#terraform-workflow)
- [Remote state](#remote-state)
- [IAM policy and Argo CD Ingress](#iam-policy-and-argo-cd-ingress)
- [Deployment and verification](#deployment-and-verification)
- [Cleanup](#cleanup)
- [Security best practices](#security-best-practices)

## Project overview

The repository is a small, root-level Terraform project using the AWS provider (version constraint `~> 5.0`) and a Kubernetes manifest for an Argo CD Ingress. Terraform's AWS region defaults to `us-east-1`, and the default cluster name is `vprofile-eks-cluster`.

The Terraform configuration declares a public-subnet EKS setup. It does not declare private subnets, NAT gateways, a Kubernetes cluster add-on for AWS Load Balancer Controller, Argo CD installation resources, application workloads, or an S3 bucket resource for the Terraform backend. Those capabilities must be provisioned and managed separately if required.

## Infrastructure architecture

The Terraform resources form this high-level topology:

```text
AWS Region (default: us-east-1)
└── VPC (default CIDR: 10.0.0.0/16; DNS support and hostnames enabled)
    ├── Internet Gateway
    ├── Public route table: 0.0.0.0/0 → Internet Gateway
    └── Public subnets (default: 10.0.1.0/24, 10.0.2.0/24)
        ├── Map public IP on launch
        ├── EKS control plane VPC configuration
        └── EKS managed node group

EKS cluster
├── Cluster IAM role + AmazonEKSClusterPolicy
├── Managed node group IAM role + worker, CNI, and ECR read-only policies
├── OIDC provider
└── EBS CSI driver add-on + IRSA role/policy
```

The VPC's public subnet tags indicate Kubernetes ELB usage and cluster ownership. There are no private subnet resources or explicit security group resources declared in `main.tf`. EKS and EC2 networking details beyond the checked-in Terraform should be verified against AWS provider behavior and your account configuration.

The `argocd-ingress.yaml` manifest describes an AWS ALB Ingress routing to an `argocd-server` Service on port 443 in the `argocd` namespace. It is not applied by Terraform and requires the Kubernetes resources and controller to exist independently.

## AWS services and resources

The configuration declares or directly references:

- **Amazon VPC:** One VPC with DNS support and DNS hostnames enabled.
- **Amazon EC2 networking:** An Internet Gateway, a public route table, public subnets, and route table associations. Subnets map public IPs on launch.
- **Amazon EKS:** An EKS cluster and a managed node group with configurable EC2 instance type and scaling values.
- **AWS IAM:** EKS cluster and node-group roles; managed policy attachments for EKS cluster, worker nodes, VPC CNI, and ECR read-only access.
- **IAM OIDC federation:** An EKS issuer OIDC provider and a role trust for the EBS CSI controller service account.
- **Amazon EBS CSI:** EKS add-on `aws-ebs-csi-driver`, configured with its service-account role and the AWS managed EBS CSI driver policy.
- **Amazon S3:** Terraform state is configured to use an existing S3 bucket, as described in [Remote state](#remote-state). No S3 bucket is created by the Terraform resources in `main.tf`.
- **AWS Certificate Manager and Elastic Load Balancing:** Referenced by the standalone ALB Ingress configuration and by `iam_policy.json` permissions. The Terraform files do not create the certificate or ALB.

The IAM policy document includes permissions used by the AWS Load Balancer Controller for load-balancer, target-group, listener, security-group, certificate, WAF, and Shield-related operations. It is a policy document in the repository; no Terraform resource attaches it to a role.

## Repository structure

```text
.
├── .gitignore             # Ignores Terraform state/cache and editor/OS files
├── argocd-ingress.yaml    # Kubernetes ALB Ingress for the Argo CD Service
├── backend.tf             # S3 remote state backend declaration
├── iam_policy.json        # IAM policy document for load-balancer controller operations
├── main.tf                # AWS provider, network, EKS, IAM, OIDC, and EBS CSI resources
├── outputs.tf             # EKS endpoint, cluster name, and ARN outputs
└── variables.tf           # Region, network, cluster, node scaling, and bucket inputs
```

No additional Kubernetes manifests or Terraform module directories are present in the repository tree inspected for this README.

## Terraform files

### `main.tf`

- Configures the HashiCorp AWS provider at `var.region`, constrained to AWS provider `~> 5.0`.
- Creates the VPC, Internet Gateway, public route table, public subnets and route table associations.
- Creates IAM roles and attaches the AWS-managed EKS and node-group policies.
- Creates the EKS cluster and managed node group using the public subnets.
- Reads the EKS OIDC issuer TLS certificate, creates the IAM OIDC provider, and defines an IRSA trust relationship for `system:serviceaccount:kube-system:ebs-csi-controller-sa`.
- Creates the EBS CSI driver IAM role, attaches `AmazonEBSCSIDriverPolicy`, and enables the `aws-ebs-csi-driver` EKS add-on.

### `variables.tf`

Declares typed variables and defaults:

| Variable | Default | Purpose |
|---|---|---|
| `region` | `us-east-1` | AWS provider region |
| `cluster_name` | `vprofile-eks-cluster` | EKS cluster and resource naming |
| `vpc_cidr` | `10.0.0.0/16` | VPC address range |
| `public_subnets` | `10.0.1.0/24`, `10.0.2.0/24` | Public subnet CIDRs |
| `availability_zones` | `us-east-1a`, `us-east-1b` | Availability zones indexed alongside public subnet CIDRs |
| `instance_type` | `t3.large` | Managed node group instance type |
| `min_size`, `max_size`, `desired_size` | `1`, `2`, `1` | Node group scaling bounds and desired capacity |
| `s3_bucket` | `vprofile-eks-terraform-state` | Declared bucket variable; it is not referenced by the checked-in backend block |

The lists `public_subnets` and `availability_zones` are indexed by the same `count`; provide lists with matching lengths and valid CIDRs/AZs in the selected region.

### `outputs.tf`

Declares the EKS cluster endpoint, name, and ARN. The endpoint and ARN are infrastructure metadata, not credentials, but should still be handled according to your organization's information-sharing practices.

### `backend.tf`

Configures Terraform's S3 backend with a hard-coded bucket name, state key `eks/terraform.tfstate`, and region `us-east-1`. The bucket must exist before `terraform init`; backend configuration is initialized separately from managed resources. See [Remote state](#remote-state) for the important mismatch between the backend and the declared `s3_bucket` variable.

## Prerequisites

Install and configure:

- **Terraform CLI** compatible with the AWS provider constraint. `main.tf` requires AWS provider `~> 5.0`; there is no checked-in `required_version` constraint for Terraform itself.
- **AWS CLI v2** for credential checks and EKS kubeconfig setup.
- **kubectl** to inspect the cluster and apply the standalone Ingress manifest.
- An AWS account and IAM identity authorized to create the declared VPC, IAM, EKS, EC2 node group, OIDC, add-on, and S3 backend state/lock-related resources as applicable.
- An existing backend S3 bucket in `us-east-1` with appropriate access. The backend block does not configure a DynamoDB lock table.
- Quota and availability for the selected EKS version/defaults and EC2 instance type in the selected region. The cluster Kubernetes version is not explicitly pinned in this configuration.

Review AWS service quotas, costs, and supported AZs before applying. Creating EKS and EC2 node group resources can incur ongoing charges.

## AWS CLI configuration and authentication

Terraform's AWS provider uses the standard AWS credential chain; the repository contains no access keys and does not specify a credentials profile. Prefer AWS IAM Identity Center/SSO, an assumed role, or another approved short-lived credential mechanism instead of static keys.

For an AWS CLI named profile configured through your organization's process, you can select it for local commands without putting credentials in source files:

```bash
export AWS_PROFILE=<your-profile>
aws sts get-caller-identity
aws configure list
```

If using AWS IAM Identity Center, authenticate with your configured profile before running Terraform, for example:

```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
aws sts get-caller-identity
```

Use a principal with appropriately scoped permissions for the Terraform resources and the existing S3 state bucket. The separate `iam_policy.json` is for ALB controller permissions and is not, by itself, the full permission set required to create this infrastructure. Do not paste credentials into shell commands, Terraform files, variable files, or README content.

## Terraform workflow

Run commands from the repository root.

### Initialize

```bash
terraform init
```

Terraform will configure the S3 backend from `backend.tf` and download the AWS provider. Initialization will fail if the hard-coded S3 backend bucket/key/region cannot be accessed or the bucket does not exist.

### Format and validate

```bash
terraform fmt -recursive
terraform validate
```

`terraform fmt` changes formatting in Terraform files; review the resulting diff before committing it. `terraform validate` checks Terraform configuration structure and provider schemas after initialization; it does not confirm AWS permissions, quotas, live resource availability, or that the plan is safe.

### Plan

Review the plan before applying:

```bash
terraform plan
```

To customize variables without editing defaults, create a local `terraform.tfvars` file (ensure it contains no secrets and is not committed) or pass a reviewed variable file:

```bash
terraform plan -var-file="environment.tfvars"
```

The repository's `.gitignore` does not currently list `*.tfvars`; keep local variable files out of commits or extend ignore rules in a separate, reviewed change if needed. Do not put credentials in Terraform variables.

### Apply

After reviewing the planned resource changes and confirming AWS identity/region:

```bash
terraform apply
```

Terraform prompts for confirmation unless automatic approval is requested. Avoid `-auto-approve` for initial or production changes; inspect the plan, IAM changes, public network exposure, and estimated costs first.

## Remote state

`backend.tf` configures the S3 backend with:

- Bucket: `gitiops-terraformcode928` (must already exist)
- Key: `eks/terraform.tfstate`
- Region: `us-east-1`

`variables.tf` separately declares `s3_bucket` with default `vprofile-eks-terraform-state`, but the checked-in backend block does not refer to that variable. Terraform backend blocks do not accept ordinary input variables in the same way as resources, so changing `s3_bucket` will not change this backend. To change backend settings, edit the backend configuration or supply supported partial backend configuration at `terraform init`, and carefully migrate state if the backend location changes.

The backend block does not enable an S3 lock table or document bucket versioning, encryption, or public-access settings. Configure the state bucket securely before using it: enable encryption and versioning, block public access, restrict bucket access, and use the locking mechanism supported by your Terraform version/backend setup. State can contain sensitive infrastructure data even if no sensitive output is declared. Never commit state files.

## IAM policy and Argo CD Ingress

### `iam_policy.json`

The JSON is an IAM policy document with `Allow` statements for AWS Load Balancer Controller-style operations. It includes EC2 and ELBv2 discovery and modification permissions, security-group operations, target registration, and selected ACM, WAF, Cognito, and Shield actions. Several statements use `Resource: "*"`, while others constrain actions using resource ARNs and ELB cluster tags.

This policy file is **not wired into Terraform**: there is no `aws_iam_policy` or attachment resource referencing it. If used, review it against the current AWS Load Balancer Controller policy guidance and your organization's least-privilege requirements, then attach it through a separately managed and reviewed process. Do not assume it is automatically active because it is present in the repository.

### `argocd-ingress.yaml`

This manifest:

- Uses `networking.k8s.io/v1` Ingress in namespace `argocd`, named `argocd-ingress`.
- Selects the `alb` Ingress class and annotates the ALB as internet-facing with IP targets.
- Configures HTTP and HTTPS listeners, redirects HTTP to HTTPS, and sets the ALB-to-backend protocol to HTTPS.
- Routes host `argocd.hkhinfotek.xyz` and path `/` to Service `argocd-server` on port `443`.
- Contains an ACM certificate ARN hard-coded in `us-east-1`; replace it with a certificate appropriate to your account, region, and host before use. The README intentionally does not repeat the account-specific ARN.

This manifest is applied independently of Terraform and assumes the `argocd` namespace, `argocd-server` Service, ALB controller, certificate, and supporting AWS permissions already exist. The repository provides no evidence that these prerequisites are installed or that the Ingress works.

## Deployment and verification

Terraform provisions the infrastructure resources declared in `main.tf`. Once the EKS cluster exists and access is granted to your AWS identity, retrieve cluster credentials for `kubectl` (replace the cluster name/region if you supplied overrides):

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name vprofile-eks-cluster

kubectl config current-context
kubectl get nodes
kubectl get namespaces
```

The EKS endpoint, name, and ARN can be reviewed using Terraform outputs:

```bash
terraform output
terraform output cluster_name
terraform output cluster_endpoint
```

Only run `kubectl apply` for Argo CD Ingress after confirming the prerequisites and editing the host/certificate configuration as appropriate:

```bash
kubectl apply --dry-run=server -f argocd-ingress.yaml
kubectl apply -f argocd-ingress.yaml
kubectl get ingress argocd-ingress --namespace argocd
kubectl describe ingress argocd-ingress --namespace argocd
```

The server-side dry run requires a reachable cluster and API authorization. Check the ALB controller's events/logs and AWS load balancer state separately if the Ingress has no address. Terraform does not install Argo CD or the controller, and applying this manifest does not prove that the configured endpoint is reachable.

## Cleanup

Destroying Terraform-managed infrastructure is destructive and may delete the EKS cluster, node group, VPC resources, IAM roles, and EBS CSI add-on. It can cause service downtime and data loss. First inspect the planned destroy operations and ensure any workloads, persistent data, external load balancers, and state you need are backed up or intentionally disposable.

```bash
terraform plan -destroy
terraform destroy
```

The standalone `argocd-ingress.yaml` manifest is not managed by Terraform. Remove it separately if you applied it and no longer need it:

```bash
kubectl delete -f argocd-ingress.yaml
```

Review any resources created outside Terraform, including controller-managed load balancers and the remote-state bucket, separately. `terraform destroy` will not delete the S3 backend bucket, because it is not declared as a Terraform resource here.

## Security best practices

- Use short-lived AWS credentials and least-privilege IAM roles; do not commit access keys, session tokens, private keys, passwords, or credentials.
- Review IAM policies before attachment. The ALB policy includes broad permissions and is not attached by the Terraform configuration.
- Keep Terraform state in a private, encrypted, versioned S3 bucket with tightly scoped IAM access and appropriate locking. Treat state and plan files as sensitive artifacts.
- Restrict public exposure. The Terraform network uses public subnets and public IP assignment; the Argo CD Ingress is internet-facing. Confirm network controls, authentication, TLS, and operational requirements before deployment.
- Replace the hard-coded host/certificate configuration in `argocd-ingress.yaml` with environment-appropriate values through a reviewed change; do not expose private administrative endpoints unnecessarily.
- Review security group behavior, EKS endpoint access, node-group access, and cluster authentication against your requirements. These settings are not explicitly customized in the checked-in Terraform.
- Pin and review Terraform/provider and cluster-related versions according to a controlled upgrade process; the EKS Kubernetes version is not explicitly set in this configuration.
- Protect local variable, plan, and state files. The checked-in `.gitignore` ignores Terraform cache and state files, but does not ignore all possible local tfvars or plan files.
- Run `terraform plan` and review all proposed IAM/network/resource changes before applying or destroying infrastructure.
