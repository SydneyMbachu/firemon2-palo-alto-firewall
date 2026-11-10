terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
provider "aws" {
  region = var.region
  default_tags { tags = { Project = "northwind-firewall-lab", ManagedBy = "Terraform" } }
}

variable "region" { default = "us-east-1" }
variable "availability_zone" { type = string }
variable "firewall_ami_id" {
  type        = string
  description = "Exact subscribed Marketplace VM-Series AMI for this region; no guessed AMI."
  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.firewall_ami_id))
    error_message = "Supply the regional Marketplace AMI ID."
  }
}
variable "firewall_instance_type" {
  type        = string
  description = "Supported x86 instance type from the selected offer; must support three ENIs."
}
variable "admin_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && can(regex("/32$", var.admin_cidr))
    error_message = "Use your single public IPv4 address with /32."
  }
}
variable "ssh_public_key" {
  type        = string
  description = "Public key only. Keep the private key on your machine."
}

data "aws_ami" "firewall" {
  owners = ["aws-marketplace"]
  filter {
    name   = "image-id"
    values = [var.firewall_ami_id]
  }
}
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
resource "aws_vpc" "lab" {
  cidr_block           = "10.77.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}
resource "aws_internet_gateway" "lab" { vpc_id = aws_vpc.lab.id }
locals {
  subnets = { management = "10.77.0.0/24", client = "10.77.1.0/24", app = "10.77.2.0/24" }
}
resource "aws_subnet" "lab" {
  for_each          = local.subnets
  vpc_id            = aws_vpc.lab.id
  availability_zone = var.availability_zone
  cidr_block        = each.value
  tags              = { Name = "northwind-${each.key}" }
}
resource "aws_security_group" "management" {
  name_prefix = "northwind-management-"
  vpc_id      = aws_vpc.lab.id
  dynamic "ingress" {
    for_each = toset([22, 443])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "dataplane" {
  name_prefix = "northwind-dataplane-"
  vpc_id      = aws_vpc.lab.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.77.1.0/24", "10.77.2.0/24"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.77.1.0/24", "10.77.2.0/24"]
  }
}
resource "aws_security_group" "app" {
  name_prefix = "northwind-app-"
  vpc_id      = aws_vpc.lab.id
  dynamic "ingress" {
    for_each = toset([22, 8443])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["10.77.1.20/32"]
    }
  }
  # Responses to allowed inbound traffic are stateful; no outbound initiation.
}
resource "aws_network_interface" "firewall" {
  for_each          = local.subnets
  subnet_id         = aws_subnet.lab[each.key].id
  private_ips       = [cidrhost(each.value, 10)]
  security_groups   = [each.key == "management" ? aws_security_group.management.id : aws_security_group.dataplane.id]
  source_dest_check = false
}
resource "aws_key_pair" "lab" {
  key_name_prefix = "northwind-"
  public_key      = var.ssh_public_key
}
resource "aws_instance" "firewall" {
  ami           = data.aws_ami.firewall.id
  instance_type = var.firewall_instance_type
  key_name      = aws_key_pair.lab.key_name
  dynamic "network_interface" {
    for_each = { management = 0, client = 1, app = 2 }
    content {
      device_index         = network_interface.value
      network_interface_id = aws_network_interface.firewall[network_interface.key].id
    }
  }
  user_data = "type=dhcp-client;hostname=northwind-fw;"
  root_block_device { encrypted = true }
  tags = { Name = "northwind-firewall" }
}
resource "aws_eip" "firewall" {
  domain            = "vpc"
  network_interface = aws_network_interface.firewall["management"].id
  depends_on        = [aws_internet_gateway.lab]
}
resource "aws_instance" "client" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.lab["client"].id
  private_ip                  = "10.77.1.20"
  vpc_security_group_ids      = [aws_security_group.management.id]
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true
  metadata_options { http_tokens = "required" }
  root_block_device { encrypted = true }
  tags = { Name = "northwind-client" }
}
resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.lab["app"].id
  private_ip                  = "10.77.2.20"
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = false
  metadata_options { http_tokens = "required" }
  root_block_device { encrypted = true }
  user_data = <<-STARTUP
    #!/bin/bash
    set -eu
    mkdir -p /srv/northwind
    printf 'Northwind application is reachable\n' > /srv/northwind/index.html
    cat > /etc/systemd/system/northwind.service <<'UNIT'
    [Unit]
    Description=Northwind demo HTTP listener on TCP 8443 (not TLS)
    After=network.target
    [Service]
    ExecStart=/usr/bin/python3 -m http.server 8443 --bind 0.0.0.0 --directory /srv/northwind
    Restart=always
    User=nobody
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now northwind
  STARTUP
  tags      = { Name = "northwind-app" }
}
resource "aws_route_table" "lab" {
  for_each = local.subnets
  vpc_id   = aws_vpc.lab.id
}
resource "aws_route_table_association" "lab" {
  for_each       = local.subnets
  subnet_id      = aws_subnet.lab[each.key].id
  route_table_id = aws_route_table.lab[each.key].id
}
resource "aws_route" "internet" {
  for_each               = toset(["management", "client"])
  route_table_id         = aws_route_table.lab[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab.id
}
# More-specific routes override VPC-local routing in both directions.
resource "aws_route" "client_to_app" {
  route_table_id         = aws_route_table.lab["client"].id
  destination_cidr_block = "10.77.2.0/24"
  network_interface_id   = aws_network_interface.firewall["client"].id
}
resource "aws_route" "app_to_client" {
  route_table_id         = aws_route_table.lab["app"].id
  destination_cidr_block = "10.77.1.0/24"
  network_interface_id   = aws_network_interface.firewall["app"].id
}

output "firewall_management_ip" { value = aws_eip.firewall.public_ip }
output "client_public_ip" { value = aws_instance.client.public_ip }
output "app_private_ip" { value = aws_instance.app.private_ip }
