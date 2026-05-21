# ── VPC for Redshift Serverless ───────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${local.prefix}-vpc"
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_subnet" "redshift_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${local.prefix}-subnet-a"
  }
}

resource "aws_subnet" "redshift_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${local.prefix}-subnet-b"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.prefix}-igw"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.prefix}-rt"
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.redshift_a.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.redshift_b.id
  route_table_id = aws_route_table.main.id
}

# ── Security group — allow your IP + QuickSight ───────────────────────────────
resource "aws_security_group" "redshift" {
  name        = "${local.prefix}-redshift-sg"
  description = "Redshift Serverless access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Redshift port from your IP"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [var.your_ip_cidr]
  }

  # QuickSight CIDR for us-east-1
  ingress {
    description = "QuickSight us-east-1"
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = ["52.23.63.224/27"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.prefix}-redshift-sg"
    Project     = var.project_name
    Environment = var.environment
  }
}

# ── Redshift Serverless namespace ─────────────────────────────────────────────
resource "aws_redshiftserverless_namespace" "main" {
  namespace_name      = "${local.prefix}-namespace"
  db_name             = "ecomm_db"
  admin_username      = var.redshift_admin_username
  admin_user_password = var.redshift_admin_password
  iam_roles           = [aws_iam_role.redshift.arn]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# ── Redshift Serverless workgroup ─────────────────────────────────────────────
resource "aws_redshiftserverless_workgroup" "main" {
  namespace_name = aws_redshiftserverless_namespace.main.namespace_name
  workgroup_name = "${local.prefix}-workgroup"

  base_capacity      = 4    # 4""" RPUs — minimum, cheapest for dev
  publicly_accessible = true

  subnet_ids         = [aws_subnet.redshift_a.id, aws_subnet.redshift_b.id]
  security_group_ids = [aws_security_group.redshift.id]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
