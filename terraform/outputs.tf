output "app_url" {
  description = "URL publica del servicio (DNS del ALB)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "health_url" {
  description = "Endpoint de validacion"
  value       = "http://${aws_lb.app.dns_name}/health"
}

output "status_url" {
  description = "Endpoint que valida la conexion con la base primaria y la replica"
  value       = "http://${aws_lb.app.dns_name}/status"
}

output "alb_dns_name" {
  description = "Nombre DNS del Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group (variable ASG_NAME del pipeline)"
  value       = aws_autoscaling_group.app.name
}

output "target_group_arn" {
  description = "Target Group donde el ALB registra las instancias"
  value       = aws_lb_target_group.app.arn
}

output "availability_zones" {
  description = "Zonas de disponibilidad usadas (variable AZS de la prueba k6)"
  value       = join(",", local.azs)
}

output "vpc_id" {
  description = "ID de la VPC"
  value       = aws_vpc.main.id
}

output "subnets" {
  description = "Subredes por capa"
  value = {
    public      = aws_subnet.public[*].id
    private_app = aws_subnet.private_app[*].id
    private_db  = aws_subnet.private_db[*].id
  }
}

output "security_groups" {
  description = "Security Groups por capa"
  value = {
    alb = aws_security_group.alb.id
    app = aws_security_group.app.id
    db  = aws_security_group.db.id
  }
}

output "db_primary_endpoint" {
  description = "Endpoint privado de la base de datos primaria (escrituras)"
  value       = aws_db_instance.primary.address
}

output "db_replica_endpoint" {
  description = "Endpoint privado de la replica de lectura"
  value       = aws_db_instance.replica.address
}

output "cloudwatch_dashboard_url" {
  description = "Dashboard de CloudWatch con metricas del ALB, ASG y RDS"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
