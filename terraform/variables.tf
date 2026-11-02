variable "aws_region" {
  description = "Region de AWS (AWS Academy Learner Lab permite us-east-1 y us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para el nombre de todos los recursos"
  type        = string
  default     = "dgiti-ef"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Use solo minusculas, numeros y guiones (3 a 21 caracteres)."
  }
}

variable "environment" {
  description = "Nombre del ambiente"
  type        = string
  default     = "academy"
}

# ---------------------------------------------------------------- Red
variable "vpc_cidr" {
  description = "Bloque CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Subredes publicas (ALB y NAT Gateway), una por zona de disponibilidad"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "Subredes privadas para las instancias EC2 de la aplicacion"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "Subredes privadas aisladas para RDS (sin salida a Internet)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

# ---------------------------------------------------------------- Computo
variable "instance_type" {
  description = "Tipo de instancia EC2 de la aplicacion"
  type        = string
  default     = "t3.micro"
}

variable "asg_min_size" {
  description = "Minimo de instancias en el Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Instancias deseadas en el Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximo de instancias en el Auto Scaling Group"
  type        = number
  default     = 4
}

variable "cpu_target_value" {
  description = "Porcentaje de CPU promedio que el escalado automatico intenta mantener"
  type        = number
  default     = 50
}

variable "instance_profile_name" {
  description = "Perfil IAM existente para las instancias (en AWS Academy: LabInstanceProfile). Vacio para no usar perfil."
  type        = string
  default     = "LabInstanceProfile"
}

variable "app_port" {
  description = "Puerto en el que escucha la aplicacion dentro de las instancias"
  type        = number
  default     = 8080
}

variable "app_version" {
  description = "Version de la aplicacion; al cambiarla se crea una nueva version del Launch Template y se hace un instance refresh"
  type        = string
  default     = "1.0.0"
}

variable "repo_url" {
  description = "URL HTTPS del repositorio PUBLICO de GitHub que contiene la carpeta app/"
  type        = string

  validation {
    condition     = can(regex("^https://", var.repo_url))
    error_message = "repo_url debe ser una URL https:// (por ejemplo https://github.com/usuario/repo.git)."
  }
}

variable "repo_branch" {
  description = "Rama del repositorio que se despliega"
  type        = string
  default     = "main"
}

# ---------------------------------------------------------------- Base de datos
variable "db_name" {
  description = "Nombre de la base de datos inicial"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Usuario administrador de RDS"
  type        = string
  default     = "appadmin"
}

variable "db_password" {
  description = "Contrasena de RDS. Se pasa por terraform.tfvars (no versionado) o TF_VAR_db_password"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9]{8,41}$", var.db_password))
    error_message = "La contrasena debe tener entre 8 y 41 caracteres alfanumericos."
  }
}

variable "db_instance_class" {
  description = "Clase de instancia de RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "Version de MySQL"
  type        = string
  default     = "8.0"
}
