# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.37"
    }
  }
}

provider "azurerm" {
  features {}
}

# Core Azure resources/configuration

resource "azurerm_resource_group" "tf-kirkr-group" {
  name     = "tf-kirkr-group"
  location = var.region
}

resource "azurerm_virtual_network" "tf-kirkr-vnet" {
  name                = "tf-kirkr-vnet"
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  location            = azurerm_resource_group.tf-kirkr-group.location
  address_space       = ["20.0.0.0/16"]
}

resource "azurerm_subnet" "vms" {
  name                 = "vms"
  resource_group_name  = azurerm_resource_group.tf-kirkr-group.name
  virtual_network_name = azurerm_virtual_network.tf-kirkr-vnet.name
  address_prefixes     = ["20.0.1.0/24"]
}

resource "azurerm_subnet" "anf" {
  name                 = "anf"
  resource_group_name  = azurerm_resource_group.tf-kirkr-group.name
  virtual_network_name = azurerm_virtual_network.tf-kirkr-vnet.name
  address_prefixes     = ["20.0.2.0/24"]

  delegation {
    name = "anfdelegation"

    service_delegation {
      name = "Microsoft.Netapp/volumes"
    }
  }
}

# Provision public IP for the Windows AD server
resource "azurerm_public_ip" "tf-kirkr-win-ad-01-public-ip" {
  name                = "tf-kirkr-linux-win-ad-01-public-ip"
  location            = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  allocation_method   = "Dynamic"

  tags = {
    environment = "Terraform Demo"
  }
}

# Provision and configure the NIC interface for the Windows AD server
resource "azurerm_network_interface" "tf-kirk-win-ad-01-nic-01" {
  name                          = "tf-kirk-win-ad-01-nic-01"
  location                      = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name           = azurerm_resource_group.tf-kirkr-group.name
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vms.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "20.0.1.100"
    public_ip_address_id          = azurerm_public_ip.tf-kirkr-win-ad-01-public-ip.id
  }
}

# Create the NSG for the Windows AD server
resource "azurerm_network_security_group" "tf-kirkr-win-ad-01-nsg" {
  name                = "tf-kirkr-win-ad-01-nsg"
  location            = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name

  security_rule {
    name                       = "RDP"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    environment = "Terraform Demo"
  }
}

# Provision the Windows AD server VM
resource "azurerm_windows_virtual_machine" "tf-kirkr-win-ad-01" {
  name                = "ad01"
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  location            = azurerm_resource_group.tf-kirkr-group.location
  size                = "Standard_D4s_v3"
  admin_username      = var.username
  admin_password      = var.password
  network_interface_ids = [
    azurerm_network_interface.tf-kirk-win-ad-01-nic-01.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter"
    version   = "latest"
  }
}

# TODO output "azurerm_windows_virtual_machine" { value = azurerm_windows_virtual_machine.tf-kirkr-win-ad-01.private_key_pem }

# Connect the security group to the network interface (Enable RDP connectivity)
resource "azurerm_network_interface_security_group_association" "tf-kirkr-nsg-asso-02" {
  network_interface_id      = azurerm_network_interface.tf-kirk-win-ad-01-nic-01.id
  network_security_group_id = azurerm_network_security_group.tf-kirkr-win-ad-01-nsg.id
}

# TODO - Configure AD role and services
// the `exit_code_hack` is to keep the VM Extension resource happy
# locals { 
#   import_command       = "Import-Module ADDSDeployment"
#   password_command     = "$password = ConvertTo-SecureString ${var.admin_password} -AsPlainText -Force"
#   install_ad_command   = "Add-WindowsFeature -name ad-domain-services -IncludeManagementTools"
#   configure_ad_command = "Install-ADDSForest -CreateDnsDelegation:$false -DomainMode Win2012R2 -DomainName ${var.active_directory_domain} -DomainNetbiosName ${var.active_directory_netbios_name} -ForestMode Win2012R2 -InstallDns:$true -SafeModeAdministratorPassword $password -Force:$true"
#   shutdown_command     = "shutdown -r -t 10"
#   exit_code_hack       = "exit 0"
#   powershell_command   = "${local.import_command}; ${local.password_command}; ${local.install_ad_command}; ${local.configure_ad_command}; ${local.shutdown_command}; ${local.exit_code_hack}"
# }

resource "azurerm_virtual_machine_extension" "tf-kirkr-win-ad-01-ext-install-ad" {
  name                 = azurerm_windows_virtual_machine.tf-kirkr-win-ad-01.name
  virtual_machine_id   = azurerm_windows_virtual_machine.tf-kirkr-win-ad-01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  protected_settings = <<PROTECTED_SETTINGS
    {
        "commandToExecute": "powershell.exe -Command \"Import-Module ADDSDeployment, ActiveDirectory; $password = ConvertTo-SecureString ${var.password} -AsPlainText -Force; Add-WindowsFeature -name ad-domain-services -IncludeManagementTools; Install-ADDSForest -DomainName ${var.domainname} -SafeModeAdministratorPassword $password -Force:$true; shutdown -r -t 10; exit 0\""
    }
PROTECTED_SETTINGS

  tags = {
    environment = "Production"
  }

  depends_on = [
    azurerm_windows_virtual_machine.tf-kirkr-win-ad-01
  ]
}

# Provision NetApp Account
resource "azurerm_netapp_account" "tf-kirkr-anf" {
  name                = "tf-kirkr-anf"
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  location            = azurerm_resource_group.tf-kirkr-group.location

  # Disabled due to test lab already having an AD:
  # Error: Error waiting for creation of NetApp Account "tf-kirkr-anf" (Resource Group "tf-kirkr-group"): Code="BadRequest" Message="Only one active directory allowed within the same region. Account core-west-europe in resource group emea-core-west-europe-anf currently has an active directory connection string." Details=[{"code":"TooManyActiveDirectories","message":"Only one active directory allowed within the same region. Account core-west-europe in resource group emea-core-west-europe-anf currently has an active directory connection string."}]

  #   active_directory {
  #   username            = var.username
  #   password            = var.password
  #   smb_server_name     = var.smbservername
  #   dns_servers         = ["20.0.1.100"]
  #   domain              = var.domainname
  # }

  depends_on = [
    azurerm_windows_virtual_machine.tf-kirkr-win-ad-01
  ]

}

# Provision Storage Pool
resource "azurerm_netapp_pool" "tf-kirkr-anf-pool-01" {
  name                = "tf-kirkr-anf-pool-01"
  account_name        = azurerm_netapp_account.tf-kirkr-anf.name
  location            = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  service_level       = "Standard"
  size_in_tb          = 4

  depends_on = [
    azurerm_netapp_account.tf-kirkr-anf,
  ]
}

# Provision NFS Volume

resource "azurerm_netapp_volume" "tf-kirkr-vol-01" {
  #   lifecycle {
  #     prevent_destroy = true
  #   }

  name                = "tf-kirkr-vol-01"
  location            = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  account_name        = azurerm_netapp_account.tf-kirkr-anf.name
  pool_name           = azurerm_netapp_pool.tf-kirkr-anf-pool-01.name
  volume_path         = "nfs01"
  service_level       = "Standard"
  subnet_id           = azurerm_subnet.anf.id
  protocols           = ["NFSv3"]
  storage_quota_in_gb = 1000

  depends_on = [
    azurerm_netapp_pool.tf-kirkr-anf-pool-01,
  ]

}

# Create a Public IP address for the network

resource "azurerm_public_ip" "tf-kirkr-linux-vm-01-public-ip" {
  name                = "tf-kirkr-linux-vm-01-public-ip"
  location            = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name
  allocation_method   = "Dynamic"

  tags = {
    environment = "Terraform Demo"
  }
}

# Create an NSG for SSH to the Linux VM

resource "azurerm_network_security_group" "tf-kirkr-linux-vm-01-nsg" {
  name                = "mtf-kirkr-linux-vm-01-nsg"
  location            = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name = azurerm_resource_group.tf-kirkr-group.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    environment = "Terraform Demo"
  }
}

# Create Network Interface for Linux VM

resource "azurerm_network_interface" "tf-kirkr-linux-vm-nic-01" {
  name                          = "tf-kirkr-linux-vm-nic-01"
  location                      = azurerm_resource_group.tf-kirkr-group.location
  resource_group_name           = azurerm_resource_group.tf-kirkr-group.name
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vms.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.tf-kirkr-linux-vm-01-public-ip.id
  }

  tags = {
    environment = "Terraform Demo"
  }
}

# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "tf-kirkr-nsg-asso-01" {
  network_interface_id      = azurerm_network_interface.tf-kirkr-linux-vm-nic-01.id
  network_security_group_id = azurerm_network_security_group.tf-kirkr-linux-vm-01-nsg.id
}

# Create (and display) an SSH key
resource "tls_private_key" "netapp_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
output "tls_private_key" { value = tls_private_key.netapp_ssh.private_key_pem }

# Create the Virtual Machine
resource "azurerm_linux_virtual_machine" "tf-kirkr-linux-vm-01" {
  name                            = "tf-kirkr-linux-vm-01"
  resource_group_name             = azurerm_resource_group.tf-kirkr-group.name
  location                        = azurerm_resource_group.tf-kirkr-group.location
  size                            = "Standard_D4s_v3"
  admin_username                  = var.username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.tf-kirkr-linux-vm-nic-01.id]

  admin_ssh_key {
    username   = "netapp"
    public_key = tls_private_key.netapp_ssh.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }

  tags = {
    environment = "Terraform Demo"
  }
}
