# Provedor AWS: define o provedor da AWS e a região onde os recursos serão provisionados.
provider "aws" {
  region = "us-east-1"  # Altere conforme a região que você preferir.
}

# Criação do Cluster EKS
resource "aws_eks_cluster" "eks_cluster" {
  name     = "my-eks-cluster"  # Nome do cluster EKS.
  role_arn = aws_iam_role.eks_role.arn  # ARN da role associada ao cluster, fornecendo permissões.

  # Configura as subnets onde o cluster EKS será criado.
  vpc_config {
    subnet_ids = aws_subnet.eks_subnets[*].id  # Usa as subnets criadas anteriormente.
  }

  version = "1.30"  # Versão do Kubernetes no EKS. Ajuste conforme a versão necessária.

  # Habilita tipos específicos de logs para o cluster (API, auditoria e autenticador).
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # O recurso depende da política IAM estar anexada antes de ser criado.
  depends_on = [aws_iam_role_policy_attachment.eks_policy_attach]
}

# Criação do Node Group (grupo de nós) para o cluster EKS
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name  # Nome do cluster ao qual o grupo de nós está associado.
  node_group_name = "eks-node-group"  # Nome do Node Group.
  node_role_arn   = aws_iam_role.eks_node_role.arn  # ARN da role do Node Group.

  # Definição das subnets onde os nós do cluster serão executados.
  subnet_ids = aws_subnet.eks_subnets[*].id

  # Configuração de escalabilidade para o Node Group.
  scaling_config {
    desired_size = 2  # Número desejado de nós.
    max_size     = 5  # Número máximo de nós.
    min_size     = 1  # Número mínimo de nós.
  }

  # Configuração do tipo de AMI e instância para os nós do EKS.
  ami_type       = "AL2_x86_64"  # AMI usada (Amazon Linux 2, arquitetura x86_64).
  instance_types = ["t2.small"]  # Tipo de instância EC2 (ajuste conforme a carga de trabalho).
  disk_size      = 8  # Tamanho do disco em GB.

  depends_on = [aws_eks_cluster.eks_cluster]  # O Node Group só pode ser criado após o cluster EKS.
}

# IAM Role para o Cluster EKS
resource "aws_iam_role" "eks_role" {
  name = "eks-cluster-role"  # Nome da role IAM para o cluster.

  # Política que permite ao EKS assumir a role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"  # O serviço EKS pode assumir essa role.
        }
      }
    ]
  })
}

# Anexar a política necessária para o cluster EKS
resource "aws_iam_role_policy_attachment" "eks_policy_attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"  # Política padrão para clusters EKS.
  role       = aws_iam_role.eks_role.name  # Associa a política à role do cluster.
}

# IAM Role para o Node Group do EKS (para as instâncias EC2)
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role"  # Nome da role para os nós (EC2).

  # Política que permite ao EC2 assumir essa role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"  # O serviço EC2 pode assumir essa role.
        }
      }
    ]
  })
}

# Anexar a política necessária para os nós do EKS (EC2)
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"  # Política necessária para os nós do EKS.
  role       = aws_iam_role.eks_node_role.name  # Associa a política à role dos nós.
}

# Anexar a política CNI para permitir a comunicação entre os containers no EKS.
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"  # Política de rede para containers.
  role       = aws_iam_role.eks_node_role.name  # Associa a política à role dos nós.
}

# Anexar a política que permite acesso ao Amazon EC2 Container Registry (ECR).
resource "aws_iam_role_policy_attachment" "eks_ec2_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"  # Política para acesso de leitura ao ECR.
  role       = aws_iam_role.eks_node_role.name  # Associa a política à role dos nós.
}

# Criação da VPC (Virtual Private Cloud) para o cluster EKS
resource "aws_vpc" "eks_vpc" {
  cidr_block = "10.0.0.0/16"  # Faixa de endereços IP para a VPC.
  tags = {
    Name = "eks-vpc"  # Nome da VPC.
  }
}

# Criação das subnets para a VPC, cada uma em uma zona de disponibilidade diferente
resource "aws_subnet" "eks_subnets" {
  count             = 2  # Cria duas subnets.
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)  # Define a faixa de IP para cada subnet.
  vpc_id            = aws_vpc.eks_vpc.id  # Associa as subnets à VPC.
  availability_zone = element(data.aws_availability_zones.available.names, count.index)  # Distribui as subnets em zonas de disponibilidade diferentes.

  map_public_ip_on_launch = true  # Habilita IP público para instâncias lançadas nessas subnets.

  tags = {
    Name = "eks-subnet-${count.index + 1}"  # Nome da subnet, identificada pelo índice.
  }
}

# Internet Gateway para a VPC (necessário para conectar à internet)
resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id  # Associa o Internet Gateway à VPC.
  tags = {
    Name = "eks-internet-gateway"  # Nome do Internet Gateway.
  }
}

# Tabela de rotas para a VPC, permitindo tráfego para a internet
resource "aws_route_table" "eks_route_table" {
  vpc_id = aws_vpc.eks_vpc.id  # Associa a tabela de rotas à VPC.

  # Cria uma rota para tráfego de saída para a internet.
  route {
    cidr_block = "0.0.0.0/0"  # Permite tráfego para qualquer IP.
    gateway_id = aws_internet_gateway.eks_igw.id  # Direciona o tráfego para o Internet Gateway.
  }

  tags = {
    Name = "eks-route-table"  # Nome da tabela de rotas.
  }
}

# Associação da Tabela de Rotas às Subnets
resource "aws_route_table_association" "eks_route_table_association" {
  count          = 2  # Cria a associação para as duas subnets.
  subnet_id      = aws_subnet.eks_subnets[count.index].id  # Associa cada subnet à tabela de rotas.
  route_table_id = aws_route_table.eks_route_table.id  # Especifica a tabela de rotas.
}

# Data source para obter as zonas de disponibilidade disponíveis
data "aws_availability_zones" "available" {}