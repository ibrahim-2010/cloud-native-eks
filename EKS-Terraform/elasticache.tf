# ──────────────────────────────────────────────
#  ElastiCache — Redis 7
#  Used by: catalog-service (cache), cart-service (sessions)
# ──────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.cluster_name}-redis-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name    = "${var.cluster_name}-redis-subnet-group"
    Project = "nimbus-retail"
  }
}

resource "aws_security_group" "redis" {
  name        = "${var.cluster_name}-redis-sg"
  description = "Redis access from EKS cluster nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.cluster_name}-redis-sg"
    Project = "nimbus-retail"
  }
}

resource "aws_elasticache_cluster" "main" {
  cluster_id           = "${var.cluster_name}-redis"
  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  tags = {
    Name    = "${var.cluster_name}-redis"
    Project = "nimbus-retail"
  }
}
