# Northwind live VM-Series lab — deployment draft

No AWS deployment has been performed. This extends the offline demo in [firemon1-ports](https://github.com/SydneyMbachu/firemon1-ports) with a real firewall and two EC2 test machines. Single-AZ disposable lab, not a production design. Terraform validation does not verify Marketplace entitlement, image compatibility, licensing, or runtime behavior.

## Files to read

- `terraform/aws/aws.tf`: AWS setup, input variables, application startup, and outputs.
- `terraform/aws/terraform.tfvars.example`: copy and fill in your settings.
- `terraform/panos/firewall.tf`: firewall networking and the three policy scenarios.
- `scripts/probe.py`: run on the test client to check the two ports.

The two Terraform directories run at different stages. Lock files pin provider versions; `.terraform/` contains generated downloads and is ignored by Git. There is no deployment workflow. AWS deployment is on hold until the subscription is ready.

## Send these Marketplace details

Subscribe to **Palo Alto Networks VM-Series** (self-hosted EC2 PAYG trial), not Cloud NGFW or Panorama. Send:

- Marketplace product URL and exact offer/bundle name.
- Confirmation the subscription is active in the AWS account we will use.
- Selected AWS region, PAN-OS/software version, and regional AMI ID from the launch/configuration page.
- A supported x86 EC2 instance type that supports at least three network interfaces.
- Trial expiration date, software price after expiration, and any listed restrictions.

Do not launch through the Marketplace wizard. We will launch with Terraform after checking the offer. An AMI ID and public listing URL are not secrets. Do not send passwords, private keys, API keys, or AWS credentials in chat.

Also needed before deployment: AWS CLI profile/SSO authentication locally, account confirmation, availability zone, public IPv4 /32 for SSH/HTTPS management, local SSH public key, approved cost ceiling, and teardown date. Trial software can still incur EC2, EBS, and public IPv4 charges; subscription cancellation is separate from resource deletion.

## Design

All resources use a new 10.77.0.0/16 VPC in one availability zone:

| Subnet | Hosts | Routing |
|---|---|---|
| Management 10.77.0.0/24 | Firewall MGT .10, public EIP | Internet gateway, management limited to your /32 |
| Client 10.77.1.0/24 | Firewall ethernet1/1 .10, test client .20 | Internet gateway; app subnet routed through firewall client ENI |
| App 10.77.2.0/24 | Firewall ethernet1/2 .10, app .20 | Client subnet routed through firewall app ENI; no default internet route |

Three firewall ENIs use conventional MGT/ethernet1/1/ethernet1/2 mapping, no management-interface swap. Source/destination checks are disabled. More-specific subnet routes override VPC-local routing in both directions. PAN-OS uses static interface addresses; both test networks are directly connected, so no firewall default route or NAT is needed for this demo. Management has its own DHCP route for licensing/updates.

The app SG permits TCP 8443 and 22 only from the client IP. PAN-OS independently controls that path. The app runs a plain **HTTP** listener on 8443 (not HTTPS) plus native SSH; tests establish TCP connections without logging into SSH. No package downloads are needed at boot; validate that the selected AL2023 image includes /usr/bin/python3 and cloud-init completes.

The broad scenario allows any service between the two fixed hosts; the AWS app SG still limits reachable ports to 22 and 8443. The scoped scenario adds only 8443 alongside existing 8080. Policy ends in an explicit logged deny.

## Stage 1: AWS (later, after authorization)

From `2026/firemon2-palo-alto-firewall/`:

```sh
cp terraform/aws/terraform.tfvars.example terraform/aws/terraform.tfvars
# Replace every placeholder. Authenticate locally using AWS SSO/profile.
terraform -chdir=terraform/aws init
terraform -chdir=terraform/aws plan -out=deployment.tfplan
# Review exact resource changes and cost before executing:
terraform -chdir=terraform/aws apply deployment.tfplan
terraform -chdir=terraform/aws output
```

No workflow automatically applies changes. Local state, plans, credentials and real tfvars are ignored by Git; protect and retain the state until teardown. For shared ongoing work, migrate state to an encrypted, access-controlled remote backend with locking first.

## Stage 2: initial firewall access (later)

Wait for appliance initialization. SSH as admin using your local private key to the management EIP. Set the initial admin password interactively using the PAN-OS CLI (`configure`, `set mgt-config users admin password`, then `commit`). Confirm licensing and software readiness. Establish a trusted management certificate and use its DNS hostname for API access; locally trust its CA. Generate a PAN-OS API key locally and keep it out of source control and shell history.

The Marketplace image/version may impose additional onboarding or licensing steps. Verify those against the selected offer before deployment; no license/auth code is guessed here.

## Stage 3: firewall configuration (later)

The PAN-OS Terraform stage owns the complete security rulebase on this **new dedicated firewall**. Do not point it at an existing/shared firewall. It also manages the default virtual router, two data interfaces and zones. Confirm vsys1 interface assignment (if missing, use `set vsys vsys1 import network interface [ ethernet1/1 ethernet1/2 ]` in configuration mode before the final commit) and legacy virtual-router mode on the selected PAN-OS version before applying (advanced routing engine uses different resources).

```sh
export PANOS_HOSTNAME='trusted-management-hostname'
# Set PANOS_API_KEY securely in your local environment; never paste it in chat.
# Trust the appliance CA in your system trust store for the provider.
terraform -chdir=terraform/panos init
terraform -chdir=terraform/panos plan -var='scenario=current' -out=current.tfplan
terraform -chdir=terraform/panos apply current.tfplan
# In the firewall web interface: click Commit, then wait for success.
```

Terraform updates candidate configuration. Click **Commit** in the firewall web interface after each apply and wait for success. A commit activates the candidate configuration: keep this dedicated lab free of concurrent manual changes. Repeat plan/apply/commit with scenario=broad or scenario=scoped. Reverting to scenario=current restores the starting policy. Use fresh TCP connections; existing firewall sessions can preserve earlier policy decisions.

## Demonstration and troubleshooting

Copy scripts/probe.py to the client using scp and your local SSH private key; SSH as ec2-user to client_public_ip. Run `python3 probe.py current`, then broad and scoped after each corresponding apply/commit. Expected results:

| Scenario | TCP 8443 | TCP 22 |
|---|---|---|
| current | blocked | blocked |
| broad | reachable | reachable |
| scoped | reachable | blocked |

A timeout by itself does not prove firewall enforcement. First use broad to prove both listeners and routing work, then correlate probes with PAN-OS Monitor > Traffic logs (source 10.77.1.20, destination 10.77.2.20, rule/action). Confirm app cloud-init/service health, ENI mapping, vsys assignment, routes, SGs, license and commit status if results differ. The script returns nonzero on an unexpected observation.

## Teardown (later)

Destroy the AWS stage while retaining its state until completion:

```sh
terraform -chdir=terraform/aws plan -destroy -out=teardown.tfplan
terraform -chdir=terraform/aws apply teardown.tfplan
```

The PAN-OS state can then be archived/deleted locally because the dedicated appliance is gone; do not run its destroy against a different firewall. Verify EC2 instances, EBS volumes and EIP are gone. Separately review/cancel the Marketplace subscription and verify billing. No automated destroy or subscription cancellation has been scheduled.

## References

- https://www.paloaltonetworks.com/trial/aws-freetrial
- https://docs.aws.amazon.com/marketplace/latest/buyerguide/buyer-free-trials.html
- https://registry.terraform.io/providers/PaloAltoNetworks/panos/2.0.13/docs
- https://pan.dev/terraform/docs/panos/tutorials/config-secpol-and-objs/

## Local validation

Both Terraform roots passed `terraform validate` against installed providers (AWS 6.72.0 and PAN-OS 2.0.13). Provider lock files are included. Terraform formatting and provider-schema validation passed; the probe compiles. Live testing remains pending the subscription. No AWS plan/apply or live firewall test has run.
