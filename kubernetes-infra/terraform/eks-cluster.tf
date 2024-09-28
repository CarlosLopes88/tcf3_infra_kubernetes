provider "aws" {
  region = "us-east-1"
}

# Verificar se o IAM Role para o EKS Cluster já existe
data "aws_iam_role" "eks_role_existing" {
  name = "eks-cluster-role"
}

# Criar o IAM Role para o EKS Cluster, caso não exista
resource "aws_iam_role" "eks_role" {
  count = length(data.aws_iam_role.eks_role_existing.name) == 0 ? 1 : 0
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

# Anexar a política necessária para o IAM Role do EKS Cluster
resource "aws_iam_role_policy_attachment" "eks_policy_attach" {
  count = length(data.aws_iam_role.eks_role_existing.name) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_role.name
}

# Verificar se o IAM Role para o Node Group já existe
data "aws_iam_role" "eks_node_role_existing" {
  name = "eks-node-group-role"
}

# Criar o IAM Role para o Node Group, caso não exista
resource "aws_iam_role" "eks_node_role" {
  count = length(data.aws_iam_role.eks_node_role_existing.name) == 0 ? 1 : 0
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Anexar as políticas para o Node Group
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  count = length(data.aws_iam_role.eks_node_role_existing.name) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  count = length(data.aws_iam_role.eks_node_role_existing.name) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_ec2_container_registry_policy" {
  count = length(data.aws_iam_role.eks_node_role_existing.name) == 0 ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

# Criar o EKS Cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = "my-eks-cluster"
  role_arn = aws_iam_role.eks_role.arn

  vpc_config {
    subnet_ids = aws_subnet.eks_subnets[*].id
  }

  version    = "1.27"  # Ajuste conforme a versão do EKS que deseja utilizar
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.eks_policy_attach]
}

# Node Group (grupo de nós) do Kubernetes
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "eks-node-group"
  node_role       = aws_iam_role.eks_node_role.arn
  subnets         = aws_subnet.eks_subnets[*].id

  scaling_config {
    desired_size = 1  # Limite de 1 nó para evitar custos adicionais
    max_size     = 2
    min_size     = 1
  }

  ami_type        = "AL2_x86_64"
  instance_types  = ["t3.medium"]  # Instâncias compatíveis com o nível gratuito
  disk_size       = 20  # Definir o tamanho do disco conforme necessário

  depends_on = [aws_eks_cluster.eks_cluster]
}

# VPC e subnets para o EKS Cluster (se já não estiverem criadas em outro lugar)
resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "eks-vpc"
  }
}

resource "aws_subnet" "eks_subnets" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  vpc_id            = aws_vpc.eks_vpc.id
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

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

# Tabela de Rotas para a VPC
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

# Associação da Tabela de Rotas às Subnets
resource "aws_route_table_association" "eks_route_table_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnets[count.index].id
  route_table_id = aws_route_table.eks_route_table.id
}

# Data source para obter as zonas de disponibilidade
data "aws_availability_zones" "available" {}