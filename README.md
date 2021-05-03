#Terraform Demo Lab
v1.0 Created by Kirk Ryan - Nov 2020
This configuration will deploy a full ANF deployment with fully configured domain services, Windows SMB and Linux NFS capabilities.

#Instructions
This assumes you have already configured Terraform and are logged into Azure CLI

1. Simply change the default values in variables.tf to configure anything specific to your environment such as region.
2. Run the following command ```terraform apply```

To clean-up the lab

1. Simply run ```Terraform destroy```
