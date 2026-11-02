data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name = var.project_name
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

# =====================================================================
# RED: VPC con 3 capas (publica, privada de aplicacion, privada de datos)
# =====================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private_app" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-app-${local.azs[count.index]}", Tier = "private-app" }
}

resource "aws_subnet" "private_db" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-db-${local.azs[count.index]}", Tier = "private-db" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

# Las instancias privadas salen a Internet (git clone, dnf, pip) por el NAT Gateway.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-private-app" }
}

# Tabla sin ruta por defecto: la capa de datos no tiene salida a Internet.
resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-private-db" }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_app" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table_association" "private_db" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}

# =====================================================================
# SEGURIDAD: Security Groups encadenados (Internet -> ALB -> EC2 -> RDS)
# =====================================================================
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB: HTTP desde Internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "EC2: trafico de la aplicacion solo desde el ALB"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-app-sg" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "RDS: MySQL solo desde las instancias de la aplicacion"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP publico"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Hacia las instancias de la aplicacion"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Solo el ALB puede llegar a la aplicacion"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS saliente (GitHub, pip, repositorios dnf) via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP saliente para repositorios de paquetes via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "MySQL hacia RDS"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL solo desde la capa de aplicacion"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# =====================================================================
# BASE DE DATOS: RDS MySQL primaria + replica de lectura en otra AZ
# =====================================================================
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.private_db[*].id
  tags       = { Name = "${local.name}-db-subnets" }
}

resource "aws_db_instance" "primary" {
  identifier              = "${local.name}-db"
  engine                  = "mysql"
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp2"
  storage_encrypted       = true
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  availability_zone       = local.azs[0]
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 1 # requerido para poder crear la replica
  apply_immediately       = true
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = { Name = "${local.name}-db-primary", Role = "primary" }
}

resource "aws_db_instance" "replica" {
  identifier             = "${local.name}-db-replica"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.db_instance_class
  storage_encrypted      = true
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = local.azs[1]
  publicly_accessible    = false
  apply_immediately      = true
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = { Name = "${local.name}-db-replica", Role = "read-replica" }
}

# =====================================================================
# BALANCEO: Application Load Balancer en subredes publicas
# =====================================================================
resource "aws_lb" "app" {
  name                       = "${local.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name}-tg"
  port                 = var.app_port
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# =====================================================================
# COMPUTO: Launch Template + Auto Scaling Group en subredes privadas
# =====================================================================
resource "aws_launch_template" "app" {
  name_prefix            = "${local.name}-lt-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]
  update_default_version = true

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    repo_url        = var.repo_url
    repo_branch     = var.repo_branch
    app_port        = var.app_port
    app_version     = var.app_version
    db_host         = aws_db_instance.primary.address
    db_replica_host = aws_db_instance.replica.address
    db_name         = var.db_name
    db_user         = var.db_username
    db_password     = var.db_password
  }))

  dynamic "iam_instance_profile" {
    for_each = var.instance_profile_name == "" ? [] : [var.instance_profile_name]
    content {
      name = iam_instance_profile.value
    }
  }

  # ALMACENAMIENTO: disco raiz EBS gp3 cifrado en cada instancia.
  # (AWS Academy bloquea s3:GetBucketObjectLockConfiguration con una SCP, por lo que
  # Terraform no puede gestionar buckets S3 en el Learner Lab.)
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true # metricas de EC2 cada 1 minuto en CloudWatch
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 obligatorio
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-app", Project = var.project_name }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-app-volume", Project = var.project_name }
  }

  lifecycle {
    # La AMI se fija al crear; asi un "plan" posterior no reemplaza instancias por sorpresa.
    ignore_changes = [image_id]
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-asg"
  vpc_zone_identifier       = aws_subnet.private_app[*].id
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 120
  metrics_granularity       = "1Minute"
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Cada cambio del Launch Template reemplaza las instancias de forma gradual.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-app"
    propagate_at_launch = true
  }

  lifecycle {
    # El escalado automatico cambia la capacidad deseada; Terraform no la revierte.
    ignore_changes = [desired_capacity]
  }

  # Las instancias necesitan salida a Internet (NAT) desde el primer arranque.
  depends_on = [aws_route_table_association.private_app]
}

resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target_value
  }
}

# =====================================================================
# MONITOREO: alarmas y dashboard de CloudWatch
# =====================================================================
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  alarm_description   = "Hay instancias que no pasan el health check del ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-target-5xx"
  alarm_description   = "Errores 5XX generados por la aplicacion"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${local.name}-latency-p95"
  alarm_description   = "Tiempo de respuesta p95 mayor a 1 segundo"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.app.arn_suffix
  }
}

locals {
  alb_dim = ["LoadBalancer", aws_lb.app.arn_suffix]
  tg_dims = ["TargetGroup", aws_lb_target_group.app.arn_suffix, "LoadBalancer", aws_lb.app.arn_suffix]
  asg_dim = ["AutoScalingGroupName", aws_autoscaling_group.app.name]

  dashboard_widgets = [
    {
      title   = "ALB - Solicitudes por minuto"
      metrics = [concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim, [{ stat = "Sum", label = "Solicitudes" }])]
    },
    {
      title = "ALB - Tiempo de respuesta (s)"
      metrics = [
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "Average", label = "Promedio" }]),
        concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p95", label = "p95" }]),
      ]
    },
    {
      title = "ALB - Codigos HTTP"
      metrics = [
        concat(["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count"], local.alb_dim, [{ stat = "Sum", label = "2XX" }]),
        concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb_dim, [{ stat = "Sum", label = "5XX app" }]),
        concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb_dim, [{ stat = "Sum", label = "5XX ALB" }]),
      ]
    },
    {
      title = "Target Group - Instancias sanas / solicitudes por instancia"
      metrics = [
        concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg_dims, [{ stat = "Minimum", label = "Sanas" }]),
        concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg_dims, [{ stat = "Maximum", label = "No sanas" }]),
        ["AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", aws_lb_target_group.app.arn_suffix, { stat = "Sum", label = "Solicitudes por instancia", yAxis = "right" }],
      ]
    },
    {
      title = "EC2 (ASG) - CPU %"
      metrics = [
        concat(["AWS/EC2", "CPUUtilization"], local.asg_dim, [{ stat = "Average", label = "CPU promedio" }]),
        concat(["AWS/EC2", "CPUUtilization"], local.asg_dim, [{ stat = "Maximum", label = "CPU maxima" }]),
      ]
    },
    {
      title = "Auto Scaling - Instancias"
      metrics = [
        concat(["AWS/AutoScaling", "GroupInServiceInstances"], local.asg_dim, [{ stat = "Maximum", label = "En servicio" }]),
        concat(["AWS/AutoScaling", "GroupDesiredCapacity"], local.asg_dim, [{ stat = "Maximum", label = "Deseadas" }]),
      ]
    },
    {
      title = "RDS - CPU % y conexiones"
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.primary.identifier, { label = "CPU primaria" }],
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.replica.identifier, { label = "CPU replica" }],
        ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", aws_db_instance.primary.identifier, { label = "Conexiones primaria", yAxis = "right" }],
      ]
    },
    {
      title   = "RDS - Retraso de la replica (s)"
      metrics = [["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", aws_db_instance.replica.identifier, { stat = "Maximum", label = "ReplicaLag" }]]
    },
  ]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      for i, w in local.dashboard_widgets : {
        type   = "metric"
        x      = (i % 2) * 12
        y      = floor(i / 2) * 6
        width  = 12
        height = 6
        properties = {
          title   = w.title
          metrics = w.metrics
          view    = "timeSeries"
          stacked = false
          region  = var.aws_region
          period  = 60
        }
      }
    ]
  })
}
