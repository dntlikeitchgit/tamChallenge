# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "wiz-eks-tasky"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "wiz-eks-tasky-vpc"

  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.4.0/28", "10.0.5.0/28"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  ## Removing for now... Prefix deligation doesn't appear to get applied as documented.
  # cluster_addons = {
  #   vpc-cni = {
  #     most_recent = true  
  #     before_compute = true
  #     configuration_values = jsonencode({
  #       env = {
  #         # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
  #         ENABLE_PREFIX_DELEGATION = "true"
  #         WARM_PREFIX_TARGET       = "1"
  #       }
  #     })
  #   }
  # }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    wiz-eks-tasky-ng = {
      instance_types       = ["t2.micro"]

      min_size             = 1
      max_size             = 2
      desired_size         = 2
      
    }
  }
}



## Create S3 Bucket for MongoDB Dumps ##

resource "aws_s3_bucket" "cjudd-wiz-mongo-backups" {
  bucket = "cjudd-wiz-mongo-backups"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "enable_public_access" {
    bucket = aws_s3_bucket.cjudd-wiz-mongo-backups.id
}

resource "aws_s3_bucket_policy" "allow_read_from_all" {
  depends_on = [ aws_s3_bucket_public_access_block.enable_public_access ]
  bucket = aws_s3_bucket.cjudd-wiz-mongo-backups.id
  policy = data.aws_iam_policy_document.allow_read_from_all.json
}
data "aws_iam_policy_document" "allow_read_from_all" {
  statement {
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.cjudd-wiz-mongo-backups.arn,
      "${aws_s3_bucket.cjudd-wiz-mongo-backups.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_website_configuration" "static_website_configuration" {
  bucket = aws_s3_bucket.cjudd-wiz-mongo-backups.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_cors_configuration" "cors_rules" {
  bucket = aws_s3_bucket.cjudd-wiz-mongo-backups.id

  cors_rule {
    allowed_headers = ["*s"]
    allowed_methods = ["GET"]
    allowed_origins = ["http://${aws_s3_bucket.cjudd-wiz-mongo-backups.id}.s3-website-us-east-1.amazonaws.com"]
    expose_headers  = ["x-amz-server-side-encryption", "x-amz-request-id", "x-amz-id-2"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_object" "index_file" {
  depends_on = [ aws_s3_bucket.cjudd-wiz-mongo-backups ]
  bucket = "cjudd-wiz-mongo-backups"
  key = "index.html"
  source = "${path.module}/index.html"
  content_type = "text/html"
}



## Deploy EC2 Intance for MongoDB into EKS VPC (And Related Resources)##

# Set data source to get ARN for the AdministratorAccess AWS managed policy (Used in MongoDB instance creation)
data "aws_iam_policy" "FullAdminAccess" {
#  arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  name = "AdministratorAccess"
}

# Create IAM 'Assume' Role w/Full Admin access poilcy for attachment to MongoDB Instance
resource "aws_iam_role" "assume_admin_role" {
  name = "assume_admin_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    Name = "mongodb-host"
  }
  # Attach the AWS Managed policy for Full Admin Access (AdministratorAccess) to the Role
  # managed_policy_arns = [data.aws_iam_policy.FullAdminAccess.arn]
}

# Attach the AWS Managed policy for Full Admin Access (AdministratorAccess) to the Role
resource "aws_iam_role_policy_attachment" "assume_admin_role" {
  role       = aws_iam_role.assume_admin_role.name
  policy_arn = data.aws_iam_policy.FullAdminAccess.arn
}


# Create the IAM Instance Profile for above Role / Policy combo - To be referenced in the MongoDB instance creation.
resource "aws_iam_instance_profile" "mongodb-iam-instance-profile" {
  name = "mongodb-iam-instance-profile"
  role = aws_iam_role.assume_admin_role.name
}

# Security Group for MongoDB EC2 Instance
resource "aws_security_group" "mongodb_sg" {
  depends_on  = [ module.vpc ]
  name        = "mongodb_sg"
  description = "Security group for MongoDB EC2 instance"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = ["64.99.200.69/32"]
  }
  ingress {
    from_port = 27017
    to_port   = 27017
    protocol  = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
   }
}

# Create MongoDB EC2 Instance
resource "aws_instance" "mongodb" {
  depends_on = [ aws_security_group.mongodb_sg, aws_iam_instance_profile.mongodb-iam-instance-profile ]
  ami             = "ami-0a0e5d9c7acc336f1" # Ubuntu 22.04 LTS
  instance_type   = "t2.micro"
  key_name        = "EC2-default"
  metadata_options {
    http_tokens = "required"
  }
  iam_instance_profile = aws_iam_instance_profile.mongodb-iam-instance-profile.name
#  subnet_id       = module.vpc.public_subnets[0]
  subnet_id       = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.mongodb_sg.id]
#  associate_public_ip_address = true
  user_data = <<-EOF
              #!/bin/bash

              # Set Apt Config and Install MongoDB / Other Required Packages
              sudo apt-get install -y gnupg curl
              curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | \
              sudo gpg -o /usr/share/keyrings/mongodb-server-6.0.gpg --dearmor
              echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
              sudo apt-get update
              sudo apt-get install -y mongodb-org=6.0.16 mongodb-org-database=6.0.16 mongodb-org-server=6.0.16 mongodb-org-mongos=6.0.16 mongodb-org-tools=6.0.16

              # Prohibit MongoDB Updates
              echo "mongodb-org hold" | sudo dpkg --set-selections
              echo "mongodb-org-database hold" | sudo dpkg --set-selections
              echo "mongodb-org-server hold" | sudo dpkg --set-selections
              echo "mongodb-mongosh hold" | sudo dpkg --set-selections
              echo "mongodb-org-mongos hold" | sudo dpkg --set-selections
              echo "mongodb-org-tools hold" | sudo dpkg --set-selections

              # Start / Enable MongoDB
              sleep 10
              sudo systemctl start mongod.service
              sudo systemctl enable mongod.service

              # Create MongoDB Script to Create Admin User
              echo 'db = connect( "mongodb://localhost:27017/admin" ); _
              db.createUser( _
                { _
                  user: "administrator", _
                  pwd: "password", _
                  roles: [ _
                    { role: "userAdminAnyDatabase", db: "admin" }, _
                    { role: "readWriteAnyDatabase", db: "admin" }, _
                    { role: "backup", db: "admin" } _
                  ] _
                } _
              ); _
              db.adminCommand( { shutdown: 1 } );' > /home/ubuntu/create_user.js

              # Remove Line Continuation Characters
              su - ubuntu -c "sed -i -e 's/ \_//g' /home/ubuntu/create_user.js"
              chown ubuntu:ubuntu /home/ubuntu/create_user.js

              # Run Script to Create Admin User
              sleep 10
              su - ubuntu -c "mongosh --file /home/ubuntu/create_user.js  >/home/ubuntu/mongoUserCreate.out 2>&1"

              # Update IP bind config, set SCRAM Auth, and restart MongoDB
              sed -i -e 's/127.0.0.1/0.0.0.0/' /etc/mongod.conf
              sed -i -e 's/#security:/security:\n     authorization: enabled/' /etc/mongod.conf
              sleep 10
              sudo systemctl restart mongod.service

              # Install AWS CLI (Uses attached Instance Profile for security)
              sudo snap install aws-cli --classic
              
              # Create MongoDB Dump Script
              echo '#!/bin/bash _
              MONGODUMP_BIN_PATH="/usr/bin/mongodump" _
              DUMP_PATH="/home/ubuntu/mongodb-backups" _
              S3_BUCKET_URI="s3://${aws_s3_bucket.cjudd-wiz-mongo-backups.id}/" _
               _
              ## Create backup _
              $MONGODUMP_BIN_PATH --host=$(hostname -s) --authenticationDatabase "admin" --username=administrator --password=password --out=$DUMP_PATH --gzip _
               _
              ## Upload to S3 _
              aws s3 mv --recursive $DUMP_PATH $S3_BUCKET_URI' > /home/ubuntu/mongodb-dump.sh

              # Strip Line Continuation Character and Make Executable
              sed -i -e 's/ \_//g' /home/ubuntu/mongodb-dump.sh
              chown ubuntu:ubuntu /home/ubuntu/mongodb-dump.sh
              chmod +x /home/ubuntu/mongodb-dump.sh

              # Create Nightly Cron Job for DB Dump
              su - ubuntu -c 'CRONCMD="/home/ubuntu/mongodb-dump.sh" && CRONJOB="00 00 * * * $CRONCMD" &&cat <(fgrep -i -v "$CRONCMD" <(crontab -l >/dev/null 2>&1)) <(echo "$CRONJOB") | crontab -'
              EOF
 tags = {
    Name = "mongodb-host"
 }
}

## Removing for now. Interface is deployed and attached... and AWS Console shows correct IP assigned, but 
## actual interface in MongoDB instance doesn't have an address assigned (or sometimes gets and IPv6 address).
# resource "aws_network_interface" "mongodb-host-private-eni" {
#   depends_on = [ aws_instance.mongodb ]
#   subnet_id       = module.vpc.private_subnets[0]
#   security_groups = [aws_security_group.mongodb_sg.id]

#   attachment {
#     instance     = aws_instance.mongodb.id
#     device_index = 1
#   }
#   tags = {
#     Name = "mongodb-secondary-eni"
#   }
# }
