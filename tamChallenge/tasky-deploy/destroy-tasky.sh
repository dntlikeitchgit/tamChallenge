#!/bin/bash
cd ~/terraform/wiz-eks-tasky/tasky-deploy
terraform destroy -auto-approve
cd ~/terraform/wiz-eks-tasky
terraform destroy -auto-approve

