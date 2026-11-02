// Prueba de carga con k6 contra el Application Load Balancer.
//
// Uso (desde la raiz del repositorio, despues de terraform apply):
//   mkdir -p loadtest/results
//   k6 run -e BASE_URL=$(terraform -chdir=terraform output -raw app_url) \
//     -e AZS=$(terraform -chdir=terraform output -raw availability_zones) \
//     --summary-export=loadtest/results/summary.json loadtest/k6-loadtest.js
//
// Variables opcionales:
//   STRESS_MS  milisegundos de CPU que consume cada llamada a /api/stress (por defecto 50)
//   MAX_VUS    usuarios virtuales en la fase de saturacion (por defecto 150)
//   AZS        zonas del ASG separadas por coma (output availability_zones de Terraform)
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE_URL = (__ENV.BASE_URL || '').replace(/\/$/, '');
const STRESS_MS = parseInt(__ENV.STRESS_MS || '50', 10);
const MAX_VUS = parseInt(__ENV.MAX_VUS || '150', 10);
const AZS = (__ENV.AZS || 'us-east-1a,us-east-1b').split(',');

if (!BASE_URL) {
  throw new Error('Defina BASE_URL, por ejemplo: -e BASE_URL=http://mi-alb.us-east-1.elb.amazonaws.com');
}

// Cuenta cuantas respuestas dio cada zona/instancia: evidencia del reparto del ALB.
const instanceHits = new Counter('instance_hits');

const thresholds = {
  http_req_failed: ['rate<0.05'],          // menos de 5 % de errores
  http_req_duration: ['p(95)<1500'],       // p95 por debajo de 1.5 s
  'http_req_duration{endpoint:info}': ['p(95)<1000'],
};
// Un sub-umbral por zona hace que el resumen muestre las solicitudes atendidas en cada AZ.
for (const az of AZS) {
  thresholds[`instance_hits{az:${az.trim()}}`] = ['count>0'];
}

export const options = {
  scenarios: {
    rampa: {
      executor: 'ramping-vus',
      startVUs: 0,
      // Duracion total: 4 min 20 s
      stages: [
        { duration: '30s', target: Math.round(MAX_VUS * 0.15) }, // calentamiento
        { duration: '1m', target: Math.round(MAX_VUS * 0.4) },   // carga normal
        { duration: '1m', target: Math.round(MAX_VUS * 0.7) },   // carga alta
        { duration: '1m30s', target: MAX_VUS },                  // saturacion
        { duration: '20s', target: 0 },                         // recuperacion
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'max'],
};

export default function () {
  const info = http.get(`${BASE_URL}/api/info`, { tags: { endpoint: 'info' } });
  const ok = check(info, {
    'info responde 200': (r) => r.status === 200,
    'info trae instance_id': (r) => r.status === 200 && !!r.json('instance_id'),
  });
  if (ok) {
    instanceHits.add(1, {
      az: info.json('availability_zone'),
      instance: info.json('instance_id'),
    });
  }

  const stress = http.get(`${BASE_URL}/api/stress?ms=${STRESS_MS}`, { tags: { endpoint: 'stress' } });
  check(stress, { 'stress responde 200': (r) => r.status === 200 });

  sleep(0.5);
}
