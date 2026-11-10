terraform {
  required_version = ">= 1.8, < 2.0"
  required_providers {
    panos = { source = "PaloAltoNetworks/panos", version = "2.0.13" }
  }
}
# PANOS_HOSTNAME and PANOS_API_KEY are supplied in the environment.
provider "panos" {}
variable "scenario" {
  default = "current"
  validation {
    condition     = contains(["current", "broad", "scoped"], var.scenario)
    error_message = "Choose current, broad, or scoped."
  }
}
resource "panos_ethernet_interface" "lab" {
  for_each = { "ethernet1/1" = "10.77.1.10/24", "ethernet1/2" = "10.77.2.10/24" }
  location = { ngfw = {} }
  name     = each.key
  layer3   = { ips = [{ name = each.value }] }
}
resource "panos_virtual_router" "lab" {
  location   = { ngfw = {} }
  name       = "default"
  interfaces = [for interface in panos_ethernet_interface.lab : interface.name]
}
resource "panos_zone" "lab" {
  for_each = { client = "ethernet1/1", app = "ethernet1/2" }
  location = { vsys = { name = "vsys1" } }
  name     = each.key
  network  = { layer3 = [panos_ethernet_interface.lab[each.value].name] }
}
resource "panos_service" "port" {
  for_each = toset(["8080", "8443"])
  location = { vsys = { name = "vsys1" } }
  name     = "tcp-${each.value}"
  protocol = { tcp = { destination_port = each.value } }
}
# Each scenario changes only the allowed services between the two test hosts.
locals {
  services = {
    current = [panos_service.port["8080"].name]
    broad   = ["any"]
    scoped  = [panos_service.port["8080"].name, panos_service.port["8443"].name]
  }
}

resource "panos_security_policy" "lab" {
  location = { vsys = { name = "vsys1" } }
  rules = [
    {
      name                  = "northwind-application"
      source_zones          = [panos_zone.lab["client"].name]
      destination_zones     = [panos_zone.lab["app"].name]
      source_addresses      = ["10.77.1.20/32"]
      destination_addresses = ["10.77.2.20/32"]
      source_users          = ["any"]
      applications          = ["any"]
      services              = local.services[var.scenario]
      action                = "allow"
      log_end               = true
    },
    {
      name                  = "deny-and-log"
      source_zones          = ["any"]
      destination_zones     = ["any"]
      source_addresses      = ["any"]
      destination_addresses = ["any"]
      source_users          = ["any"]
      applications          = ["any"]
      services              = ["any"]
      action                = "deny"
      log_end               = true
    }
  ]
}
