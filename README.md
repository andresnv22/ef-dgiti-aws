# EF DGITI – Despliegue, automatización y validación de infraestructura AWS

Servicio web en Python (Flask + Gunicorn) desplegado en AWS con **Terraform**, detrás de un
**Application Load Balancer**, con **Auto Scaling Group** en dos zonas de disponibilidad,
**RDS MySQL con réplica de lectura** en subredes privadas, **pipeline CI/CD en GitHub Actions**,
**prueba de carga con k6** y **monitoreo con CloudWatch**.

## Cómo se cumple cada requisito

| Requisito del enunciado | Dónde está |
|---|---|
| Servicio accesible por endpoint + endpoint de validación | `app/app.py` → `/health`, `/status`, `/api/info`, `/api/visits`, `/api/stress` |
| Código versionado en GitHub | este repositorio |
| BD con réplica y acceso solo desde la red privada | `terraform/main.tf` → `aws_db_instance.primary` + `aws_db_instance.replica`, subredes BD sin ruta a Internet, `SG-DB` solo acepta 3306 desde `SG-App` |
| Disponible ante fallo de una instancia + distribución de tráfico | ALB + ASG (mín. 2, en 2 AZ), health check `/health`, reemplazo automático |
| Controles de acceso de red | 3 Security Groups encadenados: Internet → ALB (80) → EC2 (8080) → RDS (3306) |
| Terraform con `provider.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars.example`, `user_data.sh` | carpeta `terraform/` |
| Pipeline: validación, pruebas, despliegue, secretos | `.github/workflows/ci-cd.yml` |
| Prueba de desempeño (tiempo de respuesta, VUs, % errores, saturación, balanceador) | `loadtest/k6-loadtest.js` y `loadtest/check_balancer.sh` |
| Monitoreo | Dashboard y alarmas de CloudWatch creados por Terraform |
| Diagrama con iconos oficiales AWS | `docs/arquitectura-aws.png` (editable en `docs/arquitectura-aws.drawio`) |
| Guion del video por integrante | `docs/GUION_VIDEO.md` |

## Estructura

```
.
├── .github/workflows/ci-cd.yml   Pipeline (4 etapas)
├── app/
│   ├── app.py                    Servicio Flask
│   ├── requirements*.txt
│   └── tests/                    Pruebas unitarias e integración (pytest)
├── terraform/
│   ├── provider.tf  variables.tf  main.tf  outputs.tf
│   ├── terraform.tfvars.example
│   └── user_data.sh              Arranque de cada EC2 (clona el repo y levanta Gunicorn)
├── loadtest/
│   ├── k6-loadtest.js            Prueba de carga con rampa hasta saturación
│   └── check_balancer.sh         Muestra qué instancia/AZ responde cada solicitud
└── docs/
    ├── arquitectura-aws.png      Diagrama listo para usar
    ├── arquitectura-aws.drawio   Diagrama editable (app.diagrams.net)
    ├── GUION_VIDEO.md / .pdf     Guion de 10 minutos para 2 integrantes
```

## Arquitectura en una frase

El usuario entra por el **Internet Gateway** al **ALB** (subredes públicas). El ALB reparte entre
las **EC2 del ASG** (subredes privadas, una por AZ), que escriben en la **RDS primaria** y leen de la
**réplica** (subredes de datos sin salida a Internet). Las EC2 salen a Internet solo por el
**NAT Gateway** para descargar el código y las dependencias. **CloudWatch** recoge métricas del ALB,
ASG y RDS; **S3** guarda los reportes de pruebas. **GitHub Actions** valida, prueba y despliega.

---

## Paso a paso (cada integrante en su propia cuenta de AWS Academy)

> Requisito de la evaluación: **cada integrante usa su propia cuenta**. Como todo es código, cada
> uno despliega la misma infraestructura en su Learner Lab con los pasos 2 a 4 (unos 25 minutos,
> la mayoría esperando a RDS). Hágalo **el mismo día de la grabación**: las sesiones del lab duran 4 horas.

### 0. Herramientas (una sola vez)

macOS:

```bash
brew install terraform awscli k6 git
```

Windows: instale Terraform, AWS CLI v2, k6 y Git desde sus sitios oficiales, o use WSL.

### 1. Repositorio en GitHub (lo crea quien presenta el pipeline)

> El dueño del repositorio debe ser **el integrante que presenta el CI/CD**: en un repositorio
> personal, los colaboradores no pueden ver ni editar los *Secrets*.

1. Cree un repositorio **público** en GitHub (las EC2 hacen `git clone` sin credenciales).
2. Suba este proyecto:

```bash
git init -b main
git add .
git commit -m "Proyecto EF DGITI"
git remote add origin https://github.com/USUARIO/REPOSITORIO.git
git push -u origin main
```

3. Agregue al otro integrante como colaborador (Settings → Collaborators). Ese integrante clona
   el repositorio y usa la misma `repo_url` en su `terraform.tfvars`.

### 2. Credenciales de AWS Academy

1. Entre a AWS Academy → curso → **Learner Lab** → **Start Lab** y espere el círculo verde.
2. **AWS Details** → **AWS CLI: Show** → copie el bloque completo.
3. Péguelo en `~/.aws/credentials` (reemplazando el contenido de `[default]`).
4. Verifique:

```bash
aws sts get-caller-identity
```

Las credenciales cambian cada vez que se inicia el lab. Si aparece `ExpiredToken`, repita este paso.

### 3. Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edite `terraform.tfvars`: ponga la URL de **su** repositorio en `repo_url` y una contraseña propia en `db_password`.

```bash
terraform init
terraform plan
terraform apply
terraform output
```

`apply` tarda **20 a 25 minutos** (la primaria de RDS y luego la réplica). Al terminar, las
instancias necesitan unos 3 minutos más para instalar la aplicación y pasar el health check.

### 4. Validar el servicio

```bash
APP=$(terraform output -raw app_url)
curl -s $APP/health
curl -s $APP/status
curl -s -X POST $APP/api/visits
curl -s $APP/api/visits
../loadtest/check_balancer.sh $APP 20
```

- `/status` debe mostrar `primary.ok = true` y `replica.ok = true`.
- `POST /api/visits` escribe en la primaria y `GET /api/visits` lee de la réplica (`read_from: replica`).
- `check_balancer.sh` debe mostrar respuestas de **dos instancias distintas** (dos AZ).
- En el navegador, abra `app_url` y recargue: cambia el `instance_id`.

### 5. Pipeline CI/CD (lo configura el integrante que lo presenta, con su cuenta)

En GitHub → **Settings → Secrets and variables → Actions**:

| Tipo | Nombre | Valor |
|---|---|---|
| Secret | `AWS_ACCESS_KEY_ID` | de AWS Details |
| Secret | `AWS_SECRET_ACCESS_KEY` | de AWS Details |
| Secret | `AWS_SESSION_TOKEN` | de AWS Details |
| Secret | `DB_PASSWORD` | la misma de su `terraform.tfvars` |
| Variable | `AWS_DEPLOY_ENABLED` | `true` |
| Variable | `AWS_REGION` | `us-east-1` (opcional) |
| Variable | `PROJECT_NAME` | `dgiti-ef` (opcional, igual a `project_name`) |

Etapas del pipeline:

1. **Validación del código y pruebas unitarias**: `flake8` y `pytest` con cobertura (15 pruebas).
2. **Validación de Terraform**: `fmt -check`, `init`, `validate`.
3. **Preparación del despliegue**: `terraform plan` autenticado con los secretos.
4. **Despliegue**: *instance refresh* gradual del ASG (las nuevas EC2 clonan el último commit),
   **pruebas de integración** contra el ALB y subida de reportes a S3.

En un *pull request* solo corren las etapas 1 y 2, que no usan credenciales.

Para ejecutarlo: haga un commit a `main` o vaya a **Actions → CI-CD → Run workflow**.

> Los secretos del Learner Lab **vencen al cerrar la sesión**. Actualícelos justo antes de grabar.
>
> El plan de la etapa 3 corre sin el *state* local, por eso muestra los recursos a crear
> (`Plan: 46 to add`): sirve para validar credenciales, proveedor y configuración. El despliegue
> real de la aplicación es la etapa 4.

### 6. Prueba de carga y monitoreo

```bash
cd ..   # raíz del repositorio
mkdir -p loadtest/results
k6 run -e BASE_URL=$(terraform -chdir=terraform output -raw app_url) \
  -e AZS=$(terraform -chdir=terraform output -raw availability_zones) \
  --summary-export=loadtest/results/summary.json loadtest/k6-loadtest.js
```

- Rampa de 4 min 20 s: 23 → 60 → 105 → **150 VUs** (saturación durante 1 min 30 s) → 0.
- Cada iteración llama a `/api/info` y a `/api/stress?ms=50` (consume CPU a propósito).
- Umbrales: errores < 5 %, p95 < 1,5 s. Si se superan en la fase de 150 VUs, esa es la **evidencia de saturación**.
- `instance_hits{az:us-east-1a}` y `instance_hits{az:us-east-1b}` muestran **cuántas solicitudes atendió cada AZ**: prueba directa de que el ALB reparte.
- Más o menos carga: `-e MAX_VUS=250` o `-e STRESS_MS=100`.

Mientras corre, abra la URL de `terraform output cloudwatch_dashboard_url`:

| Métrica en el dashboard | Qué demuestra |
|---|---|
| ALB RequestCount | volumen generado por k6 |
| TargetResponseTime (prom. y p95) | el tiempo de respuesta sube al saturar |
| Códigos HTTP 2XX/5XX | el porcentaje de errores |
| HealthyHostCount / RequestCountPerTarget | el ALB reparte entre instancias sanas |
| EC2 CPU del ASG | la CPU supera el 50 % objetivo |
| GroupInServiceInstances | el ASG **escala de 2 a 3 o 4** instancias |
| RDS CPU / conexiones / ReplicaLag | comportamiento de la capa de datos |

También: **EC2 → Target Groups → dgiti-ef-tg → Targets** (instancias *healthy*) y
**EC2 → Auto Scaling Groups → dgiti-ef-asg → Activity** (eventos de escalado).

Guardar el resultado en S3:

```bash
aws s3 cp loadtest/results/summary.json s3://$(terraform -chdir=terraform output -raw artifacts_bucket)/k6/
```

Si no tiene k6, Apache Benchmark sirve como alternativa:

```bash
ab -n 3000 -c 100 "$(terraform -chdir=terraform output -raw app_url)/api/stress?ms=50"
```

### 7. Prueba de alta disponibilidad (opcional, muy útil en el video)

EC2 → Instances → seleccione una instancia `dgiti-ef-app` → **Instance state → Terminate**.
Mientras tanto ejecute `check_balancer.sh` en bucle: el ALB deja de enviarle tráfico, el
servicio sigue respondiendo y el ASG crea una instancia nueva automáticamente.

### 8. Diagrama

- `docs/arquitectura-aws.png`: imagen lista para el video y la entrega.
- `docs/arquitectura-aws.drawio`: fuente editable; se abre en <https://app.diagrams.net>
  (File → Open from → Device). Usa la librería oficial **AWS Architecture Icons** de draw.io.

### 9. Destruir (al terminar la evaluación)

```bash
cd terraform
terraform destroy
```

Costo aproximado mientras está encendido: unos 0,16 USD por hora (NAT, ALB, 2 EC2, 2 RDS).

---

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| Targets *unhealthy* en el Target Group | Espere 3 a 5 minutos tras el `apply`. Si sigue igual, revise que el repositorio sea **público** y que `repo_url` sea correcto. Log de arranque: EC2 → la instancia → Actions → Monitor and troubleshoot → **Get system log**. |
| `ExpiredToken` en Terraform o en el pipeline | Las credenciales del lab vencieron: copie las nuevas de AWS Details (y actualice los secretos de GitHub). |
| `/status` muestra la réplica con `ok: false` | La réplica todavía se está creando o el lab la detuvo. Verifique en RDS que ambas estén *Available*. |
| El pipeline salta las etapas 3 y 4 | Falta la variable `AWS_DEPLOY_ENABLED = true`, o es un *pull request*. |
| `InstanceRefreshInProgress` | Ya había un refresh en curso; el pipeline lo detecta y espera a que termine. |
| Tras reiniciar el lab no responde | El lab detiene recursos al cerrar la sesión. Inicie el lab y espere a que RDS esté *Available* y el ASG tenga 2 instancias *InService*. |

## Pruebas locales

```bash
cd app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
flake8 . && pytest -v
```

Pruebas de integración contra el despliegue:

```bash
APP_URL=http://<alb_dns_name> pytest -m integration -v
```
