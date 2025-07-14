provider "kubernetes" {
  host = data.aws_eks_cluster.tasky-cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.tasky-cluster.certificate_authority[0].data)
  token = data.aws_eks_cluster_auth.tasky-cluster-auth.token  
}

locals {
  cluster_name = "wiz-eks-tasky"
}

## Datasources req for deployement of CRB, SVC, and Tasky Deployment
data "aws_eks_cluster" "tasky-cluster" {
  name = local.cluster_name
}

data "aws_eks_cluster_auth" "tasky-cluster-auth" {
  name = local.cluster_name
}

data "aws_instance" "mongodb-instance" {
  filter {
    name   = "tag:Name"
    values = ["mongodb-host"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

## Removing for now. (See note in the wiz-eks-asky.tf for more info.  Also update lines 153 and 154 accordingly.)
# data "aws_network_interface" "mongodb-2nd-network-interface" {
#   filter {
#     name   = "tag:Name"
#     values = ["mongodb-secondary-eni"]
#   }
#   filter {
#     name   = "status"
#     values = ["in-use"]
#   }
# }

# # Try to create the 2nd nework interface here vs when the instance is getting created
# data "aws_security_group" "mongodb_sg" {
#   name = "mongodb_sg"
# }

# data "aws_subnet" "tasky_private_subnet" {
#   filter {
#     name = "tag:Name"
#     values = ["wiz-eks-tasky-vpc-private-us-east-1a"]
#   }
# }

## Removing 2nd Option... both result in an interface being added to the instance and IP assigned according to the console; however,
## the actual instance is not configured with an IP address on the new en1 interface. Restarting the interface or instance results in
## an IPv6 address being assigned (while the AWS Console is still showing the intended IPv4 address). Line 155 set back to 153.
# resource "aws_network_interface" "mongodb-host-private-eni" {
#   depends_on = [ data.aws_instance.mongodb-instance, data.aws_security_group.mongodb_sg, data.aws_subnet.tasky_private_subnet]
#   subnet_id       = data.aws_subnet.tasky_private_subnet.id
#   security_groups = [data.aws_security_group.mongodb_sg.id]

#   attachment {
#     instance     = data.aws_instance.mongodb-instance.id
#     device_index = 1
#   }
#   tags = {
#     Name = "mongodb-secondary-eni"
#   }
# }

## Add Permissive Cluster Role Binding for ALL Service Accounts
resource "kubernetes_cluster_role_binding" "permissive" {
  depends_on = [ data.aws_eks_cluster.tasky-cluster ]
  metadata {
    name = "permissive-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "User"
    name      = "admin"
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "User"
    name      = "kubelet"
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "Group"
    name      = "system:serviceaccounts"
    api_group = "rbac.authorization.k8s.io"
  }
}



## K8s Service and AWS LB for Accessing Tasky UI

resource "kubernetes_service" "lb-tasky" {
  depends_on = [ data.aws_eks_cluster.tasky-cluster ]
  metadata {
    name = "lb-tasky"
  }
  spec {
    port {
      port        = 80
      target_port = 8080
    }
    type = "LoadBalancer"
    selector = {
      app = "tasky"
    }
  }
}


## Tasky Deployment

resource "kubernetes_deployment" "tasky-deployment" {
  depends_on = [ kubernetes_cluster_role_binding.permissive, kubernetes_service.lb-tasky ]
  metadata {
    name = "tasky-deployment"
    labels = {
      app = "tasky"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "tasky"
      }
    }
    template {
      metadata {
        labels = {
          app = "tasky"
        }
      }
      spec {
        container {
          image = "judch01/tasky:latest"
          name  = "tasky"
          env {
            name = "MONGODB_URI"
#            value = "mongodb://administrator:password@${data.aws_network_interface.mongodb-2nd-network-interface.private_dns_name}:27017/?authSource=admin"
            value = "mongodb://administrator:password@${data.aws_instance.mongodb-instance.private_dns}:27017/?authSource=admin"
#            value = "mongodb://administrator:password@${aws_network_interface.mongodb-host-private-eni.private_dns_name}:27017/?authSource=admin"
          }
          env {
            name = "SECRET_KEY"
            value = "53crE7$"
          }
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}