cluster_name       = "nimbus-cluster"
cluster_version    = "1.31"
aws_region         = "us-east-1"

availability_zones   = ["us-east-1a", "us-east-1b"]
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24"]

node_instance_type = "t3.xlarge"
node_desired_size  = 2
node_min_size      = 2
node_max_size      = 3
node_disk_size     = 20

db_engine_version = "16.3"
db_instance_class = "db.t3.micro"

redis_engine_version = "7.1"
redis_node_type      = "cache.t3.micro"
