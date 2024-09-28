provider "aws" {
  region = "us-east-1"
}

# Verificando se a Role do cluster EKS já existe
data "aws_iam_role" "existing_eks_role" {
  name = "eks-cluster-role"
}

resource "aws_iam_role" "eks_role" {
  count = length(try(data.aws_iam_role.existing_eks_role.id, [])) == 0 ? 1 : 0
  name  = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

# Verificando se a Role do Node Group já existe
data "aws_iam_role" "existing_node_role" {
  name = "eks-node-group-role"
}

resource "aws_iam_role" "eks_node_role" {
  count = length(try(data.aws_iam_role.existing_node_role.id, [])) == 0 ? 1 : 0
  name  = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Anexando a política necessária para o cluster EKS
resource "aws_iam_role_policy_attachment" "eks_policy_attach" {
  count      = length(try(data.aws_iam_role.existing_eks_role.id, [])) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = coalesce(data.aws_iam_role.existing_eks_role.name, aws_iam_role.eks_role[count.index].name)
}

# Anexando as políticas necessárias para o Node Group
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  count      = length(try(data.aws_iam_role.existing_node_role.id, [])) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = coalesce(data.aws_iam_role.existing_node_role.name, aws_iam_role.eks_node_role[count.index].name)
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  count      = length(try(data.aws_iam_role.existing_node_role.id, [])) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = coalesce(data.aws_iam_role.existing_node_role.name, aws_iam_role.eks_node_role[count.index].name)
}

resource "aws_iam_role_policy_attachment" "eks_ec2_container_registry_policy" {
  count      = length(try(data.aws_iam_role.existing_node_role.id, [])) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = coalesce(data.aws_iam_role.existing_node_role.name, aws_iam_role.eks_node_role[count.index].name)
}

# Definindo o cluster EKS
resource "aws_eks_cluster" "eks_cluster" {
  name     = "my-eks-cluster"
  role_arn = coalesce(data.aws_iam_role.existing_eks_role.arn, aws_iam_role.eks_role[0].arn)

  vpc_config {
    subnet_ids = aws_subnet.eks_subnets[*].id
  }

  version                  = "1.27"
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_policy_attach]
}

# Definindo o Node Group do EKS
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "eks-node-group"
  node_role_arn   = coalesce(data.aws_iam_role.existing_node_role.arn, aws_iam_role.eks_node_role[0].arn)
  subnet_ids      = aws_subnet.eks_subnets[*].id

  scaling_config {
    desired_size = 1
    max_size     = 1
    min_size     = 1
  }

  ami_type       = "AL2_x86_64"
  instance_types = ["t2.micro"]
  disk_size      = 8

  depends_on = [aws_eks_cluster.eks_cluster]
}

# Criação da VPC
resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "eks-vpc"
  }
}

# Subnets com IP público automaticamente atribuído
resource "aws_subnet" "eks_subnets" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  vpc_id            = aws_vpc.eks_vpc.id
  availability_zone = element(data.aws_availability_zones.available.names, count.index)
  
  map_public_ip_on_launch = true  # Habilitar atribuição automática de IP público

  tags = {
    Name = "eks-subnet-${count.index + 1}"
  }
}

# Internet Gateway para a VPC
resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = {
    Name = "eks-internet-gateway"
  }
}

# Tabela de rotas para a VPC
resource "aws_route_table" "eks_route_table" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks_igw.id
  }

  tags = {
    Name = "eks-route-table"
  }
}

# Associação da Tabela de Rotas com as Subnets
resource "aws_route_table_association" "eks_route_table_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnets[count.index].id
  route_table_id = aws_route_table.eks_route_table.id
}

# Data source para obter as zonas de disponibilidade
data "aws_availability_zones" "available" {}